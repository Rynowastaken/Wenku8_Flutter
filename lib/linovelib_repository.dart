import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import 'app_language.dart';
import 'book_search.dart';
import 'catalog.dart';
import 'linovelib_client.dart';
import 'linovelib_ids.dart';
import 'linovelib_parser.dart';
import 'publication_catalog.dart';
import 'tag_catalogue.dart';

class _Cached<T> {
  const _Cached(this.value, this.at);
  final T value;
  final DateTime at;

  bool fresh(Duration ttl) => DateTime.now().difference(at) < ttl;
}

class _IndexedBook {
  const _IndexedBook(this.book, this.aliases);
  final Novel book;
  final List<String> aliases;

  String get titleText =>
      aliases.isEmpty ? book.title : '${book.title} ${aliases.join(' ')}';
}

/// Read-only Linovelib source.
///
/// The app's models are shared with local reading, so this adapter translates
/// the site's numeric book/chapter ids into namespaced ids and turns chapter
/// HTML into the reader's paragraph format. No credentials are used.
class LinovelibRepository extends NovelRepository
    implements PublicationCatalog, ProgressiveTagCatalogue {
  LinovelibRepository({LinovelibClient? client})
    : _client = client ?? LinovelibClient();

  final LinovelibClient _client;
  LinovelibClient get client => _client;
  final _details = <int, _Cached<Novel>>{};
  final _missingDetails = <int, DateTime>{};
  final _catalogues = <int, _Cached<List<NovelChapter>>>{};
  final _contents = <(int, int), _Cached<String>>{};
  final _known = <int, Novel>{};
  final _tags = <String, int>{};
  final _publicationSlugs = <int, String>{};
  List<PublicationLibrary>? _publications;
  DateTime? _publicationsAt;
  Future<List<_IndexedBook>>? _index;

  static const _catalogAsset = 'assets/linovelib_catalog.json';

  static const _detailTtl = Duration(minutes: 20);
  static const _missingDetailTtl = Duration(minutes: 5);
  static const _catalogueTtl = Duration(minutes: 20);
  static const _contentTtl = Duration(minutes: 20);
  static const _publicationTtl = Duration(hours: 6);
  static const _searchTtl = Duration(minutes: 2);
  static const _maxContentEntries = 24;

  @override
  Future<List<Novel>> list() async => (await browse()).items;

  @override
  Future<NovelPage> browse({
    NovelSort sort = NovelSort.lastUpdate,
    int page = 1,
    bool refresh = false,
  }) async {
    if (page < 1) throw ArgumentError.value(page, 'page');
    final document = await _client.document(
      _browsePath(sort, page),
      refresh: refresh,
    );
    final parsed = parseNovelList(document);
    _rememberAll(parsed.items);
    final totalPages =
        parsed.totalPages ?? (parsed.items.isEmpty ? page : page + 1);
    return NovelPage(items: parsed.items, page: page, totalPages: totalPages);
  }

  @override
  Future<Novel?> find(int id) async {
    if (LinovelibIds.websiteBook(id) == null) return null;
    final cached = _details[id];
    if (cached != null && cached.fresh(_detailTtl)) return cached.value;
    final known = _known[id];
    if (known != null) return known;
    final index = await _loadIndex();
    for (final entry in index) {
      if (entry.book.id == id) {
        _known[id] = entry.book;
        return entry.book;
      }
    }
    try {
      return await _loadDetail(id);
    } on LinovelibException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  @override
  Future<List<Novel>> search(String query) async =>
      (await searchPage(query)).items;

  @override
  Future<NovelPage> searchPage(
    String query, {
    int page = 1,
    bool refresh = false,
  }) async {
    final term = query.trim();
    if (term.isEmpty) {
      return NovelPage(items: const [], page: page, totalPages: 0);
    }
    final direct = _websiteIdFromQuery(term);
    if (direct != null) return _searchById(direct, page);
    final index = await _loadIndex();
    if (index.isNotEmpty) {
      // The bundled catalogue is traditional Chinese; convert simplified
      // input before matching so a normal mainland query still finds books.
      final query = await ChineseText.traditionalSearchQuery(term);
      final matches = _matchBooks(index, query);
      if (matches.isNotEmpty) return NovelPage.fromItems(matches, page);
      // The snapshot cannot contain a brand-new book. Try one public search
      // engine as a best-effort fallback; failure is an empty result, not a
      // blocking 429 error.
      try {
        return await _webSearch(term, page, refresh: refresh);
      } catch (_) {
        return NovelPage(items: const [], page: page, totalPages: 0);
      }
    }
    try {
      return await _webSearch(term, page, refresh: refresh);
    } catch (error) {
      final local = _localSearch(term, page);
      if (local.items.isNotEmpty) return local;
      return NovelPage(items: const [], page: page, totalPages: 0);
    }
  }

  @override
  Future<NovelPage> authorPage(
    String author, {
    int page = 1,
    bool refresh = false,
  }) async {
    final index = await _loadIndex();
    if (index.isNotEmpty) {
      final name = await ChineseText.traditionalSearchQuery(author);
      final matches = index
          .where((entry) => sameNovelAuthor(entry.book.author, name))
          .map((entry) => entry.book)
          .toList(growable: false);
      return NovelPage.fromItems(matches, page);
    }
    return super.authorPage(author, page: page, refresh: refresh);
  }

  @override
  Future<NovelPage> searchFilteredPage(
    String query, {
    BookSearchField field = BookSearchField.all,
    int page = 1,
    bool refresh = false,
  }) async {
    final term = query.trim();
    if (term.isEmpty) {
      return NovelPage(items: const [], page: page, totalPages: 0);
    }
    if (field == BookSearchField.id) {
      final id = _websiteIdFromQuery(term);
      if (id != null) return _searchById(id, page);
      return NovelPage(items: const [], page: page, totalPages: 0);
    }
    if (field == BookSearchField.tags) {
      return tagPage(term, page: page, refresh: refresh);
    }
    if (field == BookSearchField.all && _websiteIdFromQuery(term) != null) {
      return _searchById(_websiteIdFromQuery(term)!, page);
    }
    final index = await _loadIndex();
    if (index.isNotEmpty) {
      final query = await ChineseText.traditionalSearchQuery(term);
      final matches = _matchBooks(index, query, field: field);
      if (matches.isNotEmpty) return NovelPage.fromItems(matches, page);
      try {
        final web = await _webSearch(term, page, refresh: refresh);
        final pattern = BookSearch(query, field: field);
        final filtered = web.items
            .where(
              (book) => pattern.matches(
                title: book.title,
                author: book.author,
                tags: book.genre,
                summary: book.summary,
                id: '${book.id}',
              ),
            )
            .toList(growable: false);
        return NovelPage.fromItems(filtered, page);
      } catch (_) {
        return NovelPage(items: const [], page: page, totalPages: 0);
      }
    }
    return super.searchFilteredPage(
      query,
      field: field,
      page: page,
      refresh: refresh,
    );
  }

  @override
  Future<Novel> detail(Novel novel) async {
    if (LinovelibIds.websiteBook(novel.id) == null) {
      throw const FormatException('这本书来自其他书源，请重新搜索添加');
    }
    return _loadDetail(novel.id);
  }

  @override
  Future<List<NovelChapter>> chapters(int id) async {
    final websiteId = LinovelibIds.websiteBook(id);
    if (websiteId == null) {
      throw const FormatException('这本书来自其他书源，请重新搜索添加');
    }
    final cached = _catalogues[id];
    if (cached != null && cached.fresh(_catalogueTtl)) return cached.value;
    final document = await _client.document('/novel/$websiteId/catalog');
    final chapters = parseCatalogue(document, websiteId);
    if (chapters.isEmpty) throw const FormatException('本书暂无可阅读的章节');
    _catalogues[id] = _Cached(chapters, DateTime.now());
    final detail = _details[id];
    if (detail != null) {
      _details[id] = _Cached(detail.value.withChapters(chapters), detail.at);
    }
    return chapters;
  }

  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) async {
    final bookId = LinovelibIds.websiteBook(novelId);
    final chapterId = LinovelibIds.websiteChapter(chapter.id);
    if (bookId == null || chapterId == null) {
      throw const FormatException('这一章来自其他书源，请重新打开本书');
    }
    final key = (novelId, chapter.id);
    final cached = _contents[key];
    if (cached != null && cached.fresh(_contentTtl)) return cached.value;
    final text = await _loadChapter(bookId, chapterId);
    _contents[key] = _Cached(text, DateTime.now());
    while (_contents.length > _maxContentEntries) {
      _contents.remove(_contents.keys.first);
    }
    return text;
  }

  @override
  Future<NovelPage> tagPage(
    String tag, {
    int page = 1,
    bool refresh = false,
    bool Function()? current,
    TagProgressCallback? onProgress,
  }) async {
    final terms = tagSearchTerms(tag);
    if (terms.isEmpty) {
      return NovelPage(items: const [], page: page, totalPages: 0);
    }
    final traditionalTerms = await Future.wait(
      terms.map(ChineseText.traditionalSearchQuery),
    );
    final index = await _loadIndex();
    if (index.isNotEmpty) {
      final matches = index
          .where(
            (entry) => traditionalTerms.every(
              (term) =>
                  entry.book.tags.any((tag) => tagKey(tag) == tagKey(term)),
            ),
          )
          .map((entry) => entry.book)
          .toList(growable: false);
      if (matches.isNotEmpty) {
        final result = NovelPage.fromItems(matches, page);
        onProgress?.call(
          TagSearchProgress(
            items: result.items,
            scannedPages: page,
            totalPages: result.totalPages,
          ),
        );
        if (current != null && !current()) {
          return NovelPage(
            items: const [],
            page: page,
            totalPages: result.totalPages,
          );
        }
        return result;
      }
    }
    await _ensureTags();
    final first = _tags[tagKey(traditionalTerms.first)];
    if (first == null) {
      onProgress?.call(
        TagSearchProgress(items: const [], scannedPages: page, totalPages: 0),
      );
      return NovelPage(items: const [], page: page, totalPages: 0);
    }
    final document = await _client.document(
      '/wenku/lastupdate_${first}_0_0_0_0_0_0_${page}_0.html',
      refresh: refresh,
    );
    final parsed = parseNovelList(document);
    var items = parsed.items;
    if (traditionalTerms.length > 1) {
      items = items
          .where(
            (book) => traditionalTerms.every(
              (term) => book.tags.any((tag) => tagKey(tag) == tagKey(term)),
            ),
          )
          .toList(growable: false);
    }
    final totalPages =
        parsed.totalPages ?? (parsed.items.isEmpty ? page : page + 1);
    onProgress?.call(
      TagSearchProgress(
        items: items,
        scannedPages: page,
        totalPages: totalPages,
      ),
    );
    if (current != null && !current()) {
      return NovelPage(items: const [], page: page, totalPages: totalPages);
    }
    return NovelPage(items: items, page: page, totalPages: totalPages);
  }

  @override
  Future<List<PublicationLibrary>> publicationLibraries({
    bool refresh = false,
  }) async {
    final at = _publicationsAt;
    if (!refresh &&
        _publications != null &&
        at != null &&
        DateTime.now().difference(at) < _publicationTtl) {
      return _publications!;
    }
    final document = await _client.document('/sort/', refresh: refresh);
    final parsed = parsePublicationLibraries(document);
    if (parsed.isEmpty) throw const FormatException('暂时没有可用的出版分类');
    _publicationSlugs
      ..clear()
      ..addEntries(
        parsed.map((entry) => MapEntry(entry.library.id, entry.slug)),
      );
    _publications = List.unmodifiable(parsed.map((entry) => entry.library));
    _publicationsAt = DateTime.now();
    return _publications!;
  }

  @override
  Future<NovelPage> browsePublication(
    int libraryId, {
    int page = 1,
    bool refresh = false,
  }) async {
    if (page < 1) throw ArgumentError.value(page, 'page');
    await publicationLibraries();
    final slug = _publicationSlugs[libraryId];
    if (slug == null) {
      throw const FormatException('分类不存在，请刷新后重试');
    }
    final document = await _client.document(
      '/wenku/$slug/$page.html',
      refresh: refresh,
    );
    final parsed = parseNovelList(document);
    _rememberAll(parsed.items);
    final totalPages =
        parsed.totalPages ?? (parsed.items.isEmpty ? page : page + 1);
    return NovelPage(items: parsed.items, page: page, totalPages: totalPages);
  }

  Future<Uint8List> fetchCover(int id, String? url) {
    final websiteId = LinovelibIds.websiteBook(id);
    final resolved = url?.trim();
    if (resolved != null && resolved.isNotEmpty) {
      return _client.image(resolved);
    }
    if (websiteId == null) {
      return Future.error(const FormatException('封面地址缺失'));
    }
    return _client.image(
      '$LinovelibClient.origin/files/article/image/'
      '${websiteId ~/ 1000}/$websiteId/${websiteId}s.jpg',
    );
  }

  Future<Uint8List> fetchImage(String url) => _client.image(url);

  void dispose() => _client.close();

  Future<Novel> _loadDetail(int id) async {
    final cached = _details[id];
    if (cached != null && cached.fresh(_detailTtl)) return cached.value;
    final missingAt = _missingDetails[id];
    if (missingAt != null &&
        DateTime.now().difference(missingAt) < _missingDetailTtl) {
      throw const LinovelibException('书籍不存在或已下架', statusCode: 404);
    }
    final websiteId = LinovelibIds.websiteBook(id);
    if (websiteId == null) {
      throw const FormatException('这本书来自其他书源，请重新搜索添加');
    }
    final document = await _client.document('/novel/$websiteId.html');
    final hasBook =
        document.querySelector('#bookDetailWrapper') != null ||
        (document
                .querySelector('meta[property="og:novel:book_name"]')
                ?.attributes['content']
                ?.trim()
                .isNotEmpty ??
            false);
    if (!hasBook) {
      _missingDetails[id] = DateTime.now();
      throw const LinovelibException('书籍不存在或已下架', statusCode: 404);
    }
    _missingDetails.remove(id);
    var novel = parseNovelDetail(document, websiteId);
    final catalogue = _catalogues[id];
    if (catalogue != null && catalogue.fresh(_catalogueTtl)) {
      novel = novel.withChapters(catalogue.value);
    }
    _details[id] = _Cached(novel, DateTime.now());
    _known[id] = novel;
    return novel;
  }

  Future<String> _loadChapter(int bookId, int chapterId) async {
    final blocks = <String>[];
    final visited = <String>{};
    var uri = _client.resolve('/novel/$bookId/$chapterId.html');
    for (var page = 0; page < 40; page++) {
      if (!visited.add(uri.toString())) break;
      final document = await _client.documentUri(uri);
      blocks.add(parseChapterContent(document));
      final info = parseChapterReadInfo(document);
      final next = info?.nextPath;
      if (next == null) break;
      final nextUri = uri.resolve(next);
      final nextChapter = RegExp(
        r'/novel/\d+/(\d+)(?:_\d+)?\.html$',
      ).firstMatch(nextUri.path)?.group(1);
      if (nextChapter == null || int.tryParse(nextChapter) != chapterId) break;
      uri = nextUri;
    }
    if (blocks.isEmpty) throw const FormatException('章节正文为空');
    return blocks.join('\n\n');
  }

  Future<NovelPage> _searchById(int websiteId, int page) async {
    if (page > 1) {
      return NovelPage(items: const [], page: page, totalPages: page - 1);
    }
    try {
      final book = await _loadDetail(LinovelibIds.book(websiteId));
      return NovelPage(items: [book], page: page, totalPages: 1);
    } on LinovelibException catch (error) {
      if (error.statusCode == 404) {
        return NovelPage(items: const [], page: page, totalPages: 0);
      }
      rethrow;
    }
  }

  Future<NovelPage> _webSearch(
    String query,
    int page, {
    required bool refresh,
  }) async {
    final uri = Uri.https('search.brave.com', '/search', {
      'q': 'site:tw.linovelib.com $query',
      'source': 'web',
      if (page > 1) 'offset': '${page - 1}',
    });
    final document = await _client.documentUri(
      uri,
      refresh: refresh,
      ttl: _searchTtl,
    );
    final items = parseSearchResults(document);
    final totalPages = items.length >= 10 ? page + 1 : page;
    return NovelPage(items: items, page: page, totalPages: totalPages);
  }

  NovelPage _localSearch(String query, int page) => NovelPage.fromItems(
    _matchBooks(
      _known.values.map((book) => _IndexedBook(book, const [])),
      query,
    ),
    page,
  );

  Future<List<_IndexedBook>> _loadIndex() => _index ??= _readIndex();

  Future<List<_IndexedBook>> _readIndex() async {
    try {
      final raw = await rootBundle.loadString(_catalogAsset);
      final value = jsonDecode(raw);
      if (value is! Map || value['books'] is! List) {
        return const <_IndexedBook>[];
      }
      final books = <_IndexedBook>[];
      for (final entry in (value['books'] as List)) {
        if (entry is! Map) continue;
        final id = entry['id'];
        final title = entry['title'];
        if (id is! int ||
            id <= 0 ||
            id > LinovelibIds.maxWebsiteId ||
            title is! String ||
            title.isEmpty) {
          continue;
        }
        final tags = entry['tags'];
        final genre = tags is List ? tags.whereType<String>().join(' ') : '';
        final rawAliases = entry['aliases'];
        final aliases = rawAliases is List
            ? rawAliases.whereType<String>().toList(growable: false)
            : const <String>[];
        books.add(
          _IndexedBook(
            Novel(
              id: LinovelibIds.book(id),
              title: title,
              author: entry['author'] is String
                  ? entry['author'] as String
                  : '',
              genre: genre,
              summary: entry['summary'] is String
                  ? entry['summary'] as String
                  : '',
              colors: linovelibColorsFor(id),
              isComplete: entry['complete'] == true,
              coverUrl:
                  entry['cover'] is String &&
                      (entry['cover'] as String).isNotEmpty
                  ? entry['cover'] as String
                  : null,
            ),
            aliases,
          ),
        );
      }
      return List.unmodifiable(books);
    } catch (_) {
      // A preview build or an older asset set may omit the generated index;
      // fall back to the web search adapter.
      return const <_IndexedBook>[];
    }
  }

  List<Novel> _matchBooks(
    Iterable<_IndexedBook> entries,
    String query, {
    BookSearchField field = BookSearchField.all,
  }) {
    final pattern = BookSearch(query, field: field);
    return entries
        .where(
          (entry) => pattern.matches(
            title: entry.titleText,
            author: entry.book.author,
            tags: entry.book.genre,
            summary: entry.book.summary,
            id: '${entry.book.id}',
          ),
        )
        .map((entry) => entry.book)
        .toList(growable: false);
  }

  Future<void> _ensureTags() async {
    if (_tags.isNotEmpty) return;
    final document = await _client.document(
      '/wenku/lastupdate_0_0_0_0_0_0_0_1_0.html',
    );
    _tags.addAll(parseTagIds(document));
  }

  void _rememberAll(Iterable<Novel> books) {
    for (final book in books) {
      _known[book.id] = book;
    }
  }

  int? _websiteIdFromQuery(String value) {
    final raw = value.trim();
    // Accept the displayed LN-xxxxx code, but never silently reinterpret a
    // legacy Wenku8 WK- code as a Linovelib site id.
    if (raw.toUpperCase().startsWith('WK-')) return null;
    final normalized = raw.replaceFirst(
      RegExp(r'^LN[\s-]*', caseSensitive: false),
      '',
    );
    final parsed = int.tryParse(normalized);
    if (parsed == null || parsed <= 0) return null;
    final encoded = LinovelibIds.websiteBook(parsed);
    if (encoded != null) return encoded;
    return parsed <= LinovelibIds.maxWebsiteId ? parsed : null;
  }

  static String _browsePath(NovelSort sort, int page) => switch (sort) {
    NovelSort.lastUpdate => '/wenku/lastupdate_0_0_0_0_0_0_0_${page}_0.html',
    NovelSort.postDate => '/wenku/postdate_0_0_0_0_0_0_0_${page}_0.html',
    NovelSort.fullFlag => '/topfull/postdate/$page.html',
    _ => '/top/${sort.apiKey}/$page.html',
  };
}

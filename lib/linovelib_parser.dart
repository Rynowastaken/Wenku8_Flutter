import 'package:flutter/material.dart' show Color;
import 'package:html/dom.dart';

import 'catalog.dart';
import 'linovelib_ids.dart';
import 'publication_catalog.dart';

/// A parsed page of books plus the source's own page count, when it exposes
/// one. The repository turns a missing count into a conservative bounded page.
class LinovelibListPage {
  const LinovelibListPage(this.items, this.totalPages);
  final List<Novel> items;
  final int? totalPages;
}

class LinovelibPublication {
  const LinovelibPublication(this.slug, this.library);
  final String slug;
  final PublicationLibrary library;
}

class LinovelibReadInfo {
  const LinovelibReadInfo({
    required this.chapterId,
    required this.nextPath,
    required this.page,
  });
  final int? chapterId;
  final String? nextPath;
  final int page;
}

final _tagSeparator = RegExp(r'[\s\u3000·,，、;；|/]+');
String _text(Element? element) =>
    element == null ? '' : normalizeText(element.text);

String _textWithBreaks(Element? element) {
  if (element == null) return '';
  final buffer = StringBuffer();
  void visit(Node node) {
    if (node is Text) {
      buffer.write(node.data);
      return;
    }
    if (node is! Element) return;
    final tag = node.localName?.toLowerCase() ?? '';
    if (tag == 'br') {
      buffer.write('\n');
      return;
    }
    if (tag == 'center' &&
        RegExp(r'^\d{1,4}$').hasMatch(normalizeText(node.text))) {
      return;
    }
    if (tag == 'script' || tag == 'style' || tag == 'rt' || tag == 'rp') {
      return;
    }
    for (final child in node.nodes) {
      visit(child);
    }
  }

  visit(element);
  return normalizeText(buffer.toString());
}

String normalizeText(String value) {
  final lines = value
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('\u00a0', ' ')
      .replaceAll('\u3000', ' ')
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
      .where((line) => line.isNotEmpty)
      .toList();
  return lines.join('\n').trim();
}

int? _idFromNovelHref(String? href) {
  if (href == null) return null;
  final match = RegExp(r'/novel/(\d+)(?:\.html|/|$)').firstMatch(href);
  return match == null ? null : int.tryParse(match.group(1)!);
}

String? _coverUrl(Element? image) {
  if (image == null) return null;
  for (final attribute in const [
    'data-src',
    'data-original',
    'data-lazy-src',
    'src',
  ]) {
    final raw = image.attributes[attribute]?.trim();
    if (raw == null || raw.isEmpty || raw.startsWith('data:')) continue;
    final parsed = Uri.tryParse(raw);
    final uri = parsed != null && parsed.hasScheme
        ? parsed
        : Uri.parse('https://tw.linovelib.com').resolve(raw);
    if (!const {'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty) {
      continue;
    }
    final path = uri.path.toLowerCase();
    if (path.endsWith('sloading.svg') ||
        path.endsWith('book-cover-no.svg') ||
        path.endsWith('noavatar.png') ||
        path.endsWith('noavatar.jpg')) {
      continue;
    }
    return uri.replace(scheme: 'https', port: 443).toString();
  }
  return null;
}

String _author(Element? element) {
  final value = _text(element);
  return value.replaceFirst(RegExp(r'^作者[:：]?\s*'), '').trim();
}

List<String> _splitTags(String value) => value
    .split(_tagSeparator)
    .map((tag) => tag.trim())
    .where((tag) => tag.isNotEmpty && tag != '連載' && tag != '连载')
    .toSet()
    .toList();

List<Color> linovelibColorsFor(int websiteId) {
  const palettes = <List<Color>>[
    [Color(0xFF5E87B8), Color(0xFF222C5B)],
    [Color(0xFFB06B62), Color(0xFF45272A)],
    [Color(0xFF6E8E6A), Color(0xFF26382A)],
    [Color(0xFF8C76A8), Color(0xFF332B47)],
    [Color(0xFFB98B52), Color(0xFF44301D)],
    [Color(0xFF5B9A9A), Color(0xFF203C3D)],
  ];
  return palettes[websiteId % palettes.length];
}

Novel _novelFromList(Element anchor, int websiteId) {
  final title = _text(anchor.querySelector('.book-title')).trim();
  final cover = _coverUrl(
    anchor.querySelector('.book-cover img') ??
        anchor.querySelector('.book-img img') ??
        anchor.querySelector('img'),
  );
  final summary = _text(
    anchor.querySelector('.book-desc') ??
        anchor.querySelector('.book-intro') ??
        anchor.querySelector('.book-summary'),
  );
  final tags = <String>[
    for (final tag in anchor.querySelectorAll('.tag-small.yellow'))
      ..._splitTags(tag.text),
  ];
  final status = _text(anchor.querySelector('.tag-small.red'));
  final complete = status.contains('完結') || status.contains('完结');
  final author = _author(anchor.querySelector('.book-author'));
  return Novel(
    id: LinovelibIds.book(websiteId),
    title: title.isEmpty ? '未命名书籍' : title,
    author: author,
    genre: tags.join(' '),
    summary: summary,
    colors: linovelibColorsFor(websiteId),
    isComplete: complete,
    coverUrl: cover,
  );
}

LinovelibListPage parseNovelList(Document document) {
  final items = <Novel>[];
  final seen = <int>{};
  for (final anchor in document.querySelectorAll(
    'li.book-li a.book-layout[href]',
  )) {
    final websiteId = _idFromNovelHref(anchor.attributes['href']);
    if (websiteId == null || !seen.add(websiteId)) continue;
    items.add(_novelFromList(anchor, websiteId));
  }
  if (items.isEmpty) {
    final title = document.querySelector('title')?.text ?? '';
    final body = document.querySelector('body')?.text ?? '';
    if (RegExp(
      r'錯誤|错误|Just a moment|cf-challenge|抱歉，該小說不存在|內容加載失敗|内容加载失败',
    ).hasMatch('$title $body')) {
      throw const FormatException('来源返回了错误页面，请稍后重试');
    }
  }
  return LinovelibListPage(List.unmodifiable(items), _totalPages(document));
}

int? _totalPages(Document document) {
  final last = document.querySelector('#pagelink a.last')?.attributes['href'];
  final match = last == null ? null : RegExp(r'/(\d+)\.html').firstMatch(last);
  if (match != null) return int.tryParse(match.group(1)!);
  var maximum = 0;
  for (final link in document.querySelectorAll('#pagelink a')) {
    final value = int.tryParse(_text(link));
    if (value != null && value > maximum) maximum = value;
  }
  return maximum == 0 ? null : maximum;
}

Novel parseNovelDetail(Document document, int websiteId) {
  String meta(String property) =>
      document
          .querySelector('meta[property="$property"]')
          ?.attributes['content']
          ?.trim() ??
      '';

  final title = meta('og:novel:book_name').isNotEmpty
      ? meta('og:novel:book_name')
      : _text(document.querySelector('.book-title'));
  final author = meta('og:novel:author').isNotEmpty
      ? meta('og:novel:author')
      : _author(document.querySelector('.authorname'));
  final category = meta('og:novel:category');
  final summaryElement =
      document.querySelector('#bookSummary content') ??
      document.querySelector('#bookSummary');
  final summary = _textWithBreaks(
    summaryElement,
  ).replaceFirst(RegExp(r'^內容簡介\s*'), '');
  final tags = <String>[
    for (final tag in document.querySelectorAll(
      '#bookDetailWrapper span.tag-small-group.origin-left em.tag-small.red a',
    ))
      ..._splitTags(tag.text),
  ];
  final cover =
      _coverUrl(document.querySelector('#bookDetailWrapper img.book-cover')) ??
      (meta('og:image').isEmpty ? null : meta('og:image'));
  final status = meta('og:novel:status');
  final updated = meta('og:novel:update_time');
  return Novel(
    id: LinovelibIds.book(websiteId),
    title: title.isEmpty ? '未命名书籍' : title,
    author: author,
    genre: tags.isEmpty ? category : tags.join(' '),
    summary: summary,
    colors: linovelibColorsFor(websiteId),
    isComplete: status.contains('完結') || status.contains('完结'),
    coverUrl: cover,
    lastUpdate: updated.isEmpty ? null : updated,
    chapterCount: 0,
  );
}

List<NovelChapter> parseCatalogue(Document document, int bookWebsiteId) {
  final chapters = <NovelChapter>[];
  final seen = <int>{};

  void addChapter(
    Element row, {
    required int volumeId,
    required String volumeTitle,
  }) {
    final anchor = row.querySelector('a[href]');
    final href = anchor?.attributes['href'];
    final match = href == null
        ? null
        : RegExp(
            '/novel/$bookWebsiteId/(\\d+)(?:_\\d+)?\\.html',
          ).firstMatch(href);
    if (match == null) return;
    final websiteChapterId = int.tryParse(match.group(1)!);
    if (websiteChapterId == null || !seen.add(websiteChapterId)) return;
    final title = _text(row.querySelector('.chapter-index') ?? anchor).trim();
    if (title.isEmpty) return;
    chapters.add(
      NovelChapter(
        title,
        '',
        id: LinovelibIds.chapter(websiteChapterId),
        volumeId: volumeId,
        volumeTitle: volumeTitle,
      ),
    );
  }

  final volumes = document.querySelectorAll('#volumes .catalog-volume');
  if (volumes.isNotEmpty) {
    for (final (index, volume) in volumes.indexed) {
      final anchor = volume.querySelector('.chapter-bar a[href]');
      final href = anchor?.attributes['href'];
      final volumeId = href == null
          ? index + 1
          : int.tryParse(
                  RegExp(r'vol_(\d+)').firstMatch(href)?.group(1) ?? '',
                ) ??
                index + 1;
      final volumeTitle = _text(volume.querySelector('.chapter-bar h3')).trim();
      for (final row in volume.querySelectorAll('li.chapter-li')) {
        if (row.classes.contains('chapter-bar') ||
            row.classes.contains('volume-cover')) {
          continue;
        }
        addChapter(row, volumeId: volumeId, volumeTitle: volumeTitle);
      }
    }
    return List.unmodifiable(chapters);
  }

  for (final row in document.querySelectorAll('li.chapter-li')) {
    if (row.classes.contains('chapter-bar') ||
        row.classes.contains('volume-cover')) {
      continue;
    }
    addChapter(row, volumeId: 0, volumeTitle: '');
  }
  return List.unmodifiable(chapters);
}

/// Converts the chapter HTML into the paragraph format used by [ReaderContent].
/// Images become standalone `<!--image-->url<!--image-->` paragraphs in source
/// order, including illustrations placed in the site's hidden image block.
String parseChapterContent(Document document) {
  final root =
      document.querySelector('#acontent') ??
      document.querySelector('.acontent');
  if (root == null) throw const FormatException('章节正文为空');
  final blocks = <String>[];
  final buffer = StringBuffer();
  final seenImages = <String>{};

  void flush() {
    final value = normalizeText(buffer.toString());
    buffer.clear();
    if (value.isNotEmpty) blocks.add(value);
  }

  void addImage(String url) {
    flush();
    if (seenImages.add(url)) blocks.add('<!--image-->$url<!--image-->');
  }

  void visit(Node node) {
    if (node is Text) {
      if (node.data.trim().isNotEmpty) buffer.write(node.data);
      return;
    }
    if (node is! Element) return;
    final tag = node.localName?.toLowerCase() ?? '';
    if (const {'script', 'style', 'noscript', 'rt', 'rp'}.contains(tag)) return;
    if (tag == 'img') {
      final url = _coverUrl(node);
      if (url != null) addImage(url);
      return;
    }
    if (tag == 'br') {
      buffer.write('\n');
      return;
    }
    final block = const {
      'p',
      'div',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'li',
      'blockquote',
      'section',
      'article',
    }.contains(tag);
    if (block) flush();
    for (final child in node.nodes) {
      visit(child);
    }
    if (block) flush();
  }

  for (final child in root.nodes) {
    visit(child);
  }
  flush();
  if (blocks.isEmpty) throw const FormatException('章节正文为空');
  final text = blocks.join('\n\n');
  if (RegExp(r'內容加載失敗|内容加载失败|請使用手機閱讀|手机版页面由于兼容性|zation\(\);').hasMatch(text)) {
    throw const FormatException('章节内容被来源截断，请稍后重试');
  }
  return text;
}

LinovelibReadInfo? parseChapterReadInfo(Document document) {
  for (final script in document.querySelectorAll('script')) {
    final text = script.text;
    if (!text.contains('ReadParams')) continue;
    String? value(String key) => RegExp(
      '$key\\s*:\\s*[\'"]?([^\'",}]+)',
    ).firstMatch(text)?.group(1)?.trim();
    final next = value('url_next');
    final chapter = int.tryParse(value('chapterid') ?? '');
    final page = int.tryParse(value('page') ?? '') ?? 1;
    return LinovelibReadInfo(
      chapterId: chapter,
      nextPath: next == null || next.isEmpty || next == 'null' ? null : next,
      page: page,
    );
  }
  return null;
}

Map<String, int> parseTagIds(Document document) {
  final result = <String, int>{};
  for (final tag in document.querySelectorAll('[data-filter-type="tagid"]')) {
    final id = int.tryParse(tag.attributes['data-filter-value'] ?? '');
    final name = normalizeText(tag.text);
    if (id == null || id <= 0 || name.isEmpty || name == '不限') continue;
    result[_tagKey(name)] = id;
  }
  return result;
}

String tagKey(String value) => value
    .replaceAll('#', '')
    .replaceAll(RegExp(r'[\s\u3000]+'), '')
    .toLowerCase();

String _tagKey(String value) => tagKey(value);

List<LinovelibPublication> parsePublicationLibraries(Document document) {
  final result = <LinovelibPublication>[];
  final seen = <String>{};
  for (final anchor in document.querySelectorAll('h3.module-title a[href]')) {
    final href = anchor.attributes['href'] ?? '';
    final match = RegExp(r'^/wenku/([a-z0-9_-]+)/\d+\.html$').firstMatch(href);
    if (match == null) continue;
    final slug = match.group(1)!;
    final name = normalizeText(anchor.text);
    if (name.isEmpty || !seen.add(slug)) continue;
    result.add(
      LinovelibPublication(
        slug,
        PublicationLibrary(LinovelibIds.library(slug), name),
      ),
    );
  }
  return List.unmodifiable(result);
}

/// Normalizes public search-result links to lightweight book cards. Search
/// engines also index catalog and volume pages, so only the `/novel/{id}`
/// prefix is used. Titles/authors come from the result title, avoiding a burst
/// of detail requests just to render a result list.
List<Novel> parseSearchResults(Document document) {
  final cards =
      <int, ({String title, String author, String cover, bool canonical})>{};
  for (final anchor in document.querySelectorAll('a[href]')) {
    final raw = anchor.attributes['href'] ?? '';
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        !(uri.host == 'tw.linovelib.com' ||
            uri.host.endsWith('.linovelib.com'))) {
      continue;
    }
    final match = RegExp(r'^/novel/(\d+)(?:/|\.html|$)').firstMatch(uri.path);
    if (match == null) continue;
    final id = int.tryParse(match.group(1)!);
    if (id == null || id <= 0 || id > LinovelibIds.maxWebsiteId) continue;

    final text = normalizeText(anchor.text);
    final tail = text.split('›').last.trim();
    var title = tail.replaceFirst(
      RegExp(r'^(?:catalog|vol_\d+(?:\.html)?|\d+(?:\.html)?)\s*'),
      '',
    );
    for (final suffix in ['小說線上看', '線上看', '在線閱讀', '在線', '_嗶哩輕小說']) {
      title = title.split(suffix).first.trim();
    }
    title = title.replaceFirst(RegExp(r'_[^_]+作品_.*$'), '').trim();
    if (title.isEmpty) continue;
    final author =
        RegExp(r'_([^_]+)作品_').firstMatch(text)?.group(1)?.trim() ?? '';
    final canonical = RegExp(
      r'^/novel/\d+(?:\.html)?$|^/novel/\d+/catalog$|^/novel/\d+/vol_',
    ).hasMatch(uri.path);
    final existing = cards[id];
    if (existing == null || (!existing.canonical && canonical)) {
      cards[id] = (
        title: title,
        author: author,
        cover:
            'https://tw.linovelib.com/files/article/image/'
            '${id ~/ 1000}/$id/${id}s.jpg',
        canonical: canonical,
      );
    }
  }
  return List.unmodifiable([
    for (final entry in cards.entries)
      Novel(
        id: LinovelibIds.book(entry.key),
        title: entry.value.title,
        author: entry.value.author,
        genre: '',
        summary: '',
        colors: linovelibColorsFor(entry.key),
        coverUrl: entry.value.cover,
      ),
  ]);
}

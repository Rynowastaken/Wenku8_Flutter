import 'package:flutter/widgets.dart';

import 'catalog.dart';

class PublicationLibrary {
  const PublicationLibrary(this.id, this.name);
  final int id;
  final String name;
}

/// Source-neutral access to publication categories for the discovery filter.
/// It stays independent from the Wenku account/community scope.
class PublicationCatalogScope extends InheritedWidget {
  const PublicationCatalogScope({
    super.key,
    required this.catalog,
    required super.child,
  });

  final PublicationCatalog? catalog;

  static PublicationCatalog? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<PublicationCatalogScope>()
      ?.catalog;

  @override
  bool updateShouldNotify(PublicationCatalogScope oldWidget) =>
      catalog != oldWidget.catalog;
}

abstract interface class PublicationCatalog {
  Future<List<PublicationLibrary>> publicationLibraries({bool refresh = false});
  Future<NovelPage> browsePublication(
    int libraryId, {
    int page = 1,
    bool refresh = false,
  });
}

/// A category feed still uses the normal paging/prefetch/stale-result machinery.
class PublicationNovelRepository extends NovelRepository {
  const PublicationNovelRepository(this.source, this.catalog, this.library);
  final NovelRepository source;
  final PublicationCatalog catalog;
  final PublicationLibrary library;
  @override
  Future<List<Novel>> list() async => (await browse()).items;
  @override
  Future<NovelPage> browse({
    NovelSort sort = NovelSort.lastUpdate,
    int page = 1,
    bool refresh = false,
  }) => catalog.browsePublication(library.id, page: page, refresh: refresh);
  @override
  Future<Novel?> find(int id) => source.find(id);
  @override
  Future<List<Novel>> search(String query) => source.search(query);
  @override
  Future<Novel> detail(Novel novel) => source.detail(novel);
  @override
  Future<List<NovelChapter>> chapters(int id) => source.chapters(id);
  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) =>
      source.chapterContent(novelId, chapter);
}

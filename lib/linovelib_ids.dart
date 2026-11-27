/// Numeric namespaces for Linovelib records.
///
/// The app's existing caches, reading positions and shelf records are keyed by
/// a bare `int`. Keeping Linovelib ids in their own ranges prevents a cached
/// Wenku8 book (or a local book) with the same small id from being mistaken for
/// the Linovelib title. Local books already reserve `>= 0x60000000`.
abstract final class LinovelibIds {
  static const int bookBase = 0x20000000;
  static const int chapterBase = 0x30000000;
  static const int maxWebsiteId = 0x0fffffff;
  static const int _limit = maxWebsiteId;

  static int book(int websiteId) {
    if (websiteId <= 0 || websiteId > _limit) {
      throw ArgumentError.value(websiteId, 'websiteId');
    }
    return bookBase + websiteId;
  }

  static int chapter(int websiteId) {
    if (websiteId <= 0 || websiteId > _limit) {
      throw ArgumentError.value(websiteId, 'websiteId');
    }
    return chapterBase + websiteId;
  }

  static int? websiteBook(int id) =>
      id > bookBase && id <= bookBase + _limit ? id - bookBase : null;

  static int? websiteChapter(int id) =>
      id > chapterBase && id <= chapterBase + _limit ? id - chapterBase : null;

  /// Stable positive key for a publication slug. The value only has to survive
  /// a process so the current discovery selection can address the same shelf.
  static int library(String slug) {
    var hash = 0x811c9dc5;
    for (final code in slug.codeUnits) {
      hash ^= code;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash == 0 ? 1 : hash;
  }
}

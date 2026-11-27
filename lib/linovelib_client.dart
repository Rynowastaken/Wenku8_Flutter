import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

/// A user-facing source failure. It extends [FormatException] so existing feed
/// and reader error surfaces show the message without source-specific glue.
class LinovelibException extends FormatException {
  const LinovelibException(super.message, {this.statusCode});

  final int? statusCode;

  @override
  String toString() => message.toString();
}

class _CachedDocument {
  const _CachedDocument(this.uri, this.document, this.at);
  final Uri uri;
  final Document document;
  final DateTime at;
}

/// HTTP boundary for Linovelib pages, authenticated sessions, and image hosts.
///
/// Pages are cached briefly and identical in-flight GET requests are shared.
/// Session cookies are scoped strictly to Linovelib hosts and never sent to
/// third-party image CDNs or web search endpoints.
class LinovelibClient {
  LinovelibClient({Uri? baseUri, HttpClient? httpClient})
    : baseUri = baseUri ?? Uri.parse(origin),
      _http = httpClient ?? HttpClient() {
    _http.connectionTimeout = const Duration(seconds: 20);
    _http.idleTimeout = const Duration(seconds: 20);
    _http.autoUncompress = true;
  }

  static const origin = 'https://tw.linovelib.com';
  static const userAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';
  static const _desktopUserAgent =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124 Safari/537.36';

  static const _pageTtl = Duration(minutes: 8);
  static const _maxPages = 48;
  static const _maxPageBytes = 12 * 1024 * 1024;
  static const _maxImageBytes = 32 * 1024 * 1024;
  static const _requestTimeout = Duration(seconds: 25);
  static const _imageHosts = {
    'linovelib.com',
    'linovelib.net',
    'linovelib.cc',
    'readpai.com',
    'bilinovel.com',
    'bilinovel.net',
  };

  final Uri baseUri;
  final HttpClient _http;
  final _documents = <String, _CachedDocument>{};
  final _pending = <String, Future<({Uri uri, Document document})>>{};
  final _cookies = <String, String>{};
  void Function(Map<String, String> cookies)? onCookiesChanged;
  DateTime _nextRequestAt = DateTime.fromMillisecondsSinceEpoch(0);

  Map<String, String> get cookies => Map.unmodifiable(_cookies);

  void setCookies(Map<String, String> cookies, {bool notify = false}) {
    _cookies
      ..clear()
      ..addAll(cookies);
    if (notify) onCookiesChanged?.call(this.cookies);
  }

  void clearCookies({bool notify = true}) {
    if (_cookies.isEmpty) return;
    _cookies.clear();
    if (notify) onCookiesChanged?.call(const {});
  }

  void clearDocumentCache() => _documents.clear();

  Uri resolve(String href) {
    final parsed = Uri.tryParse(href.trim());
    if (parsed == null) throw const FormatException('页面链接格式有误');
    return parsed.hasScheme ? parsed : baseUri.resolveUri(parsed);
  }

  Future<Document> document(
    String pathOrUrl, {
    bool refresh = false,
    Duration ttl = _pageTtl,
  }) async =>
      (await documentWithUri(pathOrUrl, refresh: refresh, ttl: ttl)).document;

  Future<({Uri uri, Document document})> documentWithUri(
    String pathOrUrl, {
    bool refresh = false,
    Duration ttl = _pageTtl,
  }) => documentUriWithUrl(
    pathOrUrl.contains('://') ? Uri.parse(pathOrUrl) : resolve(pathOrUrl),
    refresh: refresh,
    ttl: ttl,
  );

  Future<Document> documentUri(
    Uri uri, {
    bool refresh = false,
    Duration ttl = _pageTtl,
  }) async => (await documentUriWithUrl(uri, refresh: refresh, ttl: ttl)).document;

  Future<({Uri uri, Document document})> documentUriWithUrl(
    Uri uri, {
    bool refresh = false,
    Duration ttl = _pageTtl,
  }) {
    final key = _normalize(uri);
    final cached = _documents[key];
    if (!refresh &&
        cached != null &&
        DateTime.now().difference(cached.at) < ttl) {
      return Future.value((uri: cached.uri, document: cached.document));
    }
    final pending = _pending[key];
    if (pending != null) return pending;
    final future = _fetchDocument(Uri.parse(key));
    _pending[key] = future;
    return future.whenComplete(() {
      if (identical(_pending[key], future)) _pending.remove(key);
    });
  }

  Future<({Uri uri, Document document})> _fetchDocument(Uri uri) async {
    final result = await _request(
      uri,
      accept:
          'text/html,application/xhtml+xml,application/xml;q=0.9,'
          'image/avif,image/webp,*/*;q=0.8',
      limit: _maxPageBytes,
    );
    final html = utf8.decode(result.bytes, allowMalformed: true);
    final document = html_parser.parse(html);
    final key = _normalize(uri);
    _documents[key] = _CachedDocument(result.uri, document, DateTime.now());
    while (_documents.length > _maxPages) {
      _documents.remove(_documents.keys.first);
    }
    return (uri: result.uri, document: document);
  }

  Future<({Uri uri, Document document, String text})> postForm(
    String pathOrUrl,
    Map<String, String> fields, {
    String? referer,
  }) async {
    final uri = pathOrUrl.contains('://')
        ? Uri.parse(pathOrUrl)
        : resolve(pathOrUrl);
    final body = fields.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
    final result = await _request(
      uri,
      method: 'POST',
      bodyBytes: utf8.encode(body),
      contentType: 'application/x-www-form-urlencoded; charset=utf-8',
      accept:
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      referer: referer ?? origin,
      limit: _maxPageBytes,
    );
    clearDocumentCache();
    final text = utf8.decode(result.bytes, allowMalformed: true);
    return (uri: result.uri, document: html_parser.parse(text), text: text);
  }

  Future<Uint8List> image(String url, {String? referer}) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && ![80, 443].contains(uri.port)) ||
        !_allowedImageHost(uri.host)) {
      throw const FormatException('插图地址格式有误');
    }
    final normalized = uri.replace(scheme: 'https', port: 443);
    final result = await _request(
      normalized,
      accept: 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
      referer: referer ?? origin,
      limit: _maxImageBytes,
      pace: false,
    );
    return result.bytes;
  }

  bool _isSessionHost(Uri uri) {
    final host = uri.host.toLowerCase();
    return host == 'linovelib.com' || host.endsWith('.linovelib.com');
  }

  void _captureCookies(Uri uri, HttpClientResponse response) {
    if (!_isSessionHost(uri) || response.cookies.isEmpty) return;
    var changed = false;
    for (final cookie in response.cookies) {
      final deleted =
          cookie.value.isEmpty ||
          cookie.value.toLowerCase() == 'deleted' ||
          cookie.maxAge == 0;
      if (deleted) {
        if (_cookies.remove(cookie.name) != null) changed = true;
      } else if (_cookies[cookie.name] != cookie.value) {
        _cookies[cookie.name] = cookie.value;
        changed = true;
      }
    }
    if (changed) onCookiesChanged?.call(cookies);
  }

  Future<({Uri uri, Uint8List bytes})> _request(
    Uri uri, {
    String method = 'GET',
    List<int>? bodyBytes,
    String? contentType,
    required String accept,
    required int limit,
    String? referer,
    bool pace = true,
  }) async {
    for (var attempt = 0; ; attempt++) {
      HttpClientResponse? response;
      try {
        var currentUri = uri;
        var currentMethod = method;
        var currentBody = bodyBytes;
        var currentReferer = referer;
        for (var hops = 0; ; hops++) {
          if (pace) await _pace(currentUri);
          final request = await _http.openUrl(currentMethod, currentUri);
          request.followRedirects = false;
          request.headers.set(
            HttpHeaders.userAgentHeader,
            currentUri.host == 'search.brave.com' ? _desktopUserAgent : userAgent,
          );
          request.headers.set(HttpHeaders.acceptHeader, accept);
          request.headers.set(HttpHeaders.acceptLanguageHeader, 'zh-TW,zh;q=0.9');
          if (currentReferer != null) {
            request.headers.set(HttpHeaders.refererHeader, currentReferer);
          } else if (currentUri.host == 'tw.linovelib.com') {
            request.headers.set(HttpHeaders.refererHeader, origin);
          }
          if (_isSessionHost(currentUri) && _cookies.isNotEmpty) {
            request.headers.set(
              HttpHeaders.cookieHeader,
              _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
            );
          }
          if (currentBody != null && currentMethod == 'POST') {
            if (contentType != null) {
              request.headers.set(HttpHeaders.contentTypeHeader, contentType);
            }
            request.contentLength = currentBody.length;
            request.add(currentBody);
          }
          response = await request.close().timeout(_requestTimeout);
          _captureCookies(currentUri, response);
          final status = response.statusCode;
          if (const {301, 302, 303, 307, 308}.contains(status)) {
            final location = response.headers.value(HttpHeaders.locationHeader);
            await response.drain<void>();
            if (location == null || location.isEmpty || hops >= 5) {
              throw LinovelibException(_statusMessage(status), statusCode: status);
            }
            currentReferer = currentUri.toString();
            currentUri = currentUri.resolve(location);
            if (status != 307 && status != 308) {
              currentMethod = 'GET';
              currentBody = null;
            }
            continue;
          }
          if (status == 429 && attempt < 1) {
            final delay = _retryAfter(response) ?? const Duration(seconds: 5);
            final until = DateTime.now().add(delay);
            if (_nextRequestAt.isBefore(until)) _nextRequestAt = until;
            await response.drain<void>();
            await Future<void>.delayed(delay);
            break;
          }
          if (status < 200 || status >= 300) {
            await response.drain<void>();
            throw LinovelibException(_statusMessage(status), statusCode: status);
          }
          final declared = response.contentLength;
          if (declared > limit) {
            await response.drain<void>();
            throw const LinovelibException('网站返回的内容过大');
          }
          final builder = BytesBuilder(copy: false);
          await for (final chunk in response.timeout(_requestTimeout)) {
            builder.add(chunk);
            if (builder.length > limit) {
              throw const LinovelibException('网站返回的内容过大');
            }
          }
          final bytes = builder.takeBytes();
          if (bytes.isEmpty) throw const LinovelibException('网站返回了空内容');
          return (uri: currentUri, bytes: bytes);
        }
      } on LinovelibException {
        rethrow;
      } on TimeoutException {
        throw const LinovelibException('连接哔哩轻小说超时，请稍后重试');
      } on SocketException {
        throw const LinovelibException('无法连接到哔哩轻小说，请检查网络后重试');
      } on HandshakeException {
        throw const LinovelibException('无法安全连接到哔哩轻小说，请检查网络后重试');
      } on HttpException {
        throw const LinovelibException('哔哩轻小说连接中断，请稍后重试');
      }
    }
  }

  /// The site rate-limits bursts of page requests. Serializing linovelib page
  /// requests keeps a search's follow-up detail reads from tripping it.
  Future<void> _pace(Uri uri) async {
    if (uri.host != 'tw.linovelib.com') return;
    final now = DateTime.now();
    final scheduled = _nextRequestAt.isAfter(now) ? _nextRequestAt : now;
    _nextRequestAt = scheduled.add(const Duration(milliseconds: 900));
    final wait = scheduled.difference(now);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }

  static Duration? _retryAfter(HttpClientResponse response) {
    final raw = response.headers.value(HttpHeaders.retryAfterHeader);
    final seconds = int.tryParse(raw ?? '');
    if (seconds == null || seconds <= 0) return null;
    return Duration(seconds: seconds.clamp(1, 60));
  }

  void close() => _http.close(force: true);

  static bool _allowedImageHost(String host) {
    final value = host.toLowerCase();
    return _imageHosts.any(
      (allowed) => value == allowed || value.endsWith('.$allowed'),
    );
  }

  static String _normalize(Uri uri) =>
      uri.replace(scheme: 'https', port: 443, fragment: '').toString();

  static String _statusMessage(int status) => switch (status) {
    401 || 403 => '哔哩轻小说拒绝了这次访问，请稍后重试',
    404 => '哔哩轻小说上没有找到这个页面',
    429 => '请求过于频繁，请稍后再试',
    451 => '这个页面在当前地区不可用',
    _ => '哔哩轻小说暂时无法访问（HTTP $status）',
  };
}

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
  const _CachedDocument(this.document, this.at);
  final Document document;
  final DateTime at;
}

/// Small, polite HTTP boundary for the Linovelib pages and image hosts.
///
/// Pages are cached briefly and identical in-flight requests are shared. The
/// client never stores cookies or credentials because the source is read-only.
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
  final _pending = <String, Future<Document>>{};
  DateTime _nextRequestAt = DateTime.fromMillisecondsSinceEpoch(0);

  Uri resolve(String href) {
    final parsed = Uri.tryParse(href.trim());
    if (parsed == null) throw const FormatException('页面链接格式有误');
    return parsed.hasScheme ? parsed : baseUri.resolveUri(parsed);
  }

  Future<Document> document(
    String pathOrUrl, {
    bool refresh = false,
    Duration ttl = _pageTtl,
  }) => documentUri(
    pathOrUrl.contains('://') ? Uri.parse(pathOrUrl) : resolve(pathOrUrl),
    refresh: refresh,
    ttl: ttl,
  );

  Future<Document> documentUri(
    Uri uri, {
    bool refresh = false,
    Duration ttl = _pageTtl,
  }) {
    final key = _normalize(uri);
    final cached = _documents[key];
    if (!refresh &&
        cached != null &&
        DateTime.now().difference(cached.at) < ttl) {
      return Future.value(cached.document);
    }
    final pending = _pending[key];
    if (pending != null) return pending;
    final future = _fetchDocument(Uri.parse(key));
    _pending[key] = future;
    return future.whenComplete(() {
      if (identical(_pending[key], future)) _pending.remove(key);
    });
  }

  Future<Document> _fetchDocument(Uri uri) async {
    final bytes = await _request(
      uri,
      accept:
          'text/html,application/xhtml+xml,application/xml;q=0.9,'
          'image/avif,image/webp,*/*;q=0.8',
      limit: _maxPageBytes,
    );
    final html = utf8.decode(bytes, allowMalformed: true);
    final document = html_parser.parse(html);
    final key = _normalize(uri);
    _documents[key] = _CachedDocument(document, DateTime.now());
    while (_documents.length > _maxPages) {
      _documents.remove(_documents.keys.first);
    }
    return document;
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
    return _request(
      normalized,
      accept: 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
      referer: referer ?? origin,
      limit: _maxImageBytes,
      pace: false,
    );
  }

  Future<Uint8List> _request(
    Uri uri, {
    required String accept,
    required int limit,
    String? referer,
    bool pace = true,
  }) async {
    for (var attempt = 0; ; attempt++) {
      HttpClientResponse? response;
      try {
        if (pace) await _pace(uri);
        final request = await _http.getUrl(uri);
        request.followRedirects = true;
        request.maxRedirects = 5;
        request.headers.set(
          HttpHeaders.userAgentHeader,
          uri.host == 'search.brave.com' ? _desktopUserAgent : userAgent,
        );
        request.headers.set(HttpHeaders.acceptHeader, accept);
        request.headers.set(HttpHeaders.acceptLanguageHeader, 'zh-TW,zh;q=0.9');
        if (referer != null) {
          request.headers.set(HttpHeaders.refererHeader, referer);
        } else if (uri.host == 'tw.linovelib.com') {
          request.headers.set(HttpHeaders.refererHeader, origin);
        }
        response = await request.close().timeout(_requestTimeout);
        final status = response.statusCode;
        if (status == 429 && attempt < 1) {
          final delay = _retryAfter(response) ?? const Duration(seconds: 5);
          final until = DateTime.now().add(delay);
          if (_nextRequestAt.isBefore(until)) _nextRequestAt = until;
          await response.drain<void>();
          await Future<void>.delayed(delay);
          continue;
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
        return bytes;
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

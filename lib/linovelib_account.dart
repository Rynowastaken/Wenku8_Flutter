import 'dart:async';
import 'dart:convert';

import 'package:html/dom.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'library_state.dart';
import 'linovelib_client.dart';
import 'linovelib_ids.dart';
import 'linovelib_parser.dart';
import 'online_component.dart';
import 'wenku_account.dart';
import 'wenku_reviews.dart';
import 'wenku_shelf_sync.dart';

/// Authenticated session, profile, cloud bookshelf sync, recommend and
/// community reviews adapter for Linovelib (`tw.linovelib.com`).
class LinovelibAccount extends WenkuAccount {
  LinovelibAccount({
    required LinovelibClient client,
    required SharedPreferences preferences,
  }) : _client = client,
       _preferences = preferences {
    _client.onCookiesChanged = _persistCookies;
  }

  static const _cookiesKey = 'linovelib.account.cookies.v1';
  static const _profileKey = 'linovelib.account.profile.v1';
  static const _signedDateKey = 'linovelib.account.signed_date.v1';
  static const _bookcaseCleanupKey = 'linovelib.account.bookcase_cleanup.v1';
  static const _suspectCaseIdFloor = 100000;

  final LinovelibClient _client;
  final SharedPreferences _preferences;
  final _caseIds = <int, String>{};

  Future<void>? _initializing;
  int _sessionRevision = 0;
  String? _signPath;
  String _signMethod = 'GET';

  @override
  int get sessionRevision => _sessionRevision;

  @override
  bool get supportsSignIn => authenticated;

  @override
  ReviewPageReader? get reviewReader => _readReviews;

  @override
  Future<void> initialize() => _initializing ??= _restore();

  Future<void> _restore() async {
    final rawCookies = _preferences.getString(_cookiesKey);
    if (rawCookies == null || rawCookies.isEmpty) return;
    try {
      final decoded = jsonDecode(rawCookies);
      if (decoded is! Map) return;
      final restored = <String, String>{
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
      };
      if (restored.isEmpty) return;
      _client.setCookies(restored);
      authenticated = true;
      signedToday = _preferences.getString(_signedDateKey) == _todayKey();
      profile = _restoreProfile() ?? _profileFromCookies(restored);
      _sessionRevision++;
      notifyListeners();
      unawaited(_refreshAfterRestore());
    } catch (_) {
      await _clearSessionState(notify: false);
    }
  }

  Future<void> _refreshAfterRestore() async {
    try {
      await _fetchProfile();
      await _fetchCloudBooks();
      notifyListeners();
    } on OnlineAuthenticationRequired {
      await _clearSessionState();
    } catch (_) {
      // Keep restored offline state when the network is temporarily unavailable.
    }
  }

  @override
  Future<void> login(String username, String password) async {
    final trimmedUser = username.trim();
    if (trimmedUser.isEmpty || password.isEmpty) {
      error = '请输入用户名和密码';
      notifyListeners();
      throw FormatException(error!);
    }
    await _runBusy('正在登录哔哩轻小说…', () async {
      _client.clearCookies(notify: false);
      _client.clearDocumentCache();
      _caseIds.clear();
      _signPath = null;
      final response = await _client.postForm('/login.php?do=submit', {
        'username': trimmedUser,
        'password': password,
        'act': 'login',
        'usecookie': '2592000',
        'submit': '',
      }, referer: '${LinovelibClient.origin}/login.php');
      if (_isCaptchaBlocked(response.document)) {
        throw const FormatException('网站当前需要图形验证，请稍后重试');
      }
      final err = _extractSiteError(response.document);
      if (err != null) {
        _client.clearCookies(notify: false);
        throw FormatException(err);
      }
      if (_isLoginPage(response.uri, response.document) &&
          !_hasAuthCookie(_client.cookies)) {
        _client.clearCookies(notify: false);
        throw const FormatException('用户名或密码有误，请检查后重试');
      }
      authenticated = true;
      signedToday = true;
      await _preferences.setString(_signedDateKey, _todayKey());
      _sessionRevision++;
      await _persistCookiesNow(_client.cookies);
      profile =
          _profileFromCookies(_client.cookies) ??
          WenkuProfile(
            id: _fallbackUid(trimmedUser),
            username: trimmedUser,
            nickname: trimmedUser,
            score: 0,
            experience: 0,
            rank: '哔哩轻小说',
          );
      await _persistProfile(profile!);
      notifyListeners();
      try {
        await _fetchProfile();
      } on OnlineAuthenticationRequired {
        await _clearSessionState(notify: false);
        throw const FormatException('登录状态未生效，请重试');
      } catch (_) {}
      try {
        await _fetchCloudBooks();
      } catch (_) {}
    });
  }

  @override
  Future<void> refreshProfile() => _runBusy('正在刷新账号资料…', () async {
    _requireAuth();
    await _fetchProfile();
  });

  @override
  Future<void> signIn() => _runBusy('正在触发每日登录…', () async {
    _requireAuth();
    lastSignInMessage = null;
    if (signedToday) {
      lastSignInMessage = '今日已完成登录';
      return;
    }
    if (_signPath == null) {
      await _fetchProfile();
    }
    final explicitPath = _signPath;
    if (explicitPath != null) {
      final result = _signMethod == 'POST'
          ? await _client.postForm(explicitPath, const {'ajax_request': '1'})
          : (await _client.documentWithUri(explicitPath, refresh: true));
      final doc = result is ({Uri uri, Document document, String text})
          ? result.document
          : (result as ({Uri uri, Document document})).document;
      final uri = result is ({Uri uri, Document document, String text})
          ? result.uri
          : (result as ({Uri uri, Document document})).uri;
      if (_isLoginPage(uri, doc)) {
        await _clearSessionState();
        throw const OnlineAuthenticationRequired();
      }
      final err = _extractSiteError(doc);
      if (err != null && !err.contains('已') && !err.contains('重複')) {
        throw FormatException(err);
      }
      signedToday = true;
      await _preferences.setString(_signedDateKey, _todayKey());
      try {
        await _fetchProfile();
      } catch (_) {}
      lastSignInMessage = '今日签到已完成';
      return;
    }

    final beforeScore = profile?.score ?? 0;
    final autoCookies = Map<String, String>.from(_client.cookies)
      ..remove('PHPSESSID');
    if (autoCookies.containsKey('jieqiUserInfo')) {
      try {
        final probe = await _client.fetchIsolatedDocument(
          '/user.php',
          cookies: autoCookies,
        );
        if (!_isLoginPage(probe.uri, probe.document)) {
          if (probe.cookies.isNotEmpty) {
            _client.setCookies({..._client.cookies, ...probe.cookies});
            await _persistCookiesNow(_client.cookies);
          }
          await _fetchProfile();
          final afterScore = profile?.score ?? beforeScore;
          if (afterScore > beforeScore) {
            signedToday = true;
            await _preferences.setString(_signedDateKey, _todayKey());
            lastSignInMessage =
                '每日登录成功 · +${afterScore - beforeScore} 积分（当前 $afterScore）';
            return;
          }
        }
      } on OnlineAuthenticationRequired {
        rethrow;
      } catch (_) {}
    }

    // Cookie auto-login either redirected or did not increase points today;
    // prompt for one-time re-login without disturbing the active session.
    throw const DailyLoginPasswordRequired();
  });

  @override
  Future<void> signInWithPassword(String password) =>
      _runBusy('正在重新登录以领取今日积分…', () async {
        _requireAuth();
        lastSignInMessage = null;
        if (password.isEmpty) {
          throw const FormatException('请输入密码');
        }
        final username = profile?.username.trim() ?? '';
        if (username.isEmpty) {
          throw const FormatException('无法获取当前用户名');
        }
        final beforeScore = profile?.score ?? 0;
        final previousCookies = Map<String, String>.from(_client.cookies);
        try {
          _client.clearCookies(notify: false);
          _client.clearDocumentCache();
          final response = await _client.postForm(
            '/login.php?do=submit',
            {
              'username': username,
              'password': password,
              'act': 'login',
              'usecookie': '2592000',
              'submit': '',
            },
            referer: '${LinovelibClient.origin}/login.php',
          );
          if (_isCaptchaBlocked(response.document)) {
            _client.setCookies(previousCookies);
            throw const FormatException('网站当前需要图形验证，请稍后重试');
          }
          final err = _extractSiteError(response.document);
          if (err != null) {
            _client.setCookies(previousCookies);
            throw FormatException(err);
          }
          if (_isLoginPage(response.uri, response.document) &&
              !_hasAuthCookie(_client.cookies)) {
            _client.setCookies(previousCookies);
            throw const FormatException('密码有误，请检查后重试');
          }
          await _persistCookiesNow(_client.cookies);
          await _fetchProfile();
          signedToday = true;
          await _preferences.setString(_signedDateKey, _todayKey());
          final afterScore = profile?.score ?? beforeScore;
          final delta = afterScore - beforeScore;
          lastSignInMessage = delta > 0
              ? '每日登录成功 · +$delta 积分（当前 $afterScore）'
              : '今日登录已完成（当前 $afterScore 积分）';
        } catch (err) {
          if (!_hasAuthCookie(_client.cookies) &&
              previousCookies.isNotEmpty) {
            _client.setCookies(previousCookies);
          }
          rethrow;
        }
      });

  @override
  Future<List<CloudBook>> refreshCloud() => _runBusy('正在读取云书架…', () async {
    _requireAuth();
    return _fetchCloudBooks();
  });

  @override
  Future<void> addCloud(int id) => _runBusy('正在加入云书架…', () async {
    _requireAuth();
    final siteId = LinovelibIds.websiteBook(id);
    if (siteId == null) {
      throw const FormatException('仅支持线上哔哩轻小说书目加入云书架');
    }
    final result = await _client.postForm(
      '/modules/article/addbookcase.php?bid=$siteId',
      const {'ajax_request': '1'},
      referer: '${LinovelibClient.origin}/novel/$siteId.html',
    );
    if (_isLoginPage(result.uri, result.document)) {
      await _clearSessionState();
      throw const OnlineAuthenticationRequired();
    }
    final err = _extractSiteError(result.document);
    if (err != null && !err.contains('已經在') && !err.contains('已经在')) {
      throw FormatException(err);
    }
    await _fetchCloudBooks();
  });

  @override
  Future<void> removeCloud(int id) => _runBusy('正在移出云书架…', () async {
    _requireAuth();
    final siteId = LinovelibIds.websiteBook(id);
    if (siteId == null) {
      throw const FormatException('仅支持线上哔哩轻小说书目操作');
    }
    var caseId = _caseIds[siteId];
    if (caseId == null) {
      await _fetchCloudBooks();
      caseId = _caseIds[siteId];
    }
    if (caseId != null) {
      final res = await _client.documentWithUri(
        '/modules/article/bookcase.php?delid=$caseId',
        refresh: true,
      );
      if (_isLoginPage(res.uri, res.document)) {
        await _clearSessionState();
        throw const OnlineAuthenticationRequired();
      }
      final err = _extractSiteError(res.document);
      if (err != null) throw FormatException(err);
    }
    await _fetchCloudBooks();
  });

  @override
  Future<CloudShelfPlan> exchangeShelf({
    required Set<int> local,
    Set<int>? lastLocal,
    Set<int>? lastCloud,
  }) => _runBusy('正在同步云书架…', () async {
    _requireAuth();
    Set<int>? filter(Set<int>? source) => source == null
        ? null
        : {for (final id in source) if (LinovelibIds.websiteBook(id) != null) id};
    final remoteBooks = await _fetchCloudBooks();
    final remoteIds = {for (final b in remoteBooks) b.id};
    final needsCleanup = _preferences.getBool(_bookcaseCleanupKey) != true;
    final bogusLocal = needsCleanup
        ? {
            for (final id in filter(local)!)
              if ((LinovelibIds.websiteBook(id) ?? 0) >= _suspectCaseIdFloor &&
                  !remoteIds.contains(id))
                id,
          }
        : const <int>{};
    final filteredLocal = filter(local)!..removeAll(bogusLocal);
    final filteredLastLocal = filter(lastLocal)?..removeAll(bogusLocal);
    final filteredLastCloud = filter(lastCloud);
    final plan = CloudShelfPlan(
      local: filteredLocal,
      remote: remoteIds,
      lastLocal: filteredLastLocal,
      lastCloud: filteredLastCloud,
    );
    if (bogusLocal.isNotEmpty) {
      plan.localRemoved.addAll(bogusLocal);
    }
    if (needsCleanup) {
      await _preferences.setBool(_bookcaseCleanupKey, true);
    }
    final toUpload = plan.target.difference(remoteIds);
    final toDelete = remoteIds.difference(plan.target);
    for (final id in toUpload) {
      final siteId = LinovelibIds.websiteBook(id);
      if (siteId == null) continue;
      final res = await _client.postForm(
        '/modules/article/addbookcase.php?bid=$siteId',
        const {'ajax_request': '1'},
        referer: '${LinovelibClient.origin}/novel/$siteId.html',
      );
      if (_isLoginPage(res.uri, res.document)) {
        await _clearSessionState();
        throw const OnlineAuthenticationRequired();
      }
    }
    for (final id in toDelete) {
      final siteId = LinovelibIds.websiteBook(id);
      final caseId = siteId == null ? null : _caseIds[siteId];
      if (caseId == null) continue;
      final res = await _client.documentWithUri(
        '/modules/article/bookcase.php?delid=$caseId',
        refresh: true,
      );
      if (_isLoginPage(res.uri, res.document)) {
        await _clearSessionState();
        throw const OnlineAuthenticationRequired();
      }
    }
    if (toUpload.isNotEmpty || toDelete.isNotEmpty) {
      await _fetchCloudBooks();
    }
    return plan;
  });

  @override
  Future<CloudUploadResult> uploadMissing(Set<int> localIds) =>
      _runBusy('正在上传收藏到云书架…', () async {
        _requireAuth();
        final current = await _fetchCloudBooks();
        final remoteIds = {for (final b in current) b.id};
        final missing = [
          for (final id in localIds)
            if (LinovelibIds.websiteBook(id) != null && !remoteIds.contains(id))
              id,
        ];
        final uploaded = <int>[];
        final remaining = <int>[];
        Object? failure;
        for (final id in missing) {
          final siteId = LinovelibIds.websiteBook(id)!;
          try {
            final res = await _client.postForm(
              '/modules/article/addbookcase.php?bid=$siteId',
              const {'ajax_request': '1'},
              referer: '${LinovelibClient.origin}/novel/$siteId.html',
            );
            if (_isLoginPage(res.uri, res.document)) {
              await _clearSessionState();
              throw const OnlineAuthenticationRequired();
            }
            uploaded.add(id);
          } catch (err) {
            failure ??= err;
            remaining.add(id);
          }
        }
        if (uploaded.isNotEmpty) {
          try {
            await _fetchCloudBooks();
          } catch (_) {}
        }
        return CloudUploadResult(uploaded, remaining, failure);
      });

  @override
  Future<int> mergeCloudToLocal(LibraryState state) async {
    _requireAuth();
    final books = await refreshCloud();
    final before = state.shelf;
    final toAdd = {
      for (final b in books)
        if (!before.contains(b.id)) b.id,
    };
    if (toAdd.isEmpty) return 0;
    await state.applyCloudShelf(
      add: toAdd,
      remove: const {},
      expectedRevisions: state.shelfRevisions,
    );
    return state.shelf.difference(before).length;
  }

  @override
  Future<void> recommend(int id) => _runBusy('正在提交推荐…', () async {
    _requireAuth();
    final siteId = LinovelibIds.websiteBook(id);
    if (siteId == null) {
      throw const FormatException('仅支持线上哔哩轻小说作品推荐');
    }
    final res = await _client.postForm(
      '/modules/article/uservote.php?id=$siteId',
      const {'ajax_request': '1'},
      referer: '${LinovelibClient.origin}/novel/$siteId.html',
    );
    if (_isLoginPage(res.uri, res.document)) {
      await _clearSessionState();
      throw const OnlineAuthenticationRequired();
    }
    final err = _extractSiteError(res.document);
    if (err != null) throw FormatException(err);
  });

  Future<WenkuReviewPage> _readReviews(int id, int page, bool replies) async {
    if (!replies) {
      final siteId = LinovelibIds.websiteBook(id);
      if (siteId == null) {
        throw const FormatException('仅支持查看线上哔哩轻小说评论');
      }
      final res = await _client.documentWithUri(
        '/modules/article/reviews.php?aid=$siteId&page=$page',
        refresh: page == 1,
      );
      return _parseReviewsPage(res.document, page);
    }
    final res = await _client.documentWithUri(
      '/modules/article/reviewshow.php?tid=$id&page=$page',
      refresh: page == 1,
    );
    if (_isLoginPage(res.uri, res.document)) {
      throw const OnlineAuthenticationRequired();
    }
    return _parseThreadRepliesPage(res.document, page);
  }

  @override
  Future<void> postReview({
    required int bookId,
    required String title,
    required String content,
  }) => _runBusy('正在发表书评…', () async {
    _requireAuth();
    final siteId = LinovelibIds.websiteBook(bookId);
    if (siteId == null) {
      throw const FormatException('仅支持线上哔哩轻小说发表书评');
    }
    final formPage = await _client.documentWithUri(
      '/modules/article/reviewsnew.php?aid=$siteId',
      refresh: true,
    );
    if (_isLoginPage(formPage.uri, formPage.document)) {
      await _clearSessionState();
      throw const OnlineAuthenticationRequired();
    }
    if (_isCaptchaBlocked(formPage.document)) {
      throw const FormatException('哔哩轻小说发表书评需要图形验证码，请在网页端提交');
    }
    final form =
        formPage.document.querySelector('form[action*="review"]') ??
        formPage.document.querySelector('form');
    final fields = <String, String>{
      if (form != null)
        for (final input in form.querySelectorAll('input[type="hidden"]'))
          if ((input.attributes['name'] ?? '').isNotEmpty)
            input.attributes['name']!: input.attributes['value'] ?? '',
      'ptitle': title.trim(),
      'pcontent': content.trim(),
      'act': 'newpost',
    };
    final action =
        form?.attributes['action'] ??
        '/modules/article/reviewsnew.php?aid=$siteId';
    final res = await _client.postForm(
      action,
      fields,
      referer: formPage.uri.toString(),
    );
    if (_isLoginPage(res.uri, res.document)) {
      await _clearSessionState();
      throw const OnlineAuthenticationRequired();
    }
    final err = _extractSiteError(res.document);
    if (err != null) throw FormatException(err);
  });

  @override
  Future<void> replyReview({
    required int threadId,
    required String content,
  }) => _runBusy('正在发表回复…', () async {
    _requireAuth();
    final pageRes = await _client.documentWithUri(
      '/modules/article/reviewshow.php?tid=$threadId&page=1',
      refresh: true,
    );
    if (_isLoginPage(pageRes.uri, pageRes.document)) {
      await _clearSessionState();
      throw const OnlineAuthenticationRequired();
    }
    if (_isCaptchaBlocked(pageRes.document)) {
      throw const FormatException('哔哩轻小说回复书评需要图形验证码，请在网页端提交');
    }
    final form =
        pageRes.document.querySelector('form[action*="review"]') ??
        pageRes.document.querySelector('form');
    final fields = <String, String>{
      if (form != null)
        for (final input in form.querySelectorAll('input[type="hidden"]'))
          if ((input.attributes['name'] ?? '').isNotEmpty)
            input.attributes['name']!: input.attributes['value'] ?? '',
      'pcontent': content.trim(),
      'act': 'newpost',
    };
    final action =
        form?.attributes['action'] ??
        '/modules/article/reviewshow.php?tid=$threadId';
    final res = await _client.postForm(
      action,
      fields,
      referer: pageRes.uri.toString(),
    );
    if (_isLoginPage(res.uri, res.document)) {
      await _clearSessionState();
      throw const OnlineAuthenticationRequired();
    }
    final err = _extractSiteError(res.document);
    if (err != null) throw FormatException(err);
  });

  @override
  Future<void> logout() async {
    if (busy) return;
    busy = true;
    operation = '正在退出账号…';
    error = null;
    notifyListeners();
    try {
      await _client.documentWithUri('/logout.php', refresh: true);
    } catch (_) {}
    await _clearSessionState(notify: false);
    busy = false;
    operation = null;
    await super.logout();
  }

  Future<T> _runBusy<T>(String label, Future<T> Function() action) async {
    if (busy) throw const FormatException('请等待当前账号操作完成');
    busy = true;
    operation = label;
    error = null;
    notifyListeners();
    try {
      return await action();
    } on DailyLoginPasswordRequired {
      rethrow;
    } catch (failure) {
      error = WenkuAccount.describeError(failure);
      rethrow;
    } finally {
      busy = false;
      operation = null;
      notifyListeners();
    }
  }

  void _requireAuth() {
    if (!authenticated) throw const OnlineAuthenticationRequired();
  }

  Future<void> _clearSessionState({bool notify = true}) async {
    authenticated = false;
    profile = null;
    avatar = null;
    cloudBooks = null;
    signedToday = false;
    _caseIds.clear();
    _signPath = null;
    _client.clearCookies(notify: false);
    _client.clearDocumentCache();
    _sessionRevision++;
    await _preferences.remove(_cookiesKey);
    await _preferences.remove(_profileKey);
    await _preferences.remove(_signedDateKey);
    if (notify) notifyListeners();
  }

  Future<void> _fetchProfile() async {
    final res = await _client.documentWithUri('/user.php', refresh: true);
    if (_isLoginPage(res.uri, res.document)) {
      await _clearSessionState();
      throw const OnlineAuthenticationRequired();
    }
    final cookieProfile = _profileFromCookies(_client.cookies);
    var parsed = _parseUserPage(res.document, cookieProfile);
    _detectSignAction(res.document);
    final avatarUrl = _extractAvatarUrl(res.document, parsed?.id ?? 0);
    if (parsed == null || (parsed.score == 0 && parsed.experience == 0)) {
      try {
        final detailRes = await _client.documentWithUri(
          '/userdetail.php',
          refresh: true,
        );
        if (!_isLoginPage(detailRes.uri, detailRes.document)) {
          _detectSignAction(detailRes.document, clearFirst: false);
          parsed = _parseUserPage(detailRes.document, parsed ?? cookieProfile);
        }
      } catch (_) {}
    }
    if (parsed != null) {
      profile = parsed;
      await _persistProfile(parsed);
    }
    if (avatarUrl != null) {
      try {
        avatar = await _client.image(avatarUrl, referer: res.uri.toString());
      } catch (_) {}
    }
  }

  Future<List<CloudBook>> _fetchCloudBooks() async {
    final res = await _client.documentWithUri('/bookcase.php', refresh: true);
    if (_isLoginPage(res.uri, res.document)) {
      await _clearSessionState();
      throw const OnlineAuthenticationRequired();
    }
    final parsed = _parseBookcasePage(res.document);
    _caseIds
      ..clear()
      ..addAll(parsed.caseIds);
    cloudBooks = List.unmodifiable(parsed.books);
    syncedAt = DateTime.now().millisecondsSinceEpoch;
    return cloudBooks!;
  }

  void _detectSignAction(Document doc, {bool clearFirst = true}) {
    if (clearFirst) _signPath = null;
    for (final el in doc.querySelectorAll(
      'a, button, form, li, div, span, input',
    )) {
      final text = normalizeText(
        el.text.isNotEmpty ? el.text : (el.attributes['value'] ?? ''),
      );
      final href =
          el.attributes['href'] ??
          el.attributes['action'] ??
          el.attributes['data-url'] ??
          el.attributes['data-href'] ??
          '';
      final onclick = el.attributes['onclick'] ?? '';
      final combined = '$text $href $onclick'.toLowerCase();
      if (!combined.contains('簽到') &&
          !combined.contains('签到') &&
          !combined.contains('打卡') &&
          !combined.contains('sign') &&
          !combined.contains('qiandao')) {
        continue;
      }
      if (text.contains('已簽到') || text.contains('已签到')) {
        signedToday = true;
        unawaited(_preferences.setString(_signedDateKey, _todayKey()));
        return;
      }
      if (el.localName == 'form' && href.isNotEmpty) {
        _signPath = href;
        _signMethod = (el.attributes['method'] ?? 'POST').toUpperCase();
        return;
      }
      if (href.isNotEmpty && !href.startsWith('javascript')) {
        _signPath = href;
        _signMethod = 'GET';
        return;
      }
      final urlMatch = RegExp(
        r'''['"](/[^'"]*(?:sign|qiandao)[^'"]*)['"]''',
      ).firstMatch(onclick);
      if (urlMatch != null) {
        _signPath = urlMatch.group(1);
        _signMethod = onclick.toLowerCase().contains('post') ? 'POST' : 'GET';
        return;
      }
    }
    for (final script in doc.querySelectorAll('script')) {
      final urlMatch = RegExp(
        r'''['"](/[^'"]*(?:usersign|qiandao|/sign)[^'"]*\.php[^'"]*)['"]''',
      ).firstMatch(script.text);
      if (urlMatch != null) {
        _signPath = urlMatch.group(1);
        _signMethod = script.text.toLowerCase().contains('post')
            ? 'POST'
            : 'GET';
        return;
      }
    }
  }

  WenkuProfile? _parseUserPage(Document doc, WenkuProfile? fallback) {
    final fullText = normalizeText(doc.body?.text ?? '');
    final kvPairs = <({String key, String value})>[];
    for (final li in doc.querySelectorAll('.center-acc-li')) {
      final out = normalizeText(li.querySelector('output')?.text ?? '');
      final label = normalizeText(
        li.text.replaceFirst(out, ''),
      );
      if (out.isNotEmpty && label.isNotEmpty) {
        kvPairs.add((key: label, value: out));
      }
    }
    for (final row in doc.querySelectorAll('.center-nav-ol li, tr')) {
      final keyEl = row.querySelector('.book-title, th, td:first-child, span');
      final valEl = row.querySelector(
        '.book-author, output, td:nth-child(2), em, small',
      );
      final keyText = normalizeText(keyEl?.text ?? '');
      final valText = normalizeText(valEl?.text ?? '');
      if (keyText.isNotEmpty && valText.isNotEmpty && keyText != valText) {
        kvPairs.add((key: keyText, value: valText));
      }
    }

    int? extractPairInt(List<String> labels) {
      for (final pair in kvPairs) {
        if (labels.any((l) => pair.key.contains(l))) {
          final m = RegExp(r'(\d+)').firstMatch(pair.value);
          if (m != null) return int.tryParse(m.group(1)!);
        }
      }
      return null;
    }

    String extractPairLabel(List<String> labels) {
      for (final pair in kvPairs) {
        if (labels.any((l) => pair.key.contains(l)) && pair.value.isNotEmpty) {
          return pair.value;
        }
      }
      return '';
    }

    int? extractInt(List<RegExp> patterns) {
      for (final pattern in patterns) {
        final match = pattern.firstMatch(fullText);
        if (match != null) return int.tryParse(match.group(1)!);
      }
      return null;
    }

    String extractLabel(List<RegExp> patterns) {
      for (final pattern in patterns) {
        final match = pattern.firstMatch(fullText);
        final val = match?.group(1)?.trim() ?? '';
        if (val.isNotEmpty) return val;
      }
      return '';
    }

    final headerName = normalizeText(
      doc
          .querySelector(
            '.center-header-p, .user-name, .user-title, .my-info-name, h1, h2, .aui-center-title',
          )
          ?.text ??
          '',
    );
    final username =
        fallback?.username.isNotEmpty == true
        ? fallback!.username
        : extractLabel([
            RegExp(r'(?:用戶名|用户名|帳號|账号)[：:\s]+([^\s\n]+)'),
          ]);
    final nickname = extractLabel([
      RegExp(r'(?:暱稱|昵称)[：:\s]+([^\n]+)'),
    ]);
    final rankFromPair = extractPairLabel(['頭銜', '头衔', '等級', '等级', '會員組', '用户组']);
    final rankFromText = extractLabel([
      RegExp(r'(?:頭銜|头衔|等級|等级|會員組|用户组)[：:\s]+([^\s\n]+)'),
      RegExp(r'(LV\.?\s*\d+)', caseSensitive: false),
    ]);
    final rank = rankFromPair.isNotEmpty ? rankFromPair : rankFromText;
    final uid =
        fallback?.id ??
        extractInt([
          RegExp(r'(?:UID|用戶ID|用户ID)[：:\s]+(\d+)', caseSensitive: false),
        ]) ??
        _fallbackUid(username.isNotEmpty ? username : headerName);
    final parsedScore =
        extractPairInt(['積分', '积分', '輕石', '轻石', '金幣', '金币', '硬幣', '硬币']) ??
        extractInt([
          RegExp(
            r'(?:現有|现有)?(?:積分|积分|輕石|轻石|硬幣|硬币|金幣|金币)[：:\s]+(\d+)',
          ),
          RegExp(r'(\d+)\s*(?:積分|积分|輕石|轻石|硬幣|硬币|金幣|金币)'),
        ]);
    final score = (parsedScore != null && parsedScore > 0)
        ? parsedScore
        : (fallback?.score ?? parsedScore ?? 0);
    final parsedExp =
        extractPairInt(['經驗', '经验', '經驗值', '经验值']) ??
        extractInt([
          RegExp(r'(?:經驗值|经验值|經驗|经验)[：:\s]+(\d+)'),
          RegExp(r'(\d+)\s*(?:經驗值|经验值|經驗|经验)'),
        ]);
    final exp = (parsedExp != null && parsedExp > 0)
        ? parsedExp
        : (fallback?.experience ?? parsedExp ?? 0);

    final resolvedUser = username.isNotEmpty
        ? username
        : (headerName.isNotEmpty &&
                  !headerName.contains('用戶') &&
                  !headerName.contains('帳戶')
              ? headerName
              : (fallback?.username ?? 'Linovelib'));
    final resolvedNick = nickname.isNotEmpty
        ? nickname
        : (fallback?.nickname.isNotEmpty == true
              ? fallback!.nickname
              : resolvedUser);
    return WenkuProfile(
      id: uid,
      username: resolvedUser,
      nickname: resolvedNick,
      score: score,
      experience: exp,
      rank: rank.isNotEmpty ? rank : (fallback?.rank ?? '正式會員'),
    );
  }

  String? _extractAvatarUrl(Document doc, int uid) {
    final headerAvatar = doc.querySelector('img.center-header-img');
    if (headerAvatar != null) {
      final src =
          (headerAvatar.attributes['data-src'] ??
                  headerAvatar.attributes['src'] ??
                  '')
              .trim();
      if (src.isNotEmpty && !src.contains('noavatar')) {
        return _client.resolve(src).toString();
      }
    }
    for (final img in doc.querySelectorAll('img')) {
      final src =
          (img.attributes['data-src'] ?? img.attributes['src'] ?? '').trim();
      if (src.isEmpty || src.contains('noavatar')) continue;
      if (src.contains('avatar') || (uid > 0 && src.contains('/$uid'))) {
        return _client.resolve(src).toString();
      }
    }
    return null;
  }

  ({List<CloudBook> books, Map<int, String> caseIds}) _parseBookcasePage(
    Document doc,
  ) {
    final books = <CloudBook>[];
    final seen = <int>{};
    final caseIds = <int, String>{};
    final rows = doc.querySelectorAll(
      'li.book-li, tr, .book-layout, .bookbox, .shelf-item',
    );
    final Iterable<Element> containers = rows.isNotEmpty
        ? rows
        : doc.querySelectorAll('a[href*="/novel/"], a[href*="bid="]');

    for (final container in containers) {
      final links = container.localName == 'a'
          ? [container]
          : container.querySelectorAll('a[href]');
      int? siteId;
      int? fallbackBidId;
      var title = '';
      var latestChapter = '';
      var latestChapterId = 0;
      var updated = '';
      String? caseId;

      for (final a in links) {
        final href = a.attributes['href'] ?? '';
        final delMatch = RegExp(r'[?&]delid=(\d+)').firstMatch(href);
        if (delMatch != null) caseId = delMatch.group(1);

        // In Jieqi's readbookcase.php / bookcase.php URLs, `bid` is the bookcase
        // entry ID (`caseid`), while `aid` or `/novel/<id>` is the real book ID.
        if (href.contains('bookcase')) {
          final bidMatch = RegExp(r'[?&]bid=(\d+)').firstMatch(href);
          if (bidMatch != null) caseId ??= bidMatch.group(1);
        }

        final bookMatch =
            RegExp(r'/novel/(\d+)(?:\.html|/|$)').firstMatch(href) ??
            RegExp(r'[?&]aid=(\d+)').firstMatch(href);
        if (bookMatch != null && siteId == null) {
          siteId = int.tryParse(bookMatch.group(1)!);
        } else if (!href.contains('bookcase')) {
          final bidMatch = RegExp(r'[?&]bid=(\d+)').firstMatch(href);
          if (bidMatch != null && fallbackBidId == null) {
            fallbackBidId = int.tryParse(bidMatch.group(1)!);
          }
        }

        final chapMatch = RegExp(
          r'/novel/\d+/(\d+)\.html',
        ).firstMatch(href);
        if (chapMatch != null) {
          latestChapterId = int.tryParse(chapMatch.group(1)!) ?? 0;
          final text = normalizeText(a.text);
          if (text.isNotEmpty) latestChapter = text;
        }
        if (chapMatch == null && (bookMatch != null || href.contains('aid='))) {
          final linkText = normalizeText(a.text);
          if (title.isEmpty &&
              linkText.isNotEmpty &&
              linkText != '閱讀' &&
              linkText != '阅读' &&
              linkText != '移除' &&
              linkText != '刪除' &&
              linkText != '删除') {
            title = linkText;
          }
        }
      }
      if (siteId == null) {
        for (final img in container.querySelectorAll('img')) {
          final src =
              img.attributes['data-src'] ?? img.attributes['src'] ?? '';
          final imgMatch = RegExp(
            r'/files/article/image/\d+/(\d+)/',
          ).firstMatch(src);
          if (imgMatch != null) {
            siteId = int.tryParse(imgMatch.group(1)!);
            break;
          }
        }
      }
      siteId ??= fallbackBidId;
      if (title.isEmpty) {
        title = normalizeText(
          container.querySelector('.book-title, h4, h3, .title')?.text ?? '',
        );
      }
      if (caseId == null) {
        final checkbox = container.querySelector(
          'input[name*="checkid"][value], [data-cid], [data-caseid]',
        );
        caseId =
            checkbox?.attributes['value'] ??
            checkbox?.attributes['data-cid'] ??
            checkbox?.attributes['data-caseid'];
      }
      if (siteId == null || siteId <= 0 || siteId > LinovelibIds.maxWebsiteId) {
        continue;
      }
      if (caseId != null && caseId.isNotEmpty) {
        caseIds[siteId] = caseId;
      }
      final appId = LinovelibIds.book(siteId);
      if (!seen.add(appId)) continue;
      final metaText = normalizeText(
        container.querySelector('.book-meta, .book-desc, time')?.text ?? '',
      );
      if (updated.isEmpty && metaText.isNotEmpty) {
        final dateMatch = RegExp(r'\d{2,4}[-/]\d{1,2}[-/]\d{1,2}').firstMatch(
          metaText,
        );
        if (dateMatch != null) updated = dateMatch.group(0)!;
      }
      books.add(
        CloudBook(
          id: appId,
          title: title,
          updated: updated,
          latestChapterId: latestChapterId,
          latestChapter: latestChapter,
        ),
      );
    }
    return (books: books, caseIds: caseIds);
  }

  WenkuReviewPage _parseReviewsPage(Document doc, int currentPage) {
    final items = <WenkuReview>[];
    for (final li in doc.querySelectorAll('#list_content li.book-li')) {
      final link = li.querySelector('a[href]');
      final href = link?.attributes['href'] ?? '';
      final tidMatch =
          RegExp(r'reviewshow_(\d+)').firstMatch(href) ??
          RegExp(r'[?&]tid=(\d+)').firstMatch(href);
      final tid = tidMatch == null ? 0 : (int.tryParse(tidMatch.group(1)!) ?? 0);
      final user = normalizeText(li.querySelector('.book-meta-l em')?.text ?? '');
      final time = normalizeText(
        li.querySelector('.book-comment-time')?.text ?? '',
      );
      final content = normalizeText(
        li.querySelector('.book-comment-p')?.text ?? '',
      );
      final metaR = normalizeText(li.querySelector('.book-meta-r')?.text ?? '');
      final replyMatch = RegExp(r'\d+/(\d+)').firstMatch(metaR);
      final replyCount = replyMatch == null
          ? 0
          : (int.tryParse(replyMatch.group(1)!) ?? 0);
      if (content.isEmpty && user.isEmpty) continue;
      items.add(
        WenkuReview(
          id: tid,
          user: user.isEmpty ? '匿名讀者' : user,
          userId: 0,
          title: '',
          content: content,
          timestamp: time,
          replies: replyCount,
        ),
      );
    }
    final totalPages = _parseReviewTotalPages(doc, currentPage, items.isNotEmpty);
    return WenkuReviewPage(items, totalPages);
  }

  WenkuReviewPage _parseThreadRepliesPage(Document doc, int currentPage) {
    final items = <WenkuReview>[];
    for (final li in doc.querySelectorAll('#list_content li.book-li, .book-ol-comment li.book-li')) {
      final user = normalizeText(li.querySelector('.book-meta-l em')?.text ?? '');
      final time = normalizeText(
        li.querySelector('.book-comment-time')?.text ?? '',
      );
      final content = normalizeText(
        li.querySelector('.book-comment-p')?.text ?? '',
      );
      if (content.isEmpty) continue;
      items.add(
        WenkuReview(
          id: 0,
          user: user.isEmpty ? '匿名讀者' : user,
          userId: 0,
          title: '',
          content: content,
          timestamp: time,
          replies: 0,
        ),
      );
    }
    final totalPages = _parseReviewTotalPages(doc, currentPage, items.isNotEmpty);
    return WenkuReviewPage(items, totalPages);
  }

  int _parseReviewTotalPages(Document doc, int currentPage, bool hasItems) {
    var maxPage = currentPage;
    for (final a in doc.querySelectorAll('.pagelink a, .pages a, .page a')) {
      final href = a.attributes['href'] ?? '';
      final match =
          RegExp(r'_(\d+)\.html').firstMatch(href) ??
          RegExp(r'[?&]page=(\d+)').firstMatch(href);
      final parsed = match == null ? null : int.tryParse(match.group(1)!);
      if (parsed != null && parsed > maxPage) maxPage = parsed;
    }
    if (maxPage == currentPage && !hasItems && currentPage == 1) return 1;
    return maxPage;
  }

  WenkuProfile? _profileFromCookies(Map<String, String> cookies) {
    final raw = cookies['jieqiUserInfo'];
    if (raw == null || raw.isEmpty) return null;
    final decoded = Uri.decodeComponent(raw);
    final fields = <String, String>{};
    for (final part in decoded.split(',')) {
      final idx = part.indexOf('=');
      if (idx <= 0) continue;
      fields[part.substring(0, idx).trim()] = part.substring(idx + 1).trim();
    }
    final uid = int.tryParse(fields['jieqiUserId'] ?? '');
    final uname = fields['jieqiUserUname'] ?? '';
    final nick = fields['jieqiUserName'] ?? uname;
    if (uid == null && uname.isEmpty && nick.isEmpty) return null;
    return WenkuProfile(
      id: uid ?? _fallbackUid(uname.isNotEmpty ? uname : nick),
      username: uname.isNotEmpty ? uname : nick,
      nickname: nick,
      score:
          int.tryParse(
            fields['jieqiUserScore'] ?? fields['jieqiUserEgolds'] ?? '',
          ) ??
          0,
      experience:
          int.tryParse(
            fields['jieqiUserExperience'] ?? fields['jieqiUserExp'] ?? '',
          ) ??
          0,
      rank: fields['jieqiUserGroupName'] ?? '正式會員',
    );
  }

  bool _hasAuthCookie(Map<String, String> cookies) =>
      cookies.containsKey('jieqiUserInfo') || cookies.containsKey('PHPSESSID');

  bool _isLoginPage(Uri uri, Document doc) =>
      uri.path.contains('login.php') ||
      doc.querySelector('form[name="frmlogin"]') != null;

  bool _isCaptchaBlocked(Document doc) =>
      doc.querySelector('input[name="checkcode"], img#imgccode') != null;

  String? _extractSiteError(Document doc) {
    final title = normalizeText(doc.querySelector('title')?.text ?? '');
    final heading = normalizeText(
      doc.querySelector('.aui-center-title')?.text ?? '',
    );
    if (!title.contains('錯誤') &&
        !title.contains('错误') &&
        !heading.contains('錯誤') &&
        !heading.contains('错误')) {
      return null;
    }
    final form = doc.querySelector('.aui-ver-form');
    if (form == null) return '操作未能完成，请重试';
    final cloned = form.clone(true);
    cloned.querySelectorAll('a, script, button').forEach((e) => e.remove());
    final cleaned = normalizeText(cloned.text)
        .replaceAll(RegExp(r'\s*請\s*並修正\s*'), '')
        .trim();
    return cleaned.isEmpty ? '操作未能完成，请重试' : cleaned;
  }

  int _fallbackUid(String name) {
    var hash = 0x811c9dc5;
    for (final c in name.codeUnits) {
      hash ^= c;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash == 0 ? 1 : hash;
  }

  String _todayKey() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  void _persistCookies(Map<String, String> cookies) {
    if (!authenticated && cookies.isEmpty) return;
    unawaited(_persistCookiesNow(cookies));
  }

  Future<void> _persistCookiesNow(Map<String, String> cookies) =>
      _preferences.setString(_cookiesKey, jsonEncode(cookies));

  Future<void> _persistProfile(WenkuProfile value) => _preferences.setString(
    _profileKey,
    jsonEncode({
      'id': value.id,
      'username': value.username,
      'nickname': value.nickname,
      'score': value.score,
      'experience': value.experience,
      'rank': value.rank,
    }),
  );

  WenkuProfile? _restoreProfile() {
    final raw = _preferences.getString(_profileKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      return WenkuProfile(
        id: (map['id'] as num?)?.toInt() ?? 0,
        username: (map['username'] as String?) ?? '',
        nickname: (map['nickname'] as String?) ?? '',
        score: (map['score'] as num?)?.toInt() ?? 0,
        experience: (map['experience'] as num?)?.toInt() ?? 0,
        rank: (map['rank'] as String?) ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}

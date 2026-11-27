import 'release_notices.dart';

class ReleaseSection {
  const ReleaseSection(this.title, this.items);
  final String title;
  final List<String> items;
}

const releaseFreeNotice = '**本项目完全免费、开源，无任何赞助、打赏或付费渠道。**';
const releaseReadingNotice =
    '**第三方阅读客户端，仅提供阅读界面与本地书籍管理；不运营在线书库、不附带小说文件，在线内容及可读状态以 tw.linovelib.com 为准。**';
const _freeNotice = '不出售会员或解锁服务；升级前请先备份本地书库与阅读记录。';
const _sourceSwitch =
    '在线书源切换为哔哩轻小说（tw.linovelib.com）：支持发现、搜索、目录、正文、插图、账号登录、云书架双向同步、推荐与书评查看。';
const _bunkobonLayout =
    '新增平板与手机文库本（105:148）阅读版面：竖屏保持单页专注，横屏及折叠屏展开自动切换双页。';
const _upstreamCompat =
    '应用内更新已独立接入 Rynowastaken/LinoBunko Releases；本地书籍、WebDAV/S3 同步与本地局域网续读可与上游互通，在线书目（LN-）互相隔离。';
const _installNotes =
    'Android 安装包使用调试签名，可直接侧载（覆盖不同签名预览版前请先备份）；iOS IPA 与 HarmonyOS HAP 需自行签名后安装。';

const publicReleaseNotes =
    '''
> **$currentReleaseSourcePolicy**

- $releaseFreeNotice $_freeNotice
- $releaseReadingNotice
- $_sourceSwitch
- $_bunkobonLayout
- $_upstreamCompat
- $_installNotes
''';

const currentReleaseNotes = publicReleaseNotes;

const currentReleaseSummary = [
  currentReleaseSourcePolicy,
  _sourceSwitch,
  _bunkobonLayout,
  _upstreamCompat,
];

const currentReleaseSections = [
  ReleaseSection('重要说明', [
    releaseFreeNotice,
    releaseReadingNotice,
    currentReleaseSourcePolicy,
    _freeNotice,
  ]),
  ReleaseSection('LinoBunko 适配', [
    _sourceSwitch,
    _bunkobonLayout,
    _upstreamCompat,
  ]),
  ReleaseSection('更新与安装', [
    _installNotes,
  ]),
];

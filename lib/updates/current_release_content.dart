import 'release_notices.dart';

class ReleaseSection {
  const ReleaseSection(this.title, this.items);
  final String title;
  final List<String> items;
}

const inAppCommunityNotice = '**交流群：1131397088**\n遇到问题或有功能建议，欢迎进群反馈。';
const releaseFreeNotice = '**本项目完全免费、开源，无任何赞助、打赏或付费渠道。**';
const releaseReadingNotice =
    '**本项目仅为第三方阅读客户端，提供阅读界面与本地书籍管理，不运营在线书库、不自行发布小说资源。在线内容及可读状态一切以 tw.linovelib.com 为准；不提供因版权限制而停止开放的在线书籍阅读。**';
const _freeNotice = '不出售会员、激活码或功能解锁服务。任何以本项目或开发者名义收费、募捐、索要赞助的行为均与本项目无关，请勿付款。';
const _downloadNotice = '请通过项目仓库或 App 内更新获取安装包；升级前请备份原书和阅读记录。';
const _sourceSwitch =
    '在线书源已切换为哔哩轻小说（tw.linovelib.com）：支持发现、分类、详情、目录、正文、插图与离线缓存；搜索使用随包书目快照。';
const _sourceLimits = '本分支不包含文库账号、云书架、评论或签到；本地书籍与已缓存章节保留，旧书源在线条目需重新搜索添加。';
const _imports = '修复 iOS 背景、字体和本地书籍的文件选择；保留默认关联原文件与显式复制导入，修复重启后书架列表恢复异常。';
const _connection = '连接检查优先处理，限制检查等待时间，失败后可重新检查；官网要求验证时保留明确提示。';
const _updates =
    'iOS 与 HarmonyOS 支持应用内自动提醒和手动检查，仅在对应平台有新安装包时提醒；通过版本页下载、自行签名后安装。';
const _androidInstall =
    'Android 安装包版本 0.5.1 (263)，使用调试签名，可直接侧载；若已安装同包名但签名不同的旧预览版，请先备份并卸载。';
const publicReleaseNotes =
    '''
### ⚠️ 免费开源，请勿付费

$releaseFreeNotice

$_freeNotice

$_downloadNotice

$releaseReadingNotice

**$currentReleaseSourcePolicy**

### 书源与阅读
- $_sourceSwitch
- $_sourceLimits

### 本地阅读
- $_imports
- $_connection

### 更新提醒与安装
- $_updates
- $_androidInstall
- iOS IPA 与 HarmonyOS HAP 均未签名，需要自行签名后安装。
''';
const currentReleaseNotes = '$inAppCommunityNotice\n\n$publicReleaseNotes';
const currentReleaseSummary = [
  inAppCommunityNotice,
  releaseFreeNotice,
  releaseReadingNotice,
  currentReleaseSourcePolicy,
  _sourceSwitch,
  _sourceLimits,
  _imports,
  _connection,
  _updates,
  _androidInstall,
];
const currentReleaseSections = [
  ReleaseSection('重要说明 · 请务必阅读', [
    inAppCommunityNotice,
    releaseFreeNotice,
    _freeNotice,
    _downloadNotice,
    releaseReadingNotice,
    currentReleaseSourcePolicy,
  ]),
  ReleaseSection('书源与阅读', [_sourceSwitch, _sourceLimits]),
  ReleaseSection('文件导入与书架', [_imports, _connection]),
  ReleaseSection('更新提醒与安装', [
    _updates,
    _androidInstall,
    'iOS IPA 与 HarmonyOS HAP 均未签名，需要自行签名后安装。',
  ]),
];

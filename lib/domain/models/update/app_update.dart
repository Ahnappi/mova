import '../../../config/app_config.dart';

/// 一个「可用的新版本」（Domain 层，纯 Dart 模型）。
///
/// 信息全部来自远端的版本清单，本地不做任何网络或存储操作。
class AppUpdate {
  const AppUpdate({
    required this.versionName,
    required this.versionCode,
    required this.downloadUrl,
    this.notes = '',
    this.mandatory = false,
  });

  /// 新版本的名字（x.y.z），只用于展示。
  final String versionName;

  /// 新版本的号（整数）：判断新旧只用它，见 [AppConfig.appBuildNumber]。
  final int versionCode;

  /// 下载页地址（交给系统浏览器打开）。
  final String downloadUrl;

  /// 更新说明。
  final String notes;

  /// 是否「强烈建议更新」（比如修了会导致传输出错的问题）。
  ///
  /// 桌面端没有强制升级的合理手段——把用户锁在升级弹窗里，
  /// 他就连正在传的文件都管不了了。这里只影响文案的措辞。
  final bool mandatory;

  /// 是否比当前版本新。
  bool get isNewer => versionCode > AppConfig.appBuildNumber;

  /// 清单里给的是不是一个能打开的下载地址。
  ///
  /// 只看「非空」不够：清单可能给空串、给 `null`、或者手误写成
  /// 一个不是网址的串（版本号、文件名、相对路径）。把这种东西交给
  /// 浏览器，结果就是按钮点了没反应——用户只知道「下载不了」，
  /// 不知道该去哪儿。
  bool get hasDownloadUrl => isUsableDownloadUrl(downloadUrl);

  /// [url] 是否能作为下载页打开：http(s) 且带主机名。
  static bool isUsableDownloadUrl(String? url) {
    if (url == null) return false;
    final trimmed = url.trim();
    if (trimmed.isEmpty) return false;

    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) return false;
    return uri.scheme == 'http' || uri.scheme == 'https';
  }

  /// 解析版本清单；字段缺失或类型不对时返回 null。
  ///
  /// 返回 null 而不是抛异常，是为了让「清单格式不对」和「请求失败」
  /// 走同一条路：都当作这次没查到，而不是弹一个看不懂的报错。
  static AppUpdate? tryParse(Object? raw) {
    if (raw is! Map) return null;

    final code = raw['versionCode'];
    if (code is! int) return null;

    final name = raw['versionName'];
    final url = raw['url'];
    final notes = raw['notes'];
    final mandatory = raw['mandatory'];

    return AppUpdate(
      versionName: name is String && name.isNotEmpty
          ? name
          : '${(code / 100).floor()}.${(code % 100)}.0',
      versionCode: code,
      downloadUrl: url is String ? url : '',
      notes: notes is String ? notes : '',
      mandatory: mandatory == true,
    );
  }
}

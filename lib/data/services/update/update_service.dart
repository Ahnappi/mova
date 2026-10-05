import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

import '../../../config/app_config.dart';
import '../../../domain/models/update/app_update.dart';
import '../../../utils/result.dart';

/// 拉取版本清单的函数（测试里换成假实现，不碰网络）。
typedef ManifestFetcher = Future<String> Function(Uri url, Duration timeout);

/// 版本更新数据源（Service 层）：只回答「有没有新版本、去哪儿下」。
///
/// 不负责界面，也不保存任何状态——「要不要提醒、提醒过没有」由更上层决定。
class UpdateService {
  UpdateService({ManifestFetcher? fetcher})
      : _fetcher = fetcher ?? _httpGet;

  final ManifestFetcher _fetcher;
  final Logger _log = Logger('UpdateService');

  /// 检查有没有新版本。
  ///
  /// 三种结果用返回值区分，调用方必须都处理：
  /// - `Ok(null)`：已经是最新；
  /// - `Ok(update)`：有更新；
  /// - `Error`：这次没查成（没网 / 超时 / 清单格式不对）。
  ///
  /// 查不到**永远不等于**「没有新版本」：把失败当成「已是最新」的话，
  /// 用户在断网环境下点多少次都只看到一句「已是最新」，
  /// 也就永远不会去升级了。
  Future<Result<AppUpdate?>> check() async {
    final Uri uri;
    try {
      uri = Uri.parse(AppConfig.updateManifestUrl);
    } catch (e) {
      return Result.error(Exception('版本清单地址不合法：$e'));
    }

    final String body;
    try {
      body = await _fetcher(uri, AppConfig.updateCheckTimeout);
    } catch (e) {
      _log.info('拉取版本清单失败：$e');
      return Result.error(Exception('检查更新失败：$e'));
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (e) {
      _log.warning('版本清单不是合法 JSON：$e');
      return Result.error(Exception('版本清单不是合法 JSON：$e'));
    }

    final update = AppUpdate.tryParse(decoded);
    if (update == null) {
      return Result.error(
        Exception('版本清单里没有可用的版本号（缺少 versionCode）'),
      );
    }
    if (!update.isNewer) return const Result.ok(null);
    return Result.ok(update);
  }

  /// 默认的拉取实现：[HttpClient] + 超时（重定向由 HttpClient 自己跟）。
  ///
  /// 没有为此引入 http 包：一次 GET 加一串字节的解析，
  /// 不值得多一个依赖（桌面端 dart:io 本来就有）。
  static Future<String> _httpGet(Uri url, Duration timeout) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(url).timeout(timeout);
      final response = await request.close().timeout(timeout);
      final body =
          await response.transform(utf8.decoder).join().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}', uri: url);
      }
      return body;
    } finally {
      // force：检查更新是一次性的，没必要留着连接等它自己超时。
      client.close(force: true);
    }
  }
}

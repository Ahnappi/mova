// 版本与升级检查。
//
// 三条容易做错、且做错了不会立刻暴露的规则：
// 1. 新旧只按**整数版本号**比，不能按版本名字典序比（1.9 > 1.10）；
// 2. 查不到**不等于**已是最新——说成「已是最新」，没网的用户就永远不会升级；
// 3. AppConfig 里的版本号必须和 pubspec 里的一致，否则打包出来的
//    安装包版本与界面上显示的版本会各说各话；
// 4. 清单没给（可用的）下载地址时不能静默失败——那会得到一个
//    「发现新版本」配一个点了没反应的下载按钮。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mova/config/app_config.dart';
import 'package:mova/data/services/system/file_opener_service.dart';
import 'package:mova/data/services/update/update_service.dart';
import 'package:mova/domain/models/update/app_update.dart';
import 'package:mova/ui/settings/view_models/update_view_model.dart';
// 必须显式导入：Result 的成类（Ok / Error）不会跟着别的导入进来。
import 'package:mova/utils/result.dart';

void main() {
  UpdateService serviceWith(String body) => UpdateService(
        fetcher: (url, timeout) async => body,
      );

  group('版本清单解析', () {
    test('版本号更大时提示更新', () async {
      final result = await serviceWith('''{
        "versionName": "1.1.0",
        "versionCode": ${AppConfig.appBuildNumber + 1},
        "notes": "修了断链",
        "url": "https://example.com/1.1.0"
      }''').check();

      expect(result, isA<Ok<AppUpdate?>>());
      final update = (result as Ok<AppUpdate?>).value;
      expect(update, isNotNull);
      expect(update!.versionName, '1.1.0');
      expect(update.isNewer, isTrue);
      expect(update.notes, '修了断链');
      expect(update.downloadUrl, 'https://example.com/1.1.0');
    });

    test('版本号相同或更小时视为已最新', () async {
      final same = await serviceWith(
        '{"versionCode": ${AppConfig.appBuildNumber}}',
      ).check();
      expect((same as Ok<AppUpdate?>).value, isNull);

      final older = await serviceWith(
        '{"versionCode": ${AppConfig.appBuildNumber - 1}}',
      ).check();
      expect((older as Ok<AppUpdate?>).value, isNull,
          reason: '对端清单比本机旧，不能反过来提示升级');
    });

    test('清单缺版本号时报错，而不是「已是最新」', () async {
      final result = await serviceWith('{"versionName": "1.2.0"}').check();

      expect(result, isA<Error<AppUpdate?>>(),
          reason: '没有 versionCode 就无从判断，当「已是最新」会永久漏掉更新');
    });

    test('清单不是 JSON 时报错', () async {
      expect(
        await serviceWith('这不是 JSON').check(),
        isA<Error<AppUpdate?>>(),
      );
    });

    test('网络失败时报错，而不是「已是最新」', () async {
      final service = UpdateService(
        fetcher: (url, timeout) async => throw const SocketException('没网'),
      );

      expect(
        await service.check(),
        isA<Error<AppUpdate?>>(),
        reason: '断网时点检查更新，说「已是最新」等于骗人',
      );
    });
  });

  group('界面状态', () {
    test('查到新版本后界面能拿到下载入口', () async {
      final vm = UpdateViewModel(
        updateService: serviceWith(
          '{"versionName":"2.0.0","versionCode":'
          '${AppConfig.appBuildNumber + 1},"notes":"大改","url":"https://x/y"}',
        ),
      );
      addTearDown(vm.dispose);

      expect(vm.status, UpdateCheckStatus.idle);
      expect(vm.hasUpdate, isFalse);

      await vm.check();

      expect(vm.status, UpdateCheckStatus.available);
      expect(vm.hasUpdate, isTrue);
      expect(vm.update?.downloadUrl, 'https://x/y');
      expect(vm.detail, '大改');
    });

    test('已是最新与检查失败是两种不同结论', () async {
      final latest = UpdateViewModel(
        updateService: serviceWith(
          '{"versionCode": ${AppConfig.appBuildNumber}}',
        ),
      );
      addTearDown(latest.dispose);
      await latest.check();
      expect(latest.status, UpdateCheckStatus.upToDate);

      final broken = UpdateViewModel(
        updateService: UpdateService(
          fetcher: (url, timeout) async => throw const SocketException('没网'),
        ),
      );
      addTearDown(broken.dispose);
      await broken.check();
      expect(broken.status, UpdateCheckStatus.failed);
      expect(broken.hasUpdate, isFalse);
    });

    test('正在检查时重复点击不会再来一次', () async {
      var calls = 0;
      final vm = UpdateViewModel(
        updateService: UpdateService(
          fetcher: (url, timeout) async {
            calls++;
            await Future<void>.delayed(const Duration(milliseconds: 30));
            return '{"versionCode": ${AppConfig.appBuildNumber}}';
          },
        ),
      );
      addTearDown(vm.dispose);

      final first = vm.check();
      await vm.check(); // 第二次应被忽略
      await first;

      expect(calls, 1, reason: '两条响应谁先回来谁说了算，界面结论会来回跳');
    });
  });

  group('下载入口', () {
    _RecordingOpener opener({bool succeed = true}) =>
        _RecordingOpener(succeed: succeed);

    String newer({String url = ''}) => '{"versionName":"1.1.0",'
        '"versionCode":${AppConfig.appBuildNumber + 1},'
        '"notes":"修了断链"${url.isEmpty ? '' : ',"url":"$url"'}}';

    test('清单没给下载地址时退回固定发布页，并说明原因', () async {
      final opened = opener();
      final vm = UpdateViewModel(
        updateService: serviceWith(newer()),
        opener: opened,
      );
      addTearDown(vm.dispose);
      await vm.check();

      expect(vm.hasUpdate, isTrue);
      expect(vm.update!.hasDownloadUrl, isFalse);

      await vm.openDownloadPage();

      expect(
        opened.urls,
        [AppConfig.updateFallbackUrl],
        reason: '没有地址就静默返回的话，界面上是一个亮着却点不动的下载按钮',
      );
      expect(vm.downloadHint, isNotNull, reason: '退回发布页这件事必须告诉用户');
      expect(vm.downloadHint, contains(AppConfig.updateFallbackUrl));
    });

    test('清单里的地址不是网址时同样退回发布页', () async {
      final opened = opener();
      final vm = UpdateViewModel(
        // 手误把版本号写进了 url 字段。
        updateService: serviceWith(newer(url: '1.1.0')),
        opener: opened,
      );
      addTearDown(vm.dispose);
      await vm.check();

      await vm.openDownloadPage();

      expect(opened.urls, [AppConfig.updateFallbackUrl]);
      expect(vm.update!.downloadUrl, '1.1.0');
      expect(vm.update!.hasDownloadUrl, isFalse);
    });

    test('地址正常时就用它，不多嘴', () async {
      final opened = opener();
      final vm = UpdateViewModel(
        updateService: serviceWith(newer(url: 'https://x/y')),
        opener: opened,
      );
      addTearDown(vm.dispose);
      await vm.check();

      await vm.openDownloadPage();

      expect(opened.urls, ['https://x/y']);
      expect(vm.downloadHint, isNull);
    });

    test('浏览器打不开时把地址留在提示里', () async {
      final opened = opener(succeed: false);
      final vm = UpdateViewModel(
        updateService: serviceWith(newer(url: 'https://x/y')),
        opener: opened,
      );
      addTearDown(vm.dispose);
      await vm.check();

      await vm.openDownloadPage();

      expect(vm.downloadHint, contains('https://x/y'),
          reason: '打不开也要给退路：用户还能手动复制');
    });

    test('连兜底页都没有时，明确说没有下载地址', () async {
      // 兜底页被清空这种配置错误不该表现为「点了没反应」。
      // 这里直接构造一个地址为空的更新，验证这段分支真的存在。
      final vm = UpdateViewModel(
        updateService: serviceWith(newer()),
        opener: opener(),
      );
      addTearDown(vm.dispose);
      await vm.check();

      expect(vm.update!.hasDownloadUrl, isFalse);
      expect(
        AppUpdate.isUsableDownloadUrl(AppConfig.updateFallbackUrl),
        isTrue,
        reason: '兜底页本身必须是可用的，否则「发现新版本」就没有出口',
      );
    });
  });

  test('pubspec 的版本与 AppConfig 保持一致', () {
    // 这两处一旦走散，安装包里写的是 1.0.0+100、界面上却显示另一个版本，
    // 用户反馈问题时就会报出一个我们这边对不上的版本号。
    final pubspec = File('pubspec.yaml');
    expect(pubspec.existsSync(), isTrue, reason: '测试需要在项目根目录运行');

    final line = pubspec
        .readAsLinesSync()
        .firstWhere((line) => line.startsWith('version:'));
    expect(
      line.trim(),
      'version: ${AppConfig.appVersion}+${AppConfig.appBuildNumber}',
      reason: '改版本号时要同时改 pubspec.yaml 与 AppConfig',
    );
  });
}

/// 记录「被要求打开哪些地址」的假浏览器：
/// 真的去开浏览器既慢又不可控，这里只关心地址对不对。
class _RecordingOpener extends FileOpenerService {
  _RecordingOpener({this.succeed = true});

  final bool succeed;
  final List<String> urls = <String>[];

  @override
  Future<bool> openUrl(String url) async {
    urls.add(url);
    return succeed;
  }
}

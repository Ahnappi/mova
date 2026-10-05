// 设置里的「版本与更新」：入口真的在那儿，点下去真的有反馈。
//
// 纯逻辑测过之后还要过一遍界面，是因为这条链路上有一个只会在界面层
// 暴露的问题：结果区靠 `context.watch` 订阅 ViewModel，
// 订阅不到就永远停在「点了没反应」。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:mova/config/app_config.dart';
import 'package:mova/data/repositories/settings/settings_repository.dart';
import 'package:mova/data/services/network/network_info_service.dart';
import 'package:mova/data/services/system/file_opener_service.dart';
import 'package:mova/data/services/update/update_service.dart';
import 'package:mova/domain/models/settings/app_settings.dart';
import 'package:mova/ui/settings/view_models/settings_view_model.dart';
import 'package:mova/ui/settings/view_models/update_view_model.dart';
import 'package:mova/ui/settings/widgets/settings_dialog.dart';

import 'support/fake_transfer_repository.dart';

void main() {
  // 默认测试视口只有 800x600，设置弹窗里的「版本与更新」要滚动才够得着。
  // 放大视口之后用例就不必掺进滚动这一步，失败了也好读。
  void enlarge(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
  }

  /// 打开设置 → 滚到「检查更新」→ 点一下。
  Future<void> openAndCheck(WidgetTester tester) async {
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('检查更新'),
      300.0,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
  }

  testWidgets('设置里有版本与更新，查到新版本会给出下载入口', (tester) async {
    enlarge(tester);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _Host(
        manifest: '{"versionName":"1.1.0","versionCode":'
            '${AppConfig.appBuildNumber + 1},"notes":"修了断链",'
            '"url":"https://x/y"}',
      ),
    );

    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();

    expect(find.text('版本与更新'), findsOneWidget);
    expect(find.text('当前版本 ${AppConfig.versionLabel}'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('检查更新'),
      300.0,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();

    expect(find.textContaining('发现新版本 1.1.0'), findsOneWidget);
    expect(find.text('修了断链'), findsOneWidget);
    expect(find.text('打开下载页'), findsOneWidget);
  });

  testWidgets('已经是最新版本时给出明确结论', (tester) async {
    enlarge(tester);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _Host(manifest: '{"versionCode": ${AppConfig.appBuildNumber}}'),
    );

    await openAndCheck(tester);
    expect(find.text('已经是最新版本'), findsOneWidget);
  });

  testWidgets('没查到更新时不能说「已是最新」', (tester) async {
    enlarge(tester);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_Host(broken: true));

    await openAndCheck(tester);
    expect(find.textContaining('没查到更新'), findsOneWidget);
  });

  testWidgets('清单没给下载地址时，点「打开下载页」也要有反馈', (tester) async {
    enlarge(tester);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_Host(manifest: _newerWithoutUrl));

    await openAndCheck(tester);

    // 结果区在「检查更新」按钮下方，先滚到它再点，
    // 否则点的是一个还没进入视口的按钮（flutter test 会报 missed tap）。
    await tester.scrollUntilVisible(
      find.text('打开下载页'),
      300.0,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('打开下载页'));
    await tester.pumpAndSettle();

    // 静默失败的话，这里什么都不会出现，用户只会以为按钮坏了。
    expect(find.textContaining('项目发布页'), findsOneWidget);
  });
}

/// 版本号比本机新，但清单里没有 url 字段。
final String _newerWithoutUrl = '{"versionName":"1.1.0","versionCode":'
    '${AppConfig.appBuildNumber + 1},"notes":"修了断链"}';

class _Host extends StatelessWidget {
  const _Host({this.manifest = '{}', this.broken = false});

  final String manifest;
  final bool broken;

  @override
  Widget build(BuildContext context) {
    // Provider 必须压在 MaterialApp **上面**：弹窗是 Navigator 里的一条
    // 新路由，只继承 Navigator 之上的节点，挂在 home 里它根本看不到。
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => SettingsViewModel(
            settingsRepository: _MemorySettingsRepository(),
            historyRepository: NoopHistoryRepository(),
            networkInfoService: NetworkInfoService(),
          )..load(),
        ),
        ChangeNotifierProvider(
          create: (_) => UpdateViewModel(
            updateService: UpdateService(
              fetcher: (url, timeout) async {
                if (broken) throw const FormatException('模拟：连不上');
                return manifest;
              },
            ),
            // 假的：测试里不能真的去开浏览器。
            opener: _FakeOpener(),
          ),
        ),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSettingsDialog(context),
            child: const Text('打开设置'),
          ),
        ),
      ),
    );
  }
}

/// 只记录、不真去开浏览器的 FileOpenerService。
class _FakeOpener extends FileOpenerService {
  @override
  Future<bool> openUrl(String url) async => true;
}

class _MemorySettingsRepository implements SettingsRepository {
  AppSettings _value = const AppSettings();

  @override
  Future<AppSettings> load() async => _value;

  @override
  Future<void> save(AppSettings settings) async {
    _value = settings;
  }
}

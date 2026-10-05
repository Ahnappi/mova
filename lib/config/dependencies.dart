import 'dart:async';

import 'package:logging/logging.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import 'app_shutdown.dart';
import 'window_controller.dart';
import '../data/repositories/chat/chat_repository.dart';
import '../data/repositories/chat/chat_repository_local.dart';
import '../data/repositories/counter/counter_repository.dart';
import '../data/repositories/counter/counter_repository_local.dart';
import '../data/repositories/discovery/discovery_repository.dart';
import '../data/repositories/discovery/discovery_repository_local.dart';
import '../data/repositories/history/history_repository.dart';
import '../data/repositories/history/history_repository_local.dart';
import '../data/repositories/settings/settings_repository.dart';
import '../data/repositories/settings/settings_repository_local.dart';
import '../data/repositories/storage/storage_repository.dart';
import '../data/repositories/storage/storage_repository_local.dart';
import '../data/repositories/transfer/transfer_repository.dart';
import '../data/repositories/transfer/transfer_repository_local.dart';
import '../data/services/chat/chat_transport_service.dart';
import '../data/services/counter/counter_service.dart';
import '../data/services/discovery/discovery_service.dart';
import '../data/services/history/history_storage_service.dart';
import '../data/services/network/network_info_service.dart';
import '../data/services/storage/log_service.dart';
import '../data/services/storage/settings_service.dart';
import '../data/services/storage/storage_service.dart';
import '../data/services/system/file_opener_service.dart';
import '../data/services/system/system_settings_service.dart';
import '../data/services/transfer/file_storage_service.dart';
import '../data/services/transfer/incoming_file_writer.dart';
import '../data/services/update/update_service.dart';
import '../ui/chat/view_models/chat_view_model.dart';
import '../ui/chat/view_models/connection_view_model.dart';
import '../ui/counter/view_models/counter_view_model.dart';
import '../ui/settings/view_models/settings_view_model.dart';
import '../ui/settings/view_models/update_view_model.dart';
import '../ui/transfer/view_models/transfer_view_model.dart';

/// 依赖装配（参照 compass_app 的 config/dependencies.dart）。
///
/// 装配顺序：Service → Repository(具体实现) → ViewModel。
/// 之后替换传输方式（如加密传输）或发现方式（如 mDNS）时，
/// 只需在此替换实现，UI 与 ViewModel 无需改动。
///
/// [storageService] / [logService] 可由入口传入，
/// 以便日志在 runApp 之前就开始落盘（见 main.dart）。
///
/// [window] 同样是**为了测试**：Widget 测试没有原生插件实现，
/// 直接调 `windowManager.setPreventClose()` 会抛 MissingPluginException。
/// 注入替身之后，退出流程这条入口才能被真正验证。
List<SingleChildWidget> buildProviders({
  StorageService? storageService,
  LogService? logService,
  WindowController? window,
}) {
  final storage = storageService ?? StorageService();
  final log = logService ?? LogService(storage);

  return [
    // ---------- 计数器（分层结构演示，保留参考） ----------
    Provider(create: (context) => CounterService()),
    Provider(
      create: (context) =>
          CounterRepositoryLocal(context.read()) as CounterRepository,
    ),
    ChangeNotifierProvider(
      create: (context) => CounterViewModel(counterRepository: context.read()),
    ),

    // ---------- 本地存储 ----------
    // Service 层
    Provider.value(value: storage),
    Provider.value(value: log),
    Provider(create: (context) => SettingsService(context.read())),

    // 用户偏好（设备名 / 记录保留期限 / 发送前确认）。
    // 放在历史仓储之前：后者要靠它知道「记录保留多久」。
    Provider(
      create: (context) =>
          SettingsRepositoryLocal(context.read()) as SettingsRepository,
    ),

    // ---------- 连接记录 ----------
    // Service 层
    Provider(create: (context) => HistoryStorageService(context.read())),

    // Repository 层（先于存储装配：存储条目要展示记录文件的路径）
    //
    // 注意：这个 dispose 回调是**同步**的，宿主不会 await 它，
    // 因此它只能算「兜底的尽力保存」。真正的退出流程在 [AppShutdown]
    // 里：那里会 await 这里的 dispose()，等写入队列落地后再写最终快照。
    //
    // 写盘失败时 dispose() 会抛出（见 HistoryRepositoryLocal），
    // `unawaited` 又没人接结果，不 catchError 就是一条没人管的异步错误。
    Provider(
      create: (context) => HistoryRepositoryLocal(
        context.read(),
        settingsRepository: context.read(),
      ) as HistoryRepository,
      dispose: (_, repository) {
        unawaited(repository.dispose().catchError((Object e) {
          Logger('HistoryRepository').warning('兜底的收尾保存失败：$e');
        }));
      },
    ),

    // Repository 层
    Provider(
      create: (context) => StorageRepositoryLocal(
        storageService: context.read(),
        settingsService: context.read(),
        logService: context.read(),
        historyRepository: context.read(),
      ) as StorageRepository,
    ),

    // ---------- 局域网互传 ----------
    // Service 层
    Provider(create: (context) => NetworkInfoService()),
    Provider(create: (context) => SystemSettingsService()),
    // 版本更新：只在用户点「检查更新」时才发一次请求，不后台轮询。
    Provider(create: (context) => UpdateService()),
    // 应用内预览不了的格式（Office / SVG / HEIC）用它交给系统打开。
    Provider(create: (context) => FileOpenerService()),
    Provider(
      create: (context) => DiscoveryService(),
      dispose: (_, service) {
        service.dispose();
      },
    ),
    Provider(
      create: (context) => ChatTransportService(),
      dispose: (_, service) {
        service.dispose();
      },
    ),

    Provider(
      create: (context) => FileStorageService(
        settingsService: context.read(),
        storageService: context.read(),
      ),
    ),
    // 接收端后台落盘（独立 isolate），由传输仓储持有。
    Provider(
      create: (context) => IncomingFileWriter(),
      dispose: (_, writer) {
        unawaited(writer.dispose());
      },
    ),

    // Repository 层
    Provider(
      create: (context) =>
          DiscoveryRepositoryLocal(context.read()) as DiscoveryRepository,
      dispose: (_, repository) {
        repository.dispose();
      },
    ),
    Provider(
      create: (context) => ChatRepositoryLocal(context.read()) as ChatRepository,
      dispose: (_, repository) {
        repository.dispose();
      },
    ),
    Provider(
      create: (context) => TransferRepositoryLocal(
        context.read(),
        context.read(),
        writer: context.read(),
      ) as TransferRepository,
      dispose: (_, repository) {
        repository.dispose();
      },
    ),

    // 退出流程：[AppShutdown] 要接管窗口关闭，必须在应用一开始就建好，
    // 因此这里 `lazy: false`——否则没人 read 它，它永远不会被创建，
    // 用户关窗口时也就没有任何人去保存最后一批记录。
    Provider(
      lazy: false,
      create: (context) {
        final shutdown = AppShutdown(
          history: context.read(),
          chat: context.read(),
          transfer: context.read(),
          window: window ?? const WindowManagerController(),
        );
        unawaited(shutdown.start());
        return shutdown;
      },
      dispose: (_, shutdown) {
        unawaited(shutdown.stop());
      },
    ),

    // ViewModel 层
    //
    // 顺序是有讲究的：**ConnectionViewModel 必须排在 SettingsViewModel 前面**。
    // `context.read` 只能向上找到**祖先**节点，而 MultiProvider 是把这些
    // provider 依次嵌套起来的——写在前面的在外层。SettingsViewModel 的
    // 「改名回调」要拿到 ConnectionViewModel 去重启广播，若它被注册在
    // 内层，回调触发时会直接抛 ProviderNotFoundException：
    // 设置其实已经存好了，但广播没重启（另一台设备看不到新名字），
    // 异常又正好打断了后面的提示，界面上一点反馈都没有。
    ChangeNotifierProvider(
      create: (context) => ConnectionViewModel(
        discoveryRepository: context.read(),
        chatRepository: context.read(),
        networkInfoService: context.read(),
        historyRepository: context.read(),
        systemSettingsService: context.read(),
        settingsRepository: context.read(),
      ),
    ),
    ChangeNotifierProvider(
      create: (context) => SettingsViewModel(
        settingsRepository: context.read(),
        historyRepository: context.read(),
        networkInfoService: context.read(),
        // 改名要立刻反映到下一拍 UDP 心跳上，否则对方要等到重启才看得到。
        onDeviceNameChanged: (name) =>
            context.read<ConnectionViewModel>().applyDeviceName(name),
      )..load(),
    ),
    ChangeNotifierProvider(
      create: (context) => UpdateViewModel(
        updateService: context.read(),
        opener: context.read(),
      ),
    ),
    ChangeNotifierProvider(
      create: (context) => ChatViewModel(
        chatRepository: context.read(),
        historyRepository: context.read(),
      ),
    ),
    ChangeNotifierProvider(
      create: (context) => TransferViewModel(
        transferRepository: context.read(),
        historyRepository: context.read(),
        systemSettingsService: context.read(),
      ),
    ),
  ];
}

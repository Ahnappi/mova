import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import '../data/repositories/chat/chat_repository.dart';
import '../data/repositories/chat/chat_repository_local.dart';
import '../data/repositories/counter/counter_repository.dart';
import '../data/repositories/counter/counter_repository_local.dart';
import '../data/repositories/discovery/discovery_repository.dart';
import '../data/repositories/discovery/discovery_repository_local.dart';
import '../data/repositories/history/history_repository.dart';
import '../data/repositories/history/history_repository_local.dart';
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
import '../data/services/transfer/file_storage_service.dart';
import '../ui/chat/view_models/chat_view_model.dart';
import '../ui/chat/view_models/connection_view_model.dart';
import '../ui/counter/view_models/counter_view_model.dart';
import '../ui/transfer/view_models/transfer_view_model.dart';

/// 依赖装配（参照 compass_app 的 config/dependencies.dart）。
///
/// 装配顺序：Service → Repository(具体实现) → ViewModel。
/// 之后替换传输方式（如加密传输）或发现方式（如 mDNS）时，
/// 只需在此替换实现，UI 与 ViewModel 无需改动。
///
/// [storageService] / [logService] 可由入口传入，
/// 以便日志在 runApp 之前就开始落盘（见 main.dart）。
List<SingleChildWidget> buildProviders({
  StorageService? storageService,
  LogService? logService,
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

    // ---------- 连接记录 ----------
    // Service 层
    Provider(create: (context) => HistoryStorageService(context.read())),

    // Repository 层（先于存储装配：存储条目要展示记录文件的路径）
    Provider(
      create: (context) =>
          HistoryRepositoryLocal(context.read()) as HistoryRepository,
      dispose: (_, repository) {
        repository.dispose();
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
      create: (context) =>
          TransferRepositoryLocal(context.read(), context.read())
              as TransferRepository,
      dispose: (_, repository) {
        repository.dispose();
      },
    ),

    // ViewModel 层
    ChangeNotifierProvider(
      create: (context) => ConnectionViewModel(
        discoveryRepository: context.read(),
        chatRepository: context.read(),
        networkInfoService: context.read(),
        historyRepository: context.read(),
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
        fileStorageService: context.read(),
        historyRepository: context.read(),
      ),
    ),
  ];
}

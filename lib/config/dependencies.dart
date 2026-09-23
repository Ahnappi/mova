import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import '../data/repositories/chat/chat_repository.dart';
import '../data/repositories/chat/chat_repository_local.dart';
import '../data/repositories/counter/counter_repository.dart';
import '../data/repositories/counter/counter_repository_local.dart';
import '../data/repositories/discovery/discovery_repository.dart';
import '../data/repositories/discovery/discovery_repository_local.dart';
import '../data/services/chat/chat_transport_service.dart';
import '../data/services/counter/counter_service.dart';
import '../data/services/discovery/discovery_service.dart';
import '../data/services/network/network_info_service.dart';
import '../ui/chat/view_models/chat_view_model.dart';
import '../ui/chat/view_models/connection_view_model.dart';
import '../ui/counter/view_models/counter_view_model.dart';

/// 依赖装配（参照 compass_app 的 config/dependencies.dart）。
///
/// 装配顺序：Service → Repository(具体实现) → ViewModel。
/// 之后替换传输方式（如加密传输）或发现方式（如 mDNS）时，
/// 只需在此替换实现，UI 与 ViewModel 无需改动。
List<SingleChildWidget> get providers {
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

    // ViewModel 层
    ChangeNotifierProvider(
      create: (context) => ConnectionViewModel(
        discoveryRepository: context.read(),
        chatRepository: context.read(),
        networkInfoService: context.read(),
      ),
    ),
    ChangeNotifierProvider(
      create: (context) => ChatViewModel(chatRepository: context.read()),
    ),
  ];
}

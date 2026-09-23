import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

import '../../../data/repositories/counter/counter_repository.dart';
import '../../../domain/models/counter/counter.dart';
import '../../../utils/result.dart';

/// 计数器视图模型（ViewModel 层）。
///
/// - 通过构造注入 [CounterRepository]（依赖由 config/dependencies.dart 装配）。
/// - 状态用 [ChangeNotifier] + Provider 管理（参照官方架构状态管理约定）。
/// - 所有异步结果用 [Result] 表达成功/失败，错误向上暴露而非被吞掉。
class CounterViewModel extends ChangeNotifier {
  CounterViewModel({required CounterRepository counterRepository})
      : _counterRepository = counterRepository {
    _log.fine('CounterViewModel 创建，加载初始值');
    _load();
  }

  final Logger _log = Logger('CounterViewModel');
  final CounterRepository _counterRepository;

  Counter _counter = const Counter(value: 0);
  bool _loading = true;
  Exception? _error;

  Counter get counter => _counter;
  bool get loading => _loading;
  Exception? get error => _error;

  Future<void> _load() async {
    _loading = true;
    _error = null;
    notifyListeners();

    final result = await _counterRepository.getCounter();
    switch (result) {
      case Ok<Counter>():
        _counter = result.value;
        _log.fine('计数器已加载：${_counter.value}');
      case Error<Counter>():
        _error = result.error;
        _log.warning('加载计数器失败', result.error);
    }
    _loading = false;
    notifyListeners();
  }

  Future<void> increment() => _update(_counter.increment());
  Future<void> decrement() => _update(_counter.decrement());

  Future<void> _update(Counter next) async {
    final result = await _counterRepository.setCounter(next);
    switch (result) {
      case Ok<Counter>():
        _counter = result.value;
        _log.fine('计数器已更新：${_counter.value}');
      case Error<Counter>():
        _error = result.error;
        _log.warning('更新计数器失败', result.error);
    }
    notifyListeners();
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../view_models/counter_view_model.dart';

/// 计数器页面（View 层）。
///
/// 只负责展示与交互，所有逻辑委托给 [CounterViewModel]。
/// 通过 [context.watch] 订阅状态变化。
class CounterScreen extends StatelessWidget {
  const CounterScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<CounterViewModel>();

    return Scaffold(
      appBar: AppBar(title: const Text('Mova')),
      body: Center(
        child: viewModel.loading
            ? const CircularProgressIndicator()
            : viewModel.error != null
                ? Text(
                    '出错了：${viewModel.error}',
                    style: Theme.of(context).textTheme.bodyLarge,
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('You have pushed the button this many times:'),
                      Text(
                        '${viewModel.counter.value}',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                    ],
                  ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => viewModel.increment(),
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}

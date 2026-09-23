// 应用冒烟测试：验证根组件可正常构建，并渲染出首页的连接状态。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mova/data/services/storage/log_service.dart';
import 'package:mova/data/services/storage/storage_service.dart';
import 'package:mova/main.dart';

void main() {
  testWidgets('app renders home screen', (WidgetTester tester) async {
    final storage = StorageService();
    await tester.pumpWidget(
      MainApp(storageService: storage, logService: LogService(storage)),
    );
    await tester.pump();

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.text('Mova'), findsOneWidget);
    expect(find.text('未连接'), findsOneWidget);
  });
}

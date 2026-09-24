import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mova/data/repositories/history/history_repository_local.dart';
import 'package:mova/data/services/history/history_storage_service.dart';
import 'package:mova/data/services/storage/storage_service.dart';
import 'package:mova/domain/models/history/session_record.dart';

/// 只替换「应用数据目录」，其余能力照旧，用于在测试里隔离磁盘位置。
class _FakeStorage extends StorageService {
  _FakeStorage(this._directory);

  final Directory _directory;

  @override
  Future<Directory> appSupportDirectory() async {
    if (!await _directory.exists()) {
      await _directory.create(recursive: true);
    }
    return _directory;
  }
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mova_history_test');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  HistoryRepositoryLocal buildRepository() => HistoryRepositoryLocal(
        HistoryStorageService(_FakeStorage(root)),
      );

  test('写入后重新打开仓库，记录完整保留（模拟重启应用）', () async {
    final first = buildRepository();
    await first.load();

    final id = await first.startSession(peerName: 'MacBook', peerIp: '192.168.1.9');
    await first.appendMessage(
      SessionMessage(
        text: '你好',
        sender: '我',
        isSelf: true,
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      ),
    );
    await first.upsertFile(
      SessionFile(
        id: 42,
        fileName: '报告.pdf',
        sizeBytes: 2048,
        direction: SessionFileDirection.sent,
        status: SessionFileStatus.completed,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        localPath: '/Users/me/Desktop/报告.pdf',
      ),
    );
    await first.endSession(id);
    await first.dispose();

    // 重新打开：等价于应用重启后重新读取 history.json。
    final second = buildRepository();
    await second.load();

    expect(second.currentSessions.length, 1);
    final session = second.currentSessions.first;
    expect(session.peerName, 'MacBook');
    expect(session.peerIp, '192.168.1.9');
    expect(session.endedAt, isNotNull);
    expect(session.messages.single.text, '你好');
    expect(session.files.single.fileName, '报告.pdf');
    // 关键：当时发送的文件路径要留下来。
    expect(session.files.single.localPath, '/Users/me/Desktop/报告.pdf');
    await second.dispose();
  });

  test('清空后历史为空，但记录文件仍在磁盘上', () async {
    final repository = buildRepository();
    await repository.load();

    final id =
        await repository.startSession(peerName: 'Windows', peerIp: '192.168.1.20');
    await repository.endSession(id);
    await repository.clearAll();

    expect(repository.currentSessions, isEmpty);

    final file = File('${root.path}/history.json');
    expect(await file.exists(), isTrue);
    await repository.dispose();
  });

  test('进行中的会话不会被清空误删', () async {
    final repository = buildRepository();
    await repository.load();

    final oldId = await repository.startSession(peerName: 'A', peerIp: '1.1.1.1');
    await repository.endSession(oldId);
    final activeId = await repository.startSession(peerName: 'B', peerIp: '2.2.2.2');

    await repository.clearAll();

    expect(repository.currentSessions.length, 1);
    expect(repository.currentSessions.single.id, activeId);
    expect(repository.activeSessionId, activeId);
    await repository.dispose();
  });

  test('后挂载的订阅者（面板重建）也能拿到已有记录', () async {
    final repository = buildRepository();
    await repository.load();

    final id = await repository.startSession(peerName: 'Mac', peerIp: '1.2.3.4');
    await repository.endSession(id);

    // 模拟面板被卸载后重建：新的订阅者此时才挂上来。
    final received = <List<SessionRecord>>[];
    final subscription = repository.sessions.listen(received.add);
    await repository.load(); // 新 ViewModel 会调 refresh()

    expect(received, isNotEmpty);
    expect(received.last.length, 1);
    expect(received.last.single.peerName, 'Mac');

    await subscription.cancel();
    await repository.dispose();
  });

  test('记录文件损坏时当作空历史，不抛异常', () async {
    await root.create(recursive: true);
    await File('${root.path}/history.json').writeAsString('{ 这不是 JSON');

    final repository = buildRepository();
    await repository.load();

    expect(repository.currentSessions, isEmpty);
    await repository.dispose();
  });
}

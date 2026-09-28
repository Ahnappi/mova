import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mova/data/repositories/chat/chat_repository.dart';
import 'package:mova/data/repositories/history/history_repository_local.dart';
import 'package:mova/data/services/chat/chat_transport_service.dart';
import 'package:mova/data/services/chat/protocol.dart';
import 'package:mova/data/services/history/history_storage_service.dart';
import 'package:mova/data/services/storage/storage_service.dart';
import 'package:mova/domain/models/chat/chat_message.dart';
import 'package:mova/domain/models/chat/connection_status.dart';
import 'package:mova/ui/chat/view_models/chat_view_model.dart';
// 必须显式导入：Result 的成类（Ok / Error）不会跟着别的导入进来。
import 'package:mova/utils/result.dart';

/// 只替换「应用数据目录」，其余能力照旧。
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

/// 指定发送结果的聊天仓储：用来验证界面的失败反馈。
class _StubChatRepository implements ChatRepository {
  _StubChatRepository(this._result);

  final Result<void> _result;
  String? lastSent;

  @override
  Stream<ChatMessage> get messages => const Stream<ChatMessage>.empty();

  @override
  Stream<ConnectionStatus> get status => const Stream<ConnectionStatus>.empty();

  @override
  String? get sessionId => 's1';

  @override
  Stream<String> get notices => const Stream<String>.empty();

  @override
  String? get remoteName => '对端';

  @override
  String? get remoteAddress => '10.0.0.9';

  @override
  bool get sealed => false;

  @override
  set localName(String value) {}

  @override
  Future<void> stopAcceptingConnections() async {}

  @override
  Future<Result<void>> startListening(int port) async => Result.ok(null);

  @override
  Future<Result<void>> connect(String host, int port) async => Result.ok(null);

  @override
  Future<Result<void>> send(String text) async {
    lastSent = text;
    return _result;
  }

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> dispose() async {}
}

/// 长文本发送：长度要按**编码后**的字节数算（中文 3 字节/字，
/// 引号、反斜杠、换行还会被 JSON 转义放大），超限要返回可展示的错误，
/// 而且界面只能在这条消息真的发出去之后才清空输入框。
void main() {
  late ChatTransportService sender;
  late ChatTransportService receiver;

  Future<void> connectPair() async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();

    receiver = ChatTransportService();
    sender = ChatTransportService();
    addTearDown(() async {
      await sender.dispose();
      await receiver.dispose();
    });

    final ready = Completer<void>();
    receiver.status.listen((status) {
      if (status == ConnectionStatus.connected && !ready.isCompleted) {
        ready.complete();
      }
    });

    await receiver.startListening(port);
    await sender.connect('127.0.0.1', port);
    await ready.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('对端未接入'),
    );
  }

  /// 等一条消息到达对端。
  Future<ChatMessage> nextMessage() {
    final completer = Completer<ChatMessage>();
    late StreamSubscription<ChatMessage> sub;
    sub = receiver.messages.listen((message) {
      if (!completer.isCompleted) completer.complete(message);
      unawaited(sub.cancel());
    });
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('对端没收到消息'),
    );
  }

  setUp(connectPair);

  test('长中文消息按 UTF-8 字节算：够短的能发出去', () async {
    // 一个中文 3 字节：两万字 = 60KB，仍在 64KiB 以内。
    final text = '中' * 20000;

    final result = await sender.send(text);
    expect(result, isA<Ok<void>>());

    final received = await nextMessage();
    expect(received.text, text);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('超长中文消息：返回可展示的错误，不抛异常', () async {
    // 两万两千个字 = 66KB，超过 64KiB。
    final text = '中' * 22000;

    final result = await sender.send(text);
    expect(result, isA<Error<void>>(), reason: '超长消息居然报成功');

    final error = (result as Error<void>).error.toString();
    expect(error, contains('字节'), reason: '错误信息要能说清楚为什么发不出去');
    // 而且这一条不能真的被发出去。
    expect(jsonFrameLength({'text': text}) > maxPayloadLength(MessageType.text),
        isTrue);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('JSON 转义后超限的文本：按转义后的大小拒绝', () async {
    // 字符数本身没超（65000 < 65536），但每个 `"` 会被转义成 `\"`，
    // 编码后是 13 万字节——只看 text.length 就会漏掉这种情况。
    final text = '"' * 65000;
    expect(text.length < maxPayloadLength(MessageType.text), isTrue);

    final result = await sender.send(text);
    expect(result, isA<Error<void>>(),
        reason: '转义后已经超限，却按字符数放行了吗');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('转义字符与换行都能原样送达', () async {
    const text = '第一行\n带"引号"和反斜杠\\\t结尾';

    final result = await sender.send(text);
    expect(result, isA<Ok<void>>());

    final received = await nextMessage();
    expect(received.text, text);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('发送失败时 ViewModel 返回 false 并给出提示，成功才返回 true', () async {
    final root = await Directory.systemTemp.createTemp('mova_text_vm_test');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final history = HistoryRepositoryLocal(
      HistoryStorageService(_FakeStorage(root)),
    );
    addTearDown(() => history.dispose());
    await history.load();

    final failing = ChatViewModel(
      chatRepository: _StubChatRepository(
        Result<void>.error(Exception('这条消息太长，请拆分发送')),
      ),
      historyRepository: history,
    );
    addTearDown(failing.dispose);

    expect(await failing.send('很长的一段'), isFalse,
        reason: '发送失败必须能让界面知道，否则输入框就被清空了');
    expect(failing.errorMessage, contains('太长'));

    final ok = ChatViewModel(
      chatRepository: _StubChatRepository(Result<void>.ok(null)),
      historyRepository: history,
    );
    addTearDown(ok.dispose);

    expect(await ok.send('正常消息'), isTrue);
    expect(ok.errorMessage, isNull);
  }, timeout: const Timeout(Duration(minutes: 1)));
}

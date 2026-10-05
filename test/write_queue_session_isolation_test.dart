// 写入队列的「会话 / 连接隔离」。
//
// 单看 sendFileStream 的话，跨 await 的发送早就绑定了开始时的 socket 与
// 会话；但**单次写入**（控制帧）没有：它们排在写入链上，真正执行时用的是
// 「那时候的 _socket」。而链上前面可能压着一个等网络排空的 flush——
// 传大文件时这几乎必然发生。等待期间若从 A 断开、转连 B，
// 旧会话的 offer / 同意 / 取消帧就会写给 B。
//
// 用可控的假 socket 把「入队 → 换连接 → 执行」这个时序钉死，
// 真实网络里没法稳定复现的窗口，在测试里就是确定的几步。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:mova/data/services/chat/chat_transport_service.dart';
import 'package:mova/data/services/chat/protocol.dart';

void main() {
  test('输出侧连接复位会结束会话，不泄漏未处理异常', () async {
    final socket = _FakeSocket();
    final transport = ChatTransportService(
      connector: (host, port, timeout) async => socket,
    );
    addTearDown(transport.dispose);
    await transport.connect('10.0.0.1', 1);
    socket.failOutput();
    await Future<void>.delayed(Duration.zero);
    expect(transport.sessionId, isNull);
  });

  test('旧连接输出侧的迟到复位不影响新会话', () async {
    final oldSocket = _FakeSocket();
    final newSocket = _FakeSocket();
    final sockets = [oldSocket, newSocket];
    final transport = ChatTransportService(
      connector: (host, port, timeout) async => sockets.removeAt(0),
    );
    addTearDown(transport.dispose);
    await transport.connect('10.0.0.1', 1);
    await transport.disconnect();
    await transport.connect('10.0.0.2', 2);
    final session = transport.sessionId;
    oldSocket.failOutput();
    await Future<void>.delayed(Duration.zero);
    expect(transport.sessionId, session);
    expect(session, isNotNull);
  });

  test('排队写入抛错会结束会话，不泄漏未处理异常', () async {
    final socket = _FakeSocket();
    final transport = ChatTransportService(
      connector: (host, port, timeout) async => socket,
    );
    addTearDown(transport.dispose);
    await transport.connect('10.0.0.1', 1);
    await Future<void>.delayed(Duration.zero);
    socket.failAdd = true;
    await transport.send('触发写入失败');
    await Future<void>.delayed(Duration.zero);
    expect(transport.sessionId, isNull);
  });

  test('写入队列被 flush 卡住期间换了连接，旧会话的帧不会写给新设备', () async {
    final dir = await Directory.systemTemp.createTemp('mova_write_queue');
    addTearDown(() => dir.delete(recursive: true).catchError((Object _) => dir));
    final file = File(p.join(dir.path, 'a.bin'))
      ..writeAsBytesSync(Uint8List(64));

    final socketA = _FakeSocket();
    final socketB = _FakeSocket();
    final pending = <_FakeSocket>[socketA, socketB];
    final transport = ChatTransportService(
      // 心跳关掉：这条用例只关心写入链，不希望 ping 混进来干扰判断。
      keepAliveInterval: const Duration(minutes: 10),
      connector: (host, port, timeout) async => pending.removeAt(0),
    );
    addTearDown(() => transport.dispose());

    await transport.connect('10.0.0.1', 1);
    final sessionA = transport.sessionId;
    expect(sessionA, isNotNull);

    // 让写入链卡在一次 flush 上：真实场景就是对端不读、socket 缓冲满了，
    // flush 要等网络排空才返回。
    unawaited(
      transport.sendFileStream(fileId: 1, path: file.path, expectedSize: 64),
    );
    // 等「数据块入队 → 收尾 flush 入队」这两步走完。
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(socketA.flushCalls, greaterThanOrEqualTo(1),
        reason: '前置条件：写入链应该卡在 flush 上，否则这条用例没有验证到目标窗口');

    // 卡住的这段时间里，控制帧只能排在 flush 后面等着：
    // 一个普通控制帧（offer）、一个会话绑定的帧（cancel）。
    unawaited(
      transport.sendFileOffer(fileId: 42, name: 'secret.bin', size: 64),
    );
    transport.sendFileCancel(7, reason: '旧会话的取消', session: sessionA);

    // 期间用户断开了 A、连上了 B（两台不同设备）。
    await transport.disconnect();
    await transport.connect('10.0.0.2', 2);
    expect(transport.sessionId, isNot(sessionA));

    // 现在才放开 flush：排在它后面的帧即将执行，而此刻连接已经是 B 了。
    socketA.releaseFlush();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final leakedToB = socketB.frames();
    expect(
      leakedToB.where((frame) => frame.type == MessageType.fileOffer).length,
      0,
      reason: '旧会话的发送请求绝不能发给新连上的设备',
    );
    expect(
      leakedToB.where((frame) => frame.type == MessageType.fileCancel).length,
      0,
      reason: '旧会话的取消帧绝不能发给新连上的设备',
    );
    // 新连接自己的 hello 要照常发出去：别误伤正常帧。
    expect(
      leakedToB.where((frame) => frame.type == MessageType.hello).length,
      1,
      reason: '新会话的 hello 应当正常发给 B',
    );
  }, timeout: const Timeout(Duration(minutes: 1)));
}

/// 一个「能看住写出去的每个字节、且 flush 由测试控制」的 socket。
///
/// 真实的 Socket 没法让 flush 停在半路等一个信号，而这个窗口正是本条
/// 用例的全部意义，所以自己实现一个最小可用的假 socket。
class _FakeSocket extends Stream<Uint8List> implements Socket {
  /// 写出去的全部字节（按写入顺序）。
  final List<int> written = <int>[];
  final Completer<Socket> _done = Completer<Socket>();
  bool failAdd = false;

  void failOutput() {
    _done.completeError(const SocketException('Connection reset by peer'));
  }

  final StreamController<Uint8List> _inbound = StreamController<Uint8List>();
  final Completer<void> _flushGate = Completer<void>();

  /// flush 被调用了几次。
  int flushCalls = 0;

  /// 放开 flush：此前所有 flush 都停在半路（模拟「网络排空很慢」）。
  void releaseFlush() {
    if (!_flushGate.isCompleted) _flushGate.complete();
  }

  /// 把 socketB 写出的字节解成帧，便于按类型断言。
  List<Frame> frames() {
    final reader = FrameReader();
    reader.add(Uint8List.fromList(written));
    return reader.drain();
  }

  @override
  void add(List<int> data) {
    if (failAdd) throw const SocketException('Connection reset by peer');
    written.addAll(data);
  }

  @override
  Future<void> flush() async {
    flushCalls++;
    await _flushGate.future;
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      _inbound.stream.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {}

  @override
  Future<void> close() async {}

  @override
  Future<Socket> get done => _done.future;

  @override
  Encoding get encoding => utf8;

  @override
  set encoding(Encoding value) {}

  @override
  InternetAddress get address => InternetAddress.loopbackIPv4;

  @override
  int get port => 49153;

  @override
  InternetAddress get remoteAddress => InternetAddress('10.0.0.9');

  @override
  int get remotePort => 49154;

  @override
  void destroy() {}

  @override
  bool setOption(SocketOption option, bool enabled) => true;

  @override
  Uint8List getRawOption(RawSocketOption option) => Uint8List(0);

  @override
  void setRawOption(RawSocketOption option) {}

  @override
  void write(Object? object) {}

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {}

  @override
  void writeCharCode(int charCode) {}

  @override
  void writeln([Object? object = '']) {}
}

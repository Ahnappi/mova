// 心跳的「版本兼容」边界。
//
// 新版会在空闲时发 ping，并拿「太久没收到任何字节」当断链判据。
// 但这条判据有个前提：对端**也会**发心跳。老版本既不发 ping 也不回 ping，
// 空闲二十几秒是它的正常状态——一端升级就把所有老连接掐断是不可接受的。
//
// 所以：能力必须先协商（hello 里的 ka），没协商过就只发 ping、不判死。
//
// 写这组用例时踩到的一个坑：**`connected` 早于 hello**。
// transport 在 TCP 连上那一刻就发 `connected`（此时 `_remoteKeepAliveCapable`
// 刚被重置为 false），之后才监听、读取并解析对端的 hello。
// 所以「等到 connected 再断言心跳能力」读到的往往只是初始值：
// 断言 isFalse 是假绿，断言 isTrue 在慢机器上会假红。
// 正确做法是等 hello 真正解析完（`remoteName` 出现）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mova/data/services/chat/chat_transport_service.dart';
import 'package:mova/data/services/chat/protocol.dart';
import 'package:mova/domain/models/chat/connection_status.dart';

void main() {
  late ChatTransportService local;
  late int port;
  final statuses = <ConnectionStatus>[];

  setUp(() async {
    statuses.clear();
    // 先探一个空闲端口再交给 transport 监听：同一个端口不能被绑两次。
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    port = probe.port;
    await probe.close();

    // 心跳窗口压到几百毫秒：真实值是 5 秒 / 20 秒，测试等不起。
    local = ChatTransportService(
      keepAliveInterval: const Duration(milliseconds: 100),
      keepAliveTimeout: const Duration(milliseconds: 600),
    );
    local.status.listen(statuses.add);
    await local.startListening(port);
  });

  tearDown(() async {
    await local.dispose();
  });

  /// 连进来一个「只会说老协议」的对端：握手之后一句话都不说。
  Future<Socket> dialLegacyPeer({required bool withKeepAlive}) async {
    final socket = await Socket.connect('127.0.0.1', port);
    socket.add(encodeJsonFrame(MessageType.hello, {
      'name': '老版本',
      'proto': 2,
      if (withKeepAlive) 'ka': true,
    }));
    await socket.flush();
    return socket;
  }

  test('对端是老版本时，空闲连接不会被心跳主动断开', () async {
    final peer = await dialLegacyPeer(withKeepAlive: false);
    addTearDown(peer.destroy);

    // 先等对端的 hello 真正解析完：能力位是它带来的。
    // 不能只等 connected —— 那个状态在 TCP 连上时就发了，
    // 比 hello 到达早，等到它就断言，多半只是在看初始值 false。
    await _until(
      () => local.remoteName == '老版本',
      reason: '等待旧版对端 hello 解析完成',
    );
    expect(local.remoteKeepAliveCapable, isFalse,
        reason: '没在 hello 里声明心跳能力的对端，不能按「收不到字节」判死');

    // 再等远超心跳超时的时长：老版本空闲时本来就是零入向字节。
    await Future<void>.delayed(const Duration(seconds: 2));

    expect(
      statuses,
      isNot(contains(ConnectionStatus.disconnected)),
      reason: '老版本对端只是空闲，不该被主动断开',
    );
  });

  test('对端声明了心跳能力后，失联仍然会被判死', () async {
    final peer = await dialLegacyPeer(withKeepAlive: true);
    addTearDown(peer.destroy);

    // 同样要等 hello 解析完，而不是只等 connected（那只是 TCP 已连上）。
    await _until(
      () => local.remoteName == '老版本' && local.remoteKeepAliveCapable,
      reason: '等待对端 hello 解析完成并确认心跳能力',
    );
    expect(local.remoteKeepAliveCapable, isTrue,
        reason: 'hello 里声明了 ka，就应启用「收不到字节即断链」这条判据');

    // 这条用例是前一条的镜像：少了它，「干脆谁都不判死」也能让前一条变绿。
    await _until(
      () => statuses.contains(ConnectionStatus.disconnected),
      reason: '对端停止发任何字节后，应在心跳超时内判定连接已断',
    );
    expect(
      statuses,
      contains(ConnectionStatus.disconnected),
      reason: '对端停止发任何字节后，应在心跳超时内判定连接已断',
    );
  });
}

/// 轮询等到 [condition] 成立。
Future<void> _until(
  bool Function() condition, {
  String reason = '等待条件成立',
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('等待超时：$reason');
}

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../../../config/app_config.dart';
import '../../../domain/models/chat/chat_message.dart';
import '../../../domain/models/chat/connection_status.dart';
import '../../../domain/models/transfer/transfer_event.dart';
import '../../../utils/checksum.dart';
import '../../../utils/result.dart';
import 'protocol.dart';

/// 传输数据源（Service 层）：TCP 监听 + 连接 + 二进制分帧收发。
///
/// **同一时刻只维护一个会话**（无论是自己连出去还是对方连进来）：
/// 已经连着的时候，新的入站连接会被直接拒绝（并对外发一条提示），
/// 主动 [connect] 也会直接返回错误。否则第三台设备连进来会悄悄顶掉
/// 正在传输的会话，两边都停在半路。
///
/// 每条会话都有自己的标识 [sessionId]，消息帧也带上它，
/// 上层据此把消息与任务按会话隔离。
///
/// 大文件相关要点：
/// - 发送端按 [AppConfig.fileChunkSize] 分块读盘并逐块写出，**不把整个文件读进内存**；
/// - 每积累 [AppConfig.maxInFlightBytes] 就 `flush()` 一次做背压，
///   防止「读盘快于网络」时把内存撑爆；
/// - 接收端侧由上层用 [pauseInbound] / [resumeInbound] 做反向背压：
///   落盘来不及就停读 socket，让 TCP 窗口去压住对端；
/// - 跨越 await 的发送操作绑定**开始时的 socket 与会话**
///   （见 [sendFileStream]）：传大文件时若中途与 A 断开、随后连上 B，
///   旧循环剩下的字节绝不会写给 B；最后一次 `flush()`（等网络排空的那一步）
///   结束后同样会再核对一次取消，避免「最后一块已发出」时取消失效。
///   连**单次写入**也钉死排队那一刻的连接（见 [_write]）：写入链上的
///   帧可能被前面的 flush 挡住很久，只按执行时的 socket 发就会发错设备。
///
/// 连接尝试也有归属（见 [connect]）：[isBusy] 把「正在连接」也算作占用，
/// 一次尝试只由它自己的令牌决定是否还能改动连接状态，过期尝试的失败
/// 不会把已经建好的会话打成断连。
///
/// 来自网络的数据一律按「不可信」处理：帧头声明的长度在等数据凑齐之前
/// 就按类型校验上限（见 [maxPayloadLength]），版本不符或超限立即断开，
/// 绝不会为了一个「声明数 GB 的帧」一路扩容缓冲。
///
/// 退出期间用 [seal] 封存：[disconnect] 会**保留监听**（对方可以再连进来），
/// 而收尾那几秒里冒出来的新会话会让状态错乱——传输仓储已在释放、
/// 历史仓储可能已关闭。封存之后监听关掉，连接与发送一律拒绝。
/// 建立一条 TCP 出向连接的函数（默认就是 [Socket.connect]）。
///
/// 抽出来是为了让「连接尝试的时序」可测：真实网络里连一个不可达地址
/// 到底几秒才超时完全取决于环境，没法证明「旧尝试是在新会话建立之后
/// 才失败的」。测试注入一个用 `Completer<Socket>` 控制的版本，
/// 就能把这个交错安排得明明白白。
typedef SocketConnector = Future<Socket> Function(
  String host,
  int port,
  Duration timeout,
);

class ChatTransportService {
  /// [connector] 只给测试用：默认走 [Socket.connect]。
  ///
  /// [keepAliveInterval] / [keepAliveTimeout] 同理：默认是 [AppConfig] 里
  /// 那两个值，但「等 20 秒才发现对端没了」在测试里实在太慢，
  /// 注入成几百毫秒就能把这条规则验得又快又确定。
  ChatTransportService({
    SocketConnector? connector,
    Duration? keepAliveInterval,
    Duration? keepAliveTimeout,
  })  : _connector = connector ?? _defaultConnect,
        _keepAliveInterval = keepAliveInterval ?? AppConfig.keepAliveInterval,
        _keepAliveTimeout = keepAliveTimeout ?? AppConfig.keepAliveTimeout;

  ServerSocket? _server;
  Socket? _socket;
  StreamSubscription<Uint8List>? _socketSub;

  final SocketConnector _connector;

  static Future<Socket> _defaultConnect(
    String host,
    int port,
    Duration timeout,
  ) =>
      Socket.connect(host, port, timeout: timeout);

  final FrameReader _reader = FrameReader();
  final Logger _log = Logger('ChatTransportService');

  final StreamController<ChatMessage> _messageController =
      StreamController<ChatMessage>.broadcast();
  final StreamController<ConnectionStatus> _statusController =
      StreamController<ConnectionStatus>.broadcast();
  final StreamController<TransferEvent> _transferController =
      StreamController<TransferEvent>.broadcast();
  final StreamController<String> _noticeController =
      StreamController<String>.broadcast();

  /// 收到的文本消息流。
  Stream<ChatMessage> get messages => _messageController.stream;

  /// 连接状态流。
  Stream<ConnectionStatus> get status => _statusController.stream;

  /// 文件传输相关事件流。
  Stream<TransferEvent> get transferEvents => _transferController.stream;

  /// 需要让用户知道的提示（如「某某设备想连你，但你已经连着别人」）。
  Stream<String> get notices => _noticeController.stream;

  /// 当前会话标识；未连接时为 null。
  ///
  /// 每次建立连接都会换一个新的，上层用它来区分「这条消息属于哪一次连接」。
  String? get sessionId => _sessionId;

  String? _sessionId;
  int _sessionCounter = 0;

  /// 是否已占用（有活跃会话，**或正在建立会话**）。
  ///
  /// 只看 socket 是不够的：[connect] 里的 `Socket.connect` 本身要好几秒
  /// （连错地址时更久），这段窗口里若还允许第二次尝试，两次尝试的成败
  /// 会交错改动连接状态——最典型的就是第一次超时后广播 `disconnected`，
  /// 把第二次刚刚建好的会话打成断连。
  bool get isBusy => _socket != null || _connecting;

  /// 是否正在尝试连接（[connect] 已发出、结果还没回来）。
  bool get isConnecting => _connecting;

  bool _connecting = false;

  // ---------- 存活探测（心跳） ----------
  //
  // TCP 建好之后如果两端都不说话，谁也不知道对方还在不在。对端合盖、
  // Wi-Fi 断了、进程被杀，这些情况既不发 FIN 也不发 RST，本端会一直
  // 「以为还连着」——界面上就是「一直在接收，进度不动」，直到几分钟后
  // 下一次真正写数据失败才暴露。
  //
  // 所以建连后定期互发 ping：只要这条连接上还有字节在动（无论哪个方向、
  // 是心跳还是文件数据），就证明对端还在；连续几个周期一个字节都没有，
  // 就判定连接已死并主动断开，让上层及时把任务判失败。
  //
  // 但「收不到字节就判死」这条判据**必须先协商能力**才能用：
  // 老版本对端既不主动发 ping，也不会回应 ping，空闲二十几秒是它的
  // 正常状态。若一端升级、另一端没升级，新的一端会把自己好端端的
  // 连接主动掐断。因此只有在 hello 里确认对端支持心跳之后
  // （见 [_remoteKeepAliveCapable]）才启用这条判据；不支持时仍然照发
  // ping（对端忽略未知帧，见 FrameReader），只是不再据此断链。
  Timer? _keepAliveTimer;

  /// 最近一次收到对端字节的时间（任何帧都算，包括心跳）。
  DateTime? _lastInboundAt;

  /// 最近一次往对端发出字节的时间。
  ///
  /// 正在传文件时数据本身就是存活证明，不必再叠加心跳——只在确实
  /// 一段时间没往外发过东西时才补一个 ping。
  DateTime? _lastOutboundAt;

  final Duration _keepAliveInterval;
  final Duration _keepAliveTimeout;

  void _startKeepAlive() {
    _stopKeepAlive();
    final now = DateTime.now();
    _lastInboundAt = now;
    _lastOutboundAt = now;
    _keepAliveTimer = Timer.periodic(_keepAliveInterval, (_) {
      _keepAliveTick();
    });
  }

  void _stopKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _lastInboundAt = null;
    _lastOutboundAt = null;
  }

  /// 对端是否具备心跳能力（收到它的 hello 之后才为真）。
  ///
  /// 老版本既不发 ping 也不会回应 ping，[keepAliveTimeout] 内「零入向
  /// 字节」对它是常态。只有确认它会发心跳，才能把「收不到字节」当成
  /// 它已经不在的证据——否则版本一不一致就把正常连接掐断了。
  bool get remoteKeepAliveCapable => _remoteKeepAliveCapable;

  bool _remoteKeepAliveCapable = false;

  void _keepAliveTick() {
    if (_socket == null) return;
    final now = DateTime.now();

    // 先判死活：太久没收到任何字节，就当对端已经不在了。
    //
    // 判死活这件事不能用「我发出去的 ping 有没有回音」来做——ping 是
    // 单向的空帧，对端不需要回包。只要这条连接上还有字节在动即可。
    //
    // 前提是对端**会**发心跳：老版本空闲时本来就是零字节，
    // 拿这个当判据等于一升级就把老连接全断掉（见 [_remoteKeepAliveCapable]）。
    final lastIn = _lastInboundAt;
    if (_remoteKeepAliveCapable &&
        lastIn != null &&
        now.difference(lastIn) > _keepAliveTimeout) {
      _log.info(
        '已 ${_keepAliveTimeout.inSeconds} 秒没收到对端任何数据，判定连接已断开',
      );
      // 走 disconnect 而不是只广播状态：必须把 socket 真正关掉，
      // 否则这条半开连接会一直占着，用户点「连接」也连不上。
      unawaited(disconnect());
      return;
    }

    // 这一段时间确实没往外发过东西，补一个心跳。
    final lastOut = _lastOutboundAt;
    if (lastOut == null || now.difference(lastOut) >= _keepAliveInterval) {
      _write(encodeFrame(MessageType.ping, Uint8List(0)));
    }
  }

  /// 是否已封存（退出流程进行中，不再接受任何连接与发送）。
  ///
  /// 退出期间若只是 `disconnect()`，监听还开着，另一台设备照样能连进来
  /// 建一个新会话——而此时传输仓储可能已在释放、历史仓储可能已经关闭。
  /// 封存之后 [startListening] / [connect] / [send] / [sendFileOffer] /
  /// [sendFileStream] 一律返回错误，入站连接也会在 [_attach] 处被关掉。
  bool get isSealed => _sealed;

  bool _sealed = false;

  /// 退出专用：停止接收一切新连接，并断开当前会话。
  ///
  /// 与 [disconnect] 的区别就在于**监听一起关掉**，且之后再也不接受
  /// 连接与发送（见 [isSealed]）。
  Future<void> seal() async {
    _sealed = true;
    // 还在跑的连接尝试一律作废：它们既不能接管连接，
    // 也不能广播 disconnected（此刻我们正在收尾）。
    _connectToken++;
    _connecting = false;
    await _closeServer();
    await disconnect();
  }

  /// 连接尝试令牌：只有「当前这一次尝试」的结果能改动连接状态。
  ///
  /// 开始新尝试、成功建立会话、主动断开，都会换一个新号。
  /// 过期尝试（连 A 久久不回，期间 B 已经连进来建好会话）既不能接管
  /// 连接，也不能广播 `disconnected`——那会把刚建好的会话打成断连，
  /// 界面与传输仓储会按断连处理，正常任务随之被中止。
  int _connectToken = 0;

  /// 对端名称（收到对端 hello 后可用）。
  String? remoteName;

  /// 对端协议版本（收到对端 hello 后可用；未收到时按 1 处理）。
  ///
  /// 用于兼容：老版本对端不认识收尾回执帧，发送端也就不能干等它。
  int get remoteProtocolVersion => _remoteProtocolVersion;

  int _remoteProtocolVersion = 1;

  /// 对端 IP（连接建立后可用；断开后仍保留上一次的值，供收尾时使用）。
  String? get remoteAddress => _socket?.remoteAddress.address ?? _lastRemoteAddress;

  String? _lastRemoteAddress;

  /// 本机显示名，发送时作为 sender 带上。
  String localName = '本机';

  /// 开启 TCP 监听，等待其它设备连入。
  Future<Result<void>> startListening(int port) async {
    if (_sealed) {
      return Result.error(Exception('应用正在退出，不再接受连接'));
    }
    try {
      await _closeServer();
      final server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      server.listen(
        _attach,
        onError: (Object _) => _statusController.add(ConnectionStatus.disconnected),
      );
      _server = server;
      return Result.ok(null);
    } catch (e) {
      return Result.error(Exception('监听端口 $port 失败：$e'));
    }
  }

  /// 主动连接 [host]:[port]。
  Future<Result<void>> connect(String host, int port) async {
    // 退出期间不允许再往外连：新会话会在收尾进行中凭空出现。
    if (_sealed) {
      return Result.error(Exception('应用正在退出，不再发起连接'));
    }
    // 一次只连一台：已经有会话时拒绝新连接，由用户先断开再连。
    if (isBusy) {
      final current = _lastRemoteAddress ?? '当前设备';
      return Result.error(
        Exception('已经与 $current 保持连接，请先断开再连接其它设备'),
      );
    }
    // 这一次尝试的令牌：等待期间若有别的连接先建立了会话，
    // 令牌就会被换掉，本次尝试随即作废。
    final token = ++_connectToken;
    _connecting = true;
    try {
      _statusController.add(ConnectionStatus.connecting);
      final socket =
          await _connector(host, port, AppConfig.connectTimeout);

      // 等待期间可能已经有会话了（对端连了进来，或用户断开后重连了别人）。
      // 过期尝试绝不能再接管：它连上的这条 socket 必须关掉，
      // 否则会顶掉已经建好的会话，两边都停在半路。
      if (token != _connectToken || _socket != null) {
        unawaited(socket.close().catchError((Object _) => socket.destroy()));
        return Result.error(Exception('与 $host:$port 的连接已被更新的连接取代'));
      }
      // 本次尝试到此为止，先收回「正在连接」：
      // [isBusy] 把「正在连接」也算作占用，不清掉的话 [_attach] 会把
      // 自己刚连上的这条 socket 当成第三方连入而拒掉。
      _connecting = false;
      _attach(socket);
      return Result.ok(null);
    } catch (e) {
      // 只有「仍是当前这一次尝试」、并且确实没有会话时才广播断连。
      // 过期尝试的失败属于它自己，不能污染已经建立的连接。
      if (token == _connectToken && _socket == null) {
        _statusController.add(ConnectionStatus.disconnected);
      }
      return Result.error(Exception('连接 $host:$port 失败：$e'));
    } finally {
      // 只有当前尝试才负责把自己标记为「不再尝试中」。
      if (token == _connectToken) _connecting = false;
    }
  }

  /// 发送一行文本消息。
  ///
  /// 长度按**编码后**的字节数判断（中文 3 字节/字，引号、换行还会被 JSON
  /// 转义放大），超限就返回一条能直接显示给用户的错误——不抛异常，
  /// 也不假装发送成功：否则界面照常清空输入框，内容却根本没发出去。
  Future<Result<void>> send(String text) async {
    if (_sealed) {
      return Result.error(Exception('应用正在退出，无法发送'));
    }
    if (_socket == null) {
      return Result.error(Exception('尚未连接，无法发送'));
    }

    final json = <String, dynamic>{
      'name': localName,
      'text': text,
      'ts': DateTime.now().toIso8601String(),
    };
    final frame = tryEncodeJsonFrame(MessageType.text, json);
    if (frame == null) {
      final size = jsonFrameLength(json);
      return Result.error(
        Exception(
          '这条消息编码后有 $size 字节，超过单条 ${maxPayloadLength(MessageType.text)} '
          '字节的上限，请拆成几条发送（中文按 3 字节/字计算）。',
        ),
      );
    }
    _write(frame);
    return Result.ok(null);
  }

  // ---------- 文件传输 ----------

  /// 向对端发起文件发送请求（此时还不传数据，等对端同意）。
  Future<Result<void>> sendFileOffer({
    required int fileId,
    required String name,
    required int size,
    int? batchId,
    int? batchIndex,
    int? batchCount,
  }) async {
    if (_sealed || _socket == null) {
      return Result.error(
        Exception(_sealed ? '应用正在退出，无法发送文件' : '尚未连接，无法发送文件'),
      );
    }
    _write(encodeJsonFrame(MessageType.fileOffer, {
      'id': fileId,
      'name': name,
      'size': size,
      // 批次信息：同一批选中的文件共享 batchId，接收端据此把它们聚成
      // 一组一起展示，而不是逐个弹卡片。老对端忽略这三个字段即可，
      // 行为退化成「一次只处理一个」。
      'batch': ?batchId,
      'batchIndex': ?batchIndex,
      'batchCount': ?batchCount,
    }));
    return Result.ok(null);
  }

  /// 同意接收对端发来的文件。
  void sendFileAccept(int fileId) =>
      _write(encodeJsonFrame(MessageType.fileAccept, {'id': fileId}));

  /// 拒绝接收对端发来的文件。
  void sendFileReject(int fileId, {String? reason}) =>
      _write(encodeJsonFrame(MessageType.fileReject, {
        'id': fileId,
        'reason': ?reason,
      }));

  /// 通知对端：该文件已取消（不要再发 / 可以丢弃了）。
  ///
  /// [session] 是发起这次取消时所属的会话；会话已经换人时静默丢弃，
  /// 免得把「上一个会话的取消」发给新连上的设备。
  void sendFileCancel(int fileId, {String? reason, String? session}) =>
      _writeInSession(
        encodeJsonFrame(MessageType.fileCancel, {
          'id': fileId,
          'reason': ?reason,
        }),
        session,
      );

  /// 声明该文件的数据已全部发完。
  ///
  /// [size] 是本端**实际写出**的字节数，[checksum] 是内容的 CRC32（可为 null）。
  /// 接收端拿它跟自己落盘的结果对账，对不上就说明传输有问题。
  ///
  /// [session] 必须是「这次发送开始时」的会话：发送要跨很多次读盘 await，
  /// 中途若断连并连上另一台设备，结束帧绝不能发给新设备。
  void sendFileEnd(
    int fileId, {
    required int size,
    int? checksum,
    String? session,
  }) =>
      _writeInSession(
        encodeJsonFrame(MessageType.fileEnd, {
          'id': fileId,
          'size': size,
          'crc': ?checksum,
        }),
        session,
      );

  /// 接收端回执：文件已核对无误并保存成功（或说明失败原因）。
  ///
  /// 发送端只有收到 `ok=true` 才能认为对方真的收到了完整文件。
  void sendFileDone(
    int fileId, {
    required bool ok,
    String? reason,
    String? session,
  }) =>
      _writeInSession(
        encodeJsonFrame(MessageType.fileDone, {
          'id': fileId,
          'ok': ok,
          'reason': ?reason,
        }),
        session,
      );

  /// 暂停读取对端数据（用于接收端背压）。
  ///
  /// 暂停期间 TCP 接收窗口会填满，对端的发送自然被压慢，
  /// 这样内存里积压的待落盘数据始终是有界的。
  void pauseInbound() => _socketSub?.pause();

  /// 恢复读取对端数据。
  void resumeInbound() => _socketSub?.resume();

  /// 流式发送文件内容（不含 offer / end，只负责数据块）。
  ///
  /// - [expectedSize] 是最初在 offer 里声明的大小；**实际读出的字节数必须
  ///   和它一致**，否则说明源文件在传输途中被截短或改写，判失败
  ///   （少了这一步，接收端会拿一个「大小自洽但内容不完整」的文件，
  ///   界面却按最初大小显示完成）；
  /// - [onProgress] 每写完一块回调一次已发送字节数；
  /// - [isCancelled] 每块前检查一次，true 则立即停止（用于中途取消）；
  /// - 成功时返回实际读出的字节数与 CRC32，供收尾时声明给对端核对；
  /// - 返回 `Error` 表示失败或被取消。
  Future<Result<SentFileSummary>> sendFileStream({
    required int fileId,
    required String path,
    int? expectedSize,
    String? session,
    void Function(int sentBytes)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (_sealed) {
      return Result.error(Exception('应用正在退出，无法发送文件'));
    }
    final socket = _socket;
    if (socket == null) {
      return Result.error(Exception('尚未连接，无法发送文件'));
    }
    // 整次发送都钉死在「开始时的 socket 与会话」上。
    //
    // 发送一个文件要跨几十次读盘 await。若中途与 A 断开、随后连上 B，
    // 而这里仍然用「当前 socket」写，A 的文件字节就会被写给 B——
    // 即使 B 的客户端会因未知 fileId 丢弃它们，数据也已经离开了本机、
    // 发向了错误的设备。
    final bound = (session != null && session.isNotEmpty) ? session : _sessionId;

    RandomAccessFile? raf;
    try {
      final file = File(path);
      if (!await file.exists()) {
        return Result.error(Exception('文件不存在：$path'));
      }
      raf = await file.open(mode: FileMode.read);
      final total = await raf.length();

      final chunk = Uint8List(AppConfig.fileChunkSize);
      // 边读边算校验值：只多扫一遍内存，不需要把文件留在内存里。
      final crc = AppConfig.transferChecksumEnabled ? Crc32() : null;
      var sent = 0;
      var inFlight = 0;

      while (sent < total) {
        if (isCancelled?.call() ?? false) {
          return Result.error(Exception('已取消发送'));
        }

        final read = await raf.readInto(chunk);
        if (read <= 0) break;

        // 每次 await 回来都要重新确认：连接还是不是原来那一条。
        if (!identical(_socket, socket) || _sessionId != bound) {
          return Result.error(Exception('连接已切换，发送中止'));
        }
        if (isCancelled?.call() ?? false) {
          return Result.error(Exception('已取消发送'));
        }

        final data = Uint8List.sublistView(chunk, 0, read);
        crc?.add(data);
        _writeInSession(encodeChunkFrame(fileId, data), bound);

        sent += read;
        inFlight += read;
        onProgress?.call(sent);

        // 背压：积压到阈值就等 socket 真正写出去，避免内存被读盘速度拖爆。
        //
        // flush 也必须走写入链：它执行期间 sink 处于「已绑定」状态，
        // 别的并发流这时 add 会直接抛错。
        if (inFlight >= AppConfig.maxInFlightBytes) {
          await _flush(socket);
          inFlight = 0;
        }
      }

      // 收尾的 flush 同样只针对绑定的那条连接。
      if (!identical(_socket, socket) || _sessionId != bound) {
        return Result.error(Exception('连接已切换，发送中止'));
      }
      // 收尾 flush 同样要走写入链（理由见 [maxInFlightBytes] 那处背压）。
      await _flush(socket);

      // 排空这一次 await 期间同样可能出事，因此必须再核对一遍：
      // 少了这一步，「最后一块已写出、正在等网络排空」时点下的取消会失效
      // ——文件照样发完、结束帧照样发出，取消形同虚设。
      if (!identical(_socket, socket) || _sessionId != bound) {
        return Result.error(Exception('连接已切换，发送中止'));
      }
      if (isCancelled?.call() ?? false) {
        return Result.error(Exception('已取消发送'));
      }

      // 读到 EOF 提前结束（文件被截短）或读得比声明的多（文件在变大）
      // 都要判失败：这两种情况下「实际发送量」都不等于对端看到的声明量。
      final declared = expectedSize ?? total;
      if (sent != declared) {
        return Result.error(
          Exception(
            '文件在发送期间发生了变化：声明 $declared 字节，实际读出 $sent 字节。'
            '已停止发送，请重新选择该文件。',
          ),
        );
      }

      return Result.ok(SentFileSummary(bytes: sent, checksum: crc?.value));
    } catch (e) {
      return Result.error(Exception('发送文件失败：$e'));
    } finally {
      await raf?.close();
    }
  }

  /// 断开当前会话（监听仍保留，对方可再次连入）。
  Future<void> disconnect() async {
    _stopKeepAlive();
    await _socketSub?.cancel();
    _socketSub = null;
    _socket?.destroy();
    _socket = null;
    _sessionId = null;
    _remoteProtocolVersion = 1;
    _remoteKeepAliveCapable = false;
    // 主动断开后，此前还在跑的连接尝试一律作废：它们的成败都不再算数，
    // 也就不允许再广播 disconnected（此刻可能已经连上了别的设备）。
    _connectToken++;
    _connecting = false;
    // 断连时清空解析器：缓冲区里可能还留着半个没传完的帧，
    // 留到下一条连接会被当成新会话的开头来解析。
    _reader.reset();
    // 先通知断开、再清名字：上层收尾（写历史）时还要用到对端信息。
    _statusController.add(ConnectionStatus.disconnected);
    remoteName = null;
  }

  /// 释放全部资源（含监听与流控制器）。
  Future<void> dispose() async {
    _sealed = true;
    await disconnect();
    await _closeServer();
    await _messageController.close();
    await _statusController.close();
    await _transferController.close();
    await _noticeController.close();
  }

  Future<void> _closeServer() async {
    await _server?.close();
    _server = null;
  }

  /// 写入串行链：同一时刻只允许一个操作碰 socket 的输出缓冲。
  ///
  /// 为什么要串行化——这是支持「多文件同时传输」时才暴露出来的坑：
  /// dart:io 的 IOSink 在执行 `flush()` 期间会把 sink 标记为「已绑定」
  /// （io_sink.dart:191 的 `_isBound = true`），**此时再调用 `add()` 会
  /// 直接抛** `StateError('StreamSink is bound to a stream')`。
  /// 并发推两个文件时，一路在 flush、另一路在 add，正好撞上。
  ///
  /// 因此 add 与 flush 必须排在一条链上依次执行。注意串行化只决定谁先
  /// 谁后：每次 add 仍是「整帧一次性写入」（见 [encodeFrame]），
  /// 不会把两个文件的字节搅在一起，接收端依旧按 fileId 分得清。
  Future<void> _writeChain = Future<void>.value();

  /// 把 [action] 接到写入链的尾部，前一个完成后才轮到它。
  ///
  /// 链本身永不因异常断裂：前一个的错误已经吞掉，自己的 [whenComplete]
  /// 保证后一个一定会被放行。
  Future<T> _chain<T>(Future<T> Function() action) {
    final previous = _writeChain;
    final next = Completer<void>();
    _writeChain = next.future;
    return previous
        .catchError((Object _) {})
        .then((_) => action())
        .whenComplete(() {
          if (!next.isCompleted) next.complete();
        });
  }

  /// 把 [frame] 排到写入链上，并**钉死目标连接与会话**。
  ///
  /// 关键是「入队」与「执行」之间可能隔着很久：链上前面若压着一个
  /// 32MiB 的 flush，这一帧要等网络排空才轮得到。而等待期间完全可能
  /// 已经从 A 断开、转连 B——若执行时只看「当前的 _socket」，
  /// A 的文件数据块、取消帧、结束帧就会写给 B。数据一旦离开本机、
  /// 发向错误的设备，就再也收不回来了。
  ///
  /// 所以目标 socket 与会话在**入队那一刻**记下来，真正执行时再核对一遍：
  /// 连接或会话已经换人，这一帧直接丢弃（宁可丢一帧，也不能发错对象）。
  void _enqueueWrite(
    Uint8List frame, {
    required Socket? socket,
    required String? session,
  }) {
    unawaited(
      _chain(() async {
        final current = _socket;
        if (current == null) return;
        // 会话校验：null / 空串表示这一帧不绑定会话（普通控制帧）。
        if (session != null && session.isNotEmpty && _sessionId != session) {
          return;
        }
        // 连接校验：排队期间连接已经换人，这一帧属于旧连接，丢弃。
        if (socket != null && !identical(current, socket)) return;
        current.add(frame);
        _lastOutboundAt = DateTime.now();
      }).catchError((Object error) {
        if (socket != null) _handleSocketError(socket, error);
      }),
    );
  }

  /// 写一帧普通控制帧：绑定**当前连接**，不绑定会话。
  ///
  /// 绑定连接同样必要：text / offer / accept 这类帧虽然「发出即生效」，
  /// 但排在写入链上时也可能被前面的 flush 挡住；等到轮到自己时连接若已
  /// 换人，把它交给新设备同样是错的（比如把「同意接收」发给了 B）。
  void _write(Uint8List frame) =>
      _enqueueWrite(frame, socket: _socket, session: null);

  /// 会话绑定的写入：[session] 与当前会话不一致时直接丢弃这一帧。
  ///
  /// 跨越多次 await 的操作（发送文件、收尾回执）必须用它：
  /// 中途断连再连上别的设备后，旧操作剩下的帧绝不能再发出去。
  /// [session] 为 null 表示不校验会话（但仍校验连接）。
  void _writeInSession(Uint8List frame, String? session) {
    // 空串视为「未绑定」：调用方拿不到会话标识时不校验会话。
    final expected =
        (session != null && session.isNotEmpty) ? session : null;
    // 入队前先核对一次：明显不属于当前会话的帧，连排队的必要都没有。
    if (expected != null && _sessionId != expected) return;
    _enqueueWrite(frame, socket: _socket, session: expected);
  }

  /// 排空 [socket] 上积压的数据（同样排在写入链上）。
  ///
  /// 也要绑定连接：轮到自己时这条 socket 可能已经随会话切换被销毁，
  /// 对它 flush 既没有意义，也可能永远等不到返回。
  Future<void> _flush(Socket socket) {
    return _chain(() async {
      if (!identical(_socket, socket)) return;
      await socket.flush();
    });
  }

  /// 接管一个已建立的 socket（入站或出站）。
  ///
  /// **已经有会话时直接拒绝新连接**：悄悄顶掉当前连接会让正在传输的文件
  /// 两边都停在半路，而用户完全不知情。这里把新的 socket 关掉，
  /// 并通过 [notices] 提示「谁想连你」，由用户自己决定要不要断开再连。
  void _attach(Socket socket) {
    // 已经封存（退出中）：连监听都关了，理论上不会再有入站连接。
    // 仍然挡一道——万一有一条已经在握手队列里的连接晚到，
    // 它绝不能在收尾进行中创建新会话。
    if (_sealed) {
      unawaited(socket.close().catchError((Object _) => socket.destroy()));
      return;
    }
    if (isBusy) {
      final from = socket.remoteAddress.address;
      unawaited(socket.close().catchError((Object _) => socket.destroy()));
      _noticeController.add(
        '$from 试图连接，但当前已与 ${_lastRemoteAddress ?? '另一台设备'} '
        '保持连接。如需切换，请先点「断开」。',
      );
      return;
    }

    _socketSub?.cancel();
    _socket?.destroy();
    // 新会话从干净的解析缓冲开始。
    _reader.reset();

    // 关闭 Nagle：控制帧（offer / accept / cancel）本就很小，
    // 被攒着延迟发出会让「点了接收却半天没动静」。
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {
      // 某些平台不支持该选项，忽略即可。
    }

    _socket = socket;
    remoteName = null;
    _remoteProtocolVersion = 1;
    // 收到对端 hello 之前一律按「不具备心跳能力」处理：
    // 这时还不能拿「收不到字节」当断链证据。
    _remoteKeepAliveCapable = false;
    _lastRemoteAddress = socket.remoteAddress.address;
    _sessionId = 's${++_sessionCounter}';
    // 会话一建立，此前所有「正在进行的连接尝试」立即作废：
    // 它们既不能接管连接，也不能再广播 disconnected。
    _connectToken++;
    _connecting = false;
    _statusController.add(ConnectionStatus.connected);

    // 建连后互报名字、协议版本与能力位。
    //
    // 'ka' 是心跳能力位：老版本不认识这个键，直接忽略（JSON 里多一个键
    // 不影响它解析 name / proto），于是它们天然是「不具备心跳能力」。
    _write(encodeJsonFrame(MessageType.hello, {
      'name': localName,
      'proto': AppConfig.protocolVersion,
      'ka': true,
    }));

    // Socket 的读流与输出 done Future 是两条独立的错误通道。
    // 对端复位可能使写入失败，即使读流有 onError，done 仍需接住。
    unawaited(socket.done.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        _handleSocketError(socket, error);
      },
    ));
    _socketSub = socket.listen(
      _feed,
      onDone: () {
        if (identical(_socket, socket)) _onSocketClosed();
      },
      onError: (Object error) => _handleSocketError(socket, error),
      cancelOnError: true,
    );
    _startKeepAlive();
  }

  void _handleSocketError(Socket socket, Object error) {
    // 旧连接的迟到错误不能关闭刚建立的新连接。
    if (!identical(_socket, socket)) return;
    _log.info('连接读写失败，结束当前会话：$error');
    socket.destroy();
    _onSocketClosed();
  }

  void _onSocketClosed() {
    _stopKeepAlive();
    // 到这一步订阅已经结束（onDone 自然结束 / cancelOnError 已取消），
    // 把引用清掉，免得之后 pauseInbound / resumeInbound 打在死对象上。
    _socketSub = null;
    _socket = null;
    _sessionId = null;
    _remoteKeepAliveCapable = false;
    // 残留的半截帧不能带到下一次连接。
    _reader.reset();
    _statusController.add(ConnectionStatus.disconnected);
  }

  /// 收到字节：交给帧解析器，逐帧分发。
  void _feed(Uint8List chunk) {
    // 收到任何字节都算「对端还活着」：可能是心跳，也可能是文件数据。
    _lastInboundAt = DateTime.now();
    _reader.add(chunk);
    final frames = _reader.drain();

    final violation = _reader.violation;
    if (violation != null) {
      _abortForProtocolViolation(violation);
      return;
    }

    for (final frame in frames) {
      _handleFrame(frame);
    }
  }

  /// 收到不合协议的字节：立刻断开。
  ///
  /// 声明一个巨帧并持续灌数据的对端（无论是对端有 bug 还是有意），
  /// 会在帧解析这一层就吃掉全部内存——此时数据还没解析成帧，
  /// 写盘队列的背压根本够不着。唯一安全的处理是断开并告诉用户。
  void _abortForProtocolViolation(String reason) {
    _log.warning('收到异常数据，断开连接：$reason');
    _noticeController.add('对端数据异常，已断开连接（$reason）');
    // disconnect() 会 reset 解析器，因此下一次连接不受这次错误影响。
    unawaited(disconnect());
  }

  void _handleFrame(Frame frame) {
    try {
      switch (frame.type) {
        case MessageType.hello:
          remoteName = frame.json['name'] as String? ?? '对端';
          _remoteProtocolVersion =
              (frame.json['proto'] as num?)?.toInt() ?? 1;
          // 能力位优先，版本号兜底：两者只要有一个表明对端会发心跳，
          // 就可以启用「收不到字节即断链」这条判据。
          _remoteKeepAliveCapable =
              frame.json['ka'] == true ||
              _remoteProtocolVersion >= AppConfig.keepAliveProtocolVersion;
        case MessageType.text:
          final json = frame.json;
          _messageController.add(
            ChatMessage(
              text: json['text'] as String? ?? '',
              sender: json['name'] as String? ?? '对端',
              timestamp: DateTime.tryParse(json['ts'] as String? ?? '') ?? DateTime.now(),
              isSelf: false,
              // 带上会话标识：上层据此丢弃「上一次连接」的迟到消息。
              sessionId: _sessionId ?? '',
            ),
          );
        case MessageType.fileOffer:
          final json = frame.json;
          _transferController.add(
            OfferReceived(
              fileId: json['id'] as int? ?? 0,
              name: json['name'] as String? ?? '未知文件',
              size: json['size'] as int? ?? 0,
              batchId: (json['batch'] as num?)?.toInt(),
              batchIndex: (json['batchIndex'] as num?)?.toInt(),
              batchCount: (json['batchCount'] as num?)?.toInt(),
            ),
          );
        case MessageType.fileAccept:
          _transferController.add(AcceptReceived(frame.json['id'] as int? ?? 0));
        case MessageType.fileReject:
          final json = frame.json;
          _transferController.add(
            RejectReceived(
              fileId: json['id'] as int? ?? 0,
              reason: json['reason'] as String?,
            ),
          );
        case MessageType.fileChunk:
          _transferController.add(
            ChunkReceived(
              fileId: chunkFileId(frame.payload),
              data: chunkData(frame.payload),
            ),
          );
        case MessageType.fileEnd:
          final json = frame.json;
          _transferController.add(
            EndReceived(
              json['id'] as int? ?? 0,
              size: (json['size'] as num?)?.toInt(),
              checksum: (json['crc'] as num?)?.toInt(),
            ),
          );
        case MessageType.fileCancel:
          final json = frame.json;
          _transferController.add(
            CancelReceived(
              fileId: json['id'] as int? ?? 0,
              reason: json['reason'] as String?,
            ),
          );
        case MessageType.fileDone:
          final json = frame.json;
          _transferController.add(
            DoneReceived(
              json['id'] as int? ?? 0,
              ok: json['ok'] as bool? ?? false,
              reason: json['reason'] as String?,
            ),
          );
        case MessageType.ping:
          // 什么都不用做：能收到这一帧本身就证明对端还活着，
          // 「最近收到字节的时间」已在 _feed 里刷新过了。
          break;
      }
    } catch (e) {
      // 单帧解析失败不应影响整条连接。
      _transferController.addError(Exception('帧解析失败：$e'));
    }
  }
}

/// 一次发送的实际结果：字节数 + 校验值（供对端核对）。
class SentFileSummary {
  const SentFileSummary({required this.bytes, this.checksum});

  final int bytes;
  final int? checksum;
}

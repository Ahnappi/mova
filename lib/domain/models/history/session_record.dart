import '../transfer/transfer_task.dart';

/// 历史文件方向（以本机为参照）。
enum SessionFileDirection { sent, received }

/// 历史文件结果。
enum SessionFileStatus { completed, rejected, canceled, failed, pending }

/// 一条历史消息（Domain 层，纯 Dart 模型）。
class SessionMessage {
  const SessionMessage({
    required this.text,
    required this.sender,
    required this.isSelf,
    required this.timestamp,
  });

  final String text;
  final String sender;
  final bool isSelf;
  final DateTime timestamp;

  Map<String, dynamic> toJson() => {
        'text': text,
        'sender': sender,
        'isSelf': isSelf,
        'ts': timestamp.toIso8601String(),
      };

  factory SessionMessage.fromJson(Map<String, dynamic> json) => SessionMessage(
        text: json['text'] as String? ?? '',
        sender: json['sender'] as String? ?? '未知',
        isSelf: json['isSelf'] as bool? ?? false,
        timestamp:
            DateTime.tryParse(json['ts'] as String? ?? '') ?? DateTime.now(),
      );
}

/// 一条历史文件记录（Domain 层，纯 Dart 模型）。
///
/// 只保存元信息与「当时的路径」：**不保存任何文件内容**。
/// [localPath] 在发送端为源文件路径，在接收端为保存路径。
class SessionFile {
  const SessionFile({
    required this.id,
    required this.fileName,
    required this.sizeBytes,
    required this.direction,
    required this.status,
    required this.createdAt,
    this.localPath,
    this.finishedAt,
    this.error,
  });

  final int id;
  final String fileName;
  final int sizeBytes;
  final SessionFileDirection direction;
  final SessionFileStatus status;
  final DateTime createdAt;

  /// 当时的路径：发送端为源文件位置，接收端为保存位置。
  final String? localPath;

  /// 终结时间（未终结时为 null）。
  final DateTime? finishedAt;

  /// 失败 / 取消 / 拒绝的原因。
  final String? error;

  /// 由运行中的任务转换而来。
  factory SessionFile.fromTask(TransferTask task) => SessionFile(
        id: task.id,
        fileName: task.fileName,
        sizeBytes: task.totalBytes,
        direction: task.direction == TransferDirection.sending
            ? SessionFileDirection.sent
            : SessionFileDirection.received,
        status: _statusOf(task.status),
        createdAt: task.createdAt,
        localPath: task.localPath,
        finishedAt: task.isFinished ? DateTime.now() : null,
        error: task.error,
      );

  static SessionFileStatus _statusOf(TransferStatus status) => switch (status) {
        TransferStatus.queued => SessionFileStatus.pending,
        TransferStatus.waiting => SessionFileStatus.pending,
        TransferStatus.preparing => SessionFileStatus.pending,
        TransferStatus.transferring => SessionFileStatus.pending,
        // 等回执阶段同样是「还没成」，不能记成已完成。
        TransferStatus.confirming => SessionFileStatus.pending,
        TransferStatus.completed => SessionFileStatus.completed,
        TransferStatus.rejected => SessionFileStatus.rejected,
        TransferStatus.canceled => SessionFileStatus.canceled,
        TransferStatus.failed => SessionFileStatus.failed,
      };

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': fileName,
        'size': sizeBytes,
        'dir': direction.name,
        'status': status.name,
        'createdAt': createdAt.toIso8601String(),
        'path': localPath,
        'finishedAt': finishedAt?.toIso8601String(),
        'error': error,
      };

  factory SessionFile.fromJson(Map<String, dynamic> json) => SessionFile(
        id: json['id'] as int? ?? 0,
        fileName: json['name'] as String? ?? '未知文件',
        sizeBytes: json['size'] as int? ?? 0,
        direction: SessionFileDirection.values.firstWhere(
          (value) => value.name == json['dir'],
          orElse: () => SessionFileDirection.sent,
        ),
        status: SessionFileStatus.values.firstWhere(
          (value) => value.name == json['status'],
          orElse: () => SessionFileStatus.pending,
        ),
        createdAt:
            DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
        localPath: json['path'] as String?,
        finishedAt: DateTime.tryParse(json['finishedAt'] as String? ?? ''),
        error: json['error'] as String?,
      );
}

/// 一次连接的完整记录（Domain 层，纯 Dart 模型）。
///
/// 连接成功时创建，断开时补上 [endedAt]；期间产生的消息与文件都挂在本记录下。
/// 这样「正在进行的会话」与「历史会话」共用同一份数据，UI 只需一套渲染逻辑。
class SessionRecord {
  const SessionRecord({
    required this.id,
    required this.peerName,
    required this.peerIp,
    required this.startedAt,
    this.endedAt,
    this.messages = const <SessionMessage>[],
    this.files = const <SessionFile>[],
  });

  final String id;

  /// 对端设备名（握手后可用；握手未完成时为兜底名）。
  final String peerName;

  /// 对端 IP。
  final String peerIp;

  final DateTime startedAt;

  /// 结束时间（null 表示仍在进行中）。
  final DateTime? endedAt;

  final List<SessionMessage> messages;
  final List<SessionFile> files;

  /// 是否仍在进行中。
  bool get isActive => endedAt == null;

  /// 条目总数（消息 + 文件）。
  int get entryCount => messages.length + files.length;

  SessionRecord copyWith({
    String? peerName,
    String? peerIp,
    DateTime? endedAt,
    List<SessionMessage>? messages,
    List<SessionFile>? files,
  }) =>
      SessionRecord(
        id: id,
        peerName: peerName ?? this.peerName,
        peerIp: peerIp ?? this.peerIp,
        startedAt: startedAt,
        endedAt: endedAt ?? this.endedAt,
        messages: messages ?? this.messages,
        files: files ?? this.files,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'peerName': peerName,
        'peerIp': peerIp,
        'startedAt': startedAt.toIso8601String(),
        'endedAt': endedAt?.toIso8601String(),
        'messages': <Map<String, dynamic>>[
          for (final message in messages) message.toJson(),
        ],
        'files': <Map<String, dynamic>>[for (final file in files) file.toJson()],
      };

  factory SessionRecord.fromJson(Map<String, dynamic> json) {
    final messages = <SessionMessage>[];
    final rawMessages = json['messages'];
    if (rawMessages is List) {
      for (final item in rawMessages) {
        if (item is Map) {
          messages.add(SessionMessage.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }

    final files = <SessionFile>[];
    final rawFiles = json['files'];
    if (rawFiles is List) {
      for (final item in rawFiles) {
        if (item is Map) {
          files.add(SessionFile.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }

    return SessionRecord(
      id: json['id'] as String? ?? '',
      peerName: json['peerName'] as String? ?? '未知设备',
      peerIp: json['peerIp'] as String? ?? '',
      startedAt:
          DateTime.tryParse(json['startedAt'] as String? ?? '') ?? DateTime.now(),
      endedAt: DateTime.tryParse(json['endedAt'] as String? ?? ''),
      messages: messages,
      files: files,
    );
  }
}

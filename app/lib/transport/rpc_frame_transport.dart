import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'crc32.dart';
import 'ipc_codec.dart';

/// Reimplementation of the rpc-frame fragmentation transport
/// (`Xf`/`Zf` schemas, `sp()`/`lp()` in the web client).
///
/// Logical messages are split into frames so the JSON envelope stays below
/// [maxPhysicalFrameBytes]; each message carries a crc32 checksum; the
/// receiver acknowledges assembled messages with `rpc-frame-ack`.
class RpcFrameTransport {
  /// 物理丢帧回调（ChannelClient 挂钩：失败所有在途 RPC 触发重试）。
  void Function()? onGapDetected;
  static const maxPhysicalFrameBytes = 1024 * 1024;

  /// Upper bound for a reassembled logical message. Long-context sessions
  /// (hundreds of thousands of tokens) can produce large snapshots, so this
  /// must be generous enough not to silently drop the initial conversation
  /// frame — which would leave the UI spinning forever (a past regression).
  //单一真源在 [ValueReader.maxValueBytes]（
  /// P2-4：与解码层上限必须一致——此前 64MiB vs 16MiB 各持一个数，16-
  /// 64MiB 消息重组成功后被解码层静默丢弃）。
  static const maxMessageBytes = ValueReader.maxValueBytes;

  /// 64 MiB at 512 KiB/fragment = 128 fragments.
  static const maxFragments = 256;

  /// Raw bytes per fragment; base64 expands by 4/3, keep envelope < 1 MiB.
  static const _fragmentPayloadBytes = 512 * 1024;

  final String bridgeSessionId;
  final int? bridgeGeneration;
  final String? recoveryId;
  final void Function(Map<String, dynamic> payload) sendPayload;
  final void Function(String line)? onLog;

  int _seq = 0;
  int? _lastInboundSeq;
  int _messageSeq = 0;

  /// 已 dispose 的旧桥：迟到帧丢弃（ H1-P1-01——防残留路由/
  /// 竞态窗口把帧打进已 close 的 _messageController 抛 StateError）。
  bool _disposed = false;

  final _messageController = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get messages => _messageController.stream;

  final _assemblies = <int, _Assembly>{};
  Timer? _assemblyCleanupTimer;

  RpcFrameTransport({
    required this.bridgeSessionId,
    required this.sendPayload,
    this.bridgeGeneration,
    this.recoveryId,
    this.onLog,
  }) {
    _assemblyCleanupTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _purgeStale(),
    );
  }

  void _purgeStale() {
    final stale = <int>[];
    final now = DateTime.now();
    _assemblies.forEach((seq, a) {
      if (now.difference(a.createdAt).inSeconds > 60) stale.add(seq);
    });
    for (final seq in stale) {
      _assemblies.remove(seq);
      onLog?.call('[rpc] purged stale assembly $seq');
    }
  }

  Map<String, dynamic> get _identity => {
    'bridgeSessionId': bridgeSessionId,
    if (bridgeGeneration != null) 'bridgeGeneration': bridgeGeneration,
    if (recoveryId != null) 'recoveryId': recoveryId,
  };

  /// Fragment and send one logical message.
  void sendMessage(Uint8List bytes) {
    if (bytes.isEmpty) throw StateError('remote.rpcFrame.emptyMessage');
    if (bytes.length > maxMessageBytes) {
      throw StateError('remote.rpcFrame.messageTooLarge');
    }
    final messageSeq = ++_messageSeq;
    final checksum = Crc32.hexOf(bytes);
    final fragmentCount =
        (bytes.length + _fragmentPayloadBytes - 1) ~/ _fragmentPayloadBytes;
    if (fragmentCount > maxFragments) {
      throw StateError('remote.rpcFrame.fragmentLimitExceeded');
    }
    for (var i = 0; i < fragmentCount; i++) {
      final start = i * _fragmentPayloadBytes;
      final end = start + _fragmentPayloadBytes > bytes.length
          ? bytes.length
          : start + _fragmentPayloadBytes;
      final chunk = Uint8List.sublistView(bytes, start, end);
      _seq += 1;
      sendPayload({
        'zcode_type': 'rpc-frame',
        ..._identity,
        'seq': _seq,
        'messageSeq': messageSeq,
        'fragmentIndex': i,
        'fragmentCount': fragmentCount,
        'messageBytes': bytes.length,
        'checksum': {'algorithm': 'crc32', 'value': checksum},
        'dataBase64': base64.encode(chunk),
      });
    }
  }

  /// Feed a relay payload. Returns true if it was an rpc-frame(-ack).
  bool acceptPayload(Map<String, dynamic> payload) {
    if (_disposed) {
      // 已 dispose 的旧桥只可能收到迟到/重投帧（relay 对旧帧有重投语义）
      // ——丢弃并留痕，不得向已 close 的 _messageController add。
      onLog?.call('[rpc] drop late frame for disposed bridge $bridgeSessionId');
      return true;
    }
    final type = payload['zcode_type'];
    if (type == 'rpc-frame-ack') return true;
    if (type != 'rpc-frame') return false;
    if (payload['bridgeSessionId'] != bridgeSessionId) return false;

    // 物理 seq 连续性审计（真机 2026-10-15 定位 replayGrace 断桥用）：
    // 官方协议 seq 连续，跳号 = 帧在 relay→手机路上丢失。
    final seq = (payload['seq'] as num?)?.toInt();
    if (seq != null) {
      // 真机实录（快速切工作区）：relay 会把旧帧重投/乱序（先 2 后 1）
      // ——倒序/重复是 replay 语义而非丢帧，静默去重即可；曾据此误杀
      // 新桥的在途握手调用（failPendingOnGap → 打开工作区失败）。
      if (_lastInboundSeq != null && seq <= _lastInboundSeq!) {
        onLog?.call('[rpc] dup/reorder seq=$seq (last=${_lastInboundSeq}) '
            '- ignored');
        return true;
      }
      if (_lastInboundSeq != null && seq != _lastInboundSeq! + 1) {
        onLog?.call(
          '[rpc] SEQ GAP: expected ${_lastInboundSeq! + 1} '
          'got $seq (${seq - _lastInboundSeq! - 1} frame(s) lost)',
        );
        // 病②根治（真机实录）：切桥窗口丢帧会吞掉在途 RPC 的
        // 响应——客户端永远等不到，150s 超时前 UI 卡死。通知上层把
        // 全部在途调用立即失败，调用方秒级重试（重试走新帧，能到达）。
        onGapDetected?.call();
      }
      if (_lastInboundSeq == null || seq > _lastInboundSeq!) {
        _lastInboundSeq = seq;
      }
    }

    final messageSeq = (payload['messageSeq'] as num?)?.toInt();
    final fragmentIndex = (payload['fragmentIndex'] as num?)?.toInt();
    final fragmentCount = (payload['fragmentCount'] as num?)?.toInt();
    final messageBytes = (payload['messageBytes'] as num?)?.toInt();
    final dataBase64 = payload['dataBase64'] as String?;
    final checksum = (payload['checksum'] as Map?)?['value'] as String?;
    if (messageSeq == null ||
        fragmentIndex == null ||
        fragmentCount == null ||
        messageBytes == null ||
        dataBase64 == null) {
      return true;
    }

    if (fragmentCount > maxFragments || messageBytes > maxMessageBytes) {
      // Oversized logical message: drop it, but never silently — a dropped
      // initial snapshot previously looked like an endless spinner (#9).
      onLog?.call(
        '[rpc] dropped oversized message $messageSeq '
        '($messageBytes bytes / $fragmentCount fragments)',
      );
      return true;
    }
    if (messageSeq < 0 ||
        fragmentCount < 1 ||
        fragmentIndex < 0 ||
        fragmentIndex >= fragmentCount ||
        messageBytes < 1) {
      return true;
    }

    Uint8List? chunk;
    try {
      chunk = base64.decode(dataBase64);
    } catch (_) {
      return true;
    }
    // 接收侧不得用发送切片常量做分片上限校验：官方按 maxPhysicalFrameBytes
    // (1MiB) 动态预算切分，解码后分片可达 ~768KiB > 我们的 512KiB 发送常量
    // ——曾把桌面大分片全部静默丢弃，组装永不完成→无 ack→桌面 45s
    // replayGraceExceeded 断桥循环（真机 2026-10-15 定位，官方
    // web-remote-control-rpc-transport.ts findDecodedBudget）。

    final existing = _assemblies[messageSeq];
    if (existing != null &&
        (existing.fragmentCount != fragmentCount ||
            existing.messageBytes != messageBytes ||
            existing.checksum != checksum)) {
      _assemblies.remove(messageSeq);
      return true;
    }
    final assembly = _assemblies.putIfAbsent(
      messageSeq,
      () => _Assembly(fragmentCount, messageBytes, checksum),
    );
    assembly.add(fragmentIndex, chunk);
    // P3-8：畸形对端可声明小 messageBytes 却投递大分片——
    // 累计超声明值即整组作废，免内存放大驻留到终局尺寸校验。
    if (assembly.oversized) {
      _assemblies.remove(messageSeq);
      onLog?.call(
        '[rpc] dropped assembly $messageSeq '
        '(fragments exceed declared $messageBytes bytes)',
      );
      return true;
    }
    // 诊断（真机 2026-10-15 大消息组装卡点定位）：多分片消息的收片进度
    if (fragmentCount > 1) {
      onLog?.call(
        '[rpc] fragment msgSeq=$messageSeq '
        '${assembly.received}/$fragmentCount (+${chunk.length}B)',
      );
    }
    if (assembly.isComplete) {
      _assemblies.remove(messageSeq);
      final message = assembly.assemble();
      if (message.length != assembly.messageBytes) {
        onLog?.call('[rpc] message $messageSeq size mismatch');
      } else if (assembly.checksum == null ||
          Crc32.hexOf(message) == assembly.checksum) {
        // 性能（2026-10-17）：逐帧 assembled 日志在流式期间每秒数十条，
        // release 下白耗 CPU/刷 logcat——仅 debug 输出；异常路径照常。
        if (!kReleaseMode) {
          onLog?.call(
            '[rpc] message $messageSeq assembled (${message.length} bytes)',
          );
        }
        _messageController.add(message);
        // ack 必须携带完整桥身份三件套：官方 rawIdentityMatches 对
        // bridgeSessionId/bridgeGeneration/recoveryId 严格相等校验，缺
        // generation/recoveryId 会被桌面静默拒收 → 45s replayGrace 断桥循环
        // （真机 2026-10-15 终极定位，官方 acknowledged protocol 源码）。
        sendPayload({
          'zcode_type': 'rpc-frame-ack',
          'bridgeSessionId': bridgeSessionId,
          if (bridgeGeneration != null) 'bridgeGeneration': bridgeGeneration,
          if (recoveryId != null) 'recoveryId': recoveryId,
          'ackMessageSeq': messageSeq,
        });
      } else {
        onLog?.call('[rpc] message $messageSeq checksum mismatch');
      }
    }
    return true;
  }

  Future<void> dispose() async {
    _disposed = true;
    _assemblyCleanupTimer?.cancel();
    _assemblies.clear();
    await _messageController.close();
  }
}

class _Assembly {
  final int fragmentCount;
  final int messageBytes;
  final String? checksum;
  final List<Uint8List?> fragments;
  final DateTime createdAt = DateTime.now();
  int received = 0;

  /// 已收分片累计字节（P3-8：超过声明的 messageBytes 即
  /// oversized，调用方整组作废）。
  int _bytes = 0;
  bool get oversized => _bytes > messageBytes;

  _Assembly(this.fragmentCount, this.messageBytes, this.checksum)
    : fragments = List<Uint8List?>.filled(fragmentCount, null);

  void add(int index, Uint8List data) {
    if (index < 0 || index >= fragmentCount) return;
    if (fragments[index] == null) {
      received += 1;
      _bytes += data.length;
    } else {
      _bytes += data.length - fragments[index]!.length;
    }
    fragments[index] = data;
  }

  bool get isComplete => received == fragmentCount;

  Uint8List assemble() {
    final builder = BytesBuilder();
    for (final f in fragments) {
      if (f != null) builder.add(f);
    }
    return builder.toBytes();
  }
}

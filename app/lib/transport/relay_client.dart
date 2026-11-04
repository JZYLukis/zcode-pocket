import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'connection_params.dart';
import 'device_info.dart';
import 'proof.dart';

enum RelayState {
  idle,
  connecting,
  authenticating,
  waiting,
  paired,
  reconnecting,
  error,
  kicked,
  closed,
}

class RelayFailure {
  final String reason;
  final String? message;
  const RelayFailure(this.reason, [this.message]);

  @override
  String toString() => message == null ? reason : '$reason: $message';
}

/// 中继连接公共接口（ 双栈）：V1 RelayClient 与 V2 RelayV2Client
/// 同实现——CompanionClient/ComputerStack/LinkPhase 派生对栈版本无感。
abstract class RelayConnection {
  ValueListenable<RelayState> get stateListenable;
  RelayState get state;
  Stream<Map<String, dynamic>> get payloads;
  Stream<RelayFailure> get failures;
  void start();
  void sendPayload(Map<String, dynamic> payload);
  void poke();
  void retryAfterKicked();

  /// 后台自适应心跳（电量专项）：审批提醒保活退后台时放宽心跳档。
  /// V1 无此机制（接口对齐用，空实现）。
  void setBackgroundHeartbeat(bool enabled) {}

  /// 完全静默档（电量优化批 #17）：90s 断连倒计时窗口内不发心跳、不挂
  /// 看门狗（服务器 120s 静默容忍已实证，tools/relay-v2-probe.mjs
  /// --heartbeat）。V1 无心跳机制（接口对齐用，空实现）。
  void setRelaySilent(bool silent) {}
  Future<void> dispose();
}

/// Close-code mapping, mirrors `VC()` / `BC` in the web client.
String? relayCloseReason(int code) {
  switch (code) {
    case 4004:
      return 'session-not-found';
    case 4009:
      return 'session-conflict';
    case 4010:
      return 'desktop-disconnected';
    case 4011:
      return 'session-expired';
    case 4012:
      return 'workspace-closed';
    case 4013:
      return 'invalid-mobile-connection';
    default:
      return null;
  }
}

/// Reimplementation of the relay terminal socket (the terminal socket class
/// in the web client). JSON text frames over `wss://<host>/ws`.
/// WebSocket 收发字节累计（电量日志的网络轴：无线电活跃是耗电大头）。
/// 只累计本连接层文本长度（近似字节），进程生命周期内单调递增。
class BatteryNetCounters {
  static int rxBytes = 0;
  static int txBytes = 0;
}

class RelayClient implements RelayConnection {
  final CompanionConnectionParams params;
  final void Function(String line)? onLog;

  /// WS 连接超时（P1-3 附条/F2-P1-1：黑洞网络下 Upgrade
  /// 永不落定，无超时则 `_connectInFlight` 卡死至内核 TCP 超时 ~2min，
  /// poke/重连定时器全被互斥闸死）。对齐 V2 的 ackTimeout=15s 档；
  /// 测试可注短。
  final Duration wsConnectTimeout;

  /// 认证超时（P3-5）：auth_init 发出后服务器持续沉默时 V1
  /// 停在 authenticating 无限期（心跳只在拿到 pair_status 后才启动，此前
  /// 无任何定时器可救）。对齐 V2 的 handshakeDeadline 语义；测试可注短。
  final Duration handshakeTimeout;

  static const heartbeatInterval = Duration(seconds: 10);
  static const heartbeatAckTimeout = Duration(seconds: 30);
  static const waitingTimeout = Duration(seconds: 30);
  static const reconnectWaitTimeout = Duration(seconds: 20);
  static const _deadLinkThreshold = Duration(seconds: 25);

  WebSocketChannel? _socket;
  StreamSubscription? _socketSub;
  int _socketGeneration = 0;
  bool _connectInFlight = false;

  final _state = ValueNotifier<RelayState>(RelayState.idle);
  @override
  ValueListenable<RelayState> get stateListenable => _state;
  @override
  RelayState get state => _state.value;

  final _payloadController = StreamController<Map<String, dynamic>>.broadcast();
  @override
  Stream<Map<String, dynamic>> get payloads => _payloadController.stream;

  final _failureController = StreamController<RelayFailure>.broadcast();
  @override
  Stream<RelayFailure> get failures => _failureController.stream;

  bool _wasPaired = false;
  bool _intentionallyClosed = false;
  bool _disposed = false;
  int _reconnectAttempt = 0;
  int _heartbeatTick = 0;
  bool _staleProbeSent = false;
  DateTime? _lastKickRecoveryAt;
  DateTime _lastInboundAt = DateTime.now();

  /// Raw frame logging is expensive and can expose payload contents. Keep it
  /// off by default; connection diagnostics remain logged separately.
  static bool verboseFrames = false;
  DateTime _lastPairStatusAckAt = DateTime.now();

  Timer? _heartbeatTimer;
  Timer? _waitingTimer;
  Timer? _reconnectTimer;
  Timer? _rewaitTimer;
  Timer? _handshakeDeadline;

  RelayClient(
    this.params, {
    this.onLog,
    this.wsConnectTimeout = const Duration(seconds: 15),
    this.handshakeTimeout = const Duration(seconds: 15),
  });

  void _log(String line) => onLog?.call(line);

  void _setState(RelayState s) {
    // ValueNotifier 同值赋值本就不通知监听者；日志也必须同去重——
    // 否则心跳每 10s 的 pair_status_ack('matched') 重复打 "->paired"，
    // 制造"断线循环"假象（真机复验 V1 假案的误导源，2026-10-16）。
    final changed = _state.value != s;
    _state.value = s;
    if (changed) _log('[relay] state -> $s');
  }

  @override
  Future<void> start() async {
    // P3-6：dispose 后不得复活——dispose 已 close 两个
    // controller，旧实现重置 `_disposed=false` 后首个 payload add 即
    // StateError（API 陷阱）。生命周期一次性，重建栈走新 RelayClient
    //（生产调用面 computer_stack 每栈新建，不受影响）。
    if (_disposed) return;
    _intentionallyClosed = false;
    _reconnectAttempt = 0;
    _setState(RelayState.connecting);
    await _connect();
  }

  Future<void> _connect() async {
    if (_connectInFlight || _disposed) return;
    _connectInFlight = true;
    final generation = ++_socketGeneration;
    // finally 释放互斥（P1-1：黑洞网络下 connect 卡在
    // await socket.ready 永不落定，此前 _connectInFlight=false 在各分支
    // 逐处手写，悬挂路径漏放 → poke/重连定时器被互斥闸死，永久卡在
    // connecting）。
    try {
      _handshakeDeadline?.cancel();
      _handshakeDeadline = null;
      await _socketSub?.cancel();
      _socketSub = null;
      // P3-4：web_socket 对死 socket 的 close 可抛
      // SocketException/WebSocketException——fire-and-forget 必须接住，
      // 否则成为 zone 级未处理错误噪音。
      _socket?.sink.close().catchError((_) {});
      _socket = null;
      _lastPairStatusAckAt = DateTime.now();
      _lastInboundAt = DateTime.now();
      final uri = params.relayWsUri;
      _log('[relay] connecting ${_safeUriForLog(uri)}');
      WebSocketChannel socket;
      try {
        socket = IOWebSocketChannel.connect(
          uri,
          connectTimeout: wsConnectTimeout,
        );
        await socket.ready;
      } catch (e) {
        _log('[relay] connect failed: $e');
        // P2-3（阶段 2 波次 3c）：首连 DNS 未就绪（宿主网络慢启动）等瞬态
        // 网络错误不进终态——此前 relay-unavailable 终态后不重试，真机
        // Wi-Fi 慢启动场景会卡死在"连接失败"。按瞬态退避重连。
        // TimeoutException=wsConnectTimeout 到点（黑洞悬挂，
        // F2-P1-1），文案不含 "timed out" 故显式判定。
        if (generation == _socketGeneration &&
            !_wasPaired &&
            (e is TimeoutException || _isTransientConnectError('$e'))) {
          _log(
            '[relay] transient connect error, will retry (DNS/network warmup)',
          );
          _setState(RelayState.reconnecting);
          _scheduleReconnect();
          return;
        }
        if (generation == _socketGeneration) {
          _handleSocketClosed(1006, e.toString(), generation: generation);
        }
        return;
      }
      if (_disposed) {
        socket.sink.close().catchError((_) {});
        return;
      }
      if (generation != _socketGeneration) {
        socket.sink.close().catchError((_) {});
        return;
      }
      _socket = socket;
      _socketSub = socket.stream.listen(
        (data) {
          // 电量日志网络轴：入站字节近似累计。
          if (data is String) {
            BatteryNetCounters.rxBytes += data.length;
          } else if (data is List<int>) {
            BatteryNetCounters.rxBytes += data.length;
          }
          _handleRawMessage(data, generation: generation);
        },
        onError: (e) => _log('[relay] socket error: $e'),
        onDone: () => _handleSocketClosed(
          socket.closeCode ?? 1006,
          socket.closeReason,
          generation: generation,
        ),
      );
      _setState(RelayState.authenticating);
      _send({
        'type': 'auth_init',
        'role': 'terminal',
        'device_sid': params.deviceSid,
        'meta': {
          'platform': companionPlatformName(),
          // QR 无 app_version 时兜底 'unknown'（P3-2/F3-P3-11）
          // ——旧兜底 'web' 是字面量冒充版本号，桌面端"已连接客户端"排障
          // 误导。
          'version': params.appVersion ?? 'unknown',
          'name': companionAppName,
        },
        'client_ts': DateTime.now().millisecondsSinceEpoch,
      });
      // 握手 deadline（P3-5）：服务器持续沉默（含回未处理
      // 错误码的静默变体）时按超时转重连，不再无限期停在 authenticating。
      _handshakeDeadline?.cancel();
      _handshakeDeadline = Timer(handshakeTimeout, () {
        if (_disposed || _intentionallyClosed) return;
        if (state != RelayState.authenticating) return;
        _log('[relay] handshake deadline'
            '（${handshakeTimeout.inMilliseconds}ms 无 auth_ack）');
        _reconnect();
      });
    } finally {
      _connectInFlight = false;
    }
  }

  void _send(Map<String, dynamic> frame) {
    final socket = _socket;
    if (socket == null) return;
    final text = jsonEncode(frame);
    BatteryNetCounters.txBytes += text.length; // 电量日志网络轴
    if (verboseFrames) _log('[relay] >> $text');
    try {
      socket.sink.add(text);
    } catch (_) {
      // P3-10：已关闭 sink 上的 add 抛 StateError——重连/心跳
      // 机制会兜住，异常不得从定时器回调/业务调用方同步逃逸。
    }
  }

  Uri _safeUriForLog(Uri uri) {
    return uri.replace(
      queryParameters: {
        for (final entry in uri.queryParameters.entries)
          entry.key: '<redacted>',
      },
    );
  }

  /// Outbound data payloads are queued while unpaired (reconnecting /
  /// waiting) and flushed once the relay reports `matched` — otherwise
  /// requests sent during a reconnect vanish into a dead socket and the
  /// caller hangs until timeout.
  final _outboundQueue = <Map<String, dynamic>>[];

  @override
  void sendPayload(Map<String, dynamic> payload) {
    // P3-6：dispose 后调用不得把载荷塞进死队列（V2 已有同款
    // 守卫）。
    if (_disposed) return;
    if (state != RelayState.paired || _socket == null) {
      if (_outboundQueue.length < 100) {
        _log('[relay] queued (state=$state): ${payload['zcode_type']}');
        _outboundQueue.add(payload);
      } else {
        // A6① 顺手修（2026-10-24 修复批）：V1 同病——溢出静默丢弃留痕。
        _log('[relay] outbound queue overflow (100), drop: '
            '${payload['zcode_type'] ?? payload['type'] ?? 'payload'}');
      }
      return;
    }
    _send({
      'type': 'data',
      'payload': payload,
      'client_ts': DateTime.now().millisecondsSinceEpoch,
    });
  }

  void _flushOutboundQueue() {
    if (_outboundQueue.isEmpty) return;
    _log('[relay] flushing ${_outboundQueue.length} queued payload(s)');
    final queued = List<Map<String, dynamic>>.from(_outboundQueue);
    _outboundQueue.clear();
    for (final payload in queued) {
      _send({
        'type': 'data',
        'payload': payload,
        'client_ts': DateTime.now().millisecondsSinceEpoch,
      });
    }
  }

  void _handleRawMessage(dynamic data, {required int generation}) {
    if (generation != _socketGeneration || _disposed) return;
    _lastInboundAt = DateTime.now();
    Map<String, dynamic>? frame;
    try {
      final text = data is String ? data : utf8.decode(data as List<int>);
      if (verboseFrames) _log('[relay] << $text');
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic> && decoded.containsKey('type')) {
        frame = decoded;
      }
    } catch (e) {
      _log('[relay] bad frame: $e');
      return;
    }
    if (frame == null) return;
    switch (frame['type']) {
      case 'auth_challenge':
        _send({
          'type': 'auth_response',
          'device_sid': params.deviceSid,
          'proof': calculateProof(
            passHash: params.passHash,
            // P3-8：服务端发非字符串 nonce 时 `as String?`
            // 在 onData 内抛 TypeError→未捕获 zone 异常——安全取值。
            nonce: frame['nonce'] is String ? frame['nonce'] as String : '',
            role: 'terminal',
            deviceSid: params.deviceSid,
          ),
          'client_ts': DateTime.now().millisecondsSinceEpoch,
        });
        break;
      case 'auth_ack':
      case 'pair_status_ack':
        // P3-6：auth_ack 校验 device_sid（V2 既有严格语义对齐
        // ——多电脑局域网内跨设备误配对防护；仅在服务端回带该字段且不匹配
        // 时忽略，兼容不回带的旧中继）。
        if (frame['type'] == 'auth_ack' &&
            frame['device_sid'] != null &&
            frame['device_sid'] != params.deviceSid) {
          _log('[relay] auth_ack device_sid mismatch, ignored');
          return;
        }
        // P3-8：非字符串 pair_status 的强转同上——对齐 V2 的
        // 宽松插值语义（非字符串按 null=忽略本帧）。
        _applyPairStatus(
          frame['pair_status'] is String ? frame['pair_status'] as String? : null,
        );
        break;
      case 'data':
        final payload = frame['payload'];
        if (payload is Map<String, dynamic>) {
          _payloadController.add(payload);
        }
        break;
      case 'error':
        _handleRelayError(
          frame['code'] is String ? frame['code'] as String? : null,
          frame['message'] is String ? frame['message'] as String? : null,
        );
        break;
    }
  }

  void _applyPairStatus(String? status) {
    _handshakeDeadline?.cancel(); // 任意配对状态 ACK=握手完成（F3-P3-5）
    _lastPairStatusAckAt = DateTime.now();
    _staleProbeSent = false;
    if (status == 'waiting') {
      if (_wasPaired) {
        _clearWaitingTimer();
        _setState(RelayState.waiting);
        _startHeartbeat();
        // A reconnecting mobile that was already paired should be matched
        // immediately; if the server keeps saying "waiting", force another
        // reconnect instead of hanging forever.
        _rewaitTimer?.cancel();
        _rewaitTimer = Timer(reconnectWaitTimeout, () {
          if (_wasPaired && state == RelayState.waiting && !_disposed) {
            _log('[relay] re-pair stuck in waiting, reconnecting');
            _reconnect();
          }
        });
      } else {
        _setState(RelayState.waiting);
        _startWaitingTimer();
      }
      return;
    }
    if (status == 'matched') {
      _rewaitTimer?.cancel();
      _reconnectAttempt = 0;
      _clearWaitingTimer();
      _setState(RelayState.paired);
      _wasPaired = true;
      _startHeartbeat();
      _flushOutboundQueue();
    }
  }

  /// 瞬态连接错误判定（P2-3）：DNS 未解析/网络未就绪/连接被重置等。
  static bool _isTransientConnectError(String text) {
    final t = text.toLowerCase();
    return t.contains('failed host lookup') ||
        t.contains('socketexception') ||
        t.contains('connection refused') ||
        t.contains('connection reset') ||
        t.contains('network is unreachable') ||
        t.contains('timed out') ||
        t.contains('connection closed before');
  }

  void _handleRelayError(String? code, String? message) {
    _log('[relay] error frame: $code $message');
    if (code == 'KICKED') {
      final detail = (message ?? '').toLowerCase();
      final transient =
          detail.contains('conflict') ||
          detail.contains('duplicate') ||
          detail.contains('already connected') ||
          detail.contains('another connection');
      // 用户需求①（2026-10-17）：被踢后停止疯狂重连。原实现每次成功
      // 重配都重置 _kickRecoveryAttempted（_applyPairStatus），两台设备
      // 互踢时双方无限"conflict 恢复"=踢人风暴。改为时间窗预算：5 分钟
      // 内只允许一次自救，其后转终态 kicked（停止重连），由用户通过
      // "强制接管"按钮主动恢复。
      final withinBudget = _lastKickRecoveryAt == null ||
          DateTime.now().difference(_lastKickRecoveryAt!) >
              const Duration(minutes: 5);
      if (withinBudget &&
          (state == RelayState.authenticating || transient)) {
        _lastKickRecoveryAt = DateTime.now();
        _failureController.add(RelayFailure('session-conflict', message));
        _reconnect();
        return;
      }
      _setState(RelayState.kicked);
      _intentionallyClosed = true;
      _failureController.add(RelayFailure('kicked', message));
      _socket?.sink.close().catchError((_) {});
      return;
    }
    // 凭据失效（桌面刷新二维码后旧 URL 的真实信号，；
    // 实测 2026-10-14：伪造/作废 sid → AUTH_FAILED → close 1006）。
    // 终态不重连——凭据已废，重连只会循环报错；由上层标记档案失效引导重扫。
    if (code == 'AUTH_FAILED' || code == 'DEVICE_OFFLINE') {
      _setState(RelayState.error);
      _intentionallyClosed = true;
      _failureController.add(
        RelayFailure(
          code == 'AUTH_FAILED' ? 'auth-failed' : 'desktop-offline',
          message,
        ),
      );
      _socket?.sink.close().catchError((_) {});
      return;
    }
    // P3-5/F2-P3-8：未处理错误码（WRONG_PARAM/INTERNAL/未来
    // 枚举）此前静默忽略——打一行漂移信号日志（只观察不拦截；连接停滞
    // 由握手 deadline 兜底，错误帧后服务端通常还会主动 close）。
    _log('[relay] 未处理错误码（忽略）：$code $message');
  }

  void _handleSocketClosed(int code, String? reason, {int? generation}) {
    if (_disposed) return;
    if (generation != null && generation != _socketGeneration) return;
    _stopHeartbeat();
    _clearWaitingTimer();
    _handshakeDeadline?.cancel();
    _handshakeDeadline = null;
    final mapped = relayCloseReason(code);
    _log('[relay] closed code=$code reason=$reason mapped=$mapped');
    if (_intentionallyClosed) return;
    // P3-7：4009 close code 与 KICKED 帧同源（会话被其他终端
    // 接管）——旧实现经 `_wasPaired` 分支无限重连，两台手机互踢时形成
    // 慢速乒乓。并入 KICKED 帧路径同款 5 分钟自救预算。
    if (mapped == 'session-conflict') {
      final withinBudget =
          _lastKickRecoveryAt == null ||
          DateTime.now().difference(_lastKickRecoveryAt!) >
              const Duration(minutes: 5);
      if (withinBudget) {
        _lastKickRecoveryAt = DateTime.now();
        _failureController.add(
          RelayFailure('session-conflict', '连接被其他终端关闭（4009）'),
        );
        _scheduleReconnect();
      } else {
        _setState(RelayState.kicked);
        _intentionallyClosed = true;
        _failureController.add(
          const RelayFailure('kicked', '5 分钟内两次被接管，停止自动重连'),
        );
        _socket?.sink.close().catchError((_) {});
      }
      return;
    }
    if (_wasPaired || mapped == 'desktop-disconnected') {
      _scheduleReconnect();
      return;
    }
    _setState(RelayState.error);
    _failureController.add(
      RelayFailure(
        mapped ?? 'relay-unavailable',
        reason ?? 'connection closed ($code)',
      ),
    );
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      if (state != RelayState.paired && state != RelayState.waiting) return;
      _heartbeatTick++;
      if (state == RelayState.waiting && _heartbeatTick.isOdd) return;
      if (DateTime.now().difference(_lastPairStatusAckAt) >
          heartbeatAckTimeout) {
        if (!_staleProbeSent) {
          _staleProbeSent = true;
          _log('[relay] heartbeat stale, probing before reconnect');
        } else {
          _staleProbeSent = false;
          _log('[relay] heartbeat ack timeout, reconnecting');
          _reconnect();
          return;
        }
      } else {
        _staleProbeSent = false;
      }
      _send({
        'type': 'pair_status_query',
        'device_sid': params.deviceSid,
        'client_ts': DateTime.now().millisecondsSinceEpoch,
      });
    });
  }

  /// 用户主动"强制接管"（被踢终态后）：清旗重连——新终端天然把对端
  /// 踢下线（每桌面一个终端的官方语义）。
  @override
  void retryAfterKicked() {
    if (_disposed || state != RelayState.kicked) return;
    _log('[relay] manual takeover requested');
    _intentionallyClosed = false;
    _setState(RelayState.connecting);
    _connect();
  }

  /// 后台自适应心跳（电量专项）：V1 无此机制，空实现（接口对齐）。
  @override
  void setBackgroundHeartbeat(bool enabled) {}

  /// 完全静默档（电量优化批 #17）：V1 无心跳机制，空实现（接口对齐）。
  @override
  void setRelaySilent(bool silent) {}

  /// Probe immediately when the app returns from background. If no inbound
  /// relay frame arrived for a while, skip backoff and rebuild the socket.
  @override
  void poke() {
    if (_disposed || _intentionallyClosed) return;
    if (state == RelayState.paired) {
      if (DateTime.now().difference(_lastInboundAt) > _deadLinkThreshold) {
        _log('[relay] poke: stale inbound link, reconnecting');
        _reconnect();
        return;
      }
      _send({
        'type': 'pair_status_query',
        'device_sid': params.deviceSid,
        'client_ts': DateTime.now().millisecondsSinceEpoch,
      });
    } else if (state != RelayState.idle &&
        state != RelayState.closed &&
        state != RelayState.kicked) {
      _log('[relay] poke: state=$state, forcing reconnect');
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _connect();
    }
  }

  void _stopHeartbeat() => _heartbeatTimer?.cancel();

  void _startWaitingTimer() {
    _clearWaitingTimer();
    _waitingTimer = Timer(waitingTimeout, () {
      if (state == RelayState.waiting && !_wasPaired) {
        _setState(RelayState.error);
        _failureController.add(
          const RelayFailure(
            'invalid-mobile-connection',
            'Desktop did not match this mobile connection before the waiting timeout.',
          ),
        );
      }
    });
  }

  void _clearWaitingTimer() {
    _waitingTimer?.cancel();
    _rewaitTimer?.cancel();
  }

  void _scheduleReconnect() {
    if (_disposed || _intentionallyClosed) return;
    _setState(RelayState.reconnecting);
    final delayMs = (1000 * (1 << _reconnectAttempt.clamp(0, 4))).clamp(
      1000,
      15000,
    );
    _reconnectAttempt += 1;
    _log('[relay] reconnect in ${delayMs}ms (attempt $_reconnectAttempt)');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!_disposed) _connect();
    });
  }

  Future<void> _reconnect() async {
    if (_disposed || _intentionallyClosed || _connectInFlight) return;
    _reconnectTimer?.cancel();
    // Go through `reconnecting` so listeners (bridge recovery) know the
    // connection dropped — the heartbeat-timeout path used to skip this and
    // bridges were never recovered after re-pairing.
    _setState(RelayState.reconnecting);
    await _connect();
  }

  /// Diagnostics: forcefully drops the socket to exercise the
  /// reconnect/bridge-recovery path (used by integration probes).
  Future<void> debugDropSocket() async {
    _intentionallyClosed = false;
    await _socketSub?.cancel();
    _socketSub = null;
    final socket = _socket;
    _socket = null;
    try {
      await socket?.sink.close(3000, 'debug-drop');
    } catch (_) {}
    _handleSocketClosed(1006, 'debug-drop', generation: _socketGeneration);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _intentionallyClosed = true;
    _stopHeartbeat();
    _clearWaitingTimer();
    _reconnectTimer?.cancel();
    _rewaitTimer?.cancel();
    _handshakeDeadline?.cancel();
    _handshakeDeadline = null;
    await _socketSub?.cancel();
    _socket?.sink.close().catchError((_) {});
    _setState(RelayState.closed);
    await _payloadController.close();
    await _failureController.close();
    // P3-7/F3-P3-6：与 V2 对齐 dispose 状态通知器——两栈
    // 生命周期收尾对称，防后续改动踩 "used after being disposed" 断言。
    _state.dispose();
  }
}

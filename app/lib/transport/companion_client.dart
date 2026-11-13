// SPDX-License-Identifier: MIT
// Portions Copyright (c) 2026 Zemote contributors — initially ported from
// https://github.com/HumanAILoop/zemote, since rewritten against the official
// implementation (see THIRD-PARTY-NOTICES.md).
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'channel_client.dart';
import 'connection_params.dart';
import 'conversation.dart';
import 'device_info.dart';
import 'id.dart';
import 'protocol_drift.dart';
import 'relay_client.dart';
import 'relay_v2.dart';
import 'rpc_frame_transport.dart';

String _reqId(String prefix) => generateRequestId(prefix);

/// 终端所有权被接管（桌面已在另一台设备/另一个页面打开该桥）时给用户看
/// 的人话 degrade 文案——恢复走慢档（见 CompanionClient.slowRecoveryDelay）。
const String terminalOwnerDegradedMessage = '该电脑已在另一台设备上打开';

/// 桌面 `app-error`（官方 payloadRequester.ts:115-124 / validation.ts:
/// 493-499）：带 requestId 的请求级立即失败信号——不等 30s 超时才报错。
class RemoteAppError implements Exception {
  /// 官方 reason（webRemoteControlFailureReasonSchema：如
  /// rpc-transport-fault/source-session-replaced/…）。
  final String? reason;
  final String error;
  const RemoteAppError(this.reason, this.error);

  @override
  String toString() => reason == null ? error : '$reason: $error';
}

/// 是否属于「桌面端已把该桥交给别的终端（手机/页面）」的失效原因
/// （官方 bridge-degraded reason 枚举，validation.ts:480-489）。
bool isTerminalOwnerDegradeReason(String? reason) =>
    reason == 'terminal-owner-ended' || reason == 'source-session-replaced';

/// High-level facade replicating the web client's `otn()` flow:
/// relay connect -> pair -> bootstrap -> workspace bridge -> channel RPC.
///
/// 双栈：默认构造=V1（pass_hash 档案）；`CompanionClient.v2`
/// =Relay V2（账号 JWT 档案）。relay 对外类型=RelayConnection 公共接口。
class CompanionClient {
  final void Function(String line)? onLog;
  final RelayConnection relay;

  /// 桌面 app_version（mobile-view-state 的 deviceInfo.version 用）。
  final String? _appVersion;

  /// 桥恢复快档重试间隔（默认 3s；测试可注短）。
  final Duration fastRecoveryDelay;

  /// 终端所有权被接管后的慢档恢复间隔（默认 30s）——固定节奏单发，
  /// 不做快重试循环（官方：接管方未退出前重开注定被拒，快循环只是
  /// 无线电流量/桌面端负载）。
  final Duration slowRecoveryDelay;

  final _pendingMatchers = <String, bool Function(Map<String, dynamic>)>{};
  final _pendingCompleters = <String, Completer<Map<String, dynamic>>>{};

  StreamSubscription? _payloadSub;

  final _workspaceListUpdatedController = StreamController<dynamic>.broadcast();
  Stream<dynamic> get workspaceListUpdated =>
      _workspaceListUpdatedController.stream;

  CompanionClient(
    CompanionConnectionParams params, {
    this.onLog,
    this.fastRecoveryDelay = const Duration(seconds: 3),
    this.slowRecoveryDelay = const Duration(seconds: 30),
  }) : relay = RelayClient(params, onLog: onLog),
       _appVersion = params.appVersion {
    _listenRelay();
  }

  CompanionClient.v2({
    required RelayV2Config config,
    required Future<String?> Function() jwtProvider,
    RelayV2Timing? timing,
    this.onLog,
    this.fastRecoveryDelay = const Duration(seconds: 3),
    this.slowRecoveryDelay = const Duration(seconds: 30),
  }) : relay = RelayV2Client(
         config: config,
         jwtProvider: jwtProvider,
         timing: timing ?? const RelayV2Timing(),
         onLog: onLog,
       ),
       _appVersion = config.appVersion {
    _listenRelay();
  }

  void _listenRelay() {
    _payloadSub = relay.payloads.listen(_dispatchPayload);
    relay.stateListenable.addListener(_onRelayState);
  }

  Future<void> connect() async {
    relay.start();
  }

  void _log(String line) => onLog?.call(line);

  bool _needsBridgeRecovery = false;

  /// Relay reconnects happen silently (heartbeat timeout, network switch,
  /// laptop sleep). After re-pairing, every active bridge must be
  /// recovered — mirrors the web client's connection recovery.
  void _onRelayState() {
    final state = relay.state;
    if (state == RelayState.reconnecting || state == RelayState.error) {
      if (_activeBridges.isNotEmpty) {
        _needsBridgeRecovery = true;
        // Mark bridges degraded immediately so in-flight commands gate on
        // recovery instead of timing out on the now-dead socket/bridge.
        for (final s in _activeBridges) {
          if (s.degraded.value == null) s.degraded.value = 'reconnecting';
        }
      }
      return;
    }
    if (state == RelayState.paired && _needsBridgeRecovery) {
      _needsBridgeRecovery = false;
      _recoverActiveBridges();
    }
  }

  Future<void> _recoverActiveBridges() async {
    _log('[bridge] recovering ${_activeBridges.length} bridge(s)');
    for (final session in List<BridgeSession>.from(_activeBridges)) {
      if (_recoveringBridges.contains(session)) continue;
      _recoveringBridges.add(session);
      unawaited(_recoverBridgeWithRetry(session));
    }
  }

  final Set<BridgeSession> _recoveringBridges = {};

  /// 终端所有权被接管（terminal-owner-ended/source-session-replaced）的桥
  /// ——恢复走 [slowRecoveryDelay] 慢档（接管方未退出前重开注定被拒），
  /// 并保持 degraded 人话文案不被内部状态串覆盖。状态放在 client 侧而不是
  /// BridgeSession 字段：BridgeSession 是测试广泛 implements 的接口，加字段
  /// 会让所有假实现编译失败。
  final Set<BridgeSession> _slowRecoveryBridges = {};

  /// 测试缝：该桥是否处于终端接管慢档。
  @visibleForTesting
  bool debugSlowRecovery(BridgeSession session) =>
      _slowRecoveryBridges.contains(session);

  /// Retries bridge recovery until it succeeds, so a degraded bridge never
  /// strands commands ("can't send after reconnect"). A relay re-drop during
  /// the retries just prolongs the loop.
  ///
  /// [CompanionClient._slowRecoveryBridges]（terminal-owner-ended/source-
  /// session-replaced）下改固定慢档：接管方未退出前重开注定被拒，快重试
  /// 循环只是白耗电与桌面端负载；其余 reason 维持 3s×15→30s 快档。
  Future<void> _recoverBridgeWithRetry(BridgeSession session) async {
    try {
      var attempt = 0;
      while (true) {
        attempt++;
        final slow = _slowRecoveryBridges.contains(session);
        if (await _recoverBridgeOnce(session, slowOwner: slow)) {
          _slowRecoveryBridges.remove(session);
          return;
        }
        if (session._disposed) {
          _slowRecoveryBridges.remove(session);
          return;
        }
        if (slow) {
          if (attempt == 1) {
            _log('[bridge] terminal owner taken over, slow '
                '${slowRecoveryDelay.inSeconds}s recovery cadence');
          }
          await Future.delayed(slowRecoveryDelay);
        } else if (attempt < 15) {
          _log('[bridge] recovery attempt $attempt failed, retrying');
          await Future.delayed(fastRecoveryDelay);
        } else {
          // 原版 15 次后彻底放弃，degraded 永停 reopen-failed：桥对象
          // 还在（phase 谎报 online），所有新 RPC 经 waitHealthy 45s 挂
          // 死，真机体感"点啥都没反应，只有切工作区能恢复"（2026-10-23
          // 真机反馈，VPN 间歇抖动数分钟远超 45s 重试窗）。降频续跑：
          // 只要桥未被上层释放就持续爬，恢复即自动痊愈。
          if (attempt == 15) {
            _log('[bridge] fast retries exhausted, slow 30s cadence');
          }
          await Future.delayed(const Duration(seconds: 30));
        }
      }
    } finally {
      _recoveringBridges.remove(session);
    }
  }

  /// Returns true when the bridge is healthy again.
  Future<bool> _recoverBridgeOnce(
    BridgeSession session, {
    required bool slowOwner,
  }) async {
    final workspaceKey = session.bridge['workspaceKey'] as String?;
    if (workspaceKey == null) {
      // Nothing to reconnect; clear the degraded flag so commands unblock.
      if (!session._disposed) session.degraded.value = null;
      return true;
    }
    if (session._disposed) return true;
    // relay 未配对时不发探测/开桥请求（对抗审查 双路交叉命中）：
    // V2 出站通道非 paired 态把载荷排进 _outboundQueue（上限 100），
    // 无限恢复循环每轮 2 条请求会把队列积满，重连同刻冲刷几十条陈旧
    // bridge-open 给桌面（桥重建风暴， 同类风险）。跳过本轮
    // 等慢速档再试——配对后循环自然收敛。
    if (relay.state != RelayState.paired) {
      _log('[bridge] recovery deferred: relay not paired '
          '(${relay.state.name}), skipping this round');
      return false;
    }
    if (!slowOwner) session.degraded.value = 'recovering';
    // 1) cheap path: workspace-reconnect-request（慢档跳过：该探测对本地桥
    // 恒 success 但不重建，纯诊断价值——慢档"30s 单发"只保留真正重建的
    // bridge-open，避免接管方未退出期间每次多打一条无意义请求）。
    if (!slowOwner) {
      try {
        final res = await reconnectWorkspace(workspaceKey)
            .timeout(const Duration(seconds: 15));
        // await 期间桥可能已被上层释放（切工作区）——notifier 已 dispose，
        // 再写会抛 "used after being disposed"（真机 2026-10-15 复现）
        if (session._disposed) return true;
        // 统一根因修复（2026-10-17，真机日志实锤 + refs 官方语义）：
        // workspace-reconnect-request 是 SSH/远程主机恢复语义（官方
        // WebRemoteControlMobileTaskHome 的断开工作区按钮），对本地桥恒返
        // success 但**不重建桥**。relay 掉线重连后服务端桥已随旧终端销毁，
        // 宣布"健康"= 继续对幽灵桥发请求 → 桌端 rawIdentityMatches 静默丢弃
        // → 新 RPC（订阅/建会话/任务列表）全部超时挂死（真机现象：新会话
        // 发送无输出/重连后要切工作区才能加载/锁屏唤醒不加载）。
        // 官方语义（refs main.tsx recoverVisibleSession）：恢复一律
        // workspace-bridge-open 重开（钉 workspaceKey + recoveryId）。
        // 此 cheap path 只能作为探测日志保留，绝不能据此宣布健康。
        _log('[bridge] reconnect-request probed: success=${res['success']} '
            '(SSH-host 语义，本地桥不据此判定健康，继续 reopen)');
      } catch (e) {
        _log('[bridge] reconnect-request probe failed: $e');
      }
      if (session._disposed) return true;
    }
    // full reopen: new workspace-bridge-open, swap the transport stack
    // into the SAME BridgeSession so open pages keep working.
    try {
      await _reopenBridge(session, workspaceKey);
      if (session._disposed) return true;
      session.degraded.value = null;
      _slowRecoveryBridges.remove(session);
      session.recovered.value += 1;
      return true;
    } catch (e) {
      _log('[bridge] reopen failed: $e');
      if (session._disposed) return true;
      // 慢档恢复保持人话文案（内部状态串会盖掉"已在另一台设备打开"，
      // waitHealthy 只判非空，展示面需要稳定原因）。
      session.degraded.value = slowOwner
          ? terminalOwnerDegradedMessage
          : 'reopen-failed: $e';
      return false;
    }
  }

  /// Waits until the relay reports `matched` (paired with the desktop).
  Future<void> waitPaired({Duration timeout = const Duration(seconds: 60)}) {
    if (relay.state == RelayState.paired) return Future.value();
    final completer = Completer<void>();
    Timer? timer;
    void listener() {
      if (relay.state == RelayState.paired && !completer.isCompleted) {
        timer?.cancel();
        completer.complete();
      }
    }

    relay.stateListenable.addListener(listener);
    timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException('pairing timeout'));
      }
    });
    return completer.future.whenComplete(() {
      timer?.cancel();
      relay.stateListenable.removeListener(listener);
    });
  }

  void _dispatchPayload(Map<String, dynamic> payload) {
    final type = payload['zcode_type'];
    if (type == 'workspace-list-updated') {
      _workspaceListUpdatedController.add(payload['result']);
      return;
    }
    if (type == 'bridge-degraded') {
      _handleBridgeDegraded(payload);
      return;
    }
    if (type == 'rpc-frame' || type == 'rpc-frame-ack') {
      // Race: the desktop may push frames (e.g. IPC Initialize) before
      // openBridge's await continuation attaches the transport. Buffer
      // unknown-bridge frames and flush on registration.
      final id = payload['bridgeSessionId'] as String?;
      final router = id == null ? null : _frameRouters[id];
      if (router != null) {
        router(payload);
      } else if (id != null) {
        // 无上限缓冲对永不注册的 bridge id
        // 无限蓄积（open 超时失败/换桥后 relay 重放旧帧）。每 id 上限
        // 64 帧，超限丢最旧；孤儿 id 的清理见 openBridge 失败路径与
        // _attachStack/onDispose 的换桥清退。
        final pending = _pendingBridgePayloads.putIfAbsent(id, () => []);
        if (pending.length >= 64) pending.removeAt(0);
        pending.add(payload);
      }
      return;
    }
    // 官方 payloadRequester.ts:115-124：任何带 requestId 的 app-error
    // 命中在途 pending 即立即 reject（不等请求超时）。特例：createWorkspace
    // 的 matcher 显式接受 app-error（旧桌面「不支持该动作」的人话降级），
    // 命中 matcher 时交回下方通用分发由调用方裁决。
    if (type == 'app-error' && payload['requestId'] is String) {
      final requestId = payload['requestId'] as String;
      final completer = _pendingCompleters[requestId];
      final matcher = _pendingMatchers[requestId];
      if (completer != null &&
          !completer.isCompleted &&
          (matcher == null || !matcher(payload))) {
        _pendingMatchers.remove(requestId);
        _pendingCompleters.remove(requestId);
        completer.completeError(
          RemoteAppError(
            payload['reason'] is String ? payload['reason'] as String : null,
            payload['error'] is String ? payload['error'] as String : '',
          ),
        );
        return;
      }
    }
    // Mirrors the web client's `k()` helper: every pending matcher is
    // tested against every payload; responses are NOT guaranteed to echo
    // our requestId.
    final done = <String>[];
    _pendingMatchers.forEach((requestId, matcher) {
      final completer = _pendingCompleters[requestId];
      if (completer != null && !completer.isCompleted && matcher(payload)) {
        done.add(requestId);
        completer.complete(payload);
      }
    });
    for (final id in done) {
      _pendingMatchers.remove(id);
      _pendingCompleters.remove(id);
    }
  }

  /// Request/response over relay payloads (mirrors the `k()` helper).
  Future<Map<String, dynamic>> request(
    Map<String, dynamic> payload,
    bool Function(Map<String, dynamic>) match, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    final requestId = payload['requestId'] as String;
    final completer = Completer<Map<String, dynamic>>();
    _pendingMatchers[requestId] = match;
    _pendingCompleters[requestId] = completer;
    relay.sendPayload(payload);
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pendingMatchers.remove(requestId);
        _pendingCompleters.remove(requestId);
        throw TimeoutException('request $requestId timed out');
      },
    );
  }

  /// bootstrap-request -> bootstrap-response (workspaces overview).
  Future<Map<String, dynamic>> bootstrap() async {
    final id = _reqId('bootstrap');
    final res = await request({
      'zcode_type': 'bootstrap-request',
      'requestId': id,
    }, (p) => p['zcode_type'] == 'bootstrap-response' && p['requestId'] == id);
    return (res['result'] as Map?)?.cast<String, dynamic>() ?? res;
  }

  /// 机会项#1（2026-11-08 拍板）：workspace-create 直发（官方
  /// webRemoteControlActions：name 非空且不含 / \，同名复用）→
  /// response {success, workspacePath, workspaceKey, projectId?, hostId?}。
  Future<Map<String, dynamic>> createWorkspace(String name) async {
    final id = _reqId('workspace-create');
    // （对抗审查·协议低×2）：app-error=旧桌面「不支持该动作」的
    // 立即降级信号（官方 webRemoteControlManager :1457）——不认会干等
    // 满 30s；超时 45s 留桌面 Renderer 30s 上限的往返余量。
    final res = await request(
      {
        'zcode_type': 'workspace-create-request',
        'requestId': id,
        'name': name,
      },
      (p) =>
          (p['zcode_type'] == 'workspace-create-response' ||
              p['zcode_type'] == 'app-error') &&
          p['requestId'] == id,
      timeout: const Duration(seconds: 45),
    );
    if (res['zcode_type'] == 'app-error') {
      throw StateError('该电脑版本不支持在手机上新建项目（请升级桌面端）');
    }
    if (res['success'] != true) {
      throw StateError('${res['error'] ?? '创建失败'}');
    }
    return res.cast<String, dynamic>();
  }

  /// workspace-list-request -> workspace-list-response.
  Future<dynamic> listWorkspaces() async {
    final id = _reqId('workspace-list');
    final res = await request(
      {'zcode_type': 'workspace-list-request', 'requestId': id},
      (p) =>
          p['zcode_type'] == 'workspace-list-response' && p['requestId'] == id,
    );
    return res['result'];
  }

  int _bridgeGeneration = 0;
  final _activeBridges = <BridgeSession>[];
  final _frameRouters = <String, void Function(Map<String, dynamic>)>{};
  final _pendingBridgePayloads = <String, List<Map<String, dynamic>>>{};

  /// bridge-degraded (e.g. `rpc-transport-fault`): the desktop stopped the
  /// bridge transport. Mark it degraded and kick off the retrying recovery
  /// loop (mirrors the web client's recovery path) so it never stays stuck.
  Future<void> _handleBridgeDegraded(Map<String, dynamic> payload) async {
    final bridgeSessionId = payload['bridgeSessionId'] as String?;
    final reason = payload['reason'] as String?;
    final terminalOwner = isTerminalOwnerDegradeReason(reason);
    _log('[bridge] degraded: $bridgeSessionId reason=$reason');
    var found = false;
    for (final session in _activeBridges) {
      if (session.bridge['bridgeSessionId'] == bridgeSessionId) {
        // terminal-owner-ended/source-session-replaced：桌面已把该桥交给
        // 别的终端（另一台手机/另一个页面）——人话提示 + 慢档恢复；
        // 其余 reason（rpc-transport-fault 等）维持快档自愈。
        if (terminalOwner) {
          _slowRecoveryBridges.add(session);
        } else {
          _slowRecoveryBridges.remove(session);
        }
        session.degraded.value = terminalOwner
            ? terminalOwnerDegradedMessage
            : (reason ?? 'unknown');
        found = true;
      }
    }
    if (found) _recoverActiveBridges();
  }

  /// workspace-bridge-open -> workspace-bridge-ready, then builds the
  /// rpc-frame transport + IPC channel client for the workspace.
  ///
  /// [project]：project intent（{projectId, hostId?}）——桌面
  /// 现场准备该项目工作区，不受"workspaceKey 必须在当前窗口 tabs"限制
  /// （官方 zod：project 与 taskId/fileTreeTaskId 互斥，这里一并防护）。
  /// [taskId]+[taskHostId]：任务 intent（官方手机壳打开侧栏任务的路径，
  /// validation.ts:921-933——桌面经 resolveSessionDirectories 解析任意任务
  /// 的执行目录，未归类任务同样可达）。官方 web 同款语义：request 的
  /// workspaceKey 为占位值，真实 target 由桌面解析后随 ready 桥返回。
  Future<BridgeSession> openBridge(
    String workspaceKey, {
    String? taskId,
    String? taskHostId,
    Map<String, dynamic>? project,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (project != null && (taskId != null || taskHostId != null)) {
      throw ArgumentError('project intent 与 taskId/taskHostId 互斥（官方 zod 校验）');
    }
    if (taskHostId != null && taskId == null) {
      throw ArgumentError('taskHostId 必须与 taskId 同现（官方 zod 校验）');
    }
    final bridgeSessionId = _reqId('bridge');
    final generation = ++_bridgeGeneration;
    final requestId = _reqId('workspace-bridge');
    Map<String, dynamic> res;
    try {
      res = await request(
        {
          'zcode_type': 'workspace-bridge-open',
          'requestId': requestId,
          'bridgeSessionId': bridgeSessionId,
          'bridgeGeneration': generation,
          'workspaceKey': workspaceKey,
          'taskId': ?taskId,
          'taskHostId': ?taskHostId,
          'project': ?project,
        },
        (p) =>
            (p['zcode_type'] == 'workspace-bridge-ready' ||
                p['zcode_type'] == 'workspace-bridge-error') &&
            p['bridgeSessionId'] == bridgeSessionId,
        timeout: timeout,
      );
    } catch (e) {
      // open 失败（超时/error）后该
      // bridgeSessionId 永不注册——已缓冲的待定帧成孤儿，随即清退。
      _pendingBridgePayloads.remove(bridgeSessionId);
      rethrow;
    }
    if (res['zcode_type'] == 'workspace-bridge-error') {
      throw StateError('workspace-bridge-error: ${res['error'] ?? res}');
    }
    final bridge =
        (res['bridge'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    _log('[bridge] ready: $bridge');

    final session = BridgeSession._(
      bridge: bridge,
      projectIntent: project,
      taskIntent: (taskId != null && taskHostId != null)
          ? {'taskId': taskId, 'taskHostId': taskHostId}
          : null,
      onDispose: (s) {
        _activeBridges.remove(s);
        _slowRecoveryBridges.remove(s);
        final id = s.bridge['bridgeSessionId'];
        _frameRouters.remove(id);
        // 销桥时同步清退该 id 的待定帧缓冲。
        if (id != null) _pendingBridgePayloads.remove(id);
      },
    );
    _attachStack(session, bridgeSessionId, bridge);
    _activeBridges.add(session);

    await sendMobileViewState(
      workspaceKey: (bridge['workspaceKey'] as String?) ?? workspaceKey,
      taskId: (bridge['initialTaskId'] as String?) ?? taskId,
    );
    return session;
  }

  /// Builds the rpc-frame transport + IPC channel stack for a bridge and
  /// attaches it to [session] (fresh or swapped-in after a reopen).
  void _attachStack(
    BridgeSession session,
    String requestedBridgeSessionId,
    Map<String, dynamic> bridge,
  ) {
    session._transport.dispose();
    // 旧 ChannelClient 一并收口——dispose 现在
    // 会立即失败在途 call（gap 同款语义），换桥后调用方重试链走新桥，
    // 不再各自干等 30-120s timeout。
    session._channels.dispose();
    final transport = RpcFrameTransport(
      bridgeSessionId:
          (bridge['bridgeSessionId'] as String?) ?? requestedBridgeSessionId,
      bridgeGeneration: (bridge['bridgeGeneration'] as num?)?.toInt(),
      recoveryId: bridge['recoveryId'] as String?,
      sendPayload: relay.sendPayload,
      onLog: onLog,
    );
    // Over the workspace bridge each rpc-frame message IS one ChannelClient
    // body (value-stream) — no 13-byte IPC framing on this path.
    final channels = ChannelClient(
      sendBody: transport.sendMessage,
      onLog: onLog,
    );
    transport.messages.listen(channels.handleMessage);
    // 病②：物理丢帧 → 立即失败在途 RPC（响应可能已丢，秒级重试）。
    transport.onGapDetected = channels.failPendingOnGap;
    // 旧 bridgeSessionId 必须在 _swap 之前读——swap
    // 后 session._bridge 已是新桥，oldId 恒等于新 id，remove 永不生效
    // （每代桥泄漏一个 router 条目，且迟到旧帧会打进已 dispose 的旧
    // transport）。
    final oldId = session._bridge['bridgeSessionId'];
    session._swap(bridge, transport, channels);

    // Register at the single dispatch point and flush any frames that
    // arrived before the transport existed (Initialize race).
    final id = transport.bridgeSessionId;
    if (oldId != null && oldId != id) {
      _frameRouters.remove(oldId);
      // 旧桥 id 的待定帧随换代清退。
      _pendingBridgePayloads.remove(oldId);
    }
    _frameRouters[id] = transport.acceptPayload;
    final pending = _pendingBridgePayloads.remove(id);
    if (pending != null) {
      for (final payload in pending) {
        transport.acceptPayload(payload);
      }
    }
  }

  /// Reopens a degraded/dead bridge: new `workspace-bridge-open` (fresh
  /// bridgeSessionId, bumped generation, carries recoveryId), then swaps
  /// the stack into the existing [BridgeSession].
  ///
  /// project intent：随 session 携带重发——project 桥的工作区
  /// 可能不在桌面当前 tabs 里，纯 workspaceKey 重开会被拒
  /// （"目标工作区不在当前桌面窗口中"）。
  Future<void> _reopenBridge(BridgeSession session, String workspaceKey) async {
    final oldBridge = session.bridge;
    final bridgeSessionId = _reqId('bridge');
    final generation = ++_bridgeGeneration;
    final requestId = _reqId('workspace-bridge');
    _log('[bridge] reopen $workspaceKey (gen $generation)');
    final res = await request(
      {
        'zcode_type': 'workspace-bridge-open',
        'requestId': requestId,
        'bridgeSessionId': bridgeSessionId,
        'bridgeGeneration': generation,
        if (oldBridge['recoveryId'] != null)
          'recoveryId': oldBridge['recoveryId'],
        'workspaceKey': workspaceKey,
        if (session.projectIntent != null)
          'project': session.projectIntent,
        if (session.taskIntent != null) ...session.taskIntent!,
      },
      (p) =>
          (p['zcode_type'] == 'workspace-bridge-ready' ||
              p['zcode_type'] == 'workspace-bridge-error') &&
          p['bridgeSessionId'] == bridgeSessionId,
    );
    if (res['zcode_type'] == 'workspace-bridge-error') {
      throw StateError('workspace-bridge-error: ${res['error'] ?? res}');
    }
    final bridge =
        (res['bridge'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    noteProtocolDrift('bridge-reopen', bridge, ['bridgeSessionId', 'workspaceKey'],
        onLog: _log);
    _attachStack(session, bridgeSessionId, bridge);
    _log('[bridge] reopened: $bridge');
  }

  /// mobile-view-state-update（对齐官方 updateMobileViewState，
  /// packages/web/src/main.tsx:1903；zod 校验 packages/shared/src/validation.ts:172-202）。
  Future<void> sendMobileViewState({
    required String workspaceKey,
    String? taskId,
  }) async {
    relay.sendPayload({
      'zcode_type': 'mobile-view-state-update',
      'viewState': {
        'activeWorkspaceKey': workspaceKey,
        // official zod: activeTaskId 为 nonEmptyString——空串/null 会整条判 invalid 丢弃
        if (taskId != null && taskId.isNotEmpty) 'activeTaskId': taskId,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
        'deviceInfo': {
          'platform': companionPlatformName(),
          // 缺省版本不得用字面量 'web' 冒充
          //（桌面端"已连接客户端"展示）——统一兜底 'unknown'。
          'version': _appVersion ?? 'unknown',
          'name': companionAppName,
        // 修复（2026-10-16）：官方 deviceInfo 四必填（platform/version/
        // name/updatedAt，z.number().finite()）——此前漏 updatedAt，整条
        // 载荷被桌面端 parseWebRemoteControlAppPayload 判 invalid 丢弃。
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
    });
  }

  /// workspace-reconnect-request.
  Future<Map<String, dynamic>> reconnectWorkspace(String workspaceKey) async {
    final id = _reqId('workspace-reconnect');
    return request(
      {
        'zcode_type': 'workspace-reconnect-request',
        'requestId': id,
        'workspaceKey': workspaceKey,
      },
      (p) =>
          p['zcode_type'] == 'workspace-reconnect-response' &&
          p['requestId'] == id &&
          p['workspaceKey'] == workspaceKey,
    );
  }

  void pokeRelay() => relay.poke();

  /// 后台自适应心跳（电量专项）：转发到中继连接层。
  void setRelayBackgroundHeartbeat(bool enabled) =>
      relay.setBackgroundHeartbeat(enabled);

  /// 完全静默档（电量优化批 #17）：转发到中继连接层。
  void setRelaySilent(bool silent) => relay.setRelaySilent(silent);

  Future<void> dispose() async {
    relay.stateListenable.removeListener(_onRelayState);
    await _payloadSub?.cancel();
    for (final s in List<BridgeSession>.from(_activeBridges)) {
      s.dispose();
    }
    await relay.dispose();
    await _workspaceListUpdatedController.close();
  }
}

class BridgeSession {
  Map<String, dynamic> _bridge;
  RpcFrameTransport _transport;
  ChannelClient _channels;
  final void Function(BridgeSession) _onDispose;
  bool _disposed = false;

  /// project intent：null=普通 workspaceKey 桥；非 null=项目桥，
  /// 重开时随新 bridge-open 重发（见 _reopenBridge 注释）。
  final Map<String, dynamic>? projectIntent;

  /// 任务 intent（taskId+taskHostId， v1.1）：重开时随新
  /// bridge-open 重发（同 project intent 理由——任务目录可能不在 tabs）。
  final Map<String, dynamic>? taskIntent;

  /// Non-null while the bridge is degraded (rpc-transport-fault etc.).
  final ValueNotifier<String?> degraded = ValueNotifier(null);

  /// Bumped when the bridge recovers/reopens — subscriptions must
  /// resubscribe (server-side subscription state died with the old bridge).
  final ValueNotifier<int> recovered = ValueNotifier(0);

  /// Resolves once the bridge is healthy again (degraded cleared), or throws
  /// [TimeoutException]. Commands gate on this so a send during a
  /// reconnect/recovery window doesn't hang on a dead bridge.
  Future<void> waitHealthy({Duration timeout = const Duration(seconds: 45)}) {
    if (_disposed || degraded.value == null) return Future.value();
    final completer = Completer<void>();
    void check() {
      if (degraded.value == null && !completer.isCompleted) {
        completer.complete();
      }
    }

    degraded.addListener(check);
    check();
    return completer.future
        .timeout(
          timeout,
          onTimeout: () {
            degraded.removeListener(check);
            throw TimeoutException('bridge 恢复超时: ${degraded.value}');
          },
        )
        .whenComplete(() => degraded.removeListener(check));
  }

  BridgeSession._({
    required Map<String, dynamic> bridge,
    required this.projectIntent,
    required this.taskIntent,
    required void Function(BridgeSession) onDispose,
  }) : _bridge = bridge,
       _transport = _placeholderTransport(bridge),
       _channels = ChannelClient(sendBody: (_) {}),
       _onDispose = onDispose;

  static RpcFrameTransport _placeholderTransport(Map<String, dynamic> bridge) =>
      RpcFrameTransport(
        bridgeSessionId: '${bridge['bridgeSessionId'] ?? ''}',
        sendPayload: (_) {},
      );

  Map<String, dynamic> get bridge => _bridge;
  RpcFrameTransport get transport => _transport;
  ChannelClient get channels => _channels;

  void _swap(
    Map<String, dynamic> bridge,
    RpcFrameTransport transport,
    ChannelClient channels,
  ) {
    _bridge = bridge;
    _transport = transport;
    _channels = channels;
  }

  String? get workspaceKey => _bridge['workspaceKey'] as String?;
  String? get initialTaskId => _bridge['initialTaskId'] as String?;

  /// The web client performs the conversation handshake ONCE per service
  /// (cached via `wD`). The transport is keyed by scope and cleared on
  /// stack swap so the new bridge handshakes again.
  final Map<String, ConversationTransport> _conversations = {};

  ConversationTransport conversation(
    Map<String, dynamic> scope, {
    void Function(String line)? onLog,
  }) {
    final key = '${scope['workspaceIdentity'] ?? scope['workspacePath']}';
    return _conversations.putIfAbsent(
      key,
      () => ConversationTransport(session: this, scope: scope, onLog: onLog),
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    degraded.dispose();
    recovered.dispose();
    _transport.dispose();
    // ChannelClient 收口——在途 call 立即失败
    //（gap 同款语义），不干等各自 timeout。
    _channels.dispose();
    _onDispose(this);
  }
}

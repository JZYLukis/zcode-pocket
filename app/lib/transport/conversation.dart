import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'channel_client.dart';
import 'protocol_drift.dart';
import 'id.dart';
import 'companion_client.dart';
import 'rpc_frame_transport.dart' show RpcFrameTransport;

/// Conversation V4 protocol over the `zcode-agent` channel.
const conversationProtocolAppVersion = '3.6.5';

///
/// Flow (mirrors `sk()`/`uk()` in the web client):
/// 1. `helloConversationV4()` + `initializeConversationV4(clientHello)`
/// 2. `subscribeConversationV4(scope + sessionId)` -> ack.subscriptionId
/// 3. frames pushed via dynamic event `onDynamicConversationFrame(scope)`:
///    wire frames `{wireVersion:3, kind:'complete'|'fragment', topic,
///    subscriptionId, frame | fragment*}`; complete frames carry
///    `{topic, subscriptionId, fromSeq, toSeq, sentAt, payload}` where payload
///    is `{kind:'snapshot', snapshot}` or `{kind:'deltas', deltas}`.
/// 4. commands via `sendConversationCommandV4(scope + envelope)` with
///    envelope `{commandId, clientId, sessionId, type, payload, issuedAt}`.
/// CAS 命令重试决策（纯函数，官方 sendHostCasCommandV4 收敛语义，refs
/// zcodeV4HostCommand.ts:132-166）：ACK 为 stale 且带 revisionAtDecision、
/// 且未到尝试上限（4）→ 返回服务端最新 revision 供下次重试；其余
/// （accepted/duplicate/noop/rejected/failed、缺 revision 字段、超限）
/// → null 停止。
int? nextCasRetryRevision(
  dynamic ack, {
  required int attempts,
  int maxAttempts = 4,
}) {
  if (attempts >= maxAttempts) return null;
  if (ack is! Map || ack['status'] != 'stale') return null;
  final rev = ack['revisionAtDecision'];
  return rev is num ? rev.toInt() : null;
}

/// sendConversationCommandV4 的 params 第一参数组装。[projectId] 与
/// scope/envelope 平级放 params 顶层（官方 agentConversationTransport
/// .ts:371 的 {...workspace, ...context, envelope} 同构）——绝不能进
/// envelope payload（v4 信封 schema 无此字段，host 只认 params 顶层，
/// zcodeAgent.ts:498-504）。缺省不带键（官方语义 null=桌面「任务」区）。
Map<String, dynamic> commandParams(
  Map<String, dynamic> scope,
  Map<String, dynamic> envelope,
  String? projectId,
) {
  final out = <String, dynamic>{...scope, 'envelope': envelope};
  if (projectId != null) out['projectId'] = projectId;
  return out;
}

class ConversationTransport {
  static const channel = Channels.zcodeAgent;

  final BridgeSession session;
  final Map<String, dynamic> scope;
  final String appVersion;
  final void Function(String line)? onLog;

  final String clientId = generateUuid();
  bool _handshaken = false;
  Future<void>? _handshakeFuture;

  /// From the server hello — required for attachment uploads.
  String? connectionId;

  ConversationTransport({
    required this.session,
    required this.scope,
    // This is the desktop Conversation protocol capability version, not the
    // Zemote release version. Sending 0.x here can disable V4 capabilities
    // such as sessions-index during server negotiation.
    this.appVersion = conversationProtocolAppVersion,
    this.onLog,
  }) {
    // A reopened bridge has no handshake state — start over (mirrors the
    // web client's `wD` cache being per service instance).
    session.recovered.addListener(_onBridgeRecovered);
    // degraded 即作废握手状态：抖动窗口内的 handshake() 不得沿用旧通道
    // 缓存的"已握手"结论（真机 2026-10-15 会话订阅挂起根因之一）。
    session.degraded.addListener(_onBridgeDegraded);
  }

  void _onBridgeDegraded() {
    if (session.degraded.value != null) {
      _handshaken = false;
      _handshakeFuture = null;
    }
  }

  void _onBridgeRecovered() {
    _handshaken = false;
    _handshakeFuture = null;
    connectionId = null;
    _prep = null;
  }

  ChannelClient get _channels => session.channels;

  void _log(String line) => onLog?.call(line);

  Future<void> handshake() {
    if (_handshaken) return Future.value();
    return _handshakeFuture ??=
        () async {
          _log('[v4] handshake begin');
          final hello = await _channels.call(
            channel,
            'helloConversationV4',
            [],
          );
          _log('[v4] hello: $hello');
          if (hello is Map) {
            connectionId = hello['connectionId'] as String?;
          }
          await _channels.call(channel, 'initializeConversationV4', [
            {
              'kind': 'clientHello',
              'protocolVersion': 3,
              'clientId': clientId,
              'clientKind': 'mobileApp',
              'appVersion': appVersion,
            },
          ]);
          _handshaken = true;
          _log('[v4] handshake done');
        }().catchError((e) {
          _handshakeFuture = null;
          _log('[v4] handshake failed: $e');
          throw e;
        });
  }

  Future<ConversationSubscription> subscribe(
    String sessionId, {
    ConversationSeed? seed,
  }) async {
    // 开源审查批B组2（G1 P2-1 场景 1）：subscribe 发起=前台信号——清除
    // 驻留态标志（后台无 UI 不会发起新订阅；在飞跨入后台的注册由下方
    // 落地检查拒绝）。
    _parkedForBackground = false;
    // 抖动环境闭环（真机 2026-10-15 定位）：闸门通过后桥再断，订阅 call
    // 落到垂死通道挂死，且未注册的订阅不享受恢复自动重订阅——必须整体
    // 带超时重试，直至在某个健康窗口内完成 gate→handshake→subscribe→ack。
    // 开源审查批D组1（G1 P3-1/G2 P2-2）：waitHealthy/handshake 原在 try
    // 之外——闸门通过后、握手窗口内桥恰降级即一次性穿透整个循环（一次
    // 重试都没发生），与注释承诺的"整体重试"矛盾；移入 try 计入 attempt。
    for (var attempt = 1; attempt <= 5; attempt++) {
      ConversationSubscription? subscription;
      try {
        _log('[v4] subscribe($sessionId) attempt $attempt: waitHealthy');
        await session.waitHealthy(timeout: const Duration(seconds: 45));
        _log('[v4] subscribe($sessionId) attempt $attempt: handshake');
        await handshake();
        _log('[v4] subscribe($sessionId) attempt $attempt: _start');
        subscription = ConversationSubscription._(this, sessionId, seed: seed);
        // F6/R5：外层超时必须 ≥ 内层 RPC 的 120s 宽限——30s 超时会 dispose
        // 当前 attempt 但其 RPC 在服务端继续，attempt 2 的订阅会被 attempt 1
        // 的迟到 ACK 以同 ownershipKey 静默驱逐，之后帧全被 subId 过滤丢弃
        // （真机"永久运行中"的 P1b 竞态，官方 v4ResyncNotOwnedEvictionRace）。
        // 240s 覆盖 _start 内部最坏路径 45+60+120=225s（开源审查 G1 P2-3：
        // 旧值 150s 恰好切在内部 subscribe RPC 半途，可复现上述驱逐竞态）。
        await subscription._start().timeout(const Duration(seconds: 240));
      } catch (e) {
        await subscription?.dispose();
        if (attempt == 5) rethrow;
        _log('[v4] subscribe attempt $attempt failed ($e), retrying');
        await Future.delayed(const Duration(seconds: 2));
        continue;
      }
      // 开源审查批B组2（G1 P2-1 场景 1/G3 对称变体）：订阅在飞期间进入
      // 后台驻留（park 扫描时它尚未登记，`_start` 的对象级 `_parked` 门
      // 够不到它）——落地即拒绝：退订刚拿到的 sid 并抛人话错误，交上层
      // 在回前台后重试（对照 registry demote 的 `_closing` 闸门语义；
      // 不得让它以完整活订阅在后台整段收流式帧=电量红线）。
      if (_parkedForBackground) {
        await subscription.dispose();
        throw StateError('后台驻留中，会话订阅暂不可用（请回前台后重试）');
      }
      _subscriptions[sessionId] = subscription;
      return subscription;
    }
    throw StateError('subscribe: unreachable');
  }

  /// transport 级后台驻留态（开源审查批B组2 G1 P2-1 场景 1）：park 扫描
  /// 只含已登记订阅，在飞的新 subscribe 落地时由 [subscribe] 的落地检查
  /// 拒绝；下次 subscribe 发起（=前台信号）清除。
  bool _parkedForBackground = false;

  void _untrackSubscription(String sessionId, _SubscriptionBase sub) {
    // 开源审查 G1-P3-9：按身份移除——上游（registry 的 pending 去重）使
    // 误删不可达，但任何新的 subscribe 直调点都可能踩"旧订阅迟到 dispose
    // 删掉新订阅登记"的雷。
    if (identical(_subscriptions[sessionId], sub)) {
      _subscriptions.remove(sessionId);
    }
    // 开源审查 G1-P3-8/G2-P3-11：CAS 水位缓存随订阅终结清理（重建订阅后
    // 首条 CAS 命令回退订阅快照水位——快照本就是服务端权威值）。
    // _lastCommandIdBySession 刻意不清：A3「结果未知→重新核对」需要跨
    // 订阅代际查询（页面重进=旧订阅 dispose、新订阅落地，清了就查无可
    // 查），与 transport 同生命周期，量级=触及过的会话数×几十字节。
    _ackedRevisions.remove(sessionId);
  }

  /// 优化批 #16（电量专项，2026-10-31）：后台驻留全部会话明细订阅——
  /// 协议层退订（桌面停止推流式帧，无线电休眠；真机 logcat/dumpsys 实证
  /// 保活分支下持续推帧是后台耗电主因，docs/battery-measure.md 2026-10-30
  /// 节），保留订阅对象与状态：打开中的会话页持有的引用与状态监听继续
  /// 有效。回前台 [resumeParkedConversation] 按当前水位增量续订（服务端
  /// 只补 delta）。si/tasks-index 订阅不经此路径（通知数据源）。
  Future<void> parkConversationSubscriptionsForBackground() async {
    _parkedForBackground = true;
    for (final sub in _subscriptions.values.toList()) {
      await sub._parkForBackground();
    }
    // 开源审查批B组2（G1 P2-1/G3 P2-1 对称变体）：上方 toList 快照之后
    // 新完成登记的订阅（subscribe 在飞时退后台——`_subscriptions` 只在
    // 成功后才登记）不在首轮集合，会以完整活订阅（帧监听+服务端订阅+
    // 看门狗）在后台整段收流式帧（电量红线）。补扫一轮收口（幂等：
    // 已驻留的直接返回）；订阅对象内部的在飞竞态由 `_start` 的
    // `_parked` 门兜底。
    for (final sub in _subscriptions.values.toList()) {
      await sub._parkForBackground();
    }
  }

  /// 驻留订阅恢复（增量续订）。返回是否确有驻留订阅被触发恢复——
  /// 无该会话订阅或不在驻留态返回 false（幂等，非驻留态调用零副作用）。
  Future<bool> resumeParkedConversation(String sessionId) async {
    final sub = _subscriptions[sessionId];
    if (sub == null || !sub._parked) return false;
    await sub._resumeFromPark();
    return true;
  }

  /// Commands that require `baseRevision` (CAS; the web client behaves the same) and row-target
  /// commands that also require `baseLogEpoch`.
  static const _casCommands = {
    'applyFileRewind',
    'forkAssistant',
    'editUserQuery',
    'retryTurn',
    'setAssistantFeedback',
    'sendQueuedNow',
    'editQueueItem',
    'reorderQueueItem',
    'deleteQueueItem',
    'setAutoDrain',
    'switchModelConfig',
    'switchCollaborationMode',
    'setFollowupMode',
    'pauseGoal',
    'resumeGoal',
  };
  static const _rowTargetCommands = {
    'applyFileRewind',
    'forkAssistant',
    'editUserQuery',
    'retryTurn',
    'setAssistantFeedback',
  };

  /// Live subscriptions by sessionId — source of the current
  /// revision/logEpoch for CAS commands.
  final _subscriptions = <String, ConversationSubscription>{};

  /// Highest revision seen from command acks (`revisionAtDecision`) —
  /// acks land before the follow-up `state.updated` frame, and the next
  /// CAS command must not go stale.
  final _ackedRevisions = <String, int>{};

  /// [projectId] 仅 createSession 使用：与 workspacePath 平级放进 RPC
  /// params 第一参数（官方 agentConversationTransport.ts:371 的
  /// `{...workspace, ...context, envelope}` 同构）。host 端
  /// reserveCreatedTask 按 `params.projectId ?? null` 写 tasks 表归属，
  /// 缺省即落桌面「任务」默认区——project intent 桥下必带。
  Future<dynamic> sendCommand(
    String? sessionId,
    String type,
    Map<String, dynamic> payload, {
    Duration timeout = const Duration(seconds: 30),
    String? projectId,
    String? replayCommandId,
  }) async {
    await handshake();
    // Gate on a healthy bridge: during a relay drop/recovery the old bridge
    // is dead and requests would otherwise hang until timeout. Once the
    // bridge recovers, the send goes through on the fresh transport.
    await session.waitHealthy(timeout: const Duration(seconds: 45));
    final sub = sessionId == null ? null : _subscriptions[sessionId];
    final baseRevision = sessionId == null
        ? null
        : [
            sub?.state.revision ?? 0,
            _ackedRevisions[sessionId] ?? 0,
          ].reduce((a, b) => a > b ? a : b);
    // M2（审计）：行级命令信封的 baseLogEpoch 必填——订阅未就绪时发出去
    // 必被 proto.invalidPayload 拒，本地提前失败给用户可见错误。
    if (_rowTargetCommands.contains(type) && sub?.state.logEpoch == null) {
      throw StateError('会话状态未就绪（缺 baseLogEpoch），请稍后重试');
    }
    final envelope = {
      // review-fix-1（队列双发组）：replayCommandId=离线队列重放沿用
      // 首次 ID（崩溃窗口重试不双投递）；缺省正常生成。
      'commandId': replayCommandId ?? generateUuid(),
      'clientId': clientId,
      'sessionId': sessionId,
      if (_casCommands.contains(type)) 'baseRevision': baseRevision,
      if (_rowTargetCommands.contains(type))
        'baseLogEpoch': sub!.state.logEpoch,
      'type': type,
      'payload': payload,
      'issuedAt': DateTime.now().millisecondsSinceEpoch,
    };
    _log('[v4] command $type');
    // A3：记录最后发出的命令 id（"结果未知"回捞确权用，进程内）。
    // review-fix-1（协议组）：只记用户发送族（sendText/createSession）——
    // 此前 compact/resolveInteraction/snooze 等一切命令都覆盖此表，
    // 回捞可能查到 compact 的 accepted 就误判"发送已送达"并清稿
    // （审查 D1a/D1b 双向确认的假阳性）。
    // 开源审查批B组2（G1 P2-2/G2 P2-5）：createSession 信封的 sessionId
    // 恒 null（协议要求）——旧实现 `cmdKey != null` 对它恒假，新会话
    // 首条消息超时后无「重新核对」可查。先按假键落位，createSession
    // accepted 后迁到 result.sessionId（见 [_pendingCreateSessionKey]）。
    final cmdKey = sessionId ??
        (type == 'createSession' ? _pendingCreateSessionKey : null);
    if (cmdKey != null &&
        (type == 'sendText' || type == 'createSession')) {
      _lastCommandIdBySession[cmdKey] = '${envelope['commandId']}';
    }
    var res = await _sendCommandWithRetry(
      envelope,
      timeout,
      projectId: projectId,
    );
    if (res is Map && res['status'] != null && res['status'] != 'accepted') {
      _log(
        '[v4] command $type -> ${res['status']} '
        '${res['reasonCode'] ?? ''} ${res['message'] ?? ''}',
      );
    }
    // CAS 收敛重试（官方 sendHostCasCommandV4 同款，refs
    // zcodeV4HostCommand.ts:132-166，上限 4 次）：运行中会话 revision 随
    // 流式行持续推进，旧实现"单次重试"在运行中必然追不上——真机
    // switchCollaborationMode 7 连拒的根因。stale ACK 的
    // revisionAtDecision 是裁决时点的服务端最新值，换新 commandId 重试
    // 即收敛（典型 1-2 次）；stale 裁决不进幂等表，重提语义等价。
    var casAttempts = 1;
    while (sessionId != null) {
      final next = nextCasRetryRevision(res, attempts: casAttempts);
      if (next == null) break;
      casAttempts++;
      _log('[v4] command $type stale, retry #$casAttempts at rev $next');
      if (next > (_ackedRevisions[sessionId] ?? 0)) {
        _ackedRevisions[sessionId] = next;
      }
      res = await _sendCommandWithRetry(
        {
          ...envelope,
          'commandId': generateUuid(),
          'baseRevision': next,
          'issuedAt': DateTime.now().millisecondsSinceEpoch,
        },
        timeout,
        projectId: projectId,
      );
    }
    if (sessionId != null && res is Map && res['revisionAtDecision'] is num) {
      final rev = (res['revisionAtDecision'] as num).toInt();
      final status = res['status'];
      // revisionAtDecision is the base at decision time; an accepted
      // command bumps the revision by one, so the next CAS base is +1.
      final floor =
          (status == 'accepted' || status == 'noop' || status == 'duplicate')
          ? rev + 1
          : rev;
      if (floor > (_ackedRevisions[sessionId] ?? 0)) {
        _ackedRevisions[sessionId] = floor;
      }
    }
    return res;
  }

  /// A3（parity-fix-1，官方 zcodeTaskServiceAdapter.ts:2065-2078 对位）：
  /// ACK 丢失时查询同一命令的确权接口。result=ack Map（权威结论）或
  /// 'unknown'（查不到）。查询失败抛原错误由调用方兜底。
  Future<dynamic> queryConversationCommand({
    required String commandId,
    String? sessionId,
  }) async {
    await handshake();
    final res = await _channels.call(
      channel,
      'queryConversationCommandsV4',
      [
        {
          // review-fix-1（A1）：官方 host 层 ZCodeAgentCommandsQueryParams
          // extends ZCodeAgentWorkspaceTarget，经 resolveWorkspaceKey 路由
          // ——缺 workspacePath 时真机必败（对照官方 zcodeTaskServiceAdapter
          // 的 {...workspace, commands} 展开形状）。
          ...scope,
          'commands': [
            {'sessionId': sessionId, 'commandId': commandId},
          ],
        },
      ],
      timeout: const Duration(seconds: 15),
    );
    if (res is! Map) return null;
    final results = res['results'];
    if (results is! List || results.isEmpty) return null;
    final first = results.first;
    return first is Map ? first['result'] : null;
  }

  /// A3：本进程内每会话最后一条已发出命令（重启后丢失——完整 24h 对账
  /// 账本属官方 pendingCommandRegistry，手机侧最小版）。
  final Map<String, String> _lastCommandIdBySession = {};

  /// createSession 在拿到新 sessionId 前的 A3 记录假键（开源审查批B组2
  /// G1 P2-2/G2 P2-5：信封 sessionId 恒 null，先按此键落位、accepted 后
  /// 由 createSession 迁到真实会话键——新会话首条消息超时同样有
  /// 「重新核对」可查）。
  static const _pendingCreateSessionKey = '__pendingCreateSession__';
  String? lastCommandIdOf(String? sessionId) => sessionId == null
      ? null
      : _lastCommandIdBySession[sessionId];

  /// Sends one command envelope; on timeout (likely a relay drop mid-flight)
  /// waits for bridge recovery and retries once with a fresh commandId.
  Future<dynamic> _sendCommandWithRetry(
    Map<String, dynamic> envelope,
    Duration timeout, {
    String? projectId,
  }) async {
    try {
      return await _channels.call(channel, 'sendConversationCommandV4', [
        commandParams(scope, envelope, projectId),
      ], timeout: timeout);
    } on TimeoutException {
      // Retry only when the relay dropped mid-flight (bridge degraded): the
      // command then never reached the server. If the bridge is still
      // healthy, rethrow — a retry would double-deliver (e.g. sendText).
      if (session.degraded.value == null) rethrow;
      _log(
        '[v4] command timed out during drop, waiting for recovery and '
        'retrying',
      );
      await session.waitHealthy(timeout: const Duration(seconds: 45));
      // A1（parity-fix-1，2026-10-29 审查）：重发必须保持同一 commandId
      // ——官方 command.ts:345 明文"重试不变更 ID，ACK 丢失应查询同一
      // 命令"。桥降级只保证"很可能没到达"，不能保证没到达：换新 ID
      // 重发=首次已落库时二次投递；同 ID 重发由服务端幂等去重兜住。
      try {
        return await _channels.call(channel, 'sendConversationCommandV4', [
          commandParams(scope, envelope, projectId),
        ], timeout: timeout);
      } catch (e) {
        // A3：同 ID 重发也失败——查权收敛（官方"查询同一命令，不能生成
        // 新 ID 重发输入"）：查到权威 ack 直接采用；unknown/查询失败才
        // 抛回（上层走"结果未知"呈现）。
        final commandId = '${envelope['commandId'] ?? ''}';
        if (commandId.isEmpty) rethrow;
        try {
          final result = await queryConversationCommand(
            commandId: commandId,
            sessionId: envelope['sessionId'] as String?,
          );
          if (result is Map) {
            _log('[v4] command converged by query: '
                '${result['status']} ($commandId)');
            return result;
          }
        } catch (_) {
          // 查询通道也不可用：维持原错误。
        }
        rethrow;
      }
    }
  }

  /// Creates a new session (mirrors the composer's first-send path):
  /// command `createSession` with `{workspaceId, firstInput:{text}}` and a
  /// null envelope sessionId. Returns the new sessionId on `accepted`.
  /// [projectId] 归属项目（RPC params 上下文字段，非 envelope payload）：
  /// host 端 reserveCreatedTask 据此写 tasks.project_id，null=桌面「任务」
  /// 默认区（zcodeAgent.ts:498-504 + node.ts:2217-2224）。
  Future<String> createSession(
    String workspaceId, {
    String? firstText,
    List<Map<String, dynamic>>? attachments,
    Map<String, dynamic>? config,
    String? runtimeModel,
    List<String>? mcpServers,
    String? projectId,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final res = await sendCommand(
      null,
      'createSession',
      {
        'workspaceId': workspaceId,
        if (firstText != null)
          'firstInput': {
            'text': firstText,
            if (attachments != null && attachments.isNotEmpty)
              'attachments': attachments,
          },
        if (config != null) 'config': config,
        if (runtimeModel != null) 'runtimeModel': runtimeModel,
        if (mcpServers != null && mcpServers.isNotEmpty)
          'mcpServers': mcpServers,
      },
      timeout: timeout,
      projectId: projectId,
    );
    final map = res is Map ? res.cast<String, dynamic>() : null;
    final status = map?['status'];
    if (status != 'accepted') {
      throw StateError(
        'createSession rejected: ${map?['reasonCode'] ?? status} ${map?['message'] ?? ''}',
      );
    }
    final result = map?['result'];
    final sessionId = result is Map ? result['sessionId'] : null;
    if (sessionId is! String || sessionId.isEmpty) {
      throw StateError('createSession: missing sessionId in result');
    }
    // A3 转正（开源审查批B组2 G1 P2-2/G2 P2-5）：createSession 的命令
    // id 已按假键记录（见 sendCommand），迁到新会话键——首条消息超时后
    // 「结果未知→重新核对」按 sessionId 可查。
    final pendingCmdId = _lastCommandIdBySession.remove(
      _pendingCreateSessionKey,
    );
    if (pendingCmdId != null) {
      _lastCommandIdBySession[sessionId] = pendingCmdId;
    }
    return sessionId;
  }

  /// Creates a selection-side (auxiliary) chat attached to [parentSessionId]
  /// (command `createSelectionSideSession` with an empty payload, mirrors
  /// the web client's "ask in side chat" flow). Returns the new sessionId.
  Future<String> createSelectionSideSession(
    String parentSessionId, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final res = await sendCommand(
      parentSessionId,
      'createSelectionSideSession',
      {},
      timeout: timeout,
    );
    final map = res is Map ? res.cast<String, dynamic>() : null;
    final status = map?['status'];
    if (status != 'accepted' && status != 'duplicate') {
      throw StateError(
        'createSelectionSideSession rejected: ${map?['reasonCode'] ?? status} ${map?['message'] ?? ''}',
      );
    }
    final result = map?['result'];
    final sessionId = result is Map ? result['sessionId'] : null;
    if (sessionId is! String || sessionId.isEmpty) {
      throw StateError(
        'createSelectionSideSession: missing sessionId in result',
      );
    }
    return sessionId;
  }

  /// 工作流 run 目录（v4/conversation/workflowRuns：只读无状态超时重发
  /// 安全；runs[] 五态摘要，最近更新在前）。
  Future<dynamic> workflowRuns(String sessionId, {int? limit}) async {
    await handshake();
    return _channels.call(channel, 'conversationWorkflowRunsV4', [
      {...scope, 'sessionId': sessionId, if (limit != null) 'limit': limit},
    ]);
  }

  /// run 事件日志（workflowRunEvents：journal 分页，afterSequence 严格
  /// 大于；缺省页大小 CLI 侧钳制 ≤500）。
  Future<dynamic> workflowRunEvents(
    String sessionId,
    String runId, {
    int? afterSequence,
    int? limit,
  }) async {
    await handshake();
    return _channels.call(channel, 'conversationWorkflowRunEventsV4', [
      {
        ...scope,
        'sessionId': sessionId,
        'runId': runId,
        if (afterSequence != null) 'afterSequence': afterSequence,
        if (limit != null) 'limit': limit,
      },
    ]);
  }

  /// run 产物清单（workflowRunArtifacts：全量元数据，含 versions/交付物
  /// primary）。
  Future<dynamic> workflowRunArtifacts(String sessionId, String runId) async {
    await handshake();
    return _channels.call(channel, 'conversationWorkflowRunArtifactsV4', [
      {...scope, 'sessionId': sessionId, 'runId': runId},
    ]);
  }

  /// 内容产物字节读取（workflowRunArtifactRead：≤512KiB/块，形状照
  /// attachmentRead——dataBase64/nextOffset）。
  Future<dynamic> workflowRunArtifactRead(
    String sessionId,
    String runId,
    String artifactId, {
    required int version,
    required int offset,
    required int limit,
  }) async {
    await handshake();
    return _channels.call(channel, 'conversationWorkflowRunArtifactReadV4', [
      {
        ...scope,
        'sessionId': sessionId,
        'runId': runId,
        'artifactId': artifactId,
        'version': version,
        'offset': offset,
        'limit': limit,
      },
    ]);
  }

  /// 会话压缩（官方 compact 专用命令信封，command.ts:165-167：payload
  /// 空、idle 立即执行、busy/held 进 FIFO、sourceCommandId 幂等）。
  /// 进度反馈=时间线 compact 标记行（running→正在压缩上下文…）。
  Future<dynamic> sendCompact(String sessionId) =>
      sendCommand(sessionId, 'compact', const {});

  Future<dynamic> sendText(
    String sessionId,
    String text, {
    List<Map<String, dynamic>>? attachments,
    Map<String, dynamic>? modelSelection,
    String? mode,
    bool? planEnabled,
    String? heldQueueDisposition,
    List<String>? expectedHeldQueueItemIds,
    String? automationId,
    String? offPeakTaskId,
    String? offPeakRunType,
    String? botDeliveryTarget,
    List<String>? toolDisallowlist,
    // review-fix-1（队列双发组）：离线队列重放沿用首次尝试的 commandId
    // （服务端幂等去重）；null=正常生成。
    String? replayCommandId,
  }) => sendCommand(sessionId, 'sendText', {
    'text': text,
    if (attachments != null && attachments.isNotEmpty)
      'attachments': attachments,
    // 早期反馈①（官方语义，command.ts:109-112）："第一方用户提交始终
    // 显式携带 modelSelection/mode"——运行中的会话直接发切换命令会被
    // CAS stale 死锁（每秒推进的版本号追不上），选型必须随提交携带。
    if (modelSelection != null) 'modelSelection': modelSelection,
    if (mode != null) 'mode': mode,
    if (planEnabled != null) 'planEnabled': planEnabled,
    if (heldQueueDisposition != null)
      'heldQueueDisposition': heldQueueDisposition,
    if (expectedHeldQueueItemIds != null && expectedHeldQueueItemIds.isNotEmpty)
      'expectedHeldQueueItemIds': expectedHeldQueueItemIds,
    if (automationId != null) 'automationId': automationId,
    if (offPeakTaskId != null) 'offPeakTaskId': offPeakTaskId,
    if (offPeakRunType != null) 'offPeakRunType': offPeakRunType,
    if (botDeliveryTarget != null) 'botDeliveryTarget': botDeliveryTarget,
    if (toolDisallowlist != null && toolDisallowlist.isNotEmpty)
      'toolDisallowlist': toolDisallowlist,
  }, replayCommandId: replayCommandId);

  Future<dynamic> sendGoalCommand(
    String sessionId,
    String text, {
    String? displayText,
    String? heldQueueDisposition,
    List<String>? expectedHeldQueueItemIds,
  }) => sendCommand(sessionId, 'sendGoalCommand', {
    'text': text,
    if (displayText != null) 'displayText': displayText,
    if (heldQueueDisposition != null)
      'heldQueueDisposition': heldQueueDisposition,
    if (expectedHeldQueueItemIds != null && expectedHeldQueueItemIds.isNotEmpty)
      'expectedHeldQueueItemIds': expectedHeldQueueItemIds,
  });

  Future<dynamic> pauseGoal(String sessionId) =>
      sendCommand(sessionId, 'pauseGoal', {});

  Future<dynamic> resumeGoal(String sessionId) =>
      sendCommand(sessionId, 'resumeGoal', {});

  Future<dynamic> stop(String sessionId) => sendCommand(sessionId, 'stop', {});

  /// 旧入口，保留为 [sendCompact] 的转发别名（开源审查 G1-P3-5/G2-P3-8/
  /// G3-P3-3：两个逐字节等价的双入口并存，未来改 compact 语义极易只改
  /// 一处漏一处；调用方 app_state.compact 不在传输层域，收敛为别名零
  /// 行为变化）。
  Future<dynamic> compact(String sessionId) => sendCompact(sessionId);

  /// Switch model config. All of provider/model/thought are required by the
  /// protocol schema — pass current values for the ones not changing.
  /// Thought levels differ per model family (GLM-5.2: max/high/nothink;
  /// Turbo: enabled/off), so on `Unsupported reasoning effort` we retry
  /// with the other family's default.
  Future<dynamic> switchModelConfig(
    String sessionId, {
    required String provider,
    required String model,
    required String thought,
  }) async {
    var res = await sendCommand(sessionId, 'switchModelConfig', {
      'provider': provider,
      'model': model,
      'thought': thought,
    });
    final message = res is Map ? '${res['message'] ?? ''}' : '';
    // 开源审查 G1-P3-6/G3-P3-4：服务端消息一旦本地化/改写措辞，精确串
    // 匹配会静默失效（切换模型失败而无第二次尝试）——放宽为大小写无关。
    if (message.toLowerCase().contains('unsupported reasoning effort')) {
      final fallback = (thought == 'enabled' || thought == 'off')
          ? 'max'
          : 'enabled';
      _log('[v4] switchModelConfig retry with thought=$fallback');
      res = await sendCommand(sessionId, 'switchModelConfig', {
        'provider': provider,
        'model': model,
        'thought': fallback,
      });
    }
    return res;
  }

  /// build / edit / plan / yolo. Mirrors `switchCollaborationMode`.
  Future<dynamic> switchCollaborationMode(String sessionId, String mode) =>
      sendCommand(sessionId, 'switchCollaborationMode', {'mode': mode});

  /// queue / guide followup. Mirrors `setFollowupMode`.
  Future<dynamic> setFollowupMode(String sessionId, String mode) =>
      sendCommand(sessionId, 'setFollowupMode', {'mode': mode});

  /// like / dislike / null on an assistant row. Target is
  /// `{rowId, entityId}` (entityId optional for some row kinds).
  Future<dynamic> setAssistantFeedback(
    String sessionId,
    Map<String, dynamic> target,
    String? feedback,
  ) => sendCommand(sessionId, 'setAssistantFeedback', {
    'target': target,
    'feedback': feedback,
  });

  Future<dynamic> retryTurn(String sessionId, Map<String, dynamic> target) =>
      sendCommand(sessionId, 'retryTurn', {'target': target});

  Future<dynamic> sendQueuedNow(String sessionId, String queueItemId) =>
      sendCommand(sessionId, 'sendQueuedNow', {'queueItemId': queueItemId});

  Future<dynamic> editQueueItem(
    String sessionId,
    String queueItemId,
    String newText,
  ) => sendCommand(sessionId, 'editQueueItem', {
    'queueItemId': queueItemId,
    'newText': newText,
  });

  Future<dynamic> deleteQueueItem(String sessionId, String queueItemId) =>
      sendCommand(sessionId, 'deleteQueueItem', {'queueItemId': queueItemId});

  Future<dynamic> setAutoDrain(String sessionId, bool autoDrain) =>
      sendCommand(sessionId, 'setAutoDrain', {'autoDrain': autoDrain});

  Future<dynamic> forkAssistant(
    String sessionId,
    Map<String, dynamic> target,
  ) => sendCommand(sessionId, 'forkAssistant', {'target': target});

  Future<dynamic> editUserQuery(
    String sessionId,
    Map<String, dynamic> target,
    String newText,
  ) => sendCommand(sessionId, 'editUserQuery', {
    'target': target,
    'newText': newText,
  });

  Future<dynamic> applyFileRewind(
    String sessionId,
    Map<String, dynamic> target,
  ) => sendCommand(sessionId, 'applyFileRewind', {'target': target});

  Future<dynamic> plans(String sessionId) async {
    await handshake();
    return _channels.call(channel, 'conversationPlansV4', [
      {...scope, 'sessionId': sessionId},
    ]);
  }

  /// 会话子代理列表（2026-10-26 批④拍板⑥，官方 zcodeAgentService.
  /// listSessionSubagents 对位——同 zcode-agent 通道的服务方法）。
  /// 返回 {revision, childSessionIds, running[], ended{total, items[],
  /// nextCursor?}}；items 带 childSessionId/title/summary/subagentType/
  /// startedAt/endedAt（ended 另有 status: success|failed|cancelled|lost）。
  Future<Map<String, dynamic>> listSessionSubagents(
    String sessionId, {
    String? endedCursor,
    int endedLimit = 20,
  }) async {
    await handshake();
    final res = await _channels.call(channel, 'listSessionSubagents', [
      {
        ...scope,
        'sessionId': sessionId,
        if (endedCursor != null) 'endedCursor': endedCursor,
        'endedLimit': endedLimit,
      },
    ]);
    return res is Map ? res.cast<String, dynamic>() : const {};
  }

  Future<dynamic> fileChanges(
    String sessionId, {
    required Map<String, dynamic> target,
    int? baseRevision,
    String? baseLogEpoch,
  }) async {
    await handshake();
    // wire schema（transport.ts v4ConversationFileChangesParamsSchema）：
    // baseRevision/baseLogEpoch 必填（官方 UI 每次都带当前投影锚点，zemote
    // 写成可省略是缺陷——真机实测缺参必被服务端拒绝，F10 根因）。
    // 缺省时从当前订阅状态补齐（与官方「读当前投影」语义一致）。
    final (rev, epoch) = _readAnchor(sessionId, baseRevision, baseLogEpoch);
    return _channels.call(channel, 'conversationFileChangesV4', [
      {
        ...scope,
        'sessionId': sessionId,
        'target': target,
        'baseRevision': rev,
        'baseLogEpoch': epoch,
      },
    ]);
  }

  Future<dynamic> fileRewindPreview(
    String sessionId, {
    required Map<String, dynamic> target,
    int? baseRevision,
    String? baseLogEpoch,
  }) async {
    await handshake();
    // 同上：v4ConversationFileRewindPreviewParamsSchema 两锚点必填。
    final (rev, epoch) = _readAnchor(sessionId, baseRevision, baseLogEpoch);
    return _channels.call(channel, 'conversationFileRewindPreviewV4', [
      {
        ...scope,
        'sessionId': sessionId,
        'target': target,
        'baseRevision': rev,
        'baseLogEpoch': epoch,
      },
    ]);
  }

  /// 只读查询的投影锚点：调用方未显式给值时取当前订阅状态的
  /// revision/logEpoch。拿不到（未订阅该会话）时抛错而不是发非法请求。
  (int, String) _readAnchor(
    String sessionId,
    int? baseRevision,
    String? baseLogEpoch,
  ) {
    final sub = _subscriptions[sessionId];
    final rev = baseRevision ?? sub?.state.revision;
    final epoch = baseLogEpoch ?? sub?.state.logEpoch;
    if (rev == null || epoch == null || epoch.isEmpty) {
      throw StateError(
        '缺少只读查询锚点（会话未订阅或状态未就绪）：'
        'baseRevision=$rev baseLogEpoch=$epoch',
      );
    }
    return (rev, epoch);
  }

  // ------------------------------------------------------------ attachments

  static const _attachmentChunkBytes = 384 * 1024;

  /// Uploads an attachment (begin/chunk/commit, same as the web client).
  /// Returns the attachment descriptor `{ref, fileName, mime, bytes}` to be
  /// passed to sendText/createSession.
  Future<Map<String, dynamic>> attachmentPut(
    String sessionId, {
    required String fileName,
    required String mime,
    required Uint8List bytes,
    void Function(double progress)? onProgress,
  }) async {
    await handshake();
    final connId = connectionId;
    if (connId == null) {
      throw StateError('attachmentPut: missing connectionId');
    }
    final uploadId = 'upload-${generateUuid()}';
    final base = {
      'connectionId': connId,
      'uploadId': uploadId,
      'sessionId': sessionId,
    };
    final totalChunks =
        (bytes.length + _attachmentChunkBytes - 1) ~/ _attachmentChunkBytes;
    final checksum = 'sha256:${sha256.convert(bytes).toString()}';

    // B35（parity-fix-1）：begin 已受理后任何失败/取消都要 attachmentAbortV4
    // 清服务端 staging（官方 attachmentAbortV4 对位）——否则残留 staging
    // 只能等服务端超时回收。
    Future<void> abortStaging() async {
      try {
        await _channels.call(channel, 'attachmentAbortV4', [
          {...scope, ...base},
        ], timeout: const Duration(seconds: 10));
      } catch (_) {
        // 中止本身失败（桥已断等）只能交服务端超时回收。
      }
    }

    Map? beginRes;
    try {
      beginRes = await _channels.call(channel, 'attachmentBeginV4', [
        {
          ...scope,
          ...base,
          'fileName': fileName,
          'mime': mime,
          'totalBytes': bytes.length,
          'totalChunks': totalChunks,
          'checksum': checksum,
        },
      ]) as Map?;
    } catch (e) {
      // begin 未受理的失败无 staging 可清，原样抛。
      rethrow;
    }
    if (beginRes is Map && beginRes['state'] == 'committed') {
      onProgress?.call(1);
      return {
        'ref': beginRes['ref'],
        'fileName': fileName,
        'mime': mime,
        'bytes': bytes.length,
      };
    }
    try {
      var nextChunk = beginRes is Map
          ? (beginRes['nextChunkIndex'] as num?)?.toInt() ?? 0
          : 0;
      for (var n = nextChunk; n < totalChunks; n++) {
        final start = n * _attachmentChunkBytes;
        final end = start + _attachmentChunkBytes > bytes.length
            ? bytes.length
            : start + _attachmentChunkBytes;
        final chunkRes = await _channels.call(channel, 'attachmentChunkV4', [
          {
            ...scope,
            ...base,
            'chunkIndex': n,
            'dataBase64': base64.encode(
              Uint8List.sublistView(bytes, start, end),
            ),
          },
        ]);
        nextChunk = chunkRes is Map
            ? (chunkRes['nextChunkIndex'] as num?)?.toInt() ?? n + 1
            : n + 1;
        if (nextChunk != n + 1) {
          throw StateError('fault.attachment.invalidServerProgress');
        }
        onProgress?.call(nextChunk / totalChunks);
      }
      onProgress?.call(1);
      final commitRes = await _channels.call(channel, 'attachmentCommitV4', [
        {...scope, ...base},
      ]);
      // fall-through 返回
      return _attachmentResult(commitRes, fileName, mime, bytes.length);
    } catch (e) {
      await abortStaging();
      rethrow;
    }
  }

  Map<String, dynamic> _attachmentResult(
    dynamic commitRes,
    String fileName,
    String mime,
    int byteLength,
  ) {
    final ref = commitRes is Map ? commitRes['ref'] : null;
    return {
      'ref': ref,
      'fileName': fileName,
      'mime': mime,
      'bytes': byteLength,
    };
  }


  /// C4（2026-10-19 审查）：附件预读客户端总量上限——只信服务端 totalBytes
  /// 时理论上限 1024×384KB（坏数据/协议漂移会把超大附件整段驻留内存）。
  /// 32MB 覆盖正常图片/截图预览，超限抛错由查看器错误路径呈现。
  static const _attachmentReadMaxBytes = 32 << 20;

  /// Reads an attachment (for previews). Returns `{bytes, mediaType}`.
  Future<({Uint8List bytes, String? mediaType})> attachmentRead(
    String sessionId, {
    required String ref,
    Map<String, dynamic>? target,
    int? attachmentIndex,
  }) async {
    await handshake();
    // BytesBuilder(copy:false)：块引用零拷贝累积，终值单次物化（原
    // List<int> 累积 + fromList 双份峰值）。
    final builder = BytesBuilder(copy: false);
    var offset = 0;
    String? mediaType;
    for (var round = 0; round < 1024; round++) {
      final res = await _channels.call(channel, 'attachmentReadV4', [
        {
          ...scope,
          'sessionId': sessionId,
          'ref': ref,
          // 官方 superRefine：target 与 attachmentIndex 必须成对出现或同缺。
          if (target != null && attachmentIndex != null) ...{
            'target': target,
            'attachmentIndex': attachmentIndex,
          },
          'offset': offset,
          'limit': _attachmentChunkBytes,
        },
      ]);
      if (res is! Map) break;
      mediaType ??= res['mediaType'] as String?;
      final data = res['dataBase64'] as String?;
      if (data != null && data.isNotEmpty) {
        builder.add(base64.decode(data));
      }
      if (builder.length > _attachmentReadMaxBytes) {
        throw StateError('附件超过 32MB，已停止加载预览');
      }
      final next = (res['nextOffset'] as num?)?.toInt();
      final total = (res['totalBytes'] as num?)?.toInt();
      if (next == null || next <= offset) break;
      offset = next;
      if (total != null && offset >= total) break;
    }
    return (bytes: builder.toBytes(), mediaType: mediaType);
  }

  Future<dynamic> resolveInteraction(
    String sessionId,
    String interactionId, {
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) => sendCommand(sessionId, 'resolveInteraction', {
    'interactionId': interactionId,
    'answer': {
      if (optionId != null) 'optionId': optionId,
      if (freeText != null) 'freeText': freeText,
      if (action != null) 'action': action,
      if (content != null) 'content': content,
    },
  });

  /// A2（parity-fix-1，2026-10-29 审查）：官方 interactionAutoResolution
  /// Command.ts——交互可见即发一条幂等 snooze（accepted/duplicate/noop
  /// 均成功）。不发的后果=倒计时照跑、未处理的提问被提前自动结束
  /// （与「一次一题」产品语义冲突）。官方在弹窗/侧栏胶囊首次渲染时发。
  Future<dynamic> snoozeInteractionAutoResolution(
    String sessionId,
    String interactionId,
  ) => sendCommand(sessionId, 'snoozeInteractionAutoResolution', {
        'interactionId': interactionId,
      });

  Future<dynamic> rowsRange(
    String sessionId, {
    int? beforeRowId,
    int limit = 60,
  }) async {
    await handshake();
    return _channels.call(channel, 'conversationRowsRangeV4', [
      {
        ...scope,
        'sessionId': sessionId,
        if (beforeRowId != null) 'beforeRowId': beforeRowId,
        'limit': limit,
      },
    ]);
  }

  // ------------------------------------------------------ sessions-index

  /// Subscribes the sessions-index of this workspace
  /// (`subscribeSessionsIndexV4` + `onDynamicSessionsIndexFrame`).
  /// Provides the live session list with title/phase/lastAssistantPreview.
  /// F12（WR 对齐）：task 级配置目录（model/mode/thought_level 三选项，
  /// 官方 zcodeTaskServiceAdapter.getTaskConfigOptions——web remote 工具栏
  /// 目录的手机端等价真源；model 选项带 providerId+每模型思考档）。
  Future<List<ConfigOption>> getTaskConfigOptions(String taskId) async {
    await handshake();
    final res = await _channels.call(
      Channels.zcodeTask,
      'getTaskConfigOptions',
      [
        {...scope, 'taskId': taskId},
      ],
      timeout: const Duration(seconds: 45),
    );
    final list = res is List
        ? res
        : (res is Map ? res['configOptions'] ?? res['options'] : null);
    return [
      if (list is List)
        for (final o in list)
          if (o is Map) ConfigOption._(o),
    ];
  }

  /// F1 冷工作区占位订阅（dormant）：不发起任何 RPC，state 永不 ready，
  /// 仅供 TaskListModel 绑定；复活由上层 _retrySessionsIndex 重建真实订阅。
  SessionsIndexSubscription dormantSessionsIndex() =>
      SessionsIndexSubscription._dormant(this);

  /// [maxAttempts]：工作区切换传 1——冷/慢启 runtime 单次降级 dormant
  /// （验收⑤：3 轮耐心最坏 ~10 分钟 spinner；60s 复活定时器兜底），
  /// 默认 3 轮留给长连接恢复场景。
  Future<SessionsIndexSubscription> subscribeSessionsIndex({
    int maxAttempts = 3,
  }) async {
    // 与 subscribe() 同款抖动重试闭环（任务列表数据源，同样怕垂死窗口）。
    // 开源审查批D组1（G1 P3-1/G2 P2-2）：waitHealthy/handshake 移入 try
    // 计入 attempt（此前在 try 外，闸门/握手窗口失败一次性穿透）。
    for (var attempt = 1; attempt <= 5; attempt++) {
      SessionsIndexSubscription? subscription;
      try {
        await session.waitHealthy(timeout: const Duration(seconds: 45));
        await handshake();
        subscription = SessionsIndexSubscription._(this);
        // 不变式（真机实录教训）：外层超时必须 ≥ 内层订阅 RPC 的
        // 120s 宽限——外层更短会在桌面确认迟到时放弃并重试，而上一次的
        // 迟到 ACK 会以同 ownershipKey 静默驱逐新订阅 → 5 连超时级联
        // （64s 转圈后误降级 dormant）。240s 覆盖 _start 内部最坏
        // 45+60+120=225s（开源审查 G1 P2-3）。冷工作区不受影响：runtime
        // 未运行时服务端快败（ChannelRpcError），不走超时路径。
        await subscription._start().timeout(const Duration(seconds: 240));
        return subscription;
      } catch (e) {
        await subscription?.dispose();
        // 快败场景（runtime 未运行/桥断）不需要 5 轮耐心；挂起场景靠
        // 内层 120s 兜底。
        if (attempt >= maxAttempts) rethrow;
        _log('[v4-si] subscribe attempt $attempt failed ($e), retrying');
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    throw StateError('subscribeSessionsIndex: unreachable');
  }

  /// 订阅 controller/tasks-index（窗口级任务投影，ADR 0031——官方 3.16
  /// 删除 workspace-list tasks[] 后的继任数据源；主题 3.15.1 起存在，
  /// 现行栈可订阅可验收）。失败由调用方降级（workspace-list 兜底），
  /// 不设 dormant 态——window-controller 是窗口级服务，不依赖工作区
  /// 运行时，si dormant 不影响本订阅。
  Future<TasksIndexSubscription> subscribeTasksIndex({
    int maxAttempts = 2,
  }) async {
    // 开源审查批D组1（G1 P3-1/G2 P2-2）：waitHealthy 移入 try 计入 attempt
    //（同 subscribe/subscribeSessionsIndex；外层超时 240s 覆盖 _start 内部
    // 最坏路径，开源审查 G1 P2-3）。
    for (var attempt = 1; attempt <= 5; attempt++) {
      TasksIndexSubscription? subscription;
      try {
        await session.waitHealthy(timeout: const Duration(seconds: 45));
        subscription = TasksIndexSubscription._(this);
        await subscription._start().timeout(const Duration(seconds: 240));
        return subscription;
      } catch (e) {
        await subscription?.dispose();
        if (attempt >= maxAttempts) rethrow;
        _log('[tasks-index] subscribe attempt $attempt failed ($e), retrying');
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    throw StateError('subscribeTasksIndex: unreachable');
  }

  // ---------------------------------------------------- workspace config

  WorkspacePrep? _prep;

  /// 工作区目录（模式选择+斜杠命令）——官方 `zcode-session.
  /// readWorkspacePresentation`（mode+slashCommands）→ configOptions 形状。
  Future<WorkspacePrep> prepareWorkspace({bool refresh = false}) async {
    final cached = _prep;
    if (cached != null && !refresh) return cached;
    // 健康闸门 + 有限重试（对齐 subscribe 路径）：prepareWorkspace 落在
    // 垂死桥/抖动窗口会一次性超时——真机 2026-10-16 模型面板"为空"的一半
    // 根因（另一半是空结果被永久缓存，见下方合并语义）。
    Object? lastError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        await session.waitHealthy(timeout: const Duration(seconds: 45));
        // H2（审计）：目录真源是官方 zcode-session.readWorkspacePresentation
        // （presentation={mode,slashCommands}，官方 workspacePrepareRpc.ts
        // 同款；mode→目录映射对齐 zcodeWorkspacePresentationToConfigOptions）。
        // H08-8A（2026-10-29 批次）：旧 zcode-task.prepareWorkspace 为
        // zemote 遗产、官方快照（3.16.2 契约）零命中，兜底正式退役——
        // 失败走本循环重试 + 循环外的缓存回落，不再回退自创 RPC。
        final pres = await _channels.call(
          Channels.zcodeSession,
          'readWorkspacePresentation',
          [scope],
          timeout: const Duration(seconds: 20),
        );
        if (pres is! Map) {
          throw StateError(
            'readWorkspacePresentation 非法载荷（${pres.runtimeType}）',
          );
        }
        final raw = <String, dynamic>{
          'slashCommands': pres['slashCommands'] ?? const [],
          'configOptions': [
            {
              'id': 'mode',
              'name': '模式',
              'category': 'mode',
              'type': 'select',
              'currentValue': pres['mode'],
              'options': [
                // parity-fix-1（A6，2026-10-29 审查）：官方可切换子集含
                // edit（mode.label.glm.edit=自动编辑）——此前硬编码缺该档，
                // 桌面处于 edit 时手机目录显示不全。
                for (final m in const [
                  ('build', '变更前确认'),
                  ('edit', '自动编辑'),
                  ('guarded', '自主模式'),
                  ('plan', '计划模式'),
                  ('yolo', '完全访问'),
                ])
                  {'value': m.$1, 'name': m.$2},
              ],
            },
          ],
        };
        final fresh = WorkspacePrep._(raw);
        // 官方语义（v4-workspace-config.ts：无 live session 时 configOptions
        // 合法为空；useDraftConfigControl 空目录即重新水合）：**空结果不落缓存
        // 且不清掉已拿到的目录**——按字段合并，只升不降。
        final merged = WorkspacePrep._merge(cached, fresh);
        _prep = merged;
        return merged;
      } catch (e) {
        lastError = e;
        if (attempt < 3) {
          _log(
            '[prep] prepareWorkspace attempt $attempt failed ($e), retrying',
          );
          await Future.delayed(const Duration(seconds: 2));
        }
      }
    }
    if (cached != null) return cached;
    throw StateError('prepareWorkspace 失败：$lastError');
  }

  /// 官方 model-selection.getView（宿主级，无需会话）——草稿选型目录
  /// 真源（readWorkspacePresentation 只有 mode+斜杠，无模型目录）。
  Future<Map<String, dynamic>?> modelSelectionView() async {
    final res = await _channels.call(Channels.modelSelection, 'getView', [
      {},
    ], timeout: const Duration(seconds: 30));
    return res is Map ? res.cast<String, dynamic>() : null;
  }

  /// getView → ConfigOption 形状（模型面板直用；value=providerId/modelId）。
  Future<List<ConfigOption>> modelSelectionOptions() async {
    final view = await modelSelectionView();
    final providers = view?['providers'];
    final rawOptions = <Map>[];
    if (providers is List) {
      for (final p in providers) {
        if (p is! Map) continue;
        final pid = '${p['providerId'] ?? ''}';
        final models = p['models'];
        if (models is List) {
          for (final m in models) {
            if (m is! Map) continue;
            final mid = '${m['modelId'] ?? ''}';
            if (pid.isEmpty || mid.isEmpty) continue;
            final config = m['config'];
            final optionSpecs = config is Map ? config['optionSpecs'] : null;
            final reasoning = optionSpecs is Map
                ? optionSpecs['reasoningLevel']
                : null;
            final levels = reasoning is Map ? reasoning['values'] : null;
            rawOptions.add({
              'value': '$pid/$mid',
              'name': mid,
              'modelProviderId': pid,
              if ('${p['providerName'] ?? p['name'] ?? ''}'.isNotEmpty)
                'modelProviderName': '${p['providerName'] ?? p['name']}',
              if (levels is List) 'modelThoughtLevels': levels,
            });
          }
        }
      }
    }
    if (rawOptions.isEmpty) return const [];
    return [
      ConfigOption._({
        'id': 'model',
        'name': '模型',
        'category': '',
        'type': 'select',
        'options': rawOptions,
      }),
    ];
  }

  /// `skills.list` — enabled skills of this workspace (mirrors the web
  /// client's `skillsService.list`). Skills are invoked in the composer as
  /// `$name`. Returns an empty list when the channel rejects or returns no
  /// skill data.
  Future<List<SkillEntry>> skills() async {
    final res = await _channels.call(Channels.skills, 'list', [
      {
        'workspacePath': scope['workspacePath'],
        if (scope['workspaceIdentity'] != null)
          'workspaceIdentity': scope['workspaceIdentity'],
        'provider': 'glm',
      },
    ], timeout: const Duration(seconds: 20));
    final raw = res is List ? res : (res is Map ? res['skills'] : null);
    if (raw is! List) return const [];
    return [
      for (final item in raw.whereType<Map>())
        SkillEntry._(item.cast<String, dynamic>()),
    ].where((s) => s.name.isNotEmpty).toList();
  }

  /// `file.searchWorkspaceFiles`（fileService.ts:589）——@文件 提及的
  /// 候选来源。query 为空时返回空。
  Future<List<Map<String, dynamic>>> searchWorkspaceFiles(
    String query, {
    int limit = 12,
    bool refresh = false,
  }) async {
    if (query.trim().isEmpty) return const [];
    final res = await _channels.call(Channels.file, 'searchWorkspaceFiles', [
      {
        'rootPath': scope['workspacePath'],
        if (scope['workspaceIdentity'] != null)
          'workspaceIdentity': scope['workspaceIdentity'],
        'query': query.trim(),
        'limit': limit,
        if (refresh) 'refresh': true,
      },
    ], timeout: const Duration(seconds: 8));
    if (res is! List) return const [];
    return res.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }
}

/// Shared base for Conversation/SessionsIndex subscriptions.
/// Extracts the common wire-frame staging, fragment reassembly, bridge
/// recovery, and resubscribe retry logic.
abstract class _SubscriptionBase<T extends ChangeNotifier> {
  final ConversationTransport _transport;
  final String _logTag;

  final T state;

  String? _subscriptionId;
  String? get subscriptionId => _subscriptionId;
  void Function()? _cancelFrameListener;
  bool _disposed = false;
  // B6：暴露给 ComputerStack.ensureConversation 的缓存守卫。
  bool get isDisposed => _disposed;

  /// 后台驻留态（电量优化批 #16）：协议层已退订、帧监听与看门狗已停，
  /// 对象与状态保留——页面持有的引用继续有效。恢复走 [_resumeFromPark]。
  bool _parked = false;
  bool _resyncing = false;
  Timer? _resubscribeTimer;

  final _stagedFrames = <Map<String, dynamic>>[];
  final _fragments = <String, _LogicalFrameAssembly>{};

  /// F6/D1：subId 不符被丢弃的帧计数（驱逐竞态的决定性信号，一次性+每 20 次日志）。
  int _foreignSubDrops = 0;

  /// F6/R1：notOwned 连续升级计数（封顶防风暴；健康帧到达即清零）。
  int _notOwnedEscalations = 0;
  Timer? _fragmentCleanup;

  _SubscriptionBase(this._transport, this.state, this._logTag) {
    _transport.session.recovered.addListener(_onBridgeRecovered);
    _fragmentCleanup = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _purgeFragments(),
    );
  }

  // --- abstract: subclasses define channel/protocol specifics

  /// Frame event name (e.g. `onDynamicConversationFrame`).
  String get _frameEventName;

  /// Subscribe method name (e.g. `subscribeConversationV4`).
  String get _subscribeMethod;

  /// Unsubscribe method name (e.g. `unsubscribeConversationV4`).
  String get _unsubscribeMethod;

  /// Resync method name (e.g. `resyncConversationV4`).
  String get _resyncMethod;

  /// Extra subscribe request args (merged with scope).
  Map<String, dynamic> get _subscribeArgs;

  /// Extra unsubscribe request args.
  Map<String, dynamic> get _unsubscribeArgs;

  /// Extra resync request args.
  Map<String, dynamic> get _resyncArgs;

  /// Topic for wire-frame routing.
  String get topic;

  // --- 通用化钩子（ADR 0031：controller/tasks-index 订阅复用本基类）。
  // 默认值 = si/conversation 既有行为，逐字节不变；子类按通道差异覆写。

  /// 订阅所在通道（si/conversation=zcode-agent；controller=window-controller）。
  String get _channel => ConversationTransport.channel;

  /// 订阅/退订/resync 参数与事件监听携带的 scope。controller 主题的
  /// zod schema 是 strict（controllerSubscribeParamsSchema）——夹带任何
  /// scope 字段都会被服务端拒掉，覆写为空 Map。
  Map<String, dynamic> get _wireScope => _transport.scope;

  /// 是否依赖 v4 会话握手（hello/initialize，zcode-agent 专属）。
  /// window-controller 服务不依赖它。
  bool get _requiresConversationHandshake => true;

  /// 事件载荷是否带 v4 wire 包装（`{topic, kind:'complete'|'fragment',…}`，
  /// v4 gateway 专属）。controller 帧是裸信封直传（大快照由 bridge
  /// rpc-frame 层透明分片重组），覆写为 false。
  bool get _usesV4WireWrapper => true;

  /// Process a logical frame against [state].
  void _acceptLogicalFrame(Map<String, dynamic> frame);

  /// Called with the subscribe ack map — hook for state-specific processing.
  void _onSubscribeAck(Map<String, dynamic> ack) {}

  /// Called after a successful _start() — hook for post-start logic.
  void _onStarted() {}

  /// Called during resubscribe cleanup before re-connect.
  void _onResubscribeCleanup() {}

  /// Called during dispose — extra cleanup.
  Future<void> _onDispose() async {}

  /// Called when parked for background — extra cleanup (watchdog 等).
  Future<void> _onPark() async {}

  /// Called when resumed from park — extra re-arming before resubscribe.
  Future<void> _onResumeFromPark() async {}

  /// 后台驻留（电量优化批 #16）：协议层退订 + 停帧监听/看门狗/重试
  /// 定时器——桌面停止推流式帧（无线电休眠），但对象与 state 保留：
  /// 打开中的会话页持有的引用与状态监听继续有效（冻结在最后水位）。
  /// 与 dispose 的区别：dispose 终结对象（页面引用作废）；park 只是
  /// 把协议订阅摘下，恢复走增量续订。sendCommand 的 CAS base 仍取本
  /// 订阅水位（追踪不摘）。
  Future<void> _parkForBackground() async {
    if (_disposed || _parked) return;
    _parked = true;
    _resubscribeTimer?.cancel();
    _resubscribeTimer = null;
    _fragmentCleanup?.cancel();
    _fragmentCleanup = null;
    _cancelFrameListener?.call();
    _cancelFrameListener = null;
    final id = _subscriptionId;
    _subscriptionId = null;
    _stagedFrames.clear();
    _fragments.clear();
    await _onPark();
    if (id != null) {
      try {
        await _transport._channels.call(_channel, _unsubscribeMethod, [
          {..._wireScope, 'subscriptionId': id, ..._unsubscribeArgs},
        ]);
      } catch (_) {}
    }
  }

  /// 驻留恢复：增量续订（[_subscribeArgs] 带当前水位 base——服务端
  /// 裁决 resume 只补 delta，真滚出保留窗才整快照）。失败走既有 3s
  /// 重试链自愈（_scheduleResubscribeRetry）。
  Future<void> _resumeFromPark() async {
    if (_disposed || !_parked) return;
    _parked = false;
    _fragmentCleanup = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _purgeFragments(),
    );
    await _onResumeFromPark();
    await _resubscribe();
  }

  int get _resyncSeq => 0;
  String? get _resyncEpoch => null;

  void _purgeFragments() {
    if (_disposed) return;
    final stale = <String>[];
    final now = DateTime.now();
    _fragments.forEach((id, a) {
      if (now.difference(a.createdAt).inSeconds > 60) stale.add(id);
    });
    for (final id in stale) {
      _fragments.remove(id);
      _transport._log('[$_logTag] purged stale fragment $id');
    }
  }

  Future<void> _start() async {
    // 开源审查批D组1（G3 P2-3）：subscribe() 直连与桥恢复触发的
    // _resubscribe 可在同一订阅对象上并发跑两个 _start——本次 attempt
    // 登记的监听器/订阅 id 用局部变量持有，失败清理只动自己名下的
    // （旧实现无条件清共享字段：并发 attempt 的帧监听被撕、新 sid 被抹
    // →服务端订阅永不退订（泄漏）且放大 F6/R5 驱逐竞态）。
    void Function()? myListener;
    String? mySubId;
    try {
      // 抖动窗口闸门（真机 2026-10-15 定位）：bridge degraded→重建的窗口内
      // 发起的订阅会落到垂死旧通道，只能等 120s 超时；先等桥恢复再订阅
      // （与 sendCommand 的 waitHealthy gate 同款语义）。
      _transport._log('[$_logTag] _start: awaiting healthy bridge');
      await _transport.session.waitHealthy(
        timeout: const Duration(seconds: 45),
      );
      // disposed 闸门（对抗审查 B3）：抖动期 resubscribe 在途（waitHealthy
      // 45s+subscribe 120s）恰逢用户切工作区/退后台 dispose——继续跑会在
      // 已 dispose 的订阅上重挂帧监听器、置新 _subscriptionId（永不退订，
      // 桌面端泄漏）并经 _onStarted 武装一个无人取消的看门狗定时器。
      // 开源审查批B组2（G1/G2/G3 P2-1）：`_parked` 与 `_disposed` 同权
      // ——驻留（后台电量优化）发生在 `_start` 在飞时同样不得重挂监听/
      // 看门狗，否则被 park 的订阅在后台整段保活收帧、看门狗每 20-40s
      // 发 resync RPC（打电量红线）。
      if (_disposed || _parked) return;
      if (_requiresConversationHandshake) {
        _transport._log('[$_logTag] _start: awaiting handshake');
        await _transport.handshake();
        if (_disposed || _parked) return;
        _transport._log('[$_logTag] _start: handshake ok, adding listener');
      } else {
        _transport._log('[$_logTag] _start: adding listener (no handshake)');
      }
      myListener = _transport._channels.addEventListener(
        _channel,
        _frameEventName,
        _handleWireFrame,
        arg: _wireScope.isEmpty ? null : _wireScope,
      );
      _cancelFrameListener = myListener;
      final res = await _transport._channels.call(
        _channel,
        _subscribeMethod,
        [
          {..._wireScope, ..._subscribeArgs},
        ],
        // The desktop may need to warm the session runtime before answering —
        // give the subscribe call generous room instead of timing out at the
        // 30s channel default. Cold sessions (large history) can take well
        // over a minute to warm (real-device feedback 2026-10-14).
        timeout: const Duration(seconds: 120),
      );
      if (_disposed || _parked) {
        // dispose/park 在 subscribe 在途时发生：立即退订刚拿到的订阅，防
        // 泄漏（park 路径=驻留态不得持有服务端订阅，开源审查 G1/G2/G3
        // P2-1——退订后直接 return，不 _onStarted 不重挂看门狗）。
        final ack = res is Map ? res['ack'] : null;
        final sid = ack is Map ? ack['subscriptionId'] as String? : null;
        if (sid != null) {
          try {
            await _transport._channels.call(_channel, _unsubscribeMethod, [
              {..._wireScope, 'subscriptionId': sid, ..._unsubscribeArgs},
            ]);
          } catch (_) {}
        }
        return;
      }
      _transport._log('[$_logTag] _start: subscribe call returned');
      final ack = (res as Map?)?['ack'] as Map?;
      _subscriptionId = ack?['subscriptionId'] as String?;
      mySubId = _subscriptionId;
      _transport._log('[$_logTag] subscribed $topic id=$_subscriptionId');
      if (_subscriptionId == null) {
        throw StateError('$_subscribeMethod: missing ack.subscriptionId');
      }
      _onSubscribeAck(ack?.cast<String, dynamic>() ?? const {});
      final staged = List<Map<String, dynamic>>.from(_stagedFrames);
      _stagedFrames.clear();
      for (final frame in staged) {
        _acceptLogicalFrame(frame);
      }
      _onStarted();
    } catch (_) {
      if (!_disposed) {
        // G3 P2-3：只清理本次 attempt 自己登记的资源——并发 attempt 的
        // 监听器/订阅 id 不得误撕（identical 守卫）。
        final current = _cancelFrameListener;
        if (identical(current, myListener)) {
          current?.call();
          _cancelFrameListener = null;
        } else {
          myListener?.call();
        }
        if (mySubId != null && identical(_subscriptionId, mySubId)) {
          _subscriptionId = null;
        }
        _stagedFrames.clear();
        _fragments.clear();
      }
      rethrow;
    }
  }

  void _onBridgeRecovered() {
    // 优化批 #16：驻留订阅不随桥恢复自愈重订阅——后台驻留的目的就是
    // 不收流式帧；恢复由 ensureConversation 显式触发。
    if (_disposed || _parked) return;
    _transport._log('[$_logTag] bridge recovered, resubscribing $topic');
    _resubscribe();
  }

  /// resubscribe 互斥（对抗审查 B2）：桥恢复通知/看门狗升级/3s 重试三源
  /// 并发触发时，两个实例各自 _start 会产生双帧监听器（前者泄漏）+同
  /// ownershipKey 双订阅（服务端驱逐竞态，本项目 F6/R5/notOwned 同源）。
  bool _resubscribing = false;

  Future<void> _resubscribe() async {
    if (_disposed || _parked || _resubscribing) return;
    _resubscribing = true;
    try {
      await _resubscribeLocked();
    } finally {
      _resubscribing = false;
    }
  }

  Future<void> _resubscribeLocked() async {
    try {
      await _transport.handshake();
    } catch (e) {
      // 桥 degraded 窗口内握手会 30s 超时抛错（对抗审查 C2：此前裸抛
      // 且不挂 3s 重试——unawaited 调用点无人 catch，恢复只能靠下一次
      // 桥恢复事件）。纳入统一 3s 重试链。
      _transport._log('[$_logTag] resubscribe handshake failed: $e');
      // 开源审查批D组1（G3 P3-7）：旧 id 必须一并作废——3s 重试链的门是
      // `_subscriptionId == null`，保留旧 id 会把链拦死（idle 会话无看门
      // 狗 resync 自愈源，冻结到下一次桥恢复）。旧桥已换代，旧 id 与帧
      // 监听均已无意义。
      _cancelFrameListener?.call();
      _cancelFrameListener = null;
      _subscriptionId = null;
      _scheduleResubscribeRetry();
      return;
    }
    // 开源审查批B组2（G2 P2-1）：handshake 的 await 窗口内 park 落地则
    // 中止重订阅链——否则后续 `_start` 会在驻留态重挂监听/看门狗。
    if (_disposed || _parked) return;
    _onResubscribeCleanup();
    _cancelFrameListener?.call();
    _cancelFrameListener = null;
    final oldId = _subscriptionId;
    _subscriptionId = null;
    _stagedFrames.clear();
    _fragments.clear();
    if (oldId != null) {
      try {
        await _transport._channels.call(_channel, _unsubscribeMethod, [
          {..._wireScope, 'subscriptionId': oldId, ..._unsubscribeArgs},
        ]);
      } catch (_) {}
    }
    try {
      await _start();
    } catch (e) {
      _transport._log('[$_logTag] resubscribe failed: $e');
      _scheduleResubscribeRetry();
    }
  }

  void _scheduleResubscribeRetry() {
    if (_disposed || _parked) return;
    _resubscribeTimer?.cancel();
    _resubscribeTimer = Timer(const Duration(seconds: 3), () {
      if (!_disposed && _subscriptionId == null) _resubscribe();
    });
  }

  void _handleWireFrame(dynamic data) {
    // 开源审查批B组2（G3 P2-1）：驻留态不进帧处理——正常路径 park 已摘
    // 帧监听，此处是"park 窗口内 `_start` 重挂监听"僵尸路径的纵深防御
    // （也避免 staged 帧在后台无界积累）。
    if (_disposed || _parked || data is! Map) return;
    final frame = data.cast<String, dynamic>();
    if (!_usesV4WireWrapper) {
      // 裸信封帧（controller 主题）：载荷即 WindowHostControllerTaskFrame，
      // 无 complete/fragment 包装——大快照在 bridge rpc-frame 层已透明重组。
      if (frame['topic'] != topic) return;
      _acceptOrStage(frame);
      return;
    }
    if (frame['topic'] != topic) return;
    switch (frame['kind']) {
      case 'complete':
        final inner = frame['frame'];
        if (inner is Map) {
          _acceptOrStage(inner.cast<String, dynamic>());
        }
        break;
      case 'fragment':
        _acceptFragment(frame);
        break;
    }
  }

  /// pre-ack 窗口的 staged 帧上限（开源审查 G2-P3-14）：重订阅窗口内旧
  /// 订阅若仍在推帧（F6 驱逐竞态下服务端旧订阅未死），无上限囤积会整段
  /// 驻留内存——超限丢最旧；丢帧由 fromSeq gap→resync 自愈。
  static const _stagedFramesLimit = 64;

  void _acceptOrStage(Map<String, dynamic> frame) {
    if (_subscriptionId == null) {
      if (_stagedFrames.length >= _stagedFramesLimit) {
        _stagedFrames.removeAt(0);
      }
      _stagedFrames.add(frame);
      return;
    }
    _acceptLogicalFrame(frame);
  }

  void _acceptFragment(Map<String, dynamic> frame) {
    final id = frame['logicalFrameId'] as String?;
    final index = (frame['fragmentIndex'] as num?)?.toInt();
    final count = (frame['fragmentCount'] as num?)?.toInt();
    final dataBase64 = frame['dataBase64'] as String?;
    if (id == null || index == null || count == null || dataBase64 == null) {
      return;
    }
    // 官方上限 1024（core.ts）：64 会静默丢弃大逻辑帧（同族隐患，顺手修）。
    if (count < 1 || count > 1024 || index < 0 || index >= count) return;
    final assembly = _fragments.putIfAbsent(
      id,
      () => _LogicalFrameAssembly(count),
    );
    if (assembly.count != count) {
      _fragments.remove(id);
      return;
    }
    try {
      assembly.add(index, base64.decode(dataBase64));
    } catch (e) {
      _fragments.remove(id);
      _transport._log('[$_logTag] bad fragment: $e');
      return;
    }
    if (assembly.oversized) {
      // 开源审查 G3-P3-8：累计字节超护栏即整组作废。
      _fragments.remove(id);
      _transport._log('[$_logTag] dropped oversized logical frame assembly');
      return;
    }
    if (assembly.isComplete) {
      _fragments.remove(id);
      try {
        final decoded = jsonDecode(utf8.decode(assembly.assemble()));
        if (decoded is Map) {
          _acceptOrStage(decoded.cast<String, dynamic>());
        }
      } catch (e) {
        _transport._log('[$_logTag] bad logical frame: $e');
      }
    }
  }

  Future<void> _resync() async {
    final id = _subscriptionId;
    // 开源审查批B组2（G3 P2-1）：驻留态不发 resync RPC（后台周期性 RPC
    // =无线电唤醒，打电量红线；恢复由 resumeParkedConversation 触发）。
    if (id == null || _disposed || _parked || _resyncing) return;
    _resyncing = true;
    _transport._log(
      '[$_logTag] resync (gap detected) seq=$_resyncSeq logEpoch=$_resyncEpoch',
    );
    try {
      await _transport._channels.call(_channel, _resyncMethod, [
        {
          ..._wireScope,
          'subscriptionId': id,
          ..._resyncArgs,
          // M1（审计）：conversationResyncParamsSchema 的 base 必填
          // 但可空（nullable）——显式 null 合法，整体缺失会被拒。
          'base': _resyncEpoch == null
              ? null
              : {'logEpoch': _resyncEpoch, 'seq': _resyncSeq},
        },
      ]);
      _transport._log('[$_logTag] resync call ok (reply follows as frame)');
    } catch (e) {
      _transport._log('[$_logTag] resync failed: $e');
      // F6/R1（官方 conversationProjectionStore notOwned 自愈对齐）：
      // notOwned = 该 subId 已被服务端驱逐（同 ownershipKey 二次订阅静默
      // 驱逐）。resync 永远救不回——升级 fresh 重订阅；连续升级封顶 2 次
      // 防风暴（桥恢复路径也在重建时不叠加）。
      if ('$e'.contains('notOwned')) {
        _notOwnedEscalations++;
        if (_notOwnedEscalations <= 2 &&
            !_disposed &&
            _subscriptionId != null) {
          _transport._log('[$_logTag] notOwned -> fresh resubscribe');
          unawaited(_resubscribe());
        }
      }
    } finally {
      _resyncing = false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _resubscribeTimer?.cancel();
    _fragmentCleanup?.cancel();
    await _onDispose();
    _transport.session.recovered.removeListener(_onBridgeRecovered);
    _cancelFrameListener?.call();
    final id = _subscriptionId;
    if (id != null) {
      try {
        await _transport._channels.call(_channel, _unsubscribeMethod, [
          {..._wireScope, 'subscriptionId': id, ..._unsubscribeArgs},
        ]);
      } catch (_) {}
    }
    _fragments.clear();
  }
}

/// 会话订阅的水位种子（阶段 3 会话缓存，官方语义仲裁结论）：
///
/// 来自本地缓存的一致投影（快照控制块 + 已应用行 + (logEpoch, seq) 水位）。
/// 订阅请求携带 `base: {logEpoch, seq}`——服务端裁决（v4-gateway.ts:834-839
/// subscribe 裁决同 resync）：同 epoch 且 seq 在保留窗内 → 只重放
/// (base.seq, current] 的 delta（含离线期间的 row.removed 历史重写）；
/// 否则整快照替换。种子必须与 base 完全一致（官方"水位不变量：仅当
/// 客户端真持有该时刻一致状态才允许带 base"）——pendingInteractions
/// 等控制块不得清洗，否则 resume 路径下服务端不重发它们。
class ConversationSeed {
  final List<Map<String, dynamic>> rows;
  final String? logEpoch;
  final int seq;
  final int? firstRowId;
  final int totalCount;

  /// 完整快照控制块（control/config/queue/usage/pendingInteractions…，
  /// 快照去掉 rows 的部分）。
  final Map<String, dynamic>? snapshot;

  const ConversationSeed({
    required this.rows,
    required this.logEpoch,
    required this.seq,
    required this.firstRowId,
    required this.totalCount,
    required this.snapshot,
  });
}

/// 订阅参数：sessionId + 增量续传 base（**当前状态水位**，非缓存种子水位）。
///
/// 种子水位在桥抖动重订阅时可能早已滚出服务端保留窗（refs
/// subscribeReserved 的 resumable 判据：base.seq < floorSeq 只能改发全量
/// 快照）——旧实现重订阅仍带种子水位，强制快照后与本地旧行拼接出
/// 中间断层（2026-10-23 用户实锤"问答错位"）。取实时水位（applySeed
/// 即种子水位，帧到达后自然前进）后：保留窗内走 resume 原地续传、不
/// 打断已渲染内容；真滚出窗口/换 epoch 才快照（配合整体替换语义）。
@visibleForTesting
Map<String, dynamic> conversationSubscribeArgs(
  String sessionId,
  String? logEpoch,
  int seq,
) => {
  'sessionId': sessionId,
  if (logEpoch != null && logEpoch.isNotEmpty)
    'base': {'logEpoch': logEpoch, 'seq': seq},
};

class ConversationSubscription extends _SubscriptionBase<ConversationState> {
  final String sessionId;
  final ConversationSeed? _seed;

  /// 是否已收到本订阅的首个匹配帧（区分"缓存种子渲染"与"实时帧已流动"，
  /// 页面据此显示"同步中"提示）。
  bool _liveFrameApplied = false;
  bool get hasLiveFrames => _liveFrameApplied;

  DateTime _lastFrameAt = DateTime.now();
  Timer? _watchdog;

  /// F6/R2b：静默期间已发出的 resync 次数（帧到达清零；连续 2 次无帧 →
  /// 升级重订阅）。
  int _resyncSinceFrame = 0;

  /// 连续静默 tick 计数（H03 半项 2026-10-25）：看门狗日志降频用——
  /// 帧到达/静默解除清零。
  int _quietTicks = 0;

  ConversationSubscription._(
    ConversationTransport transport,
    this.sessionId, {
    ConversationSeed? seed,
  }) : _seed = seed,
       super(transport, ConversationState(), 'v4') {
    if (seed != null) state.applySeed(seed);
  }

  @override
  String get _frameEventName => 'onDynamicConversationFrame';
  @override
  String get _subscribeMethod => 'subscribeConversationV4';
  @override
  String get _unsubscribeMethod => 'unsubscribeConversationV4';
  @override
  String get _resyncMethod => 'resyncConversationV4';
  @override
  Map<String, dynamic> get _subscribeArgs =>
      conversationSubscribeArgs(sessionId, state.logEpoch, state.seq);
  @override
  Map<String, dynamic> get _unsubscribeArgs => const {};
  @override
  Map<String, dynamic> get _resyncArgs => const {'forceSnapshot': true};
  @override
  String get topic => 'conversation/$sessionId';
  @override
  int get _resyncSeq => state.seq;
  @override
  String? get _resyncEpoch => state.logEpoch;

  @override
  void _onSubscribeAck(Map<String, dynamic> ack) {
    // 阶段 3：ack.mode（resume=增量续传被接受 / snapshot=服务端裁决全量）
    // + epoch——种子路径成效的直接证据（仲裁 B2 裁决逻辑）。
    _transport._log(
      '[v4] subscribe ack mode=${ack['mode']} '
      'epoch=${ack['logEpoch']} (seed=${_seed?.logEpoch ?? 'none'})',
    );
    if (ack['logEpoch'] is String) {
      state.logEpoch = ack['logEpoch'] as String;
    }
    // resume 且无待重放增量（静默会话）时不会有任何帧到达——ack 即
    // "服务端确认本地水位即最新"，视作已同步（页面"同步中"提示解除）。
    if ('${ack['mode']}' == 'resume') {
      _liveFrameApplied = true;
    }
  }

  @override
  void _onStarted() {
    _startWatchdog();
  }

  @override
  void _onResubscribeCleanup() {
    // F6/R7：重订阅重建期间保留看门狗（只 dispose 时取消）。无 subId 时
    // tick 的 resync 自然 no-op，不会叠加风暴；否则桥抖动下订阅重建不成功
    // = 无帧 + 无看门狗 = UI 永久保持旧 phase。
  }

  @override
  Future<void> _onDispose() async {
    _watchdog?.cancel();
    _transport._untrackSubscription(sessionId, this);
    state.dispose();
  }

  /// 优化批 #16：驻留——停看门狗（无订阅 ID 时 tick 本就 no-op，停掉更
  /// 干净）；保留 _transport 追踪与 state（CAS base 水位、页面渲染载体）。
  @override
  Future<void> _onPark() async {
    _watchdog?.cancel();
  }

  /// 驻留恢复无需额外动作：看门狗随 _start 成功的 _onStarted 重挂；
  /// 追踪从未摘除。
  @override
  Future<void> _onResumeFromPark() async {}

  @override
  void _acceptLogicalFrame(Map<String, dynamic> frame) {
    final subId = subscriptionId;
    if (subId == null || frame['subscriptionId'] != subId) {
      // F6/D1：驱逐竞态的决定性信号——之前完全静默。
      if (subId != null && frame['subscriptionId'] is String) {
        _foreignSubDrops++;
        if (_foreignSubDrops == 1 || _foreignSubDrops % 20 == 0) {
          _transport._log(
            '[$_logTag] dropping frames with foreign subId '
            '(count=$_foreignSubDrops) — 订阅驱逐竞态证据',
          );
        }
      }
      return;
    }
    _lastFrameAt = DateTime.now();
    _resyncSinceFrame = 0;
    _foreignSubDrops = 0;
    _notOwnedEscalations = 0;
    _liveFrameApplied = true;
    // A malformed or unexpectedly large snapshot must not leave the state
    // stuck on `ready == false` (endless spinner). On failure, resync.
    try {
      state.applyFrame(
        frame,
        onGap: _resync,
        onLog: (line) => _transport._log('[v4-tl] $line'),
      );
    } catch (e) {
      _transport._log('[$_logTag] applyFrame failed: $e');
      _resync();
    }
  }

  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 10), (_) {
      // 开源审查批B组2（G3 P2-1）：驻留态看门狗 tick 直接返回——`_parked`
      // 落在 `_onStarted` 武装之后时，旧实现会在后台每 20-40s 发一次
      // resync RPC（无线电唤醒），且升级路径被 `_resubscribe` 的
      // `_parked` 门拦住形成无限循环。
      if (_disposed || _parked) return;
      final quietSeconds = DateTime.now().difference(_lastFrameAt).inSeconds;
      // 埋点（phase 卡 running 根因时间线）：降频记录（H03 半项 2026-10-25
      // 审查）——静默首记+每 60s 一记；原每 tick（10s）一记会在多订阅空闲
      // 时冲刷 app_state 500 条内存日志的排障证据。看门狗活性/静默时长
      // 证据仍在，升级路径（resync/resubscribe）日志不受影响。
      if (quietSeconds >= 10) {
        _quietTicks++;
        if (_quietTicks == 1 || _quietTicks % 6 == 0) {
          _transport._log(
            '[v4-wd] ($sessionId) tick quiet=${quietSeconds}s '
            'running=${state.isRunning} streaming='
            '${state.rows.any((r) => r['state'] == 'streaming')}',
          );
        }
      } else {
        _quietTicks = 0;
      }
      if (quietSeconds < 20) return;
      // 等用户审批/输入 ≠ 连接问题：回合活着但无帧是正常静默，
      // resync 救不了"等输入"，反而空转（实测 goal 探针卡审批时
      // 看门狗每 60s 白白 resync+resubscribe 一轮）。
      if (state.pendingInteractions.isNotEmpty) return;
      final streaming = state.rows.any((r) => r['state'] == 'streaming');
      if (state.isRunning || streaming) {
        // F6/R2b：resync 连续 2 轮仍无帧到达 → 订阅大概率已被驱逐/半开，
        // 升级 fresh 重订阅（对齐官方"停在 error 等手动重连会永久卡死"的
        // 自愈语义）。
        if (_resyncSinceFrame >= 2) {
          _transport._log(
            '[v4-wd] ($sessionId) $_resyncSinceFrame resyncs without frames, '
            'escalate to resubscribe',
          );
          _resyncSinceFrame = 0;
          if (_subscriptionId != null) {
            unawaited(_resubscribe());
          }
          return;
        }
        _resyncSinceFrame++;
        _transport._log(
          '[v4] watchdog: no frames for ${quietSeconds}s while active, resync',
        );
        _resync();
      }
    });
  }
}

class WorkspacePrep {
  final List<ConfigOption> configOptions;
  final List<SlashCommand> slashCommands;
  final Map raw;

  WorkspacePrep._(this.raw)
    : configOptions = [
        if (raw['configOptions'] is List)
          for (final o in raw['configOptions'] as List)
            if (o is Map) ConfigOption._(o),
      ],
      slashCommands = [
        if (raw['slashCommands'] is List)
          for (final c in raw['slashCommands'] as List)
            if (c is Map) SlashCommand._(c),
      ];

  ConfigOption? option(String id) {
    for (final o in configOptions) {
      if (o.id == id) return o;
    }
    return null;
  }

  /// 按字段合并（只升不降）：configOptions 依赖 live session（官方语义
  /// 无会话时合法为空），空 fresh 不清掉已有目录；slash 同理。
  static WorkspacePrep _merge(WorkspacePrep? cached, WorkspacePrep fresh) {
    if (cached == null) return fresh;
    if (fresh.configOptions.isEmpty && fresh.slashCommands.isEmpty) {
      return cached;
    }
    if (fresh.configOptions.isNotEmpty && fresh.slashCommands.isNotEmpty) {
      return fresh;
    }
    return WorkspacePrep._combined(
      fresh.configOptions.isNotEmpty
          ? fresh.configOptions
          : cached.configOptions,
      fresh.slashCommands.isNotEmpty
          ? fresh.slashCommands
          : cached.slashCommands,
    );
  }

  WorkspacePrep._combined(this.configOptions, this.slashCommands)
    : raw = const {};

  /// 公开工厂（F12）：task 级目录（getTaskConfigOptions）装进同一形状。
  factory WorkspacePrep.fromOptions(List<ConfigOption> options) =>
      WorkspacePrep._combined(options, const []);
}

/// A desktop skill (`skills.list`), triggered in the composer as `$name`.
class SkillEntry {
  final String id;
  final String name;
  final String path;
  final String scope;
  final String? description;
  final String? argumentHint;
  final bool enabled;

  SkillEntry._(Map raw)
    : id = '${raw['id'] ?? ''}',
      name = '${raw['name'] ?? ''}',
      path = '${raw['path'] ?? ''}',
      scope = '${raw['scope'] ?? 'workspace'}',
      description = raw['description'] as String?,
      argumentHint = raw['argumentHint'] as String?,
      enabled = raw['enabled'] != false;
}

class ConfigOption {
  /// 公开工厂（跨库构建：model-selection.getView 目录装填用）。
  factory ConfigOption.fromMap(Map raw) => ConfigOption._(raw);

  final String id;
  final String name;
  final String category;
  final String type;
  final Object? currentValue;
  final List<ConfigOptionValue> options;

  ConfigOption._(Map raw)
    : id = '${raw['id'] ?? ''}',
      name = '${raw['name'] ?? ''}',
      category = '${raw['category'] ?? ''}',
      type = '${raw['type'] ?? ''}',
      currentValue = raw['currentValue'],
      options = [
        if (raw['options'] is List)
          for (final v in raw['options'] as List)
            if (v is Map) ConfigOptionValue._(v),
      ];
}

class ConfigOptionValue {
  final String value;
  final String name;
  final String? description;
  final String? modelProviderName;

  /// 官方 zcodeSessionSettingsToZCodeConfigOptions 携带的扩展字段：
  /// providerId 用于 switchModelConfig；modelThoughtLevels 供选择模型后
  /// 联动思考档（子代理编辑器 F13 同源消费）。
  final String? modelProviderId;
  final List<String> modelThoughtLevels;

  ConfigOptionValue._(Map raw)
    : value = '${raw['value'] ?? ''}',
      name = '${raw['name'] ?? raw['value'] ?? ''}',
      description = raw['description'] as String?,
      modelProviderName = raw['modelProviderName'] as String?,
      modelProviderId = raw['modelProviderId'] as String?,
      modelThoughtLevels = [
        if (raw['modelThoughtLevels'] is List)
          for (final l in raw['modelThoughtLevels'] as List) '$l',
      ];
}

class SlashCommand {
  final String name;
  final String description;
  final String? inputHint;
  final String source;

  SlashCommand._(Map raw)
    : name = '${raw['name'] ?? ''}',
      description = '${raw['description'] ?? ''}',
      inputHint = raw['inputHint'] as String?,
      source = '${raw['source'] ?? ''}';

  /// 测试用公开构造（内部解析同 [_]）。
  SlashCommand.fromMap(Map raw) : this._(raw);
}

class _LogicalFrameAssembly {
  final int count;
  final List<Uint8List?> parts;
  final DateTime createdAt = DateTime.now();
  int received = 0;

  /// 组装期累计字节上限（开源审查 G3-P3-8）：v4 wire 分片无声明总长，
  /// 取 rpc-frame 逻辑消息同一真源（64MiB）作绝对护栏——畸形分片流不得
  /// 在组装期无界驻留内存。
  static const _maxTotalBytes = RpcFrameTransport.maxMessageBytes;
  int _bytes = 0;
  bool get oversized => _bytes > _maxTotalBytes;

  _LogicalFrameAssembly(this.count) : parts = List.filled(count, null);

  void add(int index, Uint8List data) {
    if (index < 0 || index >= count) return;
    if (parts[index] == null) {
      received += 1;
      _bytes += data.length;
    } else {
      _bytes += data.length - parts[index]!.length;
    }
    parts[index] = data;
  }

  bool get isComplete => received == count;

  Uint8List assemble() {
    final builder = BytesBuilder();
    for (final p in parts) {
      if (p != null) builder.add(p);
    }
    return builder.toBytes();
  }
}

/// Live sessions-index state (task list of a workspace), mirrors the
/// sessions-index subscription in the web client (`QAe` delta application).
class SessionEntry {
  final String sessionId;
  final String? parentSessionId;
  final String title;
  final String phase;
  final String? goalStatus;
  final String? lastAssistantPreview;
  final int lastActivityAt;
  final int createdAt;
  final bool hasBackgroundWork;
  final Map<String, dynamic>? pendingInteraction;
  final Map<String, dynamic> raw;

  SessionEntry(this.raw)
    : sessionId = '${raw['sessionId'] ?? ''}',
      parentSessionId = raw['parentSessionId'] as String?,
      title = '${raw['title'] ?? ''}',
      phase = '${raw['phase'] ?? ''}',
      goalStatus = raw['goalStatus'] as String?,
      lastAssistantPreview = raw['lastAssistantPreview'] as String?,
      lastActivityAt = (raw['lastActivityAt'] as num?)?.toInt() ?? 0,
      createdAt = (raw['createdAt'] as num?)?.toInt() ?? 0,
      hasBackgroundWork = raw['hasBackgroundWork'] == true,
      pendingInteraction = (raw['pendingInteraction'] as Map?)
          ?.cast<String, dynamic>();
}

class SessionsIndexState extends ChangeNotifier {
  String? workspaceId;
  String? logEpoch;
  int seq = 0;
  final Map<String, SessionEntry> sessions = {};
  bool ready = false;

  /// 逐条 upsert 回调（阶段 3 通知差分事件源）：deltas 帧内多条 upsert
  /// 批量应用、帧尾只 notify 一次——聚合监听看不到中间态（如
  /// running→completedSuccess 的 running 帧被同帧合并吞掉，差分漏发）。
  /// 通知协调器挂此回调逐条差分；回调在 ChangeNotifier 通知之前同步调用。
  void Function(SessionEntry entry)? onUpserted;

  List<SessionEntry>? _listCache;

  /// C2（2026-10-19 审查）：排序视图缓存——原 getter 每次 sort+copy 全量
  /// （TaskListModel._rebuild 每 si 通知调用，流式期间每帧一次）。全部
  /// 内部变更点（snapshot 清填/upserted/removed）后必经 notifyListeners，
  /// 在此失效；缓存种子路径（computer_stack 预渲直填 map）发生在任何
  /// 读取之前，无失效遗漏。
  List<SessionEntry> get list {
    final cached = _listCache;
    if (cached != null) return cached;
    final values = sessions.values.toList()
      ..sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
    return _listCache = values;
  }

  @override
  void notifyListeners() {
    _listCache = null;
    super.notifyListeners();
  }

  void applyFrame(
    Map<String, dynamic> frame, {
    required void Function() onGap,
    void Function(String line)? onLog,
  }) {
    final payload = frame['payload'];
    if (payload is! Map) return;
    final toSeq = (frame['toSeq'] as num?)?.toInt() ?? seq;

    if (payload['kind'] == 'snapshot') {
      final snap = (payload['snapshot'] as Map).cast<String, dynamic>();
      workspaceId = snap['workspaceId'] as String?;
      logEpoch = snap['logEpoch'] as String?;
      sessions.clear();
      final list = snap['sessions'];
      if (list is List) {
        for (final s in list) {
          if (s is Map) {
            final entry = SessionEntry(s.cast<String, dynamic>());
            sessions[entry.sessionId] = entry;
          }
        }
      }
      seq = toSeq;
      ready = true;
      onLog?.call('snapshot toSeq=$toSeq sessions=${sessions.length}');
    } else if (payload['kind'] == 'deltas') {
      // 开源审查 G2-P3-13：ack 丢失→桌面按 replay 语义重发整条逻辑消息
      //（新物理 seq 绕过 rpc-frame 的 seq 去重）——重复 delta（toSeq ≤
      // 本地水位）静默丢弃，不误判 gap 触发无谓 forceSnapshot resync
      //（会话订阅 drop-stale 同款语义，ConversationState:drop-stale）。
      if (seq > 0 && toSeq <= seq) {
        onLog?.call('drop-stale delta toSeq=$toSeq local=$seq');
        return;
      }
      final fromSeq = (frame['fromSeq'] as num?)?.toInt() ?? seq;
      if (fromSeq != seq) {
        onLog?.call('gap: fromSeq=$fromSeq local=$seq -> resync');
        onGap();
        return;
      }
      final deltas = payload['deltas'];
      if (deltas is List) {
        for (final d in deltas) {
          if (d is! Map) continue;
          if (d['op'] == 'session.upserted' && d['session'] is Map) {
            final entry = SessionEntry(
              (d['session'] as Map).cast<String, dynamic>(),
            );
            final prev = sessions[entry.sessionId];
            if (prev == null || prev.phase != entry.phase) {
              // 任务卡 phase 迁移时间线（卡 running 根因排查用）
              onLog?.call(
                'upsert ${_shortId(entry.sessionId)} '
                'phase ${prev?.phase ?? '∅'}->${entry.phase}',
              );
            }
            sessions[entry.sessionId] = entry;
            onUpserted?.call(entry);
          } else if (d['op'] == 'session.removed') {
            final removed = sessions.remove('${d['sessionId']}');
            if (removed != null) {
              onLog?.call('removed ${_shortId(removed.sessionId)}');
            }
          }
        }
      }
      seq = toSeq;
      ready = true;
    } else {
      // 开源审查 G1-P3-7/G2-P3-7：未知 kind 不置 ready——旧行为把空
      // sessions 标成就绪（"加载中"变"空列表"），且短路 si 看门狗的
      // `!ready && quiet>=90` 自愈分支；对照 ConversationState 的保守语义
      // `ready = ready || snapshot != null`。打一行漂移信号日志。
      onLog?.call('unknown payload kind: ${payload['kind']}（忽略）');
      return;
    }
    notifyListeners();
  }
}

/// 官方 createRuntimeUnavailableError 错误串（refs zcodeAgentService.ts
/// :938-949"ZCode Agent runtime is not running."）——F1 dormant 判定。
bool isRuntimeUnavailableError(Object e) =>
    '$e'.contains('runtime is not running');

class SessionsIndexSubscription extends _SubscriptionBase<SessionsIndexState> {
  SessionsIndexSubscription._(ConversationTransport transport)
    : _dormant = false,
      super(transport, SessionsIndexState(), 'v4-si');

  SessionsIndexSubscription._dormant(ConversationTransport transport)
    : _dormant = true,
      super(transport, SessionsIndexState(), 'v4-si');

  final bool _dormant;

  @override
  void _onBridgeRecovered() {
    // dormant 占位订阅不自动重订阅（否则冷工作区上会 3s 循环失败）。
    if (_dormant) return;
    super._onBridgeRecovered();
  }

  /// F6/R4：si 订阅此前没有任何看门狗——尾帧丢失则任务卡永久 running，
  /// 只有桥恢复/重开工作区能修。30s 对账：静默 >90s 且仍有 running 条目
  /// → resync；连续 3 轮无帧 → fresh 重订阅。
  DateTime _lastFrameAt = DateTime.now();
  Timer? _watchdog;
  int _resyncSinceFrame = 0;

  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_disposed) return;
      final quiet = DateTime.now().difference(_lastFrameAt).inSeconds;
      // 空快照盲区（2026-10-23 真机"列表永久转圈直到切工作区"）：订阅
      // ack 与快照帧是两步，快照丢失/被 subId 驱逐丢弃时 ready 永远
      // false，而下方对账只在有 running 条目时触发——空状态无人重试。
      // 快照静默 >90s 仍未 ready → 直接重订阅（resync 对未 ready 的
      // 订阅无意义，快照只会随订阅重放到达）。
      if (!state.ready && quiet >= 90) {
        _transport._log(
          '[si-wd] no snapshot for ${quiet}s (not ready), resubscribe',
        );
        _resyncSinceFrame = 0;
        if (_subscriptionId != null) unawaited(_resubscribe());
        return;
      }
      final anyRunning = state.sessions.values.any(
        (s) => s.phase == 'running' || s.phase == 'prewarming',
      );
      if (quiet < 90 || !anyRunning) return;
      if (_resyncSinceFrame >= 3) {
        _transport._log(
          '[si-wd] quiet=${quiet}s with running entries, escalate to resubscribe',
        );
        _resyncSinceFrame = 0;
        if (_subscriptionId != null) unawaited(_resubscribe());
        return;
      }
      _resyncSinceFrame++;
      _transport._log('[si-wd] quiet=${quiet}s with running entries, resync');
      _resync();
    });
  }

  @override
  String get _frameEventName => 'onDynamicSessionsIndexFrame';
  @override
  String get _subscribeMethod => 'subscribeSessionsIndexV4';
  @override
  String get _unsubscribeMethod => 'unsubscribeSessionsIndexV4';
  @override
  String get _resyncMethod => 'resyncSessionsIndexV4';
  @override
  Map<String, dynamic> get _subscribeArgs => const {
    'runtimePolicy': 'existing-only',
  };
  @override
  Map<String, dynamic> get _unsubscribeArgs => const {
    'runtimePolicy': 'existing-only',
  };
  @override
  Map<String, dynamic> get _resyncArgs => const {
    'runtimePolicy': 'existing-only',
  };
  @override
  String get topic =>
      'sessions-index/${_transport.scope['workspaceIdentity'] ?? _transport.scope['workspacePath']}';
  @override
  int get _resyncSeq => state.seq;
  @override
  String? get _resyncEpoch => state.logEpoch;

  @override
  void _onStarted() {
    _startWatchdog();
  }

  @override
  Future<void> _onDispose() async {
    _watchdog?.cancel();
    state.dispose();
  }

  @override
  void _acceptLogicalFrame(Map<String, dynamic> frame) {
    final subId = subscriptionId;
    if (subId == null || frame['subscriptionId'] != subId) {
      if (subId != null && frame['subscriptionId'] is String) {
        _foreignSubDrops++;
        if (_foreignSubDrops == 1 || _foreignSubDrops % 20 == 0) {
          _transport._log(
            '[$_logTag] dropping frames with foreign subId '
            '(count=$_foreignSubDrops)',
          );
        }
      }
      return;
    }
    _lastFrameAt = DateTime.now();
    _resyncSinceFrame = 0;
    _foreignSubDrops = 0;
    _notOwnedEscalations = 0;
    try {
      state.applyFrame(
        frame,
        onGap: _resync,
        onLog: (line) => _transport._log('[si-tl] $line'),
      );
    } catch (e) {
      _transport._log('[$_logTag] applyFrame failed: $e');
      _resync();
    }
  }
}

/// controller/tasks-index 地址键（官方 windowControllerTaskListRegistry.
/// taskAddressKey 同构）：remoteSessionId（本地源=local）| 工作区键
/// （workspaceIdentity 优先）| taskId。remote 重连换代 remoteSessionId
/// 即换键——投影以新地址行替换旧行。
String? tasksIndexAddressKey(Map<String, dynamic> address) {
  final taskId = '${address['taskId'] ?? ''}'.trim();
  if (taskId.isEmpty) return null;
  final remote = '${address['remoteSessionId'] ?? 'local'}';
  final workspace =
      '${address['workspaceIdentity'] ?? address['workspacePath'] ?? ''}';
  return '$remote|$workspace|$taskId';
}

String? tasksIndexRowKey(Map<String, dynamic> row) {
  final address = row['address'];
  if (address is! Map) return null;
  return tasksIndexAddressKey(address.cast<String, dynamic>());
}

/// controller/tasks-index 主题状态：窗口级任务投影（官方
/// windowHostControllerProjection——窗口聚合本地+remote 全部 source 的
/// 任务行；归档行留在主题内带 membership.archived=true，已删除行从不
/// 出现——删除以 task.removed delta 表达）。
///
/// 与 si 主题的关键差异（ADR 0031）：**无 base 续传**——subscribe/resync
/// 永远整快照重放（projection.ts:509-547 mode 恒 "snapshot"）；seq 按帧
/// 计数（每帧恰好 +1）；logEpoch 随桌面 Host 进程换代（换代即 gap）。
class TasksIndexState extends ChangeNotifier {
  /// address key → 官方 TaskRow（address/meta/membership/
  /// sourceAvailability/liveStatus/activity?/searchSnippets?，
  /// schema 见 refs controller.ts:90-123）。
  final Map<String, Map<String, dynamic>> rows = {};

  String? subscriptionId;
  String? logEpoch;
  int seq = -1;

  bool get hasSnapshot => logEpoch != null;
  List<Map<String, dynamic>> get list => rows.values.toList();

  /// 应用一帧。返回 (applied, gap, removedIds)：
  /// - snapshot：无条件整表替换并重置游标（官方 registry 快照路径
  ///   :153-158 同款——旧数据不可信，不做合并）；
  /// - deltas：gap（subId/logEpoch 换代或 fromSeq 断档，官方
  ///   isWindowHostControllerFrameGap 语义）→ 不动状态返回 gap=true，由
  ///   调用方 forceSnapshot resync；否则**先应用全部 upsert 再应用
  ///   removal**——同批重新 upsert 的 taskId 不算移除（remote 重连=旧
  ///   地址删+新地址加同帧发出，projection.ts:384-418；误报移除会让
  ///   上层把卡片压进 60s 本地墓碑）。
  ({bool applied, bool gap, List<String> removedIds}) applyFrame(
    Map<String, dynamic> frame,
  ) {
    final payload = frame['payload'];
    if (payload is! Map)
      return (applied: false, gap: false, removedIds: const []);
    final frameSubId = '${frame['subscriptionId'] ?? ''}';
    final frameEpoch = '${frame['logEpoch'] ?? ''}';
    final fromSeq = (frame['fromSeq'] as num?)?.toInt() ?? -1;
    final toSeq = (frame['toSeq'] as num?)?.toInt() ?? -1;
    final kind = payload['kind'];
    if (kind == 'snapshot') {
      final snap = payload['snapshot'];
      final tasks = snap is Map ? snap['tasks'] : null;
      rows.clear();
      if (tasks is List) {
        for (final t in tasks.whereType<Map>()) {
          final row = t.cast<String, dynamic>();
          final key = tasksIndexRowKey(row);
          if (key != null) rows[key] = row;
        }
      }
      subscriptionId = frameSubId;
      logEpoch = frameEpoch;
      seq = toSeq;
      if (rows.isNotEmpty) {
        // 漂移哨兵：快照首行抽查骨架字段（ADR 0033）。
        noteProtocolDrift('tasks-index.snapshot.row', rows.values.first, [
          'address',
          'meta',
          'membership',
          'liveStatus',
        ]);
      }
      notifyListeners();
      return (applied: true, gap: false, removedIds: const []);
    }
    if (kind == 'deltas') {
      // 开源审查 G2-P3-13：重复逻辑帧（ack 丢失后桌面 replay，新物理 seq
      // 绕过 rpc-frame 去重）静默丢弃——toSeq ≤ 本地水位即陈旧，不误判
      // gap 触发 forceSnapshot resync 风暴。
      if (toSeq <= seq) {
        return (applied: false, gap: false, removedIds: const []);
      }
      // 开源审查 G2-P3-16：帧顶 logEpoch 缺席时不参与 gap 判定（只按
      // subId+seq）——epoch 换代必有 seq 断档兜底；若按 ''!='epoch' 恒真
      // 判 gap，桌面一旦省略该字段即每条 delta 触发 resync 风暴。哨兵
      // 留痕（ADR 0033）。
      final frameEpochRaw = frame['logEpoch'];
      if (frameEpochRaw == null) {
        noteProtocolDrift('tasks-index.delta', frame, ['logEpoch']);
      }
      if (frameSubId != (subscriptionId ?? '') ||
          (frameEpochRaw != null && frameEpoch != (logEpoch ?? '')) ||
          fromSeq != seq) {
        return (applied: false, gap: true, removedIds: const []);
      }
      final deltas = payload['deltas'];
      var changed = false;
      final upsertedIds = <String>{};
      final removed = <String>[];
      if (deltas is List) {
        for (final d in deltas.whereType<Map>()) {
          if (d['op'] != 'task.upserted') continue;
          final task = d['task'];
          if (task is! Map) continue;
          final row = task.cast<String, dynamic>();
          final key = tasksIndexRowKey(row);
          if (key == null) continue;
          rows[key] = row;
          final address = row['address'];
          upsertedIds.add(address is Map ? '${address['taskId'] ?? ''}' : '');
          changed = true;
        }
        for (final d in deltas.whereType<Map>()) {
          if (d['op'] != 'task.removed') continue;
          final address = d['address'];
          if (address is! Map) continue;
          final key = tasksIndexAddressKey(address.cast<String, dynamic>());
          final row = key == null ? null : rows.remove(key);
          if (row != null) {
            changed = true;
            final id = rowTaskId(row);
            if (id.isNotEmpty && !upsertedIds.contains(id)) {
              removed.add(id);
            }
          }
        }
      }
      seq = toSeq;
      if (changed) notifyListeners();
      return (applied: changed, gap: false, removedIds: removed);
    }
    return (applied: false, gap: false, removedIds: const []);
  }
}

String rowTaskId(Map<String, dynamic> row) {
  final address = row['address'];
  if (address is Map) {
    final id = '${address['taskId'] ?? ''}'.trim();
    if (id.isNotEmpty) return id;
  }
  final meta = row['meta'];
  if (meta is Map) return '${meta['taskId'] ?? ''}'.trim();
  return '';
}

/// controller/tasks-index 订阅（window-controller 通道，官方
/// IWindowControllerService：subscribeControllerV4/resyncControllerV4/
/// onDynamicControllerFrame）。帧**不经 v4 wire 包装**（与 si 不同）——
/// 事件载荷即帧信封；大快照由 bridge rpc-frame 层（RpcFrameTransport，
/// 64MiB）透明分片重组，无需手动拼片（ADR 0031 调查 3）。
class TasksIndexSubscription extends _SubscriptionBase<TasksIndexState> {
  TasksIndexSubscription._(ConversationTransport transport)
    : super(transport, TasksIndexState(), 'tasks-index');

  /// 开源审查批B组2（G1 P2-4/G2 P2-4）：tasks-index 此前是三个订阅类中
  /// 唯一没有静默看门狗的——si 有 F6/R4 先例（2026-10-23"尾帧丢失则任务
  /// 卡永久 running"），tasks-index 作为现行主任务数据源反而裸奔：帧丢失
  /// 自愈只有"后续帧 fromSeq 断档暴露 gap"一条路，丢的是最后一帧/订阅被
  /// 服务端静默驱逐后无新帧时，任务列表永久冻结在旧水位直到桥恢复事件。
  /// 30s 对账（si 同款思路，静默阈值同为 90s——本主题变化频率低）：
  /// - 快照静默 >90s 仍未到达（hasSnapshot 恒假）→ fresh 重订阅（快照只
  ///   随订阅重放，resync 对未就绪投影无意义）；
  /// - 静默 >90s 且仍有 running 行 → forceSnapshot resync；
  /// - 连续 3 轮无帧 → 升级 fresh 重订阅。
  DateTime _lastFrameAt = DateTime.now();
  Timer? _watchdog;
  int _resyncSinceFrame = 0;

  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_disposed || _parked) return;
      final quiet = DateTime.now().difference(_lastFrameAt).inSeconds;
      if (!state.hasSnapshot && quiet >= 90) {
        _transport._log(
          '[tasks-index-wd] no snapshot for ${quiet}s (not ready), resubscribe',
        );
        _resyncSinceFrame = 0;
        if (_subscriptionId != null) unawaited(_resubscribe());
        return;
      }
      final anyRunning = state.rows.values.any(
        (r) => '${r['liveStatus'] ?? ''}' == 'running',
      );
      if (quiet < 90 || !anyRunning) return;
      if (_resyncSinceFrame >= 3) {
        _transport._log(
          '[tasks-index-wd] quiet=${quiet}s with running rows, '
          'escalate to resubscribe',
        );
        _resyncSinceFrame = 0;
        if (_subscriptionId != null) unawaited(_resubscribe());
        return;
      }
      _resyncSinceFrame++;
      _transport._log(
        '[tasks-index-wd] quiet=${quiet}s with running rows, resync',
      );
      _resync();
    });
  }

  /// 同批未被重新 upsert 的 task.removed taskId（≈删除或投影重建）。
  /// 上层职责：本地 60s 墓碑 + 去抖重拉三列表收敛持久事实——
  /// **task.removed≠删除**（remote 重连/投影重建也发，ADR 0031 调查 7），
  /// 不得直接进 deletedIds。
  void Function(List<String> removedTaskIds)? onRowsRemoved;

  @override
  String get _frameEventName => 'onDynamicControllerFrame';
  @override
  String get _subscribeMethod => 'subscribeControllerV4';
  @override
  String get _unsubscribeMethod => 'unsubscribeControllerV4';
  @override
  String get _resyncMethod => 'resyncControllerV4';
  @override
  Map<String, dynamic> get _subscribeArgs => const {
    'topic': 'controller/tasks-index',
    // 官方 registry 同款（foreground）——窗口级主题无 runtime 拉起语义，
    // 该参数只影响服务端活动度采集。
    'visibility': 'foreground',
  };
  @override
  Map<String, dynamic> get _resyncArgs => const {'forceSnapshot': true};
  @override
  Map<String, dynamic> get _unsubscribeArgs => const {};
  @override
  String get topic => 'controller/tasks-index';
  @override
  String get _channel => Channels.windowController;
  @override
  Map<String, dynamic> get _wireScope => const {};
  @override
  bool get _requiresConversationHandshake => false;
  @override
  bool get _usesV4WireWrapper => false;
  @override
  int get _resyncSeq => state.seq;
  @override
  String? get _resyncEpoch => state.logEpoch;

  @override
  void _onStarted() {
    _startWatchdog();
  }

  @override
  Future<void> _onDispose() async {
    _watchdog?.cancel();
    state.dispose();
  }

  @override
  void _acceptLogicalFrame(Map<String, dynamic> frame) {
    final subId = subscriptionId;
    if (subId != null && frame['subscriptionId'] != subId) {
      _foreignSubDrops++;
      if (_foreignSubDrops == 1 || _foreignSubDrops % 20 == 0) {
        _transport._log(
          '[$_logTag] dropping frames with foreign subId '
          '(count=$_foreignSubDrops)',
        );
      }
      return;
    }
    _lastFrameAt = DateTime.now();
    _resyncSinceFrame = 0;
    _foreignSubDrops = 0;
    _notOwnedEscalations = 0;
    try {
      final result = state.applyFrame(frame);
      if (result.gap) {
        _transport._log(
          '[$_logTag] gap (seq=${state.seq} epoch=${state.logEpoch}) '
          '-> forceSnapshot resync',
        );
        unawaited(_resync());
        return;
      }
      if (result.removedIds.isNotEmpty) {
        onRowsRemoved?.call(result.removedIds);
      }
    } catch (e) {
      _transport._log('[$_logTag] applyFrame failed: $e');
      unawaited(_resync());
    }
  }
}

String _shortId(String id) => id.length <= 8 ? id : id.substring(0, 8);

/// Conversation snapshot + row state, mirrors `fke()`/`pke()` delta
/// application in the web client.
/// rowsRange 是否仍可合并到发起请求时的那份会话投影。
/// 官方 conversationProjectionStore.loadOlder：响应 atLogEpoch 必须匹配
/// 当前 epoch，且在途期间窗口首行游标变化（快照替换/行截断）则整页作废。
bool shouldAcceptOlderRows({
  required String? requestLogEpoch,
  required String? currentLogEpoch,
  required String? responseLogEpoch,
  required int? requestCursor,
  required int? currentCursor,
}) {
  if (requestLogEpoch == null || requestLogEpoch != currentLogEpoch) {
    return false;
  }
  if (responseLogEpoch == null || responseLogEpoch != currentLogEpoch) {
    return false;
  }
  return requestCursor != null && requestCursor == currentCursor;
}

class ConversationState extends ChangeNotifier {
  Map<String, dynamic>? snapshot;
  List<Map<String, dynamic>> rows = [];
  int seq = 0;
  String? logEpoch;
  int? firstRowId;
  int totalCount = 0;
  bool ready = false;
  bool historyExhausted = false;

  /// 投影失效版本（R1-part2，2026-10-17）：applyFrame 每次 effective
  /// 应用后递增。deltas 路径对 rows 是原地变更（rows.add/rows[i]=），
  /// 页面的引用级记忆化（identical）永远不会失效——流式增量全部
  /// 不触发重投影，页面冻结在初始快照（真机"回复不可见，重进才见"）。
  int dataVersion = 0;

  /// 应用缓存种子（阶段 3）：把本地缓存的一致投影装进本订阅状态——
  /// 页面立即有内容（不等首快照），且订阅携带的 base 与此严格一致
  ///（官方水位不变量）。首个快照到达时整体替换（R6 同规则）。
  void applySeed(ConversationSeed seed) {
    rows = List<Map<String, dynamic>>.of(seed.rows);
    logEpoch = seed.logEpoch;
    seq = seed.seq;
    firstRowId = seed.firstRowId;
    totalCount = seed.totalCount;
    snapshot = seed.snapshot == null
        ? null
        : Map<String, dynamic>.of(seed.snapshot!);
    ready = true;
    dataVersion++;
    notifyListeners();
  }

  void applyFrame(
    Map<String, dynamic> frame, {
    required void Function() onGap,
    void Function(String line)? onLog,
  }) {
    final payload = frame['payload'];
    if (payload is! Map) return;
    final toSeq = (frame['toSeq'] as num?)?.toInt() ?? seq;

    // 规范 §2.4 三分支之二：deltas 的 toSeq <= 本地 seq ⇒ 迟到/重复帧
    // 静默丢弃（不丢弃会把流式文本重复拼接）。
    // R6（官方 conversationProjectionStore 规则1对齐，2026-10-16）：
    // **snapshot 永远整体替换、不做 seq 守门**——服务端 rehydrate/
    // replacement 会把 sentSeq 清 0，旧规则会把 recovery 快照当 stale
    // 丢弃（审计 P3 路径：phase 卡 running 的候选根因之一）。
    // _applySnapshot 自带旧 rows 合并，分页历史不丢。
    final isSnapshot = payload['kind'] == 'snapshot';
    String? frameEpoch;
    if (isSnapshot) {
      final snap = payload['snapshot'];
      frameEpoch = snap is Map ? snap['logEpoch'] as String? : null;
    }
    if (!isSnapshot &&
        seq > 0 &&
        toSeq <= seq &&
        (frameEpoch == null || frameEpoch == logEpoch)) {
      onLog?.call('drop-stale delta toSeq=$toSeq local=$seq epoch=$frameEpoch');
      return;
    }

    if (isSnapshot) {
      final phaseBefore = phase;
      final snap = (payload['snapshot'] as Map).cast<String, dynamic>();
      _applySnapshot(snap, toSeq, onLog);
      ready = true;
      onLog?.call(
        'snapshot epoch=${snap['logEpoch']} toSeq=$toSeq '
        'rows=${rows.length} phase $phaseBefore->${phase}',
      );
    } else if (payload['kind'] == 'deltas') {
      final fromSeq = (frame['fromSeq'] as num?)?.toInt() ?? seq;
      if (fromSeq != seq) {
        onLog?.call('gap: fromSeq=$fromSeq local=$seq -> resync');
        onGap();
        return;
      }
      final phaseBefore = phase;
      final deltas = payload['deltas'];
      final ops = deltas is List
          ? (deltas.whereType<Map>().map((d) => '${d['op']}').join(','))
          : '';
      var controlPatch = false;
      if (deltas is List) {
        for (final d in deltas) {
          if (d is Map && d['op'] == 'state.updated') {
            final patch = d['patch'];
            controlPatch =
                controlPatch || patch is Map && patch['control'] != null;
          }
        }
      }
      if (deltas is List) {
        for (final d in deltas) {
          if (d is Map) _applyDelta(d.cast<String, dynamic>());
        }
        // C3：帧尾统一物化追加缓冲（notifyListeners 前，UI 只见终值）。
        _flushAllAppends();
      }
      seq = toSeq;
      // ready = 已收到首个快照；patch-only 帧先到时保持加载态
      ready = ready || snapshot != null;
      onLog?.call(
        'delta seq $fromSeq->$toSeq ops=[$ops]'
        '${controlPatch ? " phase $phaseBefore->${phase}" : ""}',
      );
    }
    dataVersion++;
    notifyListeners();
  }

  /// [onLog]：形状哨兵输出（真机 2026-10-22/23「对话历史丢失」取证——
  /// 巨型快照分片/协议演进下 rows 结构缺席时，旧实现把 rows/totalCount/
  /// firstRowId 全部清零，后续 row.appended 又把 firstRowId 设成本轮
  /// turnHeader——canLoadOlder 永假，「加载更早消息」入口消失，列表
  /// 最老行停在本轮用户消息。协议语义（refs publisher:340-369）：window
  /// 缺席属异常帧，不是"空会话"（空会话的 window 是空 List）。
  ///
  /// window 在场时**整体替换**（官方 conversationProjectionStore 规则 1：
  /// snapshot 永远整体替换）。曾实现为"保留比快照首行更老的已有行再拼接"
  /// ——重订阅带着滚出服务端保留窗的陈旧水位时（refs subscribeReserved：
  /// base.seq<floorSeq 只能改发快照），旧段与尾窗之间未拉取的中间行凭空
  /// 蒸发，列表呈现"心跳提示下面直接接最终回复"的问答错位（2026-10-23
  /// 用户二次实锤）。快照即权威：替换后 canLoadOlder 依快照游标重判，
  /// 更早历史经 rowsRange 重新翻页。
  void _applySnapshot(
    Map<String, dynamic> snap,
    int toSeq, [
    void Function(String line)? onLog,
  ]) {
    snapshot = snap;
    if (_pendingPatch != null) {
      snapshot = {...snap, ..._pendingPatch!};
      _pendingPatch = null;
    }
    seq = toSeq;
    logEpoch = snap['logEpoch'] as String?;
    final rowsObj = snap['rows'];
    if (rowsObj is Map) {
      final window = rowsObj['window'];
      if (window is List) {
        final windowRows = window
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
        rows = windowRows;
        totalCount = (rowsObj['totalCount'] as num?)?.toInt() ?? rows.length;
        firstRowId = (rowsObj['firstRowId'] as num?)?.toInt() ?? firstRowId;
        // 分页到顶态随新快照失效：窗口头 ≠ firstRowId 说明还有更早历史，
        // 入口必须重新露出（旧值来自被替换投影的 rowsRange 终局）。
        historyExhausted = false;
      } else {
        // 形状异常：保留既有 rows/计数，等下一帧修正——清零会让
        // canLoadOlder 永假（历史入口消失，2026-10-23 真机实锤）。
        onLog?.call('[snapshot-shape] rows.window missing; rows kept');
      }
    } else {
      onLog?.call('[snapshot-shape] rows object missing; rows kept');
    }
  }

  void _applyDelta(Map<String, dynamic> delta) {
    switch (delta['op']) {
      case 'row.appended':
        // C3：非 row.delta 的行操作前先物化缓冲——保序（缓冲中的追加
        // 在时序上先于本操作，必须落在被替换/移除前的旧行上）。
        _flushAllAppends();
        final row = (delta['row'] as Map).cast<String, dynamic>();
        rows.add(row);
        totalCount += 1;
        // 全序游标只在"从零建会话"（首行同时是全会话最老行）时由首行
        // 充当——快照必带 firstRowId；缓存种子/异常快照后的追加行
        // 不许冒充（旧实现无条件 ??=，历史入口就此永久消失，
        // 2026-10-23 真机实锤）。
        if (rows.length == 1 && totalCount == 1) {
          firstRowId ??= (row['rowId'] as num?)?.toInt();
        }
        break;
      case 'row.upserted':
        _flushAllAppends();
        final row = (delta['row'] as Map).cast<String, dynamic>();
        final id = (row['rowId'] as num?)?.toInt();
        final index = rows.indexWhere(
          (r) => (r['rowId'] as num?)?.toInt() == id,
        );
        if (index != -1) rows[index] = row;
        break;
      case 'row.removed':
        _flushAllAppends();
        // Mirrors `fke()` in the web client: KEEP rows with
        // rowId < fromRowId (i.e. remove rows >= fromRowId).
        final fromRowId = (delta['fromRowId'] as num?)?.toInt() ?? 0;
        final kept = rows
            .where((r) => ((r['rowId'] as num?)?.toInt() ?? 0) < fromRowId)
            .toList();
        final removed = rows.length - kept.length;
        rows = kept;
        if (firstRowId != null && fromRowId <= firstRowId!) {
          totalCount = 0;
          firstRowId = null;
        } else {
          totalCount = (totalCount - removed).clamp(0, 1 << 31);
        }
        break;
      case 'row.delta':
        // C3（2026-10-19 审查）：追加只进缓冲，帧尾/干扰操作前统一物化。
        // 原实现每 delta 全串重拼（'${old}$append' O(n²)）+整 map 拷贝；
        // 流式期间 UI 每帧只消费终值，帧内中间串无人读取。path/kind 的
        // 忽略规则在物化时执行（见 _materializeAppend），时序等价由
        // 干扰操作前的 flush 保证（对拍测试见 reducer_append_test.dart）。
        final rowId = (delta['rowId'] as num?)?.toInt();
        if (rowId == null) break;
        final append = delta['append'] as String? ?? '';
        if (append.isEmpty) break;
        final path = delta['path'] as String? ?? '';
        _appendBufs
            .putIfAbsent(rowId, () => {})
            .putIfAbsent(path, () => StringBuffer())
            .write(append);
        break;
      case 'state.updated':
        final patch = delta['patch'];
        if (patch is Map) {
          if (snapshot != null) {
            snapshot = {...snapshot!, ...patch.cast<String, dynamic>()};
          } else {
            // Patch arrived before the initial snapshot — buffer and
            // merge when the snapshot lands (otherwise config/queue/
            // control updates are silently lost).
            _pendingPatch = {
              ...?_pendingPatch,
              ...patch.cast<String, dynamic>(),
            };
          }
        }
        break;
    }
  }

  Map<String, dynamic>? _pendingPatch;

  // C3：追加缓冲（rowId → path → StringBuffer）。
  final Map<int, Map<String, StringBuffer>> _appendBufs = {};

  void _flushAllAppends() {
    if (_appendBufs.isEmpty) return;
    for (final id in _appendBufs.keys.toList()) {
      _flushRowAppends(id);
    }
  }

  void _flushRowAppends(int rowId) {
    final bufs = _appendBufs.remove(rowId);
    if (bufs == null) return;
    final index = rows.indexWhere(
      (r) => (r['rowId'] as num?)?.toInt() == rowId,
    );
    if (index == -1) return; // 行已不存在——追加丢弃（原逐条语义同）
    var row = rows[index];
    for (final e in bufs.entries) {
      row = _materializeAppend(row, e.key, e.value.toString());
    }
    rows[index] = row;
  }

  /// 与原 `_appendToRow` 同一规则：仅特定 kind×path 生效，其余忽略。
  Map<String, dynamic> _materializeAppend(
    Map<String, dynamic> row,
    String path,
    String append,
  ) {
    switch (path) {
      case 'text':
        if (row['kind'] == 'assistantText' || row['kind'] == 'reasoning') {
          return {...row, 'text': '${row['text'] ?? ''}$append'};
        }
        return row;
      case 'inputText':
        if (row['kind'] == 'toolCall') {
          return {...row, 'inputText': '${row['inputText'] ?? ''}$append'};
        }
        return row;
      case 'output.text':
        if (row['kind'] == 'toolCall' && row['output'] is Map) {
          final output = (row['output'] as Map).cast<String, dynamic>();
          return {
            ...row,
            'output': {...output, 'text': '${output['text'] ?? ''}$append'},
          };
        }
        return row;
      case 'summaryText':
        if (row['kind'] == 'subagent') {
          return {...row, 'summaryText': '${row['summaryText'] ?? ''}$append'};
        }
        return row;
      default:
        return row;
    }
  }

  /// Optimistic local update (command already accepted; the confirming
  /// `state.updated` frame may lag). Merges into snapshot immediately.
  ///
  /// F2（2026-10-19 核销防守注释）：本组 optimistic* 只 notifyListeners
  /// **不递增 dataVersion**——刻意语义：它们不改变投影输入（rows 不进
  /// 快照投影 / snapshot 字段非投影键），页面引用级记忆化不需要失效。
  /// 若未来让 optimistic 变更进入投影消费的行数据，必须同步递增
  /// dataVersion（reducer_append_test.dart 有 dataVersion 不变式断言钉住
  /// 当前行为——改动它会先红）。
  void optimisticPatch(Map<String, dynamic> patch) {
    if (snapshot == null) return;
    snapshot = {...snapshot!, ...patch};
    notifyListeners();
  }

  /// Optimistic row edit (e.g. feedback) — mutates the row in place and
  /// notifies; the server row.upserted will confirm.
  void optimisticRowUpdate(num? rowId, Map<String, dynamic> patch) {
    final index = rows.indexWhere(
      (r) => (r['rowId'] as num?)?.toInt() == rowId?.toInt(),
    );
    if (index == -1) return;
    rows[index] = {...rows[index], ...patch};
    notifyListeners();
  }

  /// Optimistic queue removal (sendQueuedNow / deleteQueueItem accepted).
  void optimisticRemoveQueueItem(String queueItemId) {
    final q = queue;
    if (q == null) return;
    final items = (q['items'] as List?)
        ?.where((i) => i is Map && '${i['queueItemId']}' != queueItemId)
        .toList();
    snapshot = {
      ...snapshot!,
      'queue': {...q, 'items': items ?? []},
    };
    notifyListeners();
  }

  Map<String, dynamic>? get control =>
      (snapshot?['control'] as Map?)?.cast<String, dynamic>();

  /// Current conversation revision (CAS commands base this on).
  int get revision => (snapshot?['revision'] as num?)?.toInt() ?? 0;

  String get phase => control?['phase'] as String? ?? '';

  bool get canStop => control?['canStop'] == true;

  bool get isRunning => phase == 'running' || phase == 'prewarming';

  /// Session config: {provider, model, thought, thoughtLevels, followupMode,
  /// mode}.
  Map<String, dynamic>? get config =>
      (snapshot?['config'] as Map?)?.cast<String, dynamic>();

  /// 乐观写回（A3+A5 修复批 2026-10-24）：命令 accepted 即把提交值写进
  /// 本地 config 快照（官方 draft 语义）——UI 立即反映最终值，服务端
  /// config 回显同值零闪烁；桌面端外部改档由后续 patch 覆盖 config，
  /// 药丸自然跟随（替代永不失效的 _appliedMode）。快照整体替换语义
  /// 不受影响（写回值与回显一致，替换后无跳变）。
  /// 返回是否落笔——快照未就绪返回 false，调用方保留挂起值作显示
  /// 载体（等 config 回显/水位清理，不闪回旧值）。
  bool writeBackConfig(Map<String, dynamic> values) {
    final snap = snapshot;
    if (snap == null || values.isEmpty) return false;
    final cfg = snap['config'];
    if (cfg is Map) {
      for (final e in values.entries) {
        cfg[e.key] = e.value;
      }
    } else {
      snap['config'] = Map<String, dynamic>.of(values);
    }
    dataVersion++;
    notifyListeners();
    return true;
  }

  String get currentModel => config?['model'] as String? ?? '';
  String get currentThought => config?['thought'] as String? ?? '';
  String get currentMode => config?['mode'] as String? ?? 'build';
  List<String> get thoughtLevels => config?['thoughtLevels'] is List
      ? (config!['thoughtLevels'] as List).map((e) => '$e').toList()
      : const [];

  /// Held queue: {items: [...], autoDrain}.
  Map<String, dynamic>? get queue =>
      (snapshot?['queue'] as Map?)?.cast<String, dynamic>();

  List<Map<String, dynamic>> get queueItems {
    final items = queue?['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
  }

  bool get autoDrain => queue?['autoDrain'] != false;

  /// Token usage: {contextWindow: {usedTokens, maxTokens, ...}?, cumulative}.
  Map<String, dynamic>? get usage =>
      (snapshot?['usage'] as Map?)?.cast<String, dynamic>();

  /// Older history exists beyond the current window.
  ///
  /// 官方判据（refs conversation-topic-publisher.ts:342 注释）：客户端以
  /// `window[0].rowId === firstRowId` 判定已到顶。到顶判据之外
  /// firstRowId 未知（老缓存种子/异常快照后）也允许加载——按钮露出后
  /// 由 rowsRange 的 hasMore 给出终局（2026-10-23「对话历史丢失」回归：
  /// 旧实现只看 totalCount>rows.length，任何一处计数损坏都会把入口
  /// 永久藏起，列表最老行冻结在本轮用户消息）。
  bool get canLoadOlder {
    if (historyExhausted || rows.isEmpty) return false;
    final first = firstRowId;
    if (first == null) return true;
    final oldest = (rows.first['rowId'] as num?)?.toInt();
    if (oldest == null) return true;
    if (oldest != first) return true;
    return totalCount > rows.length;
  }

  /// The cursor for `rowsRange` is the oldest row currently held, not the
  /// snapshot projection head (`firstRowId`).
  int? get oldestRowId =>
      rows.isEmpty ? firstRowId : (rows.first['rowId'] as num?)?.toInt();

  /// Prepends older rows loaded via rowsRange (deduped by rowId).
  /// [hasMore]：服务端终局信号（refs getRowsRange:498）——false 表示
  /// 已到会话顶，此后不再露出加载入口；null（旧服务端/未返回）按
  /// 计数判据兜底。
  void prependOlderRows(
    List<Map<String, dynamic>> older,
    int? newFirstRowId, {
    bool? hasMore,
  }) {
    final existing = rows.map((r) => (r['rowId'] as num?)?.toInt()).toSet();
    final fresh = older
        .where((r) => !existing.contains((r['rowId'] as num?)?.toInt()))
        .toList();
    if (fresh.isNotEmpty) {
      rows = [...fresh, ...rows];
      final firstFresh = (fresh.first['rowId'] as num?)?.toInt();
      firstRowId = newFirstRowId ?? firstFresh ?? firstRowId;
      notifyListeners();
    } else if (newFirstRowId != null && newFirstRowId != firstRowId) {
      firstRowId = newFirstRowId;
      notifyListeners();
    }
    // 空页且服务端没说还有更多＝到顶（也兜住 hasMore 异常真值的自旋）。
    if (hasMore == false || (fresh.isEmpty && hasMore != true)) {
      if (!historyExhausted) {
        historyExhausted = true;
        notifyListeners();
      }
    }
  }

  List<Map<String, dynamic>> get backgroundWorks {
    final list = snapshot?['backgroundWorks'];
    if (list is! List) return const [];
    return list.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  Map<String, dynamic>? get goal =>
      (snapshot?['goal'] as Map?)?.cast<String, dynamic>();

  Map<String, dynamic>? get plan =>
      (snapshot?['plan'] as Map?)?.cast<String, dynamic>();

  /// inputRouting: {mode: startNow|enqueue|guide|reject|choice, reasonCode?}
  String get inputRoutingMode =>
      (snapshot?['inputRouting'] as Map?)?['mode'] as String? ?? 'startNow';

  List<Map<String, dynamic>> get pendingInteractions {
    final list = snapshot?['pendingInteractions'];
    if (list is! List) return const [];
    return list.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }
}

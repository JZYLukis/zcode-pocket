import 'dart:async';

import 'demo_bridge.dart';
import 'demo_channel.dart';
import 'demo_data.dart';
import 'demo_mode.dart';

/// 演示脚本：把 [demo_data] 的静态数据与「活」行为装进 [DemoChannel]。
///
/// 职责三块：
/// 1. 静态 RPC——各类只读查询直接回数据集；
/// 2. 订阅生命周期——subscribe ack + 快照帧推送（si/tasks-index/会话），
///    真实订阅状态机（看门狗/resync/CAS）在其上运行；
/// 3. 流式重放——sendText/createSession/审批解析按时间线推 delta 帧
///    （打字机节奏），首页 si/tasks-index 同步跟拍，演示「活的」会话。
class DemoScript {
  DemoScript(this.bridge) {
    _registerStaticHandlers();
  }

  final DemoBridge bridge;
  DemoChannel get channel => bridge.channel;

  int _subCounter = 0;
  int _newSessionCounter = 0;

  /// 会话订阅：sessionId → 订阅 ID 与当前 seq 水位。
  final Map<String, String> _convSubIds = {};
  final Map<String, int> _convSeq = {};

  /// si / tasks-index 订阅（单工作区，各至多一个活跃订阅）。
  String? _siSubId;
  int _siSeq = 0;
  String? _ctrlSubId;
  int _ctrlSeq = 0;

  /// 可变任务态（首页操作与流式跟拍的真源，从数据集种子化）。
  late final List<Map<String, dynamic>> _tasks = demoTasksIndexRows();
  final Map<String, Map<String, dynamic>> _siSessions = {
    for (final s
        in (demoSessionsIndexSnapshot()['sessions'] as List).cast<Map<String, dynamic>>())
      '${s['sessionId']}': s,
  };
  final Map<String, Map<String, dynamic>> _snapshots = {
    ...demoConversationSnapshots(),
  };

  /// 每会话的流式重放（stop 可中断）。
  final Map<String, _LiveReplay> _replays = {};
  final Set<Timer> _timers = {};

  void _registerStaticHandlers() {
    final h = channel.rpcHandlers;
    void reg(String channelName, String method, dynamic Function(Map) fn) =>
        h['$channelName|$method'] = fn;

    // --- 握手与会话订阅 ---
    reg('zcode-agent', 'helloConversationV4', (_) => {'connectionId': 'demo-conn'});
    reg('zcode-agent', 'initializeConversationV4', (_) => {'ok': true});
    reg('zcode-agent', 'subscribeConversationV4', _subscribeConversation);
    reg('zcode-agent', 'unsubscribeConversationV4', (_) async {
      await Future<void>.delayed(Duration.zero);
      return {'ok': true};
    });
    reg('zcode-agent', 'resyncConversationV4', (p) {
      final sid = '${p['sessionId'] ?? ''}';
      _pushConversationSnapshot(sid);
      return {'ok': true};
    });

    // --- si / tasks-index ---
    reg('zcode-agent', 'subscribeSessionsIndexV4', (_) {
      _siSubId = 'si-${++_subCounter}';
      _schedule(const Duration(milliseconds: 250), _pushSiSnapshot);
      return {
        'ack': {'subscriptionId': _siSubId, 'mode': 'snapshot'},
      };
    });
    reg('zcode-agent', 'unsubscribeSessionsIndexV4', (_) async {
      _siSubId = null;
      return {'ok': true};
    });
    reg('zcode-agent', 'resyncSessionsIndexV4', (_) {
      _schedule(const Duration(milliseconds: 250), _pushSiSnapshot);
      return {'ok': true};
    });
    reg('window-controller', 'subscribeControllerV4', (_) {
      _ctrlSubId = 'ctrl-${++_subCounter}';
      _schedule(const Duration(milliseconds: 250), _pushTasksSnapshot);
      return {
        'ack': {'subscriptionId': _ctrlSubId, 'mode': 'snapshot'},
      };
    });
    reg('window-controller', 'unsubscribeControllerV4', (_) async {
      _ctrlSubId = null;
      return {'ok': true};
    });
    reg('window-controller', 'resyncControllerV4', (_) {
      _schedule(const Duration(milliseconds: 250), _pushTasksSnapshot);
      return {'ok': true};
    });

    // --- 命令面 ---
    reg('zcode-agent', 'sendConversationCommandV4', _handleCommand);
    reg('zcode-agent', 'queryConversationCommandsV4', (p) {
      final commands = p['commands'];
      final n = commands is List ? commands.length : 1;
      return {
        'results': [
          for (var i = 0; i < n; i++)
            {
              'result': {'status': 'accepted', 'revisionAtDecision': 7},
            },
        ],
      };
    });

    // --- 会话只读查询 ---
    reg('zcode-agent', 'conversationRowsRangeV4', (p) {
      final sid = '${p['sessionId'] ?? ''}';
      final snap = _snapshots[sid];
      final rows = snap?['rows'];
      final window = rows is Map ? rows['window'] : null;
      final all = window is List ? window.cast<Map<String, dynamic>>() : const [];
      final before = p['beforeRowId'];
      final limit = (p['limit'] as num?)?.toInt() ?? 60;
      final filtered = before is num
          ? all.where((r) => (r['rowId'] as num) < before).toList()
          : all.toList();
      return {
        'rows': filtered.take(limit).toList(),
        'hasMore': false,
        'atLogEpoch': 'demo-e1',
      };
    });
    reg('zcode-agent', 'conversationFileChangesV4', (_) => {
      'items': [
        {
          'path': '$demoWorkspacePath/app/lib/widgets/drawer_menu.dart',
          'additions': 18,
          'deletions': 4,
          'patches': [
            {
              'lines': [
                '@@ -41,6 +41,14 @@',
                '   Widget build(BuildContext context) {',
                '-    return Scaffold(',
                '+    return PopScope(',
                '+      canPop: !open,',
                '+      onPopInvoked: (didPop) {',
                '+        if (!didPop) closeDrawer();',
                '+      },',
                '+      child: Scaffold(',
                '        body: HomeView(open: open),',
              ],
            },
          ],
        },
      ],
    });
    reg('zcode-agent', 'conversationFileRewindPreviewV4', (_) => {
      'canApply': true,
      'safeFiles': ['$demoWorkspacePath/app/lib/widgets/drawer_menu.dart'],
      'unsafeFiles': [],
      'ignoredFiles': [],
    });
    reg('zcode-agent', 'listSessionSubagents', (_) => {
      'revision': 3,
      'childSessionIds': ['s-sub-review'],
      'running': [],
      'ended': {
        'total': 1,
        'items': [
          {
            'sessionId': 's-sub-review',
            'title': 'code-reviewer · 复查抽屉返回键修复',
            'phase': 'completedSuccess',
            'lastActivityAt': _nowMs(),
          },
        ],
      },
    });

    // --- 工作流 ---
    reg('zcode-agent', 'conversationWorkflowRunsV4', (_) => demoWorkflowRuns());
    reg('zcode-agent', 'conversationWorkflowRunEventsV4', (p) =>
        demoWorkflowRunEvents('${p['runId'] ?? ''}'));
    reg('zcode-agent', 'conversationWorkflowRunArtifactsV4', (p) =>
        demoWorkflowRunArtifacts('${p['runId'] ?? ''}'));
    reg('zcode-agent', 'conversationWorkflowRunArtifactDataV4', (_) => {
      'items': [],
      'hasMore': false,
    });
    reg('zcode-agent', 'conversationWorkflowRunArtifactReadV4', (p) =>
        demoWorkflowArtifactRead('${p['runId'] ?? ''}', '${p['artifactId'] ?? ''}'));

    // --- 任务三列表与操作 ---
    reg('zcode-task', 'listTasks', (_) => _tasksRawList());
    reg('zcode-task', 'listPinnedTasks', (_) => [
      for (final t in _tasks)
        if ((t['membership'] as Map)['pinned'] == true) {'taskId': t['address']['taskId']},
    ]);
    reg('zcode-task', 'listArchivedTasks', (_) => const []);
    reg('zcode-task', 'listDeletedTaskIds', (_) => const []);
    reg('zcode-task', 'listTaskList', (p) {
      final search = '${p['search'] ?? ''}'.toLowerCase();
      return {
        'items': [
          for (final t in _tasks)
            if (search.isNotEmpty &&
                '${t['meta']['title'] ?? ''}'.toLowerCase().contains(search))
              {
                'taskId': t['address']['taskId'],
                'workspacePath': t['address']['workspacePath'],
                'workspaceIdentity': t['address']['workspaceIdentity'],
                'title': t['meta']['title'],
                'updatedAt': t['meta']['updatedAt'],
                'searchSnippets': ['…${t['meta']['title']}…'],
              },
        ],
      };
    });
    reg('zcode-task', 'getTaskConfigOptions', (_) => demoTaskConfigOptions());
    for (final m in const [
      'setTaskPinned',
      'renameTask',
      'archiveTask',
      'unarchiveTask',
      'deleteTask',
      'deleteArchivedTask',
      'deleteArchivedTasks',
    ]) {
      reg('zcode-task', m, (p) {
        _applyTaskMutation(m, p);
        return {'ok': true};
      });
    }
    reg('zcode-task', 'setTaskUnread', (p) {
      _applyTaskUnread(p);
      return {'ok': true};
    });

    // --- 目录与杂项 ---
    reg('zcode-session', 'readWorkspacePresentation', (_) =>
        demoWorkspacePresentation());
    reg('model-selection', 'getView', (_) => demoModelSelectionView());
    reg('skills', 'list', (_) => demoSkills());
    reg('file', 'searchWorkspaceFiles', (p) =>
        demoFileSearch('${p['query'] ?? ''}'));
    reg('subagents', 'list', (_) => demoSubagentsList());
    for (final m in const [
      'setEnabled',
      'deleteAgent',
      'createAgent',
      'updateAgent',
      'setBuiltInModelOverride',
      'setPluginAgentModelOverride',
    ]) {
      reg('subagents', m, (_) => {'ok': true});
    }
    reg('project', 'readTree', (_) => demoReadTree());
    reg('project', 'moveTask', (_) => {'ok': true});

    // --- 用量 ---
    reg('usage-stats', 'getEntitlementSnapshot', (_) => demoEntitlementSnapshot());
    reg('usage-stats', 'getCodingPlanUsageSnapshot', (p) =>
        demoCodingPlanUsageSnapshot('${p['range'] ?? '7d'}'));
    reg('usage-stats', 'getAppUsageSnapshot', (p) =>
        demoAppUsageSnapshot('${p['range'] ?? '7d'}'));
    reg('usage-stats', 'requestCodingPlanResetOpportunity', (_) => {});
    reg('usage-stats', 'getCodingPlanResetStatus', (_) => {
      'availableFiveHourResets': [],
      'availableWeekResets': [],
    });
    reg('usage-stats', 'useCodingPlanReset', (_) => {'used': true});

    // --- git ---
    reg('git', 'getWorkspaceRepositoryInfo', (_) => demoGitRepoInfo());
    reg('git', 'getLocalBranches', (_) => demoGitBranches());
    reg('git', 'switchBranch', (_) => {'ok': true, 'didChange': true});
    reg('git', 'createBranchAndSwitch', (_) => {'ok': true, 'didChange': true});

    // --- 自动化与设置 ---
    reg('zcode-agent', 'listAllAutomations', (_) => demoAutomations());
    for (final m in const [
      'createAutomation',
      'updateAutomation',
      'runAutomationNow',
      'setAutomationEnabled',
      'deleteAutomation',
      'restartAutomation',
      'syncAppRuntimePreferences',
      'snoozeInteractionAutoResolution',
    ]) {
      reg('zcode-agent', m, (_) => {'ok': true});
    }
  }

  // ------------------------------------------------------- 订阅推送

  Map<String, dynamic> _subscribeConversation(Map p) {
    final sid = '${p['sessionId'] ?? ''}';
    final subId = _convSubIds.putIfAbsent(sid, () => 'cv-${++_subCounter}');
    _schedule(const Duration(milliseconds: 250), () {
      _pushConversationSnapshot(sid);
    });
    return {
      'ack': {'subscriptionId': subId, 'mode': 'snapshot', 'logEpoch': 'demo-e1'},
    };
  }

  void _pushConversationSnapshot(String sid) {
    final subId = _convSubIds[sid];
    if (subId == null) return;
    final snap = _snapshots[sid];
    if (snap == null) return;
    final seq = _convSeq[sid] ??= 100;
    _emitConversation(sid, {
      'subscriptionId': subId,
      'toSeq': seq,
      'payload': {'kind': 'snapshot', 'snapshot': snap},
    });
  }

  void _pushSiSnapshot() {
    final subId = _siSubId;
    if (subId == null) return;
    _emitSi({
      'subscriptionId': subId,
      'toSeq': _siSeq,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'workspaceId': demoWorkspaceIdentity,
          'logEpoch': 'demo-e1',
          'sessions': _siSessions.values.toList(),
        },
      },
    });
  }

  void _pushTasksSnapshot() {
    final subId = _ctrlSubId;
    if (subId == null) return;
    channel.fireEvent('window-controller', 'onDynamicControllerFrame', {
      'topic': 'controller/tasks-index',
      'subscriptionId': subId,
      'logEpoch': 'demo-e1',
      'fromSeq': 0,
      'toSeq': _ctrlSeq,
      'sentAt': _nowMs(),
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'protocolVersion': 1,
          'logEpoch': 'demo-e1',
          'tasks': _tasks,
        },
      },
    });
  }

  void _emitConversation(String sid, Map<String, dynamic> innerFrame) {
    channel.fireEvent('zcode-agent', 'onDynamicConversationFrame', {
      'topic': 'conversation/$sid',
      'kind': 'complete',
      'frame': innerFrame,
    });
  }

  void _emitSi(Map<String, dynamic> innerFrame) {
    channel.fireEvent('zcode-agent', 'onDynamicSessionsIndexFrame', {
      'topic': 'sessions-index/$demoWorkspaceIdentity',
      'kind': 'complete',
      'frame': innerFrame,
    });
  }

  /// 会话 delta 帧推送（fromSeq=当前水位、toSeq=+1）。
  void _emitConvDelta(String sid, List<Map<String, dynamic>> deltas) {
    final subId = _convSubIds[sid];
    if (subId == null) return;
    final from = _convSeq[sid] ??= 100;
    final to = from + 1;
    _convSeq[sid] = to;
    _emitConversation(sid, {
      'subscriptionId': subId,
      'fromSeq': from,
      'toSeq': to,
      'payload': {'kind': 'deltas', 'deltas': deltas},
    });
  }

  void _emitSiSessionUpsert(Map<String, dynamic> session) {
    final subId = _siSubId;
    if (subId == null) return;
    final from = _siSeq++;
    _emitSi({
      'subscriptionId': subId,
      'fromSeq': from,
      'toSeq': _siSeq,
      'payload': {
        'kind': 'deltas',
        'deltas': [
          {'op': 'session.upserted', 'session': session},
        ],
      },
    });
  }

  void _emitTaskUpsert(Map<String, dynamic> row) {
    final subId = _ctrlSubId;
    if (subId == null) return;
    final from = _ctrlSeq++;
    channel.fireEvent('window-controller', 'onDynamicControllerFrame', {
      'topic': 'controller/tasks-index',
      'subscriptionId': subId,
      'logEpoch': 'demo-e1',
      'fromSeq': from,
      'toSeq': _ctrlSeq,
      'sentAt': _nowMs(),
      'payload': {
        'kind': 'deltas',
        'deltas': [
          {'op': 'task.upserted', 'task': row},
        ],
      },
    });
  }

  // ------------------------------------------------------- 命令面

  Map<String, dynamic> _handleCommand(Map p) {
    final envelope = p['envelope'];
    final type = envelope is Map ? '${envelope['type']}' : '';
    return switch (type) {
      'createSession' => _handleCreateSession(p),
      'sendText' => _handleSendText(p),
      'stop' => _handleStop(p),
      'resolveInteraction' => _handleResolveInteraction(p),
      _ => {
        'status': 'accepted',
        if (_snapshots['${envelope is Map ? envelope['sessionId'] : ''}'] != null)
          'revisionAtDecision': 7,
      },
    };
  }

  Map<String, dynamic> _handleCreateSession(Map p) {
    final envelope = p['envelope'] as Map;
    final payload = envelope['payload'];
    final firstInput = payload is Map ? payload['firstInput'] : null;
    final text = firstInput is Map ? '${firstInput['text'] ?? ''}' : '';
    final n = ++_newSessionCounter;
    final taskId = 't-new-$n';
    final sid = demoSessionIdOf(taskId);
    final now = _nowMs();
    _snapshots[sid] = {
      'logEpoch': 'demo-e1',
      'revision': 1,
      'title': _deriveTitle(text),
      'rows': {'window': [], 'totalCount': 0, 'firstRowId': null},
      'control': {
        'phase': 'idle',
        'canStop': false,
        'activeWorks': const [],
      },
      'config': const {
        'provider': 'zai',
        'model': 'glm-5.3',
        'thought': 'think',
        'thoughtLevels': ['nothink', 'think', 'thinkhard', 'ultrathink'],
        'mode': 'build',
        'planEnabled': false,
        'followupMode': 'queue',
      },
      'queue': const {'items': [], 'autoDrain': true},
      'usage': const {
        'contextWindow': {'usedTokens': 1200, 'maxTokens': 128000},
      },
    };
    final taskRow = {
      'address': {
        'workspacePath': demoWorkspacePath,
        'workspaceIdentity': demoWorkspaceIdentity,
        'taskId': taskId,
      },
      'meta': {
        'taskId': taskId,
        'title': _deriveTitle(text),
        'createdAt': now,
        'updatedAt': now,
        'status': 'completed',
      },
      'membership': {'pinned': false, 'archived': false, 'active': true},
      'sourceAvailability': 'online',
      'liveStatus': 'idle',
      'activity': {'hasBackgroundWork': false},
    };
    _tasks.insert(0, taskRow);
    final session = {
      'sessionId': sid,
      'parentSessionId': null,
      'title': _deriveTitle(text),
      'phase': 'draft',
      'lastAssistantPreview': '',
      'lastActivityAt': now,
      'createdAt': now,
      'hasBackgroundWork': false,
    };
    _siSessions[sid] = session;
    _emitTaskUpsert(taskRow);
    _emitSiSessionUpsert(session);
    // 首条消息（新会话一次性提交）：照常走流式重放，否则新会话是空壳
    // （新会话路由只发 createSession，不再发 sendText）——否则新会话是空壳。
    final firstText = text.trim();
    if (firstText.isNotEmpty) {
      _schedule(const Duration(milliseconds: 300), () {
        _startReplay(sid, firstText);
      });
    }
    return {
      'status': 'accepted',
      'result': {'sessionId': sid},
    };
  }

  Map<String, dynamic> _handleSendText(Map p) {
    // sendText 只回 accepted；内容重放经帧推送（见 _startReplay）。
    final sid = '${(p['envelope'] as Map)['sessionId'] ?? ''}';
    final payload = (p['envelope'] as Map)['payload'];
    final text = payload is Map ? '${payload['text'] ?? ''}' : '';
    if (sid.isNotEmpty) {
      _schedule(const Duration(milliseconds: 200), () {
        _startReplay(sid, text);
      });
    }
    return {'status': 'accepted'};
  }

  Map<String, dynamic> _handleStop(Map p) {
    final sid = '${(p['envelope'] as Map)['sessionId'] ?? ''}';
    _replays.remove(sid)?.cancel();
    _schedule(const Duration(milliseconds: 150), () {
      _patchControl(sid, 'completedInterrupted');
      _emitConvDelta(sid, const []);
      _syncTaskPhase(sid, 'completedInterrupted');
    });
    return {'status': 'accepted'};
  }

  Map<String, dynamic> _handleResolveInteraction(Map p) {
    final envelope = p['envelope'] as Map;
    final sid = '${envelope['sessionId'] ?? ''}';
    final payload = envelope['payload'];
    final interactionId = payload is Map ? '${payload['interactionId']}' : '';
    final answer = payload is Map ? payload['answer'] : null;
    final option = answer is Map ? '${answer['optionId'] ?? answer['action'] ?? ''}' : '';
    final denied = option == 'deny';
    if (sid == 't-chart-dark') {
      _schedule(const Duration(milliseconds: 250), () {
        _emitConvDelta(sid, const [
          {
            'op': 'state.updated',
            'patch': {'pendingInteractions': []},
          },
        ]);
        _continueChartDark(denied);
      });
    } else {
      final replay = _replays[sid];
      if (replay != null && replay.pendingInteractionId == interactionId) {
        replay.resolveInteraction(denied);
      }
    }
    return {'status': 'accepted'};
  }

  // ------------------------------------------------------- 流式重放

  void _startReplay(String sid, String userText) {
    _replays.remove(sid)?.cancel();
    final snap = _snapshots[sid];
    if (snap == null) return;
    final rows = (snap['rows'] as Map)['window'] as List;
    final nextRowId = rows.isEmpty
        ? 1
        : ((rows.last['rowId'] as num) + 1).toInt();
    final replay = _LiveReplay(this, sid, userText, nextRowId);
    _replays[sid] = replay;
    replay.start();
  }

  // ------------------------------------------------------- 静态审批续流

  /// t-chart-dark 的审批卡被处理后：Bash 出结果 → 收尾 → 完成。
  void _continueChartDark(bool denied) {
    const sid = 't-chart-dark';
    if (denied) {
      _emitConvDelta(sid, [
        {
          'op': 'row.upserted',
          'row': {
            'rowId': 6,
            'kind': 'toolCall',
            'entityId': 'et-6',
            'toolCallId': 'tc-bash-2',
            'toolName': 'Bash',
            'status': 'error',
            'state': 'done',
            'error': '用户拒绝了本次命令执行',
          },
        },
      ]);
      _emitConvDelta(sid, [
        {
          'op': 'row.appended',
          'row': {
            'rowId': 7,
            'kind': 'assistantText',
            'entityId': 'ea-3',
            'text': '好的，先不跑 analyze。我直接按读到的实现改配色：把硬编码灰换成主题语义色（浅色 #6B7280 / 深色 #9CA3AF），网格线降到 60% 透明度。要我继续吗？',
            'createdAt': _nowMs(),
            'state': 'done',
          },
        },
      ]);
      _patchControl(sid, 'completedInterrupted');
      _syncTaskPhase(sid, 'completedInterrupted');
      return;
    }
    _emitConvDelta(sid, [
      {
        'op': 'row.upserted',
        'row': {
          'rowId': 6,
          'kind': 'toolCall',
          'entityId': 'et-6',
          'toolCallId': 'tc-bash-2',
          'toolName': 'Bash',
          'status': 'running',
          'state': 'streaming',
        },
      },
    ]);
    _schedule(const Duration(milliseconds: 1200), () {
      _emitConvDelta(sid, [
        {
          'op': 'row.upserted',
          'row': {
            'rowId': 6,
            'kind': 'toolCall',
            'entityId': 'et-6',
            'toolCallId': 'tc-bash-2',
            'toolName': 'Bash',
            'status': 'done',
            'state': 'done',
            'durationMs': 3_800,
            'output': {
              'text': 'Analyzing ...\nissues found: 2\n  • chart_theme.dart:12 — hardcoded color (deprecated_token)\n  • chart_theme.dart:40 — hardcoded color (deprecated_token)',
            },
          },
        },
      ]);
      _emitConvDelta(sid, [
        {
          'op': 'row.appended',
          'row': {
            'rowId': 7,
            'kind': 'toolCall',
            'entityId': 'et-7',
            'toolCallId': 'tc-edit-2',
            'toolName': 'Edit',
            'status': 'done',
            'state': 'done',
            'durationMs': 980,
            'inputText':
                '{"file_path":"${demoWorkspacePath}app/lib/theme/chart_theme.dart","old_string":"static const grid = legacyGrid;","new_string":"static final grid = themeColors.outlineVariant;"}',
            'outputPreview': 'The file app/lib/theme/chart_theme.dart has been updated.',
          },
        },
      ]);
      _patchControl(sid, 'completedSuccess');
      _syncTaskPhase(sid, 'completedSuccess');
    });
  }

  // ------------------------------------------------------- 内部工具

  void _patchControl(String sid, String phase) {
    _emitConvDelta(sid, [
      {
        'op': 'state.updated',
        'patch': {
          'control': {
            'phase': phase,
            'canStop': false,
            'activeWorks': const [],
          },
        },
      },
    ]);
  }

  /// si + tasks-index 的任务相位跟拍（首页卡片状态实时收敛）。
  void _syncTaskPhase(String sid, String phase) {
    final session = _siSessions[sid];
    if (session != null) {
      session['phase'] = phase;
      _emitSiSessionUpsert(session);
    }
    final taskId = sid;
    for (final row in _tasks) {
      final addr = row['address'];
      if (addr is Map && '${addr['taskId']}' == taskId) {
        final meta = row['meta'];
        if (meta is Map) {
          meta['updatedAt'] = _nowMs();
          meta['status'] = phase == 'completedSuccess' ? 'completed' : phase;
        }
        row['liveStatus'] =
            phase == 'running' || phase == 'prewarming' ? 'running' : 'idle';
        _emitTaskUpsert(row);
        break;
      }
    }
  }

  void _applyTaskMutation(String method, Map p) {
    final taskId = '${p['taskId'] ?? ''}';
    for (var i = 0; i < _tasks.length; i++) {
      final addr = _tasks[i]['address'];
      if (addr is Map && '${addr['taskId']}' == taskId) {
        switch (method) {
          case 'setTaskPinned':
            ( _tasks[i]['membership'] as Map)['pinned'] = p['pinned'] == true;
            _emitTaskUpsert(_tasks[i]);
          case 'renameTask':
            (_tasks[i]['meta'] as Map)['title'] = '${p['title'] ?? ''}';
            _emitTaskUpsert(_tasks[i]);
          case 'archiveTask':
            (_tasks[i]['membership'] as Map)['archived'] = true;
            (_tasks[i]['membership'] as Map)['active'] = false;
            _tasks.removeAt(i);
          case 'unarchiveTask':
            (_tasks[i]['membership'] as Map)['archived'] = false;
            (_tasks[i]['membership'] as Map)['active'] = true;
          case 'deleteTask':
            _tasks.removeAt(i);
          default:
            break;
        }
        break;
      }
    }
  }

  void _applyTaskUnread(Map p) {
    final taskId = '${p['taskId'] ?? ''}';
    for (final row in _tasks) {
      final addr = row['address'];
      if (addr is Map && '${addr['taskId']}' == taskId) {
        final meta = row['meta'] as Map;
        if (p['unread'] == true) {
          meta['unreadAt'] = _nowMs();
        } else {
          meta.remove('unreadAt');
        }
        _emitTaskUpsert(row);
        break;
      }
    }
  }

  List<Map<String, dynamic>> _tasksRawList() => [
    for (final row in _tasks)
      {
        'taskId': row['address']['taskId'],
        'title': row['meta']['title'],
        'status': row['meta']['status'],
        'createdAt': row['meta']['createdAt'],
        'updatedAt': row['meta']['updatedAt'],
      },
  ];

  String _deriveTitle(String text) {
    final t = text.trim();
    if (t.isEmpty) return '新任务';
    return t.length > 24 ? '${t.substring(0, 24)}…' : t;
  }

  void _schedule(Duration delay, void Function() fn) {
    Timer? timer;
    timer = Timer(delay, () {
      _timers.remove(timer);
      fn();
    });
    _timers.add(timer);
  }

  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    for (final r in _replays.values) {
      r.cancel();
    }
    _replays.clear();
  }
}

/// 单个会话的流式重放时间线。
class _LiveReplay {
  _LiveReplay(this._script, this._sid, this._userText, this._nextRowId);

  final DemoScript _script;
  final String _sid;
  final String _userText;
  int _nextRowId;
  int _lateRowId = 0;
  final Set<Timer> _timers = {};
  bool _cancelled = false;
  String? pendingInteractionId;

  int get _rowId => _nextRowId++;

  void _at(Duration delay, void Function() fn) {
    Timer? t;
    t = Timer(delay, () {
      _timers.remove(t);
      if (!_cancelled) fn();
    });
    _timers.add(t);
  }

  void _delta(List<Map<String, dynamic>> deltas) =>
      _script._emitConvDelta(_sid, deltas);

  void _append(Map<String, dynamic> row) => _delta([
    {'op': 'row.appended', 'row': row},
  ]);

  void start() {
    // 用户消息上屏（服务端权威路径：客户端只发命令，行由帧追加）。
    _at(const Duration(milliseconds: 120), () {
      _append({
        'rowId': _rowId,
        'kind': 'userInput',
        'entityId': 'eu-live-$_nextRowId',
        'text': _userText,
        'createdAt': _nowMs(),
      });
      _script._syncTaskPhase(_sid, 'running');
    });
    // 助手回合开始。
    _at(const Duration(milliseconds: 700), () {
      _append({
        'rowId': _rowId,
        'kind': 'turnHeader',
        'createdAt': _nowMs(),
      });
      _delta(const [
        {
          'op': 'state.updated',
          'patch': {
            'control': {
              'phase': 'running',
              'canStop': true,
              'activeWorks': [
                {'foregroundExecutionId': 'exec-live', 'kind': 'turn'},
              ],
            },
          },
        },
      ]);
    });
    // 思考行：流式 → 收尾。
    _at(const Duration(milliseconds: 1100), () {
      _append({
        'rowId': _rowId,
        'kind': 'reasoning',
        'entityId': 'er-live',
        'text': '',
        'state': 'streaming',
        'createdAt': _nowMs(),
      });
    });
    _at(const Duration(milliseconds: 1500), () {
      _delta([
        {
          'op': 'row.delta',
          'rowId': _nextRowId - 1,
          'path': 'text',
          'append': '先看相关实现，确认现有结构再动手；改完跑一次测试，最后把要点总结给你。',
        },
      ]);
    });
    _at(const Duration(milliseconds: 2100), () {
      _delta([
        {
          'op': 'row.upserted',
          'row': {
            'rowId': _nextRowId - 1,
            'kind': 'reasoning',
            'entityId': 'er-live',
            'text': '先看相关实现，确认现有结构再动手；改完跑一次测试，最后把要点总结给你。',
            'state': 'done',
          },
        },
      ]);
    });
    // 读文件工具行。
    _at(const Duration(milliseconds: 2600), () {
      final id = _rowId;
      _append({
        'rowId': id,
        'kind': 'toolCall',
        'entityId': 'et-live-read',
        'toolCallId': 'tc-live-read',
        'toolName': 'Read',
        'status': 'running',
        'state': 'streaming',
        'inputText': '',
        'createdAt': _nowMs(),
      });
      _at(const Duration(milliseconds: 350), () {
        _delta([
          {
            'op': 'row.upserted',
            'row': {
              'rowId': id,
              'kind': 'toolCall',
              'entityId': 'et-live-read',
              'toolCallId': 'tc-live-read',
              'toolName': 'Read',
              'status': 'done',
              'state': 'done',
              'durationMs': 720,
              'inputText':
                  '{"file_path":"${demoWorkspacePath}app/lib/widgets/header_bar.dart"}',
              'output': {
                'text': '(36 lines shown of 88)\nclass HeaderBar extends StatelessWidget {\n  // …\n}',
              },
            },
          },
        ]);
      });
    });
    // 正文打字机。
    _at(const Duration(milliseconds: 3300), () {
      final id = _rowId;
      _append({
        'rowId': id,
        'kind': 'assistantText',
        'entityId': 'ea-live',
        'text': '',
        'state': 'streaming',
        'createdAt': _nowMs(),
      });
      const answer =
          '结构已经清楚了：`HeaderBar` 目前只在 `build` 里静态布局，滚动位置没有参与。'
          '我用 `NotificationListener` 包住页面滚动，超过 8 逻辑像素就把 `pinned` 置真，'
          '同时给标题区加一个 200ms 的渐入。改动集中在 `header_bar.dart` 一个文件。';
      const chunk = 6;
      final chunks = (answer.length / chunk).ceil();
      for (var i = 0; i < chunks; i++) {
        _at(Duration(milliseconds: 400 + i * 130), () {
          _delta([
            {
              'op': 'row.delta',
              'rowId': id,
              'path': 'text',
              'append': answer.substring(
                i * chunk,
                (i + 1) * chunk > answer.length ? answer.length : (i + 1) * chunk,
              ),
            },
          ]);
        });
      }
      _at(Duration(milliseconds: 400 + chunks * 130 + 250), () {
        _delta([
          {
            'op': 'row.upserted',
            'row': {
              'rowId': id,
              'kind': 'assistantText',
              'entityId': 'ea-live',
              'text': answer,
              'state': 'done',
            },
          },
        ]);
      });
    });
    // 改动 + 需要批准的命令（审批卡 → 用户裁决）。
    _at(const Duration(milliseconds: 8000), () {
      _append({
        'rowId': _rowId,
        'kind': 'toolCall',
        'entityId': 'et-live-edit',
        'toolCallId': 'tc-live-edit',
        'toolName': 'Edit',
        'status': 'done',
        'state': 'done',
        'durationMs': 1_060,
        'inputText':
            '{"file_path":"${demoWorkspacePath}app/lib/widgets/header_bar.dart","new_string":"return NotificationListener<ScrollNotification>(…);"}',
        'outputPreview': 'The file app/lib/widgets/header_bar.dart has been updated.',
      });
      _delta(const [
        {
          'op': 'state.updated',
          'patch': {
            'control': {
              'phase': 'running',
            },
          },
        },
      ]);
    });
    _at(const Duration(milliseconds: 9200), () {
      final bashId = _rowId;
      _lateRowId = bashId;
      _append({
        'rowId': bashId,
        'kind': 'toolCall',
        'entityId': 'et-live-bash',
        'toolCallId': 'tc-live-bash',
        'toolName': 'Bash',
        'status': 'waiting',
        'state': 'streaming',
        'inputText':
            '{"command":"cd ${demoWorkspacePath}app && flutter test test/widget/header_bar_test.dart"}',
        'createdAt': _nowMs(),
      });
      pendingInteractionId = 'ia-live';
      _delta([
        {
          'op': 'state.updated',
          'patch': {
            'pendingInteractions': [
              {
                'interactionId': 'ia-live',
                'payload': {
                  'kind': 'permission',
                  'toolName': 'Bash',
                  'summary': '运行 header_bar 单元测试',
                  'prompt': '助手请求运行以下命令来验证改动：',
                  'detail': {
                    'command':
                        'cd ${demoWorkspacePath}app && flutter test test/widget/header_bar_test.dart',
                  },
                  'options': [
                    {'value': 'allow', 'label': '允许'},
                    {'value': 'allowSession', 'label': '本次会话内允许'},
                    {'value': 'deny', 'label': '拒绝'},
                  ],
                },
                'autoResolution': {
                  'state': 'snoozed',
                  'deadlineAt': _nowMs() + 180_000,
                },
              },
            ],
          },
        },
      ]);
      // 审批期间看门狗静默（pendingInteractions 非空即跳过），可无限等待。
      // 自动演绎（宣传录像；MuMu screenrecord 期间系统输入注入被冻结，
      // 见 demo_mode.dart）：审批卡展示 4 秒后按「允许」路径自行放行。
      if (demoAutoEnabled) {
        _at(const Duration(seconds: 4), () {
          if (_cancelled || pendingInteractionId == null) return;
          pendingInteractionId = null;
          _delta(const [
            {
              'op': 'state.updated',
              'patch': {'pendingInteractions': []},
            },
          ]);
          _continueAfterApproval(bashId);
        });
      }
    });
  }

  /// 用户裁决审批后继续：allow → 测试通过 → 总结收尾。
  void resolveInteraction(bool denied) {
    final bashId = _lateRowId;
    pendingInteractionId = null;
    _delta(const [
      {
        'op': 'state.updated',
        'patch': {'pendingInteractions': []},
      },
    ]);
    if (denied) {
      _at(const Duration(milliseconds: 400), () {
        _delta([
          {
            'op': 'row.upserted',
            'row': {
              'rowId': bashId,
              'kind': 'toolCall',
              'entityId': 'et-live-bash',
              'toolCallId': 'tc-live-bash',
              'toolName': 'Bash',
              'status': 'error',
              'state': 'done',
              'error': '用户拒绝了本次命令执行',
            },
          },
        ]);
        _finish('改动已完成；测试没有运行，建议稍后在桌面端补跑一次。');
      });
      return;
    }
    _continueAfterApproval(bashId);
  }

  /// 「允许」路径的后续时间线（手动裁决与自动演绎共用）。
  void _continueAfterApproval(int bashId) {
    _at(const Duration(milliseconds: 400), () {
      _delta([
        {
          'op': 'row.upserted',
          'row': {
            'rowId': bashId,
            'kind': 'toolCall',
            'entityId': 'et-live-bash',
            'toolCallId': 'tc-live-bash',
            'toolName': 'Bash',
            'status': 'running',
            'state': 'streaming',
          },
        },
      ]);
    });
    _at(const Duration(milliseconds: 2600), () {
      _delta([
        {
          'op': 'row.upserted',
          'row': {
            'rowId': bashId,
            'kind': 'toolCall',
            'entityId': 'et-live-bash',
            'toolCallId': 'tc-live-bash',
            'toolName': 'Bash',
            'status': 'done',
            'state': 'done',
            'durationMs': 4_120,
            'output': {
              'text': '00:04 +9: All tests passed!\n(pinned on scroll, fade-in title, handoff …)',
            },
          },
        },
      ]);
      _finish('吸顶效果完成：滚动超过 8 逻辑像素触发，回滚渐隐；9 个测试全过。');
    });
  }

  void _finish(String summary) {
    _at(const Duration(milliseconds: 700), () {
      final id = _rowId;
      _append({
        'rowId': id,
        'kind': 'assistantText',
        'entityId': 'ea-live-2',
        'text': summary,
        'state': 'done',
        'createdAt': _nowMs(),
      });
      _script._patchControl(_sid, 'completedSuccess');
      _script._syncTaskPhase(_sid, 'completedSuccess');
    });
  }

  void cancel() {
    _cancelled = true;
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
  }

  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;
}

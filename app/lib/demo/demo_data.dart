/// 演示数据集：一个虚构的开源小项目「toolbox」（跨平台效率工具箱）
/// 的完整日常——任务、会话、审批、用量、工作流、子代理全部为合成
/// 内容，路径与人名均为演示占位。时间戳相对 [DateTime.now] 生成，
/// 保证任何时刻截取都落在合理的时间分组（今天/昨天/本周/更早）。
///
/// 数据形状严格对齐 wire 协议（tasks-index / sessions-index /
/// conversation 快照与行），由 DemoScript 装进 DemoChannel。
library;

import 'dart:convert';

/// 演示工作区（唯一工作区：账号下的一台电脑）。
const String demoWorkspacePath = 'G:/demo/toolbox';
const String demoWorkspaceIdentity = 'demo-ws';
const String demoDeviceSid = 'demo-device';
const String demoAccountId = 'demo-account';
const String demoComputerLabel = '演示电脑';
const String demoAccountLabel = 'GLM 编码套餐';

Map<String, dynamic> get demoWorkspace => const {
  'workspacePath': demoWorkspacePath,
  'workspaceIdentity': demoWorkspaceIdentity,
};

/// readTree：项目树（两个项目 + 未归类任务区）。
Map<String, dynamic> demoReadTree() => {
  'projects': [
    {
      'id': 'pj-app',
      'name': 'toolbox-app',
      'position': 0,
      'roots': [
        {'rootPath': '$demoWorkspacePath/app', 'isPrimary': true},
      ],
    },
    {
      'id': 'pj-docs',
      'name': 'toolbox-docs',
      'position': 1,
      'roots': [
        {'rootPath': '$demoWorkspacePath/docs', 'isPrimary': true},
      ],
    },
  ],
  'tasks': [
    for (final t in _demoTasks)
      {
        'taskId': t.taskId,
        'projectId': t.projectId,
        'hostId': 'local',
        'workspacePath': demoWorkspacePath,
        'workspaceIdentity': demoWorkspaceIdentity,
        'title': t.title,
        'updatedAt': t.updatedAtMs,
        'createdAt': t.createdAtMs,
        'pinned': t.pinned,
        'archived': false,
      },
  ],
};

final class _DemoTaskSpec {
  _DemoTaskSpec({
    required this.taskId,
    required this.title,
    required this.projectId,
    required this.updatedAgo,
    this.createdAgo = const Duration(days: 1),
    this.liveStatus = 'idle',
    this.status = 'completed',
    this.phase = 'completedSuccess',
    this.preview = '',
    this.pinned = false,
    this.unreadAgo,
    this.offPeak = false,
    this.workflowRun,
    this.backgroundWork = false,
    this.pendingKind,
  });

  final String taskId;
  final String title;
  final String? projectId;
  final Duration updatedAgo;
  final Duration createdAgo;
  final String liveStatus;
  final String status;
  final String phase;
  final String preview;
  final bool pinned;
  final Duration? unreadAgo;
  final bool offPeak;
  final Map<String, dynamic>? workflowRun;
  final bool backgroundWork;

  /// 首页任务卡上的审批提示（pendingInteraction 徽标）。
  final String? pendingKind;

  late final int createdAtMs =
      DateTime.now().subtract(createdAgo).millisecondsSinceEpoch;
  late final int updatedAtMs =
      DateTime.now().subtract(updatedAgo).millisecondsSinceEpoch;
  late final int? unreadAtMs = unreadAgo == null
      ? null
      : DateTime.now().subtract(unreadAgo!).millisecondsSinceEpoch;
}

/// 任务清单（时间由近及远；置顶与运行组由字段驱动，不靠顺序）。
List<_DemoTaskSpec> get _demoTasks => [
  _DemoTaskSpec(
    taskId: 't-chart-dark',
    title: '修复深色模式下图表颜色对比度不足',
    projectId: 'pj-app',
    updatedAgo: const Duration(minutes: 2),
    createdAgo: const Duration(hours: 3),
    liveStatus: 'running',
    status: 'running',
    phase: 'running',
    preview: '正在等待你确认是否允许运行 flutter analyze…',
    unreadAgo: const Duration(minutes: 2),
    pendingKind: 'permission',
    workflowRun: {
      'name': 'screenshot-theme-matrix',
      'status': 'running',
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    },
  ),
  _DemoTaskSpec(
    taskId: 't-export',
    title: '给设置页加上数据导出功能',
    projectId: 'pj-app',
    updatedAgo: const Duration(minutes: 26),
    createdAgo: const Duration(hours: 5),
    preview: '导出为 JSON 的入口已经加到设置页最后一组，带二次确认弹窗。',
    unreadAgo: const Duration(minutes: 26),
  ),
  _DemoTaskSpec(
    taskId: 't-startup',
    title: '看看为什么冷启动要三秒',
    projectId: null,
    updatedAgo: const Duration(hours: 2),
    createdAgo: const Duration(hours: 4),
    status: 'interrupted',
    phase: 'completedInterrupted',
    preview: '先跑了 trace：大头在首帧前的插件初始化，明天继续拆。',
    backgroundWork: true,
  ),
  _DemoTaskSpec(
    taskId: 't-migration-doc',
    title: '补充 v2.3 升级迁移指南',
    projectId: 'pj-docs',
    updatedAgo: const Duration(hours: 26),
    createdAgo: const Duration(days: 2),
    preview: '迁移指南已补到 docs/guide/migrate-v2.3.md，含破坏性变更清单。',
  ),
  _DemoTaskSpec(
    taskId: 't-menu-fix',
    title: '修复 #142 安卓返回键无法收起抽屉菜单',
    projectId: 'pj-app',
    updatedAgo: const Duration(hours: 30),
    createdAgo: const Duration(days: 2),
    preview: '已修复并用子代理复查：PopScope 拦截返回键，18 个测试全过。',
  ),
  _DemoTaskSpec(
    taskId: 't-http-dio',
    title: '把网络层从 http 切到 dio',
    projectId: 'pj-app',
    updatedAgo: const Duration(days: 3),
    createdAgo: const Duration(days: 4),
    preview: '切换完成：拦截器统一处理重试与超时，接口行为不变。',
  ),
  _DemoTaskSpec(
    taskId: 't-db-research',
    title: '调研：本地数据库选 SQLite 还是 Isar',
    projectId: null,
    updatedAgo: const Duration(days: 4),
    createdAgo: const Duration(days: 5),
    preview: '结论先记 Isar：模型层省事；等 Windows 插件稳定后再定。',
  ),
  _DemoTaskSpec(
    taskId: 't-ratelimit-test',
    title: '给 RateLimiter 补单元测试',
    projectId: 'pj-app',
    updatedAgo: const Duration(days: 5),
    createdAgo: const Duration(days: 6),
    preview: '补了 9 个用例，覆盖令牌补充与并发竞争两条边界。',
  ),
  _DemoTaskSpec(
    taskId: 't-readme-en',
    title: '翻译 README 到英文',
    projectId: 'pj-docs',
    updatedAgo: const Duration(days: 12),
    createdAgo: const Duration(days: 13),
    preview: '双语 README 完成，英文版置于主文件顶部语言切换链接。',
  ),
  _DemoTaskSpec(
    taskId: 't-upgrade-deps',
    title: '升级全部依赖到最新稳定版',
    projectId: null,
    updatedAgo: const Duration(days: 15),
    createdAgo: const Duration(days: 16),
    preview: '闲时跑完升级：11 个包更新，回归全绿。',
    offPeak: true,
  ),
  _DemoTaskSpec(
    taskId: 't-release-checklist',
    title: 'v2.4 发布检查清单',
    projectId: 'pj-app',
    updatedAgo: const Duration(hours: 8),
    createdAgo: const Duration(days: 3),
    preview: '清单还差两行：CHANGELOG 与商店截图。',
    pinned: true,
  ),
];

/// tasks-index 快照行（首页任务列表的第一数据源）。
List<Map<String, dynamic>> demoTasksIndexRows() => [
  for (final t in _demoTasks)
    {
      'address': {
        'workspacePath': demoWorkspacePath,
        'workspaceIdentity': demoWorkspaceIdentity,
        'taskId': t.taskId,
      },
      'meta': {
        'taskId': t.taskId,
        'title': t.title,
        'createdAt': t.createdAtMs,
        'updatedAt': t.updatedAtMs,
        'unreadAt': ?t.unreadAtMs,
        'status': t.status,
        if (t.offPeak) 'offPeakTaskId': 'off-${t.taskId}',
      },
      'membership': {
        'pinned': t.pinned,
        'archived': false,
        'active': true,
      },
      'sourceAvailability': 'online',
      'liveStatus': t.liveStatus,
      'activity': {
        'hasBackgroundWork': t.backgroundWork,
        if (t.workflowRun != null)
          'workflowActivity': {'runs': [t.workflowRun]},
      },
    },
];

/// sessions-index 快照（与任务一一对应的会话条目）。
Map<String, dynamic> demoSessionsIndexSnapshot() => {
  'workspaceId': demoWorkspaceIdentity,
  'logEpoch': 'demo-e1',
  'sessions': [
    for (final t in _demoTasks)
      {
        'sessionId': demoSessionIdOf(t.taskId),
        'parentSessionId': null,
        'title': t.title,
        'phase': t.phase,
        'lastAssistantPreview': t.preview,
        'lastActivityAt': t.updatedAtMs,
        'createdAt': t.createdAtMs,
        'hasBackgroundWork': t.backgroundWork,
        if (t.pendingKind != null)
          'pendingInteraction': {
            'interactionId': 'ia-${t.taskId}',
            'kind': t.pendingKind,
            'toolName': 'Bash',
          },
      },
  ],
};

/// 任务 → 会话 ID 的稳定映射：产品约定 taskId 与 sessionId 同值
/// （首页点卡 `_openConversation(taskId)` 直接用作会话键），此处保留
/// 辅助函数仅作单点真源，禁止另起前缀映射（曾致订阅键与快照键错位）。
String demoSessionIdOf(String taskId) => taskId;

int _msAgo(Duration d) => DateTime.now().subtract(d).millisecondsSinceEpoch;

int _msAhead(Duration d) => DateTime.now().add(d).millisecondsSinceEpoch;

// ---------------------------------------------------------- 会话历史

/// 旗舰演示会话（t-menu-fix）：丰富历史——思考/读文件/编辑/测试/
/// 子代理复查/最终答复。行形状对齐 wire row 契约。
List<Map<String, dynamic>> _menuFixRows() {
  final t0 = _msAgo(const Duration(hours: 30));
  int at(int offsetMs) => t0 + offsetMs;
  return [
    {
      'rowId': 1,
      'kind': 'turnHeader',
      'createdAt': at(0),
    },
    {
      'rowId': 2,
      'kind': 'userInput',
      'entityId': 'eu-1',
      'text': '安卓上抽屉菜单展开后，按系统返回键没反应，只能点左上角按钮才能收起。帮我修一下，顺便确认 iOS 侧有没有同样的问题。',
      'createdAt': at(2_000),
    },
    {
      'rowId': 3,
      'kind': 'turnHeader',
      'createdAt': at(6_000),
      'fileChanges': {'files': 1, 'additions': 18, 'deletions': 4},
    },
    {
      'rowId': 4,
      'kind': 'reasoning',
      'entityId': 'er-1',
      'text': '返回键收起抽屉通常要在路由层拦截：先看抽屉的打开状态管理和是否注册了返回键回调，再对照 Flutter 3.16 之后 WillPopScope 迁移 PopScope 的破坏性变更。',
      'createdAt': at(8_000),
      'state': 'done',
    },
    {
      'rowId': 5,
      'kind': 'toolCall',
      'entityId': 'et-1',
      'toolCallId': 'tc-read-1',
      'toolName': 'Read',
      'status': 'done',
      'state': 'done',
      'createdAt': at(10_000),
      'durationMs': 820,
      'inputText':
          '{"file_path":"${demoWorkspacePath}app/lib/widgets/drawer_menu.dart"}',
      'output': {
        'text':
            '(41 lines shown of 132)\nclass DrawerMenu extends StatelessWidget {\n  final bool open;\n  final void Function() onToggle;\n  // …\n}',
      },
    },
    {
      'rowId': 6,
      'kind': 'assistantText',
      'entityId': 'ea-1',
      'text': '找到了。`DrawerMenu` 只处理了按钮点击的开关，没有拦截系统返回键；而且项目刚升到 Flutter 3.19，旧的 `WillPopScope` 写法已经失效。用 `PopScope` 在抽屉打开时拦截返回键即可，iOS 侧手势返回走的是同一条路由管道，一并覆盖。',
      'createdAt': at(14_000),
      'state': 'done',
    },
    {
      'rowId': 7,
      'kind': 'toolCall',
      'entityId': 'et-2',
      'toolCallId': 'tc-edit-1',
      'toolName': 'Edit',
      'status': 'done',
      'state': 'done',
      'createdAt': at(16_000),
      'durationMs': 1_150,
      'inputText':
          '{"file_path":"${demoWorkspacePath}app/lib/widgets/drawer_menu.dart","old_string":"return Scaffold(...);","new_string":"return PopScope(\n  canPop: !open,\n  child: Scaffold(...),\n);"}',
      'outputPreview': 'The file app/lib/widgets/drawer_menu.dart has been updated.',
    },
    {
      'rowId': 8,
      'kind': 'toolCall',
      'entityId': 'et-3',
      'toolCallId': 'tc-bash-1',
      'toolName': 'Bash',
      'status': 'done',
      'state': 'done',
      'createdAt': at(20_000),
      'durationMs': 6_240,
      'inputText':
          '{"command":"cd ${demoWorkspacePath}app && flutter test test/widget/drawer_menu_test.dart"}',
      'output': {
        'text':
            '00:06 +18: All tests passed!\n(open/close cycle, back-key interception, focus handoff …)',
      },
    },
    {
      'rowId': 9,
      'kind': 'toolCall',
      'entityId': 'et-4',
      'toolCallId': 'tc-agent-1',
      'toolName': 'Agent',
      'status': 'done',
      'state': 'done',
      'createdAt': at(24_000),
      'durationMs': 41_300,
      'inputText':
          '{"agent":"code-reviewer","prompt":"复查 PopScope 拦截返回键的修复，重点看焦点与无障碍语义。"}',
    },
    {
      'rowId': 10,
      'kind': 'subagent',
      'entityId': 'es-1',
      'parentToolCallId': 'tc-agent-1',
      'childSessionId': 's-sub-review',
      'subagentType': 'code-reviewer',
      'summaryText': '复查通过：修复方式正确，无阻塞问题；建议给 canPop 回调补一条注释说明拦截条件。',
      'status': 'done',
      'state': 'done',
      'createdAt': at(66_000),
    },
    {
      'rowId': 11,
      'kind': 'assistantText',
      'entityId': 'ea-2',
      'text': '修复完成，总结如下：\n\n'
          '- **根因**：抽屉未拦截系统返回键；升到 Flutter 3.19 后旧 `WillPopScope` 已失效。\n'
          '- **修复**：外层包一层 `PopScope`，抽屉打开时 `canPop: false`，返回键只收起抽屉不退出页面：\n\n'
          '```dart\nPopScope(\n  canPop: !menuOpen,\n  onPopInvoked: (didPop) {\n    if (!didPop) closeDrawer();\n  },\n  child: const Scaffold(body: HomeView()),\n)\n```\n\n'
          '- **验证**：18 个抽屉相关测试全过；子代理复查无阻塞问题。\n'
          '- **iOS**：手势返回与返回键走同一路由管道，已一并覆盖。\n\n'
          '剩下一条小建议（补注释）记在待办里了，需要我顺手改掉吗？',
      'createdAt': at(70_000),
      'state': 'done',
    },
  ];
}

/// 运行中会话（t-chart-dark）：打开即呈现审批卡（Bash 权限请求）+
/// 运行态。pendingInteractions 非空时看门狗不触发，适合静态截取。
List<Map<String, dynamic>> _chartDarkRows() {
  final t0 = _msAgo(const Duration(minutes: 14));
  int at(int offsetMs) => t0 + offsetMs;
  return [
    {'rowId': 1, 'kind': 'turnHeader', 'createdAt': at(0)},
    {
      'rowId': 2,
      'kind': 'userInput',
      'entityId': 'eu-2',
      'text': '深色模式下首页的趋势图几乎看不清，曲线和网格都糊在一起了。帮我调一下配色，对比度至少要到 WCAG AA。',
      'createdAt': at(2_000),
    },
    {
      'rowId': 3,
      'kind': 'turnHeader',
      'createdAt': at(6_000),
    },
    {
      'rowId': 4,
      'kind': 'reasoning',
      'entityId': 'er-2',
      'text': '先读图表主题文件确认当前取色，再跑静态分析看有没有现成的语义色常量可以复用。',
      'createdAt': at(8_000),
      'state': 'done',
    },
    {
      'rowId': 5,
      'kind': 'toolCall',
      'entityId': 'et-5',
      'toolCallId': 'tc-read-2',
      'toolName': 'Read',
      'status': 'done',
      'state': 'done',
      'createdAt': at(10_000),
      'durationMs': 610,
      'inputText':
          '{"file_path":"${demoWorkspacePath}app/lib/theme/chart_theme.dart"}',
      'output': {
        'text':
            '(58 lines shown of 96)\nclass ChartTheme {\n  static const grid = legacyGrid; // ← 深浅色共用的硬编码灰\n}',
      },
    },
    {
      'rowId': 6,
      'kind': 'toolCall',
      'entityId': 'et-6',
      'toolCallId': 'tc-bash-2',
      'toolName': 'Bash',
      'status': 'waiting',
      'state': 'streaming',
      'createdAt': at(14_000),
      'inputText': '{"command":"cd ${demoWorkspacePath}app && flutter analyze --no-pub"}',
    },
  ];
}

List<Map<String, dynamic>> _lightRows(String title, String answer) {
  final t0 = _msAgo(const Duration(hours: 6));
  return [
    {'rowId': 1, 'kind': 'turnHeader', 'createdAt': t0},
    {
      'rowId': 2,
      'kind': 'userInput',
      'entityId': 'eu-l',
      'text': title,
      'createdAt': t0 + 2_000,
    },
    {
      'rowId': 3,
      'kind': 'turnHeader',
      'createdAt': t0 + 6_000,
    },
    {
      'rowId': 4,
      'kind': 'assistantText',
      'entityId': 'ea-l',
      'text': answer,
      'createdAt': t0 + 20_000,
      'state': 'done',
    },
  ];
}

Map<String, dynamic> _conversationSnapshot({
  required String title,
  required List<Map<String, dynamic>> rows,
  required String phase,
  int revision = 7,
  Map<String, dynamic>? config,
  Map<String, dynamic>? controlPatch,
  List<Map<String, dynamic>>? pendingInteractions,
  Map<String, dynamic>? goal,
  Map<String, dynamic>? workflowRuns,
}) => {
  'logEpoch': 'demo-e1',
  'revision': revision,
  'title': title,
  'rows': {
    'window': rows,
    'totalCount': rows.length,
    'firstRowId': rows.isNotEmpty ? rows.first['rowId'] : null,
  },
  'workflowRuns': ?workflowRuns,
  'control': {
    'phase': phase,
    'canStop': phase == 'running',
    'activeWorks': phase == 'running'
        ? [
            {
              'foregroundExecutionId': 'exec-$title',
              'kind': 'turn',
            },
          ]
        : const <Map<String, dynamic>>[],
    ...?controlPatch,
  },
  'config':
      config ??
      const {
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
    'contextWindow': {'usedTokens': 41200, 'maxTokens': 128000},
  },
  'pendingInteractions': ?pendingInteractions,
  'goal': ?goal,
};

/// 全部静态会话快照（视频动态会话由 DemoScript 生成）。
Map<String, Map<String, dynamic>> demoConversationSnapshots() => {
  // workflowRuns 投影与 demoWorkflowRuns() 目录同源：目录页按 runId
  // 联接两路（目录查询无 lastEventSequence、投影才有），投影缺席时
  // 列表展示不全（投影缺席时只出一条）。
  't-menu-fix': _conversationSnapshot(
    title: '修复 #142 安卓返回键无法收起抽屉菜单',
    rows: _menuFixRows(),
    phase: 'completedSuccess',
    workflowRuns: {
      'runs': [
        {
          'runId': 'run-release-notes',
          'toolCallId': 'tc-wf-1',
          'label': '生成 v2.4 发布说明草稿',
          'status': 'completed',
          'lastEventSequence': 3,
        },
        {
          'runId': 'run-shot-diff',
          'toolCallId': 'tc-wf-2',
          'label': '抽屉菜单截图回归对比',
          'status': 'errored',
          'lastEventSequence': 2,
        },
        {
          'runId': 'run-dep-audit',
          'toolCallId': 'tc-wf-3',
          'label': '依赖审计与许可证清单',
          'status': 'completed',
          'lastEventSequence': 2,
        },
      ],
    },
  ),
  't-chart-dark': _conversationSnapshot(
    title: '修复深色模式下图表颜色对比度不足',
    rows: _chartDarkRows(),
    phase: 'running',
    pendingInteractions: [
      {
        'interactionId': 'ia-chart-dark',
        'payload': {
          'kind': 'permission',
          'toolName': 'Bash',
          'summary': '运行 flutter analyze --no-pub',
          'prompt': '助手请求运行以下命令来检查语义色常量：',
          'detail': {
            'command': 'cd ${demoWorkspacePath}app && flutter analyze --no-pub',
          },
          'options': [
            {'value': 'allow', 'label': '允许'},
            {'value': 'allowSession', 'label': '本次会话内允许'},
            {'value': 'deny', 'label': '拒绝'},
          ],
        },
        'autoResolution': {
          'state': 'snoozed',
          'deadlineAt': _msAhead(const Duration(minutes: 10)),
        },
      },
    ],
  ),
  for (final t in _demoTasks)
    if (!const ['t-menu-fix', 't-chart-dark'].contains(t.taskId))
      demoSessionIdOf(t.taskId): _conversationSnapshot(
        title: t.title,
        rows: _lightRows(t.title, t.preview.isEmpty ? '已完成。' : t.preview),
        phase: t.phase,
      ),
  // 子代理会话（会话列表下钻可达）：与 listSessionSubagents 的
  // childSessionId 对应，避免下钻落空转圈。
  's-sub-review': _conversationSnapshot(
    title: 'code-reviewer · 复查抽屉返回键修复',
    rows: _lightRows(
      '复查 PopScope 拦截返回键的修复，重点看焦点与无障碍语义。',
      '复查通过：修复方式正确，无阻塞问题；建议给 canPop 回调补一条注释说明拦截条件。',
    ),
    phase: 'completedSuccess',
  ),
};

// ---------------------------------------------------------- 工作流

/// 旗舰会话的工作流 run 目录（挂在 t-menu-fix 上）。
Map<String, dynamic> demoWorkflowRuns() => {
  'runs': [
    {
      'runId': 'run-release-notes',
      'toolCallId': 'tc-wf-1',
      'label': '生成 v2.4 发布说明草稿',
      'status': 'completed',
      'updatedAt': _msAgo(const Duration(hours: 29)),
    },
    {
      'runId': 'run-shot-diff',
      'toolCallId': 'tc-wf-2',
      'label': '抽屉菜单截图回归对比',
      'status': 'errored',
      'failureCode': 'artifact-missing',
      'failureMessage': '基准截图缺失：drawer/closed@v2.3',
      'updatedAt': _msAgo(const Duration(hours: 28)),
    },
    {
      'runId': 'run-dep-audit',
      'toolCallId': 'tc-wf-3',
      'label': '依赖审计与许可证清单',
      'status': 'completed',
      'updatedAt': _msAgo(const Duration(days: 2)),
    },
  ],
};

Map<String, dynamic> demoWorkflowRunEvents(String runId) => switch (runId) {
  'run-release-notes' => {
    'events': [
      {
        'sequence': 1,
        'type': 'run-start',
        'message': '工作流启动：读取 CHANGELOG 与最近提交',
        'at': _msAgo(const Duration(hours: 29, minutes: 4)),
      },
      {
        'sequence': 2,
        'type': 'step',
        'message': '汇总 12 个提交，归类为 3 个特性 / 5 个修复 / 4 个杂项',
        'at': _msAgo(const Duration(hours: 29, minutes: 2)),
      },
      {
        'sequence': 3,
        'type': 'artifact',
        'message': '产出 release-notes.md 草稿',
        'at': _msAgo(const Duration(hours: 29)),
      },
    ],
    'hasMore': false,
  },
  'run-shot-diff' => {
    'events': [
      {
        'sequence': 1,
        'type': 'run-start',
        'message': '对 6 组截图执行像素差分',
        'at': _msAgo(const Duration(hours: 28, minutes: 10)),
      },
      {
        'sequence': 2,
        'type': 'error',
        'message': '基准截图缺失：drawer/closed@v2.3',
        'at': _msAgo(const Duration(hours: 28)),
      },
    ],
    'hasMore': false,
  },
  _ => {
    'events': [
      {
        'sequence': 1,
        'type': 'run-start',
        'message': '扫描 pubspec.lock 全部直接与传递依赖',
        'at': _msAgo(const Duration(days: 2)),
      },
      {
        'sequence': 2,
        'type': 'artifact',
        'message': '产出 licenses.txt（47 项，1 项需标注）',
        'at': _msAgo(const Duration(days: 2) - const Duration(minutes: 3)),
      },
    ],
    'hasMore': false,
  },
};

Map<String, dynamic> demoWorkflowRunArtifacts(String runId) => switch (runId) {
  'run-release-notes' => {
    'artifacts': [
      {
        'id': 'art-notes',
        'kind': 'markdown',
        'version': 2,
        'title': 'release-notes.md',
      },
    ],
  },
  'run-dep-audit' => {
    'artifacts': [
      {
        'id': 'art-licenses',
        'kind': 'text',
        'version': 1,
        'title': 'licenses.txt',
      },
    ],
  },
  _ => const {'artifacts': []},
};

const String _releaseNotesMd = '''# v2.4 发布说明（草稿）

## 特性
- 设置页新增数据导出（JSON）
- 深色模式图表配色达到 WCAG AA

## 修复
- #142 安卓返回键无法收起抽屉菜单
- 冷启动耗时回归

## 升级提示
- 网络层由 http 迁移至 dio，自定义拦截器需同步迁移
''';

Map<String, dynamic> demoWorkflowArtifactRead(
  String runId,
  String artifactId,
) => {
  'dataBase64': base64Encode(
    utf8.encode(
      artifactId == 'art-licenses'
          ? 'licenses.txt（演示节选）\n\n- flutter_markdown_plus — BSD-3-Clause\n- dio — MIT\n- …共 47 项'
          : _releaseNotesMd,
    ),
  ),
  'mediaType': artifactId == 'art-licenses' ? 'text/plain' : 'text/markdown',
  'nextOffset': null,
};

// ---------------------------------------------------------- 用量

/// 确定性「活跃度」函数：工作日中高、周末低、带周期起伏与零星空挡。
/// 无随机源——截图/测试跨次运行完全一致。
int _activityUnits(int daysAgo, int weekday) {
  if (daysAgo >= 70 && daysAgo <= 73) return 0; // 一段休假空挡
  if (daysAgo == 45) return 0; // 偶发空白日
  final weekend = weekday == 6 || weekday == 0;
  final wave = ((daysAgo * 37) % 11) - 5; // -5..5 的确定性起伏
  final base = weekend ? 26 : 63;
  return (base + wave * 6).clamp(0, 100);
}

List<Map<String, dynamic>> _heatmapWeeks(int weeks) {
  final today = DateTime.now();
  return [
    for (var w = weeks - 1; w >= 0; w--)
      {
        'days': [
          for (var d = 6; d >= 0; d--)
            () {
              final daysAgo = w * 7 + d;
              final date = today.subtract(Duration(days: daysAgo));
              final units = date.isAfter(today) ? 0 : _activityUnits(daysAgo, date.weekday);
              // level 是官方预计算档位（0=无活动，1-4 递增）——热力图
              // 直接读它上色，缺省全灰（实施时踩过：只给 token 数不显示）。
              final level = units <= 0
                  ? 0
                  : units < 35
                  ? 1
                  : units < 55
                  ? 2
                  : units < 70
                  ? 3
                  : 4;
              return {
                'date':
                    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
                'totalTokens': units * 18_400,
                'turnCount': (units / 7).round(),
                'toolCallCount': (units / 4).round(),
                'level': level,
              };
            }(),
        ],
      },
  ];
}

/// usage-stats.getEntitlementSnapshot：GLM 编码套餐。
/// 形状=官方 codingPlanQuotaPresentation 四卡口径：TOKENS_LIMIT 的
/// unit 是数字码（3=5 小时窗口/token、6=每周），TIME_LIMIT=每月工具
/// 调用，mcpQuota.aggregate=ZCode MCP；percentage=已用占比。
Map<String, dynamic> demoEntitlementSnapshot() => {
  'provider': {'id': 'account:zai-individual-coding-plan'},
  'quota': {
    'level': 'coding-plan',
    'limits': [
      {
        'type': 'TOKENS_LIMIT',
        'unit': 3,
        'number': 5,
        'percentage': 42,
        'usage': 2_000_000,
        'currentValue': 840_000,
        'nextResetTime': _msAhead(const Duration(hours: 2)),
      },
      {
        'type': 'TOKENS_LIMIT',
        'unit': 6,
        'percentage': 61,
        'usage': 20_000_000,
        'currentValue': 12_240_000,
        'periodStart': _msAgo(const Duration(days: 4)),
        'periodEnd': _msAhead(const Duration(days: 26)),
        'nextResetTime': _msAhead(const Duration(days: 26)),
      },
      {
        'type': 'TIME_LIMIT',
        'percentage': 23,
        'usage': 5_000,
        'currentValue': 1_150,
        'nextResetTime': _msAhead(const Duration(days: 26)),
      },
    ],
  },
  'mcpQuota': {
    'aggregate': {
      'percentage': 8,
      'usage': 10_000,
      'currentValue': 800,
      'nextResetTime': _msAhead(const Duration(days: 26)),
    },
  },
  'subscription': {
    'renewTime': _msAhead(const Duration(days: 26)),
    'expireTime': _msAhead(const Duration(days: 26)),
    'details': [
      {
        'productName': 'GLM-5.3 个人编码套餐（月付）',
        'billingCycle': 'monthly',
        'renewTime': _msAhead(const Duration(days: 26)),
        'expireTime': _msAhead(const Duration(days: 26)),
      },
    ],
  },
  'remaining': {
    'isShow': true,
    'percentage': 39,
    'usage': 20_000_000,
    'currentValue': 12_240_000,
    'nextResetTime': _msAhead(const Duration(days: 26)),
  },
  'serverTime': DateTime.now().millisecondsSinceEpoch,
};

/// usage-stats.getCodingPlanUsageSnapshot。
Map<String, dynamic> demoCodingPlanUsageSnapshot(String range) => {
  'activity': {
    'summary': {
      'totalTokens': 128_460_000,
      'peakDailyTokens': 1_940_000,
      'totalUsageDurationMs': 41_400_000,
      'currentStreakDays': 6,
      'longestStreakDays': 23,
      'favoriteModelName': 'GLM-5.3',
    },
    'heatmap': {'weeks': _heatmapWeeks(12)},
  },
  'modelUsage': _modelTrend(range),
};

/// usage-stats.getAppUsageSnapshot。
Map<String, dynamic> demoAppUsageSnapshot(String range) => {
  'timeZone': 'Asia/Shanghai',
  'summary': {
    'totalTokens': 41_230_000,
    'peakDailyTokens': 620_000,
    'longestSessionMs': 7_200_000,
    'currentStreakDays': 6,
    'longestStreakDays': 19,
    'totalSessions': 214,
    'totalTurns': 1_092,
    'cacheHitRate': 0.42,
    'favoriteModel': {'modelId': 'glm-5.3'},
  },
  'heatmap': {
    'endDate': _msAgo(Duration.zero).toString(),
    'weeks': _heatmapWeeks(12),
  },
  'dailyModelUsage': [
    for (var i = 6; i >= 0; i--)
      () {
        final date = DateTime.now().subtract(Duration(days: i));
        final d =
            '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
        final u = _activityUnits(i, date.weekday);
        return {
          'date': d,
          'models': [
            {'modelId': 'glm-5.3', 'totalTokens': u * 11_200},
            {'modelId': 'glm-5.3-air', 'totalTokens': u * 4_300},
            {'modelId': 'glm-5.3-flash', 'totalTokens': u * 2_900},
          ],
        };
      }(),
  ],
  'models': [
    {'modelId': 'glm-5.3', 'totalTokens': 23_600_000},
    {'modelId': 'glm-5.3-air', 'totalTokens': 9_700_000},
    {'modelId': 'glm-5.3-flash', 'totalTokens': 7_930_000},
  ],
};

Map<String, dynamic> _modelTrend(String range) {
  final points = range == 'today' ? 1 : (range == '7d' ? 7 : 30);
  return {
    'xTime': [
      for (var i = points - 1; i >= 0; i--)
        () {
          final date = DateTime.now().subtract(Duration(days: i));
          return '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
        }(),
    ],
    'modelDataList': [
      {
        'modelName': 'GLM-5.3',
        'totalTokens': 23_600_000,
        'tokensUsage': [
          for (var i = points - 1; i >= 0; i--)
            _activityUnits(i, DateTime.now().subtract(Duration(days: i)).weekday) * 11_200,
        ],
      },
      {
        'modelName': 'GLM-5.3-Air',
        'totalTokens': 9_700_000,
        'tokensUsage': [
          for (var i = points - 1; i >= 0; i--)
            _activityUnits(i, DateTime.now().subtract(Duration(days: i)).weekday) * 4_300,
        ],
      },
      {
        'modelName': 'GLM-5.3-Flash',
        'totalTokens': 7_930_000,
        'tokensUsage': [
          for (var i = points - 1; i >= 0; i--)
            _activityUnits(i, DateTime.now().subtract(Duration(days: i)).weekday) * 2_900,
        ],
      },
    ],
  };
}

// ---------------------------------------------------------- 模型目录

/// model-selection.getView：草稿模型目录（个人套餐 + API 双来源）。
Map<String, dynamic> demoModelSelectionView() => {
  'providers': [
    {
      // 组名对齐桌面真实分组（buildComposerPlanGroups：Z.AI/BigModel/
      // OCG 各一组；用户实证其账号下套餐组名=BigModel）。providerId
      // 保留 plan token 供徽标兜底判定。
      'providerId': 'account:bigmodel-individual-coding-plan',
      'providerName': 'BigModel',
      'config': {
        'access': {'mode': 'individual-coding-plan', 'accountType': 'bigmodel'},
      },
      'models': [
        for (final m in const [
          ('glm-5.3', 'GLM-5.3'),
          ('glm-5.3-air', 'GLM-5.3-Air'),
          ('glm-5.3-flash', 'GLM-5.3-Flash'),
        ])
          {
            'modelId': m.$1,
            'config': {
              'optionSpecs': {
                'reasoningLevel': {
                  'values': ['nothink', 'think', 'thinkhard', 'ultrathink'],
                },
              },
            },
          },
      ],
    },
    {
      'providerId': 'moonshot',
      'providerName': 'Moonshot',
      'config': {
        'access': {'mode': 'api-key', 'accountType': 'moonshot'},
      },
      'models': [
        for (final m in const ['kimi-k2-thinking', 'kimi-k2'])
          {
            'modelId': m,
            'config': {
              'optionSpecs': {
                'reasoningLevel': {'values': ['nothink', 'think']},
              },
            },
          },
      ],
    },
    {
      'providerId': 'opencode-zen',
      'providerName': 'OCG',
      'config': {
        'access': {'mode': 'api-key', 'accountType': 'opencode'},
      },
      'models': [
        for (final m in const ['claude-sonnet-4.5', 'gpt-5.2'])
          {
            'modelId': m,
            'config': {
              'optionSpecs': {
                'reasoningLevel': {'values': ['nothink', 'think']},
              },
            },
          },
      ],
    },
  ],
};

/// zcode-task.getTaskConfigOptions：会话配置目录（模型/思考/模式）。
List<Map<String, dynamic>> demoTaskConfigOptions() => [
  {
    'id': 'modelSelection',
    'name': '模型',
    'category': 'model',
    'type': 'enum',
    'currentValue': 'glm-5.3',
    'options': [
      for (final m in const [
        ('glm-5.3', 'GLM-5.3', 'account:bigmodel-individual-coding-plan', 'BigModel', 'individual-coding-plan'),
        ('glm-5.3-air', 'GLM-5.3-Air', 'account:bigmodel-individual-coding-plan', 'BigModel', 'individual-coding-plan'),
        ('glm-5.3-flash', 'GLM-5.3-Flash', 'account:bigmodel-individual-coding-plan', 'BigModel', 'individual-coding-plan'),
        ('kimi-k2-thinking', 'kimi-k2-thinking', 'moonshot', 'Moonshot', 'api-key'),
        ('kimi-k2', 'kimi-k2', 'moonshot', 'Moonshot', 'api-key'),
        ('claude-sonnet-4.5', 'claude-sonnet-4.5', 'opencode-zen', 'OCG', 'api-key'),
        ('gpt-5.2', 'gpt-5.2', 'opencode-zen', 'OCG', 'api-key'),
      ])
        {
          'value': m.$1,
          'name': m.$2,
          'modelProviderId': m.$3,
          'modelProviderName': m.$4,
          'modelAccessMode': m.$5,
          'modelAccessAccountType': m.$3.contains('coding-plan') ? 'bigmodel' : '',
          'modelThoughtLevels': m.$3.contains('coding-plan')
              ? ['nothink', 'think', 'thinkhard', 'ultrathink']
              : ['nothink', 'think'],
        },
    ],
  },
  {
    'id': 'reasoningLevel',
    'name': '思考',
    'category': 'model',
    'type': 'enum',
    'currentValue': 'think',
    'options': [
      for (final lv in const [
        ('nothink', '关闭'),
        ('think', '标准'),
        ('thinkhard', '深入'),
        ('ultrathink', '极致'),
      ])
        {'value': lv.$1, 'name': lv.$2},
    ],
  },
  {
    'id': 'collaborationMode',
    'name': '模式',
    'category': 'mode',
    'type': 'enum',
    'currentValue': 'build',
    'options': const [
      {'value': 'build', 'name': '构建'},
      {'value': 'edit', 'name': '编辑'},
      {'value': 'guarded', 'name': '守卫'},
      {'value': 'yolo', 'name': '自由'},
    ],
  },
];

// ---------------------------------------------------------- 子代理

/// subagents.list。
Map<String, dynamic> demoSubagentsList() => {
  'agents': [
    for (final a in const [
      ('code-reviewer', '代码审查', '对照项目规范审查改动，输出阻塞项与建议两级结论。'),
      ('unit-tester', '单元测试', '为指定模块补齐单元测试，优先覆盖边界与并发路径。'),
      ('refactor-advisor', '重构建议', '扫描坏味道并给出小步重构方案，不动行为。'),
    ])
      {
        'id': a.$1,
        'name': a.$1,
        'description': a.$3,
        'enabled': true,
        'path': '$demoWorkspacePath/.zcode/agents/${a.$1}.md',
        'scope': 'builtin',
        'source': 'builtin',
      },
  ],
  'userAgents': [
    {
      'id': 'ua-dart-doc',
      'name': 'dart-doc-writer',
      'description': '按 dartdoc 规范补全公共 API 文档注释。',
      'enabled': false,
      'path': '~/.zcode/agents/dart-doc-writer.md',
      'scope': 'user',
      'source': 'user',
    },
  ],
  'pluginAgents': [
    {
      'id': 'pa-docs-sync',
      'name': 'docs-sync',
      'description': '把变更同步到文档站并检查死链。',
      'enabled': true,
      'path': 'plugins/docs-sync/agent.json',
      'scope': 'workspace',
      'source': 'plugin',
    },
  ],
};

// ---------------------------------------------------------- 杂项目录

/// git 通道。
Map<String, dynamic> demoGitRepoInfo() => {
  'kind': 'repository',
  'isGitAvailable': true,
  'currentBranch': 'fix/drawer-back-key',
};

Map<String, dynamic> demoGitBranches() => {
  'currentBranchName': 'fix/drawer-back-key',
  'branches': [
    {'name': 'main', 'isCurrent': false, 'upstreamName': 'origin/main'},
    {'name': 'fix/drawer-back-key', 'isCurrent': true},
    {'name': 'release/2.4', 'isCurrent': false},
    {'name': 'feature/export-settings', 'isCurrent': false},
  ],
};

/// zcode-session.readWorkspacePresentation。
Map<String, dynamic> demoWorkspacePresentation() => {
  'mode': 'build',
  'slashCommands': const [
    {'name': 'compact', 'description': '压缩上下文', 'source': 'builtin'},
    {'name': 'review', 'description': '审查当前改动', 'source': 'builtin'},
    {'name': 'release-notes', 'description': '生成发布说明草稿', 'source': 'project'},
  ],
};

/// skills.list。
List<Map<String, dynamic>> demoSkills() => const [
  {'id': 'pdf-export', 'name': 'pdf-export', 'description': '把报告导出为 PDF', 'enabled': true, 'scope': 'user'},
  {'id': 'i18n-check', 'name': 'i18n-check', 'description': '检查文案是否有漏翻', 'enabled': true, 'scope': 'workspace'},
];

/// file.searchWorkspaceFiles。
List<Map<String, dynamic>> demoFileSearch(String query) => [
  for (final p in const [
    'app/lib/widgets/drawer_menu.dart',
    'app/lib/theme/chart_theme.dart',
    'app/test/widget/drawer_menu_test.dart',
    'docs/guide/migrate-v2.3.md',
    'docs/README.en.md',
  ])
    if (p.contains(query.toLowerCase()))
      {'path': '$demoWorkspacePath/$p', 'name': p.split('/').last},
];

/// 自动化目录（listAllAutomations 的行形状）。
List<Map<String, dynamic>> demoAutomations() => [
  {
    'id': 'at-health',
    'title': '站点健康检查',
    'prompt': '访问 docs 站点五个核心页面，报告非 200 与加载超时。',
    'cronExpr': '30 9 * * *',
    'recurring': true,
    'enabled': true,
    'createdAt': _msAgo(const Duration(days: 40)),
    'updatedAt': _msAgo(const Duration(days: 10)),
  },
  {
    'id': 'at-dep-check',
    'title': '每周依赖检查',
    'prompt': '检查 pubspec 直接依赖是否有新稳定版，汇总升级风险。',
    'cronExpr': '0 9 * * 1',
    'recurring': true,
    'enabled': false,
    'createdAt': _msAgo(const Duration(days: 60)),
    'updatedAt': _msAgo(const Duration(days: 20)),
  },
];
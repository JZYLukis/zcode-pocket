import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';
import 'package:zcode_pocket/ui/subagents_page.dart';

/// 内置/插件子智能体的「模型/思考档覆盖」：官方语义=只读档案不开放全
/// 字段编辑，开放行内模型/effort 覆盖（SubagentsSection
/// supportsModelOverride 对位；写用户级 agents-state，null=清除）。
/// 验收④重排：弹层+保存钮→两只行内下拉 chip 即改即存（官方
/// SubagentModelOverrideControl 对位）。断言：内置/插件行选模型/思考档
/// /继承默认的通道载荷正确；官方门（仅 general-purpose/Explore+插件）；
/// 自定义行照旧全量编辑。

class _OverrideChannel extends ChannelClient {
  _OverrideChannel() : super(sendBody: (_) {});

  final calls = <(String, Map<String, dynamic>)>[];
  Map<String, dynamic>? updateArgs;
  // 按 agentId 记覆盖（保存后下一次 list 带回，模拟官方 list 投影）。
  final overridesById = <String, Map<String, dynamic>?>{};

  Map<String, dynamic> _agent(
    String id,
    String name,
    String source,
    String scope, {
    Map<String, dynamic>? override,
    String? projectPath,
  }) => {
    'id': id,
    'name': name,
    'description': '$name 的描述',
    'systemPrompt': '$name 的系统提示词',
    'source': source,
    'scope': scope,
    'enabled': true,
    if (projectPath != null) 'projectPath': projectPath,
    if (override != null) 'modelSelectionOverride': override,
  };

  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    switch (method) {
      case 'list':
        return {
          // 宿主真实形态（subagentsService list=allRuntimeScopes）：agents
          // 是运行时投影，canonical 插件条目与 user/workspace 可编辑档案
          // 都在其中；pluginAgents/userAgents 各是一份投影——直接双渲染
          // 即真机 8 卡重复事故。
          'agents': [
            _agent(
              'builtin-general-purpose',
              'general-purpose',
              'built-in',
              'built-in',
              override: overridesById['builtin-general-purpose'],
            ),
            _agent('builtin-code-reviewer', 'code-reviewer', 'built-in', 'built-in'),
            _agent(
              'plugin:demo:helper',
              'demo:helper',
              'plugin',
              'plugin',
              override: overridesById['plugin:demo:helper'],
            ),
            _agent('my-agent', 'my-agent', 'user', 'user'),
            _agent(
              'ws-agent',
              'ws-helper',
              'user',
              'workspace',
              projectPath: '/example-workspace-other',
            ),
          ],
          'pluginAgents': [
            _agent(
              'plugin:demo:helper',
              'demo:helper',
              'plugin',
              'plugin',
              override: overridesById['plugin:demo:helper'],
            ),
          ],
          'userAgents': [
            _agent('my-agent', 'my-agent', 'user', 'user'),
          ],
        };
      case 'updateAgent':
        updateArgs = (args.first as Map).cast<String, dynamic>();
        return null;
      case 'setBuiltInModelOverride':
      case 'setPluginAgentModelOverride':
        final a = (args.first as Map).cast<String, dynamic>();
        calls.add((method, a));
        final ms = a['modelSelection'];
        final targetId = method == 'setPluginAgentModelOverride'
            ? '${a['agentId']}'
            : 'builtin-general-purpose';
        overridesById[targetId] = ms is Map ? ms.cast<String, dynamic>() : null;
        return null;
      case 'getView':
        return {
          'providers': [
            {
              'providerId': 'prov-a',
              'models': [
                {
                  'modelId': 'glm-test',
                  'config': {
                    'optionSpecs': {
                      'reasoningLevel': {
                        'values': ['low', 'high'],
                      },
                    },
                  },
                },
              ],
            },
          ],
        };
      default:
        return {};
    }
  }
}

class _OverrideBridge implements BridgeSession {
  final _OverrideChannel channel = _OverrideChannel();
  @override
  Map<String, dynamic>? get projectIntent => null;
  @override
  Map<String, dynamic>? get taskIntent => null;
  @override
  final ValueNotifier<String?> degraded = ValueNotifier(null);
  @override
  final ValueNotifier<int> recovered = ValueNotifier(0);
  @override
  Future<void> waitHealthy({
    Duration timeout = const Duration(seconds: 45),
  }) async {}
  @override
  Map<String, dynamic> get bridge => const {};
  @override
  RpcFrameTransport get transport => throw UnimplementedError();
  @override
  ChannelClient get channels => channel;
  @override
  String? get workspaceKey => 'ws-override';
  @override
  String? get initialTaskId => null;
  @override
  ConversationTransport conversation(
    Map<String, dynamic> scope, {
    void Function(String line)? onLog,
  }) => throw UnimplementedError();
  @override
  void dispose() {}
}

class _OverrideApp extends AppState {
  @override
  final BridgeSession bridge = _OverrideBridge();
  @override
  Map<String, dynamic>? get activeWorkspace => const {
    'workspacePath': '/example-workspace',
    'workspaceIdentity': 'ws-override',
  };

  @override
  Future<List<dynamic>> modelSelectionOptions() async => [
    ConfigOption.fromMap({
      'id': 'model',
      'name': 'Model',
      'options': const [
        {
          'value': 'prov-a/glm-test',
          'name': 'glm-test',
          'modelProviderId': 'prov-a',
          'modelThoughtLevels': ['low', 'high'],
        },
      ],
    }),
  ];
}

Future<void> _pump(WidgetTester tester, _OverrideApp app) async {
  await tester.pumpWidget(
    AppStateScope(
      app: app,
      child: MaterialApp(theme: buildAppTheme(), home: const SubagentsPage()),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 验收#17（P 重排）：覆盖下拉在点行展开区内——调用方先显式
/// 展开所属行（tap rowKey），本助手只负责点下拉+选菜单项。
Future<void> _expandRow(WidgetTester tester, Key rowKey) async {
  await tester.tap(find.byKey(rowKey));
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pick(
  WidgetTester tester,
  Key chipKey,
  String menuItem,
) async {
  final chipCtx = tester.element(find.byKey(chipKey));
  await Scrollable.ensureVisible(chipCtx);
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.tap(find.byKey(chipKey));
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.tap(find.text(menuItem).last);
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('内置行行内选模型即改即存：setBuiltInModelOverride + chip 文字即状态', (
    tester,
  ) async {
    final app = _OverrideApp();
    await _pump(tester, app);
    final channel = (app.bridge as _OverrideBridge).channel;

    // 验收#17（P 重排）：覆盖下拉默认收起（点行展开）；非目标行
    // 展开后也没有。
    expect(
      find.byKey(const ValueKey('override-model-builtin-general-purpose')),
      findsNothing,
      reason: '默认收起（主行只显模型摘要副行）',
    );
    await tester.tap(
      find.byKey(const ValueKey('subagent-builtin-general-purpose')),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      find.byKey(const ValueKey('override-model-builtin-general-purpose')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('override-model-builtin-code-reviewer')),
      findsNothing,
    );
    expect(
      find.text('继承默认'),
      findsOneWidget,
      reason: '展开行的模型下拉显示继承默认（未覆盖态）',
    );

    await _pick(
      tester,
      const ValueKey('override-model-builtin-general-purpose'),
      'glm-test',
    );

    expect(channel.calls, hasLength(1));
    expect(channel.calls.first.$1, 'setBuiltInModelOverride');
    expect(channel.calls.first.$2['agentName'], 'general-purpose');
    expect(channel.calls.first.$2['modelSelection'], {
      'providerId': 'prov-a',
      'modelId': 'glm-test',
    }, reason: '官方 modelSelectionSchema strict 形状（无思考档=不带 options）');
    expect(find.text('glm-test'), findsOneWidget, reason: 'chip 文字即覆盖状态');
  });

  testWidgets('插件行 agentId 键；思考档随选下发；继承默认=清除传 null', (
    tester,
  ) async {
    final app = _OverrideApp();
    await _pump(tester, app);
    final channel = (app.bridge as _OverrideBridge).channel;

    await _expandRow(
      tester,
      const ValueKey('subagent-plugin:demo:helper'),
    );
    await _pick(
      tester,
      const ValueKey('override-model-plugin:demo:helper'),
      'glm-test',
    );
    expect(
      channel.calls.map((c) => c.$1),
      contains('setPluginAgentModelOverride'),
    );
    final pluginCall = channel.calls
        .firstWhere((c) => c.$1 == 'setPluginAgentModelOverride');
    expect(pluginCall.$2['agentId'], 'plugin:demo:helper');

    // 思考档：有模型基后可选，随 options.reasoningLevel 下发。
    await _pick(
      tester,
      const ValueKey('override-thought-plugin:demo:helper'),
      'high',
    );
    final thoughtCall = channel.calls.last;
    expect(thoughtCall.$2['modelSelection']['options'], {
      'reasoningLevel': 'high',
    });

    // 继承默认=清除覆盖（modelSelection: null）。
    await _pick(
      tester,
      const ValueKey('override-model-plugin:demo:helper'),
      '继承默认',
    );
    expect(channel.calls.last.$2['modelSelection'], isNull,
        reason: 'null=清除覆盖恢复默认（官方 normalize 语义）');
    expect(
      find.text('继承默认'),
      findsOneWidget,
      reason: '清除后插件行（展开中）回继承默认',
    );
  });

  testWidgets('官方门：非 general-purpose/Explore 的内置行无 chips；自定义行照旧编辑', (
    tester,
  ) async {
    final app = _OverrideApp();
    await _pump(tester, app);

    expect(
      find.byKey(const ValueKey('override-model-builtin-code-reviewer')),
      findsNothing,
      reason: '官方 supportsModelOverride 仅 general-purpose/Explore+插件',
    );

    await tester.tap(find.byKey(const ValueKey('subagent-my-agent')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('编辑子智能体'), findsOneWidget, reason: '自定义行照旧打开全量编辑器');
  });

  // 真机 2026-11-05 反馈②：4 个 *:visual-judge 在「内置」与「插件」组
  // 整组重复 8 张卡。根因=宿主 agents（运行时投影含插件 canonical 与
  // user/workspace 档案）与 pluginAgents/userAgents 双渲染；官方
  // groupAgentsByScope 按 isEditableUserAgent 先归自定义组。
  testWidgets('运行时代理分组：插件/用户档案各只出现一次，内置计数正确', (
    tester,
  ) async {
    final app = _OverrideApp();
    await _pump(tester, app);

    expect(
      find.byKey(const ValueKey('subagent-plugin:demo:helper')),
      findsOneWidget,
      reason: '插件条目仅插件组一张卡（修复前 agents+pluginAgents 双渲染=两卡同 key）',
    );
    expect(
      find.byKey(const ValueKey('subagent-my-agent')),
      findsOneWidget,
      reason: 'user 档案只出现一次（agents 运行时投影与 userAgents 双源同 id 去重）',
    );
    expect(
      find.byKey(const ValueKey('subagent-ws-agent')),
      findsOneWidget,
      reason: 'workspace 档案只出现在自定义组',
    );
    expect(
      find.text('内置 (2)'),
      findsOneWidget,
      reason: '内置组只含真内置两条（修复前 agents 含插件+user/workspace=5）',
    );
    expect(
      find.text('自定义 (2)'),
      findsOneWidget,
      reason: '用户+工作区可编辑档案归自定义组',
    );
    expect(
      find.text('插件 (1)'),
      findsOneWidget,
      reason: '插件组计数照常',
    );
  });

  // 中④：编辑工作区作用域子代理此前 scope 硬编码 'user'——
  // 一次编辑把档案搬到用户目录（位置/归属全变）。
  testWidgets('编辑工作区作用域子代理：scope/projectPath 原样回写', (tester) async {
    final app = _OverrideApp();
    await _pump(tester, app);
    final channel = (app.bridge as _OverrideBridge).channel;

    await tester.tap(find.byKey(const ValueKey('subagent-ws-agent')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('编辑子智能体'), findsOneWidget, reason: '自定义/工作区行打开编辑器');
    final saveBtn = find.widgetWithText(FilledButton, '保存');
    await tester.ensureVisible(saveBtn);
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(saveBtn);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final args = channel.updateArgs;
    expect(args, isNotNull, reason: '保存走 updateAgent');
    expect(args!['agentId'], 'ws-agent');
    expect(args['scope'], 'workspace',
        reason: '工作区档案不得被搬到用户作用域');
    expect(args['workspacePath'], '/example-workspace-other',
        reason: 'workspacePath 优先 agent.projectPath');
    expect(args.containsKey('workspaceIdentity'), isFalse,
        reason: '非活跃工作区路径不配当前 identity');
  });
}

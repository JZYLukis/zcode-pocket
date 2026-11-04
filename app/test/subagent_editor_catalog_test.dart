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

class _AgentChannel extends ChannelClient {
  _AgentChannel() : super(sendBody: (_) {});
  Map<String, dynamic>? created;

  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    switch (method) {
      case 'list':
        return {'userAgents': [], 'agents': [], 'pluginAgents': []};
      case 'createAgent':
        created = (args.first as Map).cast<String, dynamic>();
        return {'ok': true};
      case 'getView':
        return {
          'providers': [
            {
              'providerId': 'prov-a',
              'providerName': '个人套餐',
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

class _AgentBridge implements BridgeSession {
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
  final ChannelClient channels = _AgentChannel();
  @override
  String? get workspaceKey => 'ws-agent';
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

class _AgentApp extends AppState {
  @override
  final BridgeSession bridge = _AgentBridge();
  @override
  Map<String, dynamic>? get activeWorkspace => const {
    'workspacePath': '/example-workspace',
    'workspaceIdentity': 'ws-agent',
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

void main() {
  testWidgets('无活跃会话也能设置子代理默认模型与思考强度', (tester) async {
    final app = _AgentApp();
    expect(app.conversationStates, isEmpty);
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(theme: buildAppTheme(), home: const SubagentsPage()),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey('subagent-new')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    await tester.enterText(find.byType(TextField).at(0), 'test-agent');
    await tester.enterText(find.byType(TextField).at(1), '测试子代理');
    await tester.enterText(find.byType(TextField).at(2), '完成测试任务');

    await tester.tap(find.byType(DropdownButtonFormField<String?>).first);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('glm-test').last);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byType(DropdownButtonFormField<String?>).last);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('high').last);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final channel = app.bridge.channels as _AgentChannel;
    final config = channel.created?['config'] as Map<String, dynamic>?;
    expect(config, isNotNull);
    expect(config?['modelSelection'], {
      'providerId': 'prov-a',
      'modelId': 'glm-test',
      'options': {'reasoningLevel': 'high'},
    });
  });

  test('生产 getView 映射读取嵌套思考档与套餐名', () async {
    final app = _AgentApp();
    final transport = ConversationTransport(
      session: app.bridge,
      scope: const {
        'workspacePath': '/example-workspace',
        'workspaceIdentity': 'ws-agent',
      },
    );
    final options = await transport.modelSelectionOptions();
    expect(options, hasLength(1));
    final value = options.first.options.first;
    expect(value.modelThoughtLevels, ['low', 'high']);
    expect(value.modelProviderName, '个人套餐');
  });
}

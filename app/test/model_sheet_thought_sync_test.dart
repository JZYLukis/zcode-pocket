// 2026-11-08 批 #7（中）：模型弹层联动作废旧思考档时只清了
// 弹层 _draftThought，页面 _pendingThought 照旧提交（发送时把不支持的
// 档位带给新模型）；且滑条当前值不在可选档位时静默回退默认档，无提示。
// 本文件锁两层：清除回调接线 + 不可用档可见提示。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/ui/composer_panels.dart';

class _ThoughtApp extends AppState {
  @override
  Future<List<dynamic>> modelSelectionOptions() async => [
    ConfigOption.fromMap({
      'id': 'model',
      'name': 'Model',
      'options': const [
        {
          'value': 'prov-a/plain',
          'name': 'Plain 模型',
          'modelProviderId': 'prov-a',
        },
        {
          'value': 'prov-a/k3',
          'name': 'Kimi K3',
          'modelProviderId': 'prov-a',
          // 新模型只支持 off/low——旧挂起档 high 必须被作废。
          'modelThoughtLevels': ['off', 'low'],
        },
      ],
    }),
  ];

  @override
  Future<Map<String, dynamic>?> modelSelectionView() async => const {
    'providers': [
      {
        'providerId': 'prov-a',
        'models': [
          {
            'modelId': 'plain',
            'config': {
              'optionSpecs': {
                'reasoningLevel': {
                  'values': ['off', 'low'],
                },
              },
            },
          },
          {
            // k3 同在 prov-a 组（分组按 provider）——缺元数据会被归入
            // 默认收起的未知组，行不渲染。
            'modelId': 'k3',
            'config': {
              'optionSpecs': {
                'reasoningLevel': {
                  'values': ['off', 'low'],
                },
              },
            },
          },
        ],
      },
    ],
  };
}

void main() {
  testWidgets('旧思考档与滑条都可用的提示 + 换模型作废时清页面挂起值', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    String? pendingThought = 'high';
    var clearedCalls = 0;

    await tester.pumpWidget(
      AppStateScope(
        app: _ThoughtApp(),
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Builder(
            builder: (context) => TextButton(
              key: const ValueKey('open'),
              onPressed: () => showModelSheet(
                context,
                sessionId: null,
                state: ConversationState(),
                pendingModelProvider: 'prov-a',
                pendingModelId: 'plain',
                pendingThought: pendingThought,
                onDraftThought: (v) => pendingThought = v,
                onDraftThoughtCleared: () {
                  clearedCalls++;
                  pendingThought = null;
                },
              ),
              child: const Text('开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 当前挂起档 high 不在该模型可选档位（off/low）→ 可见提示。
    expect(find.textContaining('当前档不可用'), findsOneWidget,
        reason: '滑条回退默认档必须给可见提示（旧实现静默）');

    // 换到只支持 off/low 的模型：旧 high 被联动作废 → 清除回调必须触发。
    // 本合成夹具的 getView 不带 displayName → 行名回落 modelId 'k3'
    // （生产 getView 有名；此处只锁清除回调接线，锚定实际渲染文本）。
    await tester.tap(find.text('k3'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(clearedCalls, 1, reason: '页面挂起思考档必须同步清除');
    expect(pendingThought, isNull);
    expect(tester.takeException(), isNull);
  });
}

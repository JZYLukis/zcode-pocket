// 模型弹层竖向点选列表回归（2026-10-25 用户拍板①：摊开 chips 改上下
// 滑动点选，参考同类 AI 应用）：每行=logo+模型名+选中勾；点选走挂起语义
// （onDraftModel 记录，不直接切）；选中行首帧滚入可视区。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/ui/composer_panels.dart';

class _CatalogApp extends AppState {
  _CatalogApp({this.onDraftThought});
  final void Function(String value)? onDraftThought;

  @override
  Future<List<dynamic>> modelSelectionOptions() async => [
    ConfigOption.fromMap({
      'id': 'model',
      'name': 'Model',
      'options': [
        for (var i = 0; i < 14; i++)
          {
            'value': 'prov-a/glm-5.3-$i',
            'name': 'GLM 5.3 $i',
            'modelProviderId': 'prov-a',
          },
        {
          'value': 'prov-a/k3.1-pro',
          'name': 'Kimi K3.1 Pro',
          'modelProviderId': 'prov-a',
          // 思考档滑动条用例：选中模型自带档位清单。
          'modelThoughtLevels': ['off', 'low', 'medium', 'high'],
        },
        {
          'value': 'prov-a/claude-sonnet-4',
          'name': 'Claude',
          'modelProviderId': 'prov-a',
        },
        {
          // 无品牌 logo 模型（minimax 不在资产表）——logo 占位对齐用例。
          'value': 'prov-a/minimax-m1',
          'name': 'MiniMax M1',
          'modelProviderId': 'prov-a',
        },
      ],
    }),
  ];

  @override
  Future<Map<String, dynamic>?> modelSelectionView() async =>
      const <String, dynamic>{};
}

class _StartPlanCatalogApp extends _CatalogApp {
  @override
  Future<List<dynamic>> modelSelectionOptions() async => [
    ConfigOption.fromMap({
      'id': 'model',
      'name': 'Model',
      'options': const [
        {
          'value': 'account:zai-individual-coding-plan/GLM-5.3-Flash',
          'name': 'GLM-5.3-Flash',
          'modelProviderId': 'account:zai-individual-coding-plan',
          'modelProviderName': '个人套餐',
        },
        {
          'value': 'account:zai-start-plan/GLM-5.3-Flash',
          'name': 'GLM-5.3-Flash',
          'modelProviderId': 'account:zai-start-plan',
          'modelProviderName': 'Start Plan',
        },
        {
          'value': 'account:zai-start-plan/GLM-5.3-Flash-Lite',
          'name': 'GLM-5.3-Flash-Lite',
          'modelProviderId': 'account:zai-start-plan',
          'modelProviderName': 'Start Plan',
        },
      ],
    }),
  ];
}

/// 开源审查 D2-01（套餐变体键插值）：同 providerId+同 modelId 的多变体
/// 目录——_dedupModels 归并一行，行内 ⇄ 是触达其余变体的唯一入口
///（18077 拍板「⇄ 仅保留同 provider 内多变体场景」）。
class _VariantCatalogApp extends AppState {
  @override
  Future<List<dynamic>> modelSelectionOptions() async => [
    ConfigOption.fromMap({
      'id': 'model',
      'name': 'Model',
      'options': const [
        {
          'value': 'ctx-a/dual-model',
          'name': 'Dual',
          'modelProviderId': 'account:zai-start-plan',
          'modelProviderName': 'Start Plan',
        },
        {
          'value': 'ctx-b/dual-model',
          'name': 'Dual B',
          'modelProviderId': 'account:zai-start-plan',
          'modelProviderName': 'Start Plan',
        },
      ],
    }),
  ];

  @override
  Future<Map<String, dynamic>?> modelSelectionView() async =>
      const <String, dynamic>{};
}

/// 打开弹层的公共帮助（验收二轮用例组）。
Future<void> _pumpCatalog(
  WidgetTester tester, {
  String? pendingModelId,
  void Function(String value)? onDraftThought,
}) async {
  await tester.pumpWidget(
    AppStateScope(
      app: _CatalogApp(onDraftThought: onDraftThought),
      child: MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => TextButton(
            key: const ValueKey('open'),
            onPressed: () => showModelSheet(
              context,
              sessionId: null,
              state: ConversationState(),
              pendingModelId: pendingModelId,
              pendingModelProvider: pendingModelId == null ? null : 'prov-a',
              onDraftThought: onDraftThought,
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
}

void main() {
  testWidgets('模型目录渲染为竖向列表行（logo+名+选中勾），点选挂起', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    String? pickedProvider;
    String? pickedModel;
    final app = _CatalogApp();
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Builder(
            builder: (context) => TextButton(
              key: const ValueKey('open'),
              onPressed: () => showModelSheet(
                context,
                sessionId: null,
                state: ConversationState(),
                onDraftModel: (p, m) {
                  pickedProvider = p;
                  pickedModel = m;
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

    // 竖向列表行存在（key=model-row-<value>）——非 ChoiceChip 摊开。
    expect(
      find.byKey(const ValueKey('model-row-prov-a/k3.1-pro')),
      findsOneWidget,
    );
    expect(
      find.byType(ChoiceChip),
      findsNothing,
      reason: '模型区不再是摊开 chips（用户 2026-10-25 拍板）',
    );

    // 未选中行点选 → 挂起回调（provider+裸 modelId）。长目录先滚到行
    // （上下滑动点选的真实旅程）。
    final rowCtx = tester.element(
      find.byKey(const ValueKey('model-row-prov-a/k3.1-pro')),
    );
    await Scrollable.ensureVisible(rowCtx);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('k3.1-pro'));
    await tester.pump();
    expect(pickedProvider, 'prov-a');
    expect(pickedModel, 'k3.1-pro');
    // 选中标记移动到新行。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('model-row-prov-a/k3.1-pro')),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('长目录：选中行滚入可视区（免翻找）——真选中态几何断言', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    // H14（2026-10-25 批①）：原用例夹具无选中行，断言只覆盖"列表能出
    // 全"——滚入从未被验证。现注入挂起选中模型（第 13 项，视口外），
    // 断言首帧后选中行真实滚入弹层可视区。
    await tester.pumpWidget(
      AppStateScope(
        app: _CatalogApp(),
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Builder(
            builder: (context) => TextButton(
              key: const ValueKey('open'),
              onPressed: () => showModelSheet(
                context,
                sessionId: null,
                state: ConversationState(),
                pendingModelId: 'glm-5.3-12',
                pendingModelProvider: 'prov-a',
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

    // 选中行存在且带选中勾。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('model-row-prov-a/glm-5.3-12')),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
      reason: '挂起选中模型应有选中勾（桌面同款细勾，2026-10-26 对齐）',
    );
    // 首帧滚入：外层滚动发生（13 项在 460 上限弹层首屏之外）。
    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    expect(
      scrollable.position.pixels,
      greaterThan(0),
      reason: '选中行在视口外时首帧必须滚入（Scrollable.ensureVisible）',
    );
    // 选中行完整落在屏内。
    final box = tester.renderObject<RenderBox>(
      find.byKey(const ValueKey('model-row-prov-a/glm-5.3-12')),
    );
    final top = box.localToGlobal(Offset.zero);
    expect(top.dy, greaterThanOrEqualTo(0), reason: '选中行顶部在屏内');
    expect(
      top.dy + box.size.height,
      lessThanOrEqualTo(806),
      reason: '选中行底部在屏内',
    );
    // 2026-10-26 验收二轮：再收紧 40（用户拍板；低于 44 触控下限，
    // design_guard 豁免留痕 ADR 0049→0051）。
    expect(
      box.size.height,
      greaterThanOrEqualTo(40),
      reason: '模型行触控命中盒 ≥40（紧凑二档，用户 2026-10-26 拍板）',
    );
  });

  testWidgets('开源审查 D2-01：同 provider 多变体 ⇄ 切换可达（键插值修复）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    String? pickedProvider;
    String? pickedModel;
    await tester.pumpWidget(
      AppStateScope(
        app: _VariantCatalogApp(),
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Builder(
            builder: (context) => TextButton(
              key: const ValueKey('open'),
              onPressed: () => showModelSheet(
                context,
                sessionId: null,
                state: ConversationState(),
                onDraftModel: (p, m) {
                  pickedProvider = p;
                  pickedModel = m;
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
    // 同 provider 同 modelId 归并一行（首变体），第二变体不单独成行。
    expect(
      find.byKey(const ValueKey('model-row-ctx-a/dual-model')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('model-row-ctx-b/dual-model')),
      findsNothing,
      reason: '同 provider 同 modelId 归并一行（18077 去重语义）',
    );
    // 修复前：'…|$_shortModelOf(v.value)' 无花括号=函数对象拼进 key，
    // alternates 查表恒 miss → ⇄ 永不出现、同 provider 多变体不可达。
    final toggle = find.byKey(
      const ValueKey('model-plan-toggle-ctx-a/dual-model'),
    );
    expect(toggle, findsOneWidget);
    expect(
      find.descendant(of: toggle, matching: find.byIcon(Icons.swap_horiz)),
      findsOneWidget,
      reason: '多变体 ⇄ 图标在场=alternates 键命中',
    );
    // 点 ⇄ → 切到第二变体（挂起回调收到其 provider/modelId）。
    await tester.tap(toggle);
    await tester.pump();
    expect(pickedModel, 'dual-model');
    expect(pickedProvider, 'account:zai-start-plan');
  });

  testWidgets('logo 恒占位：有标/无标模型的名字左缘对齐（验收二轮）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    await _pumpCatalog(tester);
    // 懒列表：两行都先进视口再量。
    for (final t in ['k3.1-pro', 'minimax-m1']) {
      await Scrollable.ensureVisible(
        tester.element(find.text(t)),
        alignment: 0.5,
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    final kimiName = tester.renderObject<RenderBox>(find.text('k3.1-pro'));
    final dotName = tester.renderObject<RenderBox>(find.text('minimax-m1'));
    expect(
      (kimiName.localToGlobal(Offset.zero).dx -
              dotName.localToGlobal(Offset.zero).dx)
          .abs(),
      lessThan(0.5),
      reason: '无标模型占位后名字与有标模型同 x 对齐（修复前左缘不齐）',
    );
  });

  testWidgets('思考档渐变滑动条：点选跳档+拖动提交（2026-10-26 复刻桌面材质）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final picked = <String>[];
    await _pumpCatalog(
      tester,
      onDraftThought: picked.add,
      pendingModelId: 'k3.1-pro',
    );
    // 文字行（桌面同款）：「思考强度」+当前档名联动；档名不上轨道。
    // （Text.rich 富文本——findRichText 开关。）
    expect(find.textContaining('思考强度', findRichText: true), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing, reason: '思考档不用 chips');
    final track = tester.getRect(
      find.byKey(const ValueKey('thought-slider-track')),
    );
    // 初始档（off=最左段）——当前档名在文字行。
    expect(find.textContaining('关闭', findRichText: true), findsOneWidget);

    // 点选最右段位置（高）→ 挂起回调；文字行当前档联动为「高」。
    await tester.tapAt(
      Offset(track.center.dx + track.width * 0.4, track.center.dy),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(picked, isNotEmpty, reason: '点选跳档提交挂起');
    expect(picked.last, 'high');
    expect(
      find.textContaining('高', findRichText: true),
      findsOneWidget,
      reason: '当前档名随把手联动',
    );
  });

  testWidgets('18077 验收#1：同名模型分块各一行，点组头展开直选 Start Plan', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    String? pickedProvider;
    String? pickedModel;
    await tester.pumpWidget(
      AppStateScope(
        app: _StartPlanCatalogApp(),
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Builder(
            builder: (context) => TextButton(
              key: const ValueKey('open'),
              onPressed: () => showModelSheet(
                context,
                sessionId: null,
                state: ConversationState(),
                onDraftModel: (p, m) {
                  pickedProvider = p;
                  pickedModel = m;
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

    // 分块语义（用户拍板取代同名单行+⇄）：同名模型在个人套餐/Start Plan
    // 各一行；无选中时个人套餐（首组）默认展开、Start Plan 默认收起。
    // 组头+行内套餐徽标可能同名（findsWidgets 宽松匹配）。
    expect(find.text('个人套餐'), findsWidgets);
    expect(find.text('Start Plan'), findsWidgets);
    expect(
      find.text('GLM-5.3-Flash'),
      findsOneWidget,
      reason: '个人套餐组展开（首组默认），Start Plan 组收起不渲染行',
    );
    final startPlanRow = find.byKey(
      const ValueKey('model-row-account:zai-start-plan/GLM-5.3-Flash'),
    );
    expect(startPlanRow, findsNothing, reason: 'Start Plan 组默认收起');

    // 点 Start Plan 组头展开 → 它的同名模型行出现（分块直选，不再 ⇄）。
    await tester.tap(find.byKey(const ValueKey('model-group-Start Plan')));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(startPlanRow, findsOneWidget);

    // 点 Start Plan 组里的同名模型 → 挂起该套餐变体。
    final rowCtx = tester.element(startPlanRow);
    await Scrollable.ensureVisible(rowCtx);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.descendant(
      of: startPlanRow,
      matching: find.text('GLM-5.3-Flash'),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(pickedProvider, 'account:zai-start-plan');
    expect(pickedModel, 'GLM-5.3-Flash');
  });
}

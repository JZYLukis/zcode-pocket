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
  _CatalogApp({this.onDraftThought, this.overrideOptions});
  final void Function(String value)? onDraftThought;

  /// 候选 13 验收反馈用例：可注入自定义目录（同名组碰撞消歧）。
  final List<dynamic>? overrideOptions;

  @override
  Future<List<dynamic>> modelSelectionOptions() async => overrideOptions ?? [
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
          // 无品牌 logo 模型（2026-11-05 反馈④后 minimax 已入资产表，
          // 换 Simple Icons 仍未收录的腾讯混元）——logo 占位对齐用例。
          'value': 'prov-a/hy3',
          'name': 'Hunyuan 3',
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

/// （套餐变体键插值）：同 providerId+同 modelId 的多变体
/// 目录——_dedupModels 归并一行，行内 ⇄ 是触达其余变体的唯一入口
///（拍板「⇄ 仅保留同 provider 内多变体场景」）。
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

/// 2026-11-05 反馈④夹具：真机实锤形态——zai/bigmodel 双账号族同名 +
/// 双 Start Plan 同名 + OCG 渠道同名 + access 元数据真源（volcengine
/// 团队档：pid 推断会误判个人，元数据纠正）。
class _CrossProviderCatalogApp extends AppState {
  @override
  Future<List<dynamic>> modelSelectionOptions() async => [
    ConfigOption.fromMap({
      'id': 'model',
      'name': 'Model',
      'options': const [
        {
          'value': 'account:zai-individual-coding-plan/GLM-5.3',
          'name': 'GLM-5.3',
          'modelProviderId': 'account:zai-individual-coding-plan',
          'modelProviderName': 'Z.AI Individual Coding Plan',
        },
        {
          'value': 'account:bigmodel-individual-coding-plan/GLM-5.3',
          'name': 'GLM-5.3',
          'modelProviderId': 'account:bigmodel-individual-coding-plan',
          'modelProviderName': 'BigModel Individual Coding Plan',
        },
        {
          'value': 'account:zai-start-plan/GLM-5.3-Flash',
          'name': 'GLM-5.3-Flash',
          'modelProviderId': 'account:zai-start-plan',
          'modelProviderName': 'Start Plan',
        },
        {
          'value': 'account:bigmodel-start-plan/GLM-5.3-Flash',
          'name': 'GLM-5.3-Flash',
          'modelProviderId': 'account:bigmodel-start-plan',
          'modelProviderName': 'Start Plan',
          'modelAccessAccountType': 'bigmodel',
        },
        {
          'value': 'opencode-go-chat/glm-5.3',
          'name': 'glm-5.3',
          'modelProviderId': 'opencode-go-chat',
          'modelProviderName': 'OCG Chat',
        },
        {
          'value': 'volcengine-coding-plan/GLM-V',
          'name': 'GLM-V',
          'modelProviderId': 'volcengine-coding-plan',
          'modelProviderName': 'Volcano Engine Coding Plan',
          // access.mode 真源：pid 含 coding-plan 推断会误入个人组，
          // 元数据纠正为团队。
          'modelAccessMode': 'team-coding-plan',
        },
      ],
    }),
  ];

  @override
  Future<Map<String, dynamic>?> modelSelectionView() async =>
      const <String, dynamic>{};
}

/// 1.0.1 真机验收③防御：同 provider 双变体（zai ctx-a/ctx-b）+异
/// provider（bigmodel）同键目录——⇄ 循环必须跳到**不同短标签**的
/// 变体（zai→zai 隐形切换=用户感知「点一次就点不了了」）。
class _DupProviderCatalogApp extends AppState {
  @override
  Future<List<dynamic>> modelSelectionOptions() async => [
    ConfigOption.fromMap({
      'id': 'model',
      'name': 'Model',
      'options': const [
        {
          'value': 'ctx-a/GLM-5.3',
          'name': 'GLM-5.3',
          'modelProviderId': 'account:zai-individual-coding-plan',
          'modelProviderName': 'Z.AI Individual Coding Plan',
        },
        {
          'value': 'ctx-b/GLM-5.3',
          'name': 'GLM-5.3',
          'modelProviderId': 'account:zai-individual-coding-plan',
          'modelProviderName': 'Z.AI Individual Coding Plan',
        },
        {
          'value': 'account:bigmodel-individual-coding-plan/GLM-5.3',
          'name': 'GLM-5.3',
          'modelProviderId': 'account:bigmodel-individual-coding-plan',
          'modelProviderName': 'BigModel Individual Coding Plan',
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
      reason: '模型区不再是摊开 chips（设计定稿）',
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
    // （2026-10-25 批①）：原用例夹具无选中行，断言只覆盖"列表能出
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
    // design_guard 豁免留痕）。
    expect(
      box.size.height,
      greaterThanOrEqualTo(40),
      reason: '模型行触控命中盒 ≥40（紧凑二档，设计定稿）',
    );
  });

  // ⇄ 已退役（用户拍板「分成不同 plan 还切换啥」）：同 provider 多变体
  // 仍合并一行（去重语义不变），但不再暴露 UI 切换入口。
  testWidgets('D2-01 语义保留：多变体合并一行无⇄（分组即选源）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
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
      reason: '同 provider 同 modelId 归并一行（去重语义保留）',
    );
    // ⇄ 退役：不再有切换图标与旧 toggle key。
    expect(find.byIcon(Icons.swap_horiz), findsNothing, reason: '⇄ 退役');
    expect(
      find.byKey(const ValueKey('model-plan-toggle-ctx-a/dual-model')),
      findsNothing,
      reason: '旧 toggle key 不再存在',
    );
  });

  testWidgets('logo 恒占位：有标/无标模型的名字左缘对齐（验收二轮）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    await _pumpCatalog(tester);
    // 懒列表：两行都先进视口再量。
    for (final t in ['k3.1-pro', 'hy3']) {
      await Scrollable.ensureVisible(
        tester.element(find.text(t)),
        alignment: 0.5,
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    final kimiName = tester.renderObject<RenderBox>(find.text('k3.1-pro'));
    final dotName = tester.renderObject<RenderBox>(find.text('hy3'));
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

  testWidgets('验收#1：同名模型分块各一行，点组头展开直选 Start Plan', (tester) async {
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

    // 1.0.1 验收终修：分组按 provider——zai 个人与 zai Start Plan 是
    // 同一 providerId（都是 account:zai-*）……不对，目录里 providerId
    // 不同（zai-individual vs zai-start-plan），故各自成组。
    // 组头=provider 短名（Z.AI 个人 / Start Plan 免费）。
    // zai 个人与 zai Start Plan 同 family 不同 providerId=两组，组头
    // 均标 Z.AI（徽标区分个人/免费）。
    expect(find.text('Z.AI'), findsWidgets, reason: 'Z.AI 组头（个人+免费两组）');
    expect(
      find.text('GLM-5.3-Flash'),
      findsOneWidget,
      reason: '首组（Z.AI 个人）默认展开显示模型行',
    );
    final startPlanRow = find.byKey(
      const ValueKey('model-row-account:zai-start-plan/GLM-5.3-Flash'),
    );
    expect(startPlanRow, findsNothing, reason: 'Start Plan 组默认收起');

    // 点 Start Plan 组头展开 → 模型行出现。
    await tester.tap(
      find.byKey(const ValueKey('model-group-account:zai-start-plan')),
    );
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

  // 2026-11-05 反馈④（真机实锤：GLM-5.3×3、Flash×4 平铺）：同套餐组内
  // 同名跨 provider 合并一行（代表=当前 provider 优先）、⇄ 循环切来源；
  // 跨套餐保留分块；access.mode 元数据优先于 pid 推断（团队档纠正）。
  testWidgets('同名跨 provider：组内合并一行+⇄ 切来源；access 元数据分团队', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpWidget(
      AppStateScope(
        app: _CrossProviderCatalogApp(),
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Builder(
            builder: (context) => TextButton(
              key: const ValueKey('open'),
              onPressed: () => showModelSheet(
                context,
                sessionId: null,
                state: ConversationState(),
                pendingModelProvider: 'account:zai-individual-coding-plan',
                pendingModelId: 'GLM-5.3',
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

    // 1.0.1 验收终修：分组按 provider（桌面对齐）——zai/bigmodel 各
    // 自成组，组头=provider 短名+套餐徽标，不跨 provider 合并同名。
    expect(find.text('Z.AI'), findsWidgets, reason: 'Z.AI 组头（个人+免费两组）');
    expect(find.text('BigModel'), findsWidgets, reason: 'BigModel 组头（个人+免费两组）');
    expect(
      find.byKey(
        const ValueKey('model-row-account:zai-individual-coding-plan/GLM-5.3'),
      ),
      findsOneWidget,
      reason: 'Z.AI 组的 GLM-5.3 行',
    );
    // BigModel 组默认收起——展开后验证行在场。
    await tester.tap(
      find.byKey(const ValueKey('model-group-account:bigmodel-individual-coding-plan')),
    );
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      find.byKey(
        const ValueKey(
          'model-row-account:bigmodel-individual-coding-plan/GLM-5.3',
        ),
      ),
      findsOneWidget,
      reason: 'BigModel 组的 GLM-5.3 行（不跨 provider 合并）',
    );
    // access.mode 真源徽标：volcengine 条目带 team 元数据 → 团队徽标。
    expect(find.text('团队'), findsOneWidget, reason: '团队套餐徽标在场');

    // ⇄ 已退役：同名合并一行+徽标纯展示（不再可点切换）。
    expect(find.byIcon(Icons.swap_horiz), findsNothing,
        reason: '⇄ 退役（用户拍板「分成不同 plan 还切换啥」）');
    expect(find.text('Z.AI'), findsWidgets,
        reason: 'Z.AI 组头（个人+免费两组均在场）');
    expect(tester.takeException(), isNull);
  });

  // ⇄ 退役（用户拍板「分成不同 plan 还切换啥」）：同 provider 双变体
  // 仍合并一行，弹层不再出现 swap_horiz。
  // 候选 13 验收反馈：两个 BigModel API 渠道（不同 providerId）组头
  // 完全同名不可辨——碰撞组追加消歧后缀（providerId 尾段/序号）。
  // 候选 15 验收 终修：后缀=人话短标签（非内部 ID 原串）。
  test('碰撞消歧后缀：套餐 token 人话映射+未知退短词/序号', () {
    expect(groupDisambigSuffix('account:bigmodel-offpeak-idle-plan', 1), '闲时包',
        reason: 'offpeak+idle 去重为闲时，plan=包');
    expect(groupDisambigSuffix('account:bigmodel-highspeed-card', 2), '高速卡');
    expect(groupDisambigSuffix('bigmodel-api', 1), '1',
        reason: '纯家族词无 token 退序号');
    expect(groupDisambigSuffix('bigmodel-superlongtokenname', 2), 'superl',
        reason: '未知 token 取末段截 6 字');
    expect(groupDisambigSuffix('account:bigmodel-offpeak-idle-plan', 1).length,
        lessThanOrEqualTo(6),
        reason: '恒短防组头溢出（真机实锤内部 ID 原串挤掉徽标）');
  });

  testWidgets('同名组碰撞消歧：两个 BigModel API 渠道组头可辨', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _CatalogApp(
      overrideOptions: [
        ConfigOption.fromMap({
          'id': 'model',
          'name': 'Model',
          'options': [
            for (final pid in ['bigmodel-api', 'bigmodel-api-2'])
              {
                'value': '$pid/GLM-5.3',
                'name': 'GLM-5.3',
                'modelProviderId': pid,
                'modelAccessMode': '',
              },
          ],
        }),
      ],
    );
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
    // 两组都在场（各 1 行）且组头文字互不相同。
    final groupHeaders = find.byKey(const ValueKey('model-group-bigmodel-api'));
    expect(groupHeaders, findsOneWidget);
    expect(find.byKey(const ValueKey('model-group-bigmodel-api-2')),
        findsOneWidget);
    final labels = tester
        .widgetList<Text>(find.descendant(
          of: find.byKey(const ValueKey('model-group-bigmodel-api')),
          matching: find.byType(Text),
        ))
        .map((t) => t.data)
        .toSet();
    final labels2 = tester
        .widgetList<Text>(find.descendant(
          of: find.byKey(const ValueKey('model-group-bigmodel-api-2')),
          matching: find.byType(Text),
        ))
        .map((t) => t.data)
        .toSet();
    // 红=修复前两组标签集合完全相同（同名不可辨）。
    expect(labels.intersection(labels2).length, lessThan(labels.length),
        reason: '碰撞组必须有消歧后缀使组头可分辨');
    expect(tester.takeException(), isNull);
  });

  testWidgets('⇄ 退役：同 provider 双变体弹层无切换图标', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpWidget(
      AppStateScope(
        app: _DupProviderCatalogApp(),
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Builder(
            builder: (context) => TextButton(
              key: const ValueKey('open'),
              onPressed: () => showModelSheet(
                context,
                sessionId: null,
                state: ConversationState(),
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
    expect(find.byIcon(Icons.swap_horiz), findsNothing,
        reason: '⇄ 退役（用户拍板）——分组即选源');
    expect(find.byKey(const ValueKey('model-plan-toggle-ctx-a/GLM-5.3')),
        findsNothing,
        reason: '旧 toggle key 不再存在');
    expect(find.text('Z.AI'), findsOneWidget,
        reason: '代表行=首条 zai 变体（纯展示首来源）');
    expect(tester.takeException(), isNull);
  });
}


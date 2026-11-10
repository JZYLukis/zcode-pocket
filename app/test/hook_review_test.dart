// E 批（2026-11-08 拍板③「对齐桌面+手机端优化」）红绿：Hook 审核
// 专用呈现——横幅路由到入口卡（不落通用提问渲染，官方禁令）→
// 审核页（源文件/逐项开关/计数）→「信任所选」发 respondWorkspaceHookReview
// {trust_selected, reviewItemIds}。红=旧代码白板横幅无法完成审核。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/ui/interaction_banner.dart';
import 'package:zcode_pocket/ui/workspace_hook_review_page.dart';

// 夹具按官方 pendingInteractionSchema（snapshot.ts:317-345）/
// workspaceHookReviewRequestPayloadSchema（workspace-hook-review.ts:75-140）
// 的**嵌套形状**构造：顶层只 interactionId/kind/anchorRowId/createdAt/
// payload，审核字段全在 payload 内——让断言穿过生产压平路径
// （interaction_banner 的 {...interaction, ...payload} spread）。
Map<String, dynamic> _interaction() {
  final now = DateTime.now().millisecondsSinceEpoch;
  return {
    'interactionId': 'hr-1',
    'kind': 'workspaceHookReview',
    'anchorRowId': null,
    'createdAt': now,
    'payload': {
      'kind': 'workspaceHookReview',
      'reviewFlowId': 'flow-1',
      'generation': 1,
      'interactionId': 'hr-1',
      'sessionId': 's1',
      'taskId': 't1',
      'runId': 'r1',
      'workspaceIdentity': 'ws-1',
      'workspaceLabel': '示例项目',
      'bundleDigest': 'a' * 64,
      'createdAt': now,
      'deadlineAt': now + 600000,
      'sourceFiles': [
        {
          'path': '.zcode/hooks/a.sh',
          'displayPath': '.zcode/hooks/a.sh',
          'editable': true,
        },
      ],
      // 官方严格关系：hookCount=items.length；eventCount=不同 event 数。
      'summary': {'eventCount': 2, 'hookCount': 2, 'pendingCount': 1},
      'warningCode': 'workspace_hooks_execute_code',
      'items': [
        {
          'reviewItemId': 'it-1',
          'event': 'PreToolUse',
          'type': 'command',
          'displayName': '前置检查',
          'displayCommand': 'bash .zcode/hooks/check.sh',
          'sourcePath': '.zcode/hooks/a.sh',
          'executionMode': 'foreground',
          'resolvedTimeoutMs': 30000,
          'resolvedMaxOutputBytes': 1024,
          'configuredEnabled': true,
          'editable': true,
          'trustState': 'pending_trust',
        },
        {
          'reviewItemId': 'it-2',
          'event': 'Stop',
          'type': 'process',
          'displayName': '已信任的钩子',
          'displayCommand': 'node done.js',
          'sourcePath': '.zcode/hooks/a.sh',
          'executionMode': 'background',
          'resolvedTimeoutMs': 60000,
          'resolvedMaxOutputBytes': 1024,
          'configuredEnabled': true,
          'editable': false,
          'trustState': 'trusted_persistent',
        },
      ],
    },
  };
}

/// 变体：多一条 pending_trust 但 editable=false 的条目——官方
/// trust_selected 只要求子集，不可写盘项也必须可勾选。
Map<String, dynamic> _interactionWithLockedPending() {
  final base = _interaction();
  final payload = base['payload'] as Map<String, dynamic>;
  payload['summary'] = {'eventCount': 3, 'hookCount': 3, 'pendingCount': 2};
  (payload['items'] as List).add({
    'reviewItemId': 'it-3',
    'event': 'PostToolUse',
    'type': 'command',
    'displayName': '锁定来源的待信任钩子',
    'displayCommand': 'sh .zcode/hooks/locked.sh',
    'sourcePath': '.zcode/hooks/locked.sh',
    'executionMode': 'foreground',
    'resolvedTimeoutMs': 30000,
    'resolvedMaxOutputBytes': 1024,
    'configuredEnabled': true,
    'editable': false,
    'trustState': 'pending_trust',
  });
  return base;
}

class _HookApp extends AppState {
  late final ConversationState convState = ConversationState();
  List<Map<String, dynamic>> respondCalls = [];
  List<Map<String, dynamic>> toggleCalls = [];

  /// F1：可注入 ACK 形态（默认 accepted）。
  Map<String, dynamic> respondResult = {'status': 'accepted'};

  _HookApp({Map<String, dynamic>? interaction}) {
    convState.applySeed(
      ConversationSeed(
        rows: const [],
        logEpoch: 'e1',
        seq: 0,
        firstRowId: null,
        totalCount: 0,
        snapshot: {
          'title': 'Hook 审核会话',
          'control': {'phase': 'idle'},
          'pendingInteractions': [interaction ?? _interaction()],
        },
      ),
    );
  }

  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  Future<dynamic> respondWorkspaceHookReview(
    String sessionId,
    Map<String, dynamic> target,
    List<String> reviewItemIds,
  ) async {
    respondCalls.add({
      'sessionId': sessionId,
      'target': target,
      'reviewItemIds': reviewItemIds,
    });
    return respondResult;
  }

  @override
  Future<dynamic> toggleWorkspaceHookReviewItem(
    String sessionId,
    Map<String, dynamic> target,
    String reviewItemId,
    bool enabled,
  ) async {
    toggleCalls.add({'reviewItemId': reviewItemId, 'enabled': enabled});
    return null;
  }
}


void main() {
  testWidgets('F1：开关=纯本地选择（toggle 命令零调用）+ 取消勾选改变信任集',
      (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _HookApp();
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: InteractionBanner(state: app.convState, sessionId: 's1'),
          ),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey('hook-review-entry-hr-1')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 取消 it-1 勾选 → 按钮变 0 禁用。
    await tester.tap(find.byWidgetPredicate(
        (w) => w is Switch && (w.value == true)));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(app.toggleCalls, isEmpty,
        reason: 'F1 高①：toggle 命令是写盘+作废审核代，选择纯本地零调用');
    expect(find.textContaining('信任所选（0）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // VR-4a（视觉审查 tools/logs/visual-retro-1109，触控维）：逐项开关旧
  // 命中区=SizedBox(32,24)+FittedBox 缩放后的开关本体，实际仅 32×24；
  // 修=40×40 热区外壳（开关视觉尺寸不变）。红=修复前 getSize ≈32×24。
  testWidgets('VR-4a：逐项开关热区 ≥38×38 且槽内空白点按可切换',
      (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _HookApp();
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: InteractionBanner(state: app.convState, sessionId: 's1'),
          ),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey('hook-review-entry-hr-1')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final hot = find.byKey(const ValueKey('hook-item-switch-it-1'));
    expect(hot, findsOneWidget);
    final rect = tester.getRect(hot);
    expect(rect.width, greaterThanOrEqualTo(38));
    expect(rect.height, greaterThanOrEqualTo(38));
    // 开关视觉尺寸不变（FittedBox 仍把小壳压到 32×24）。
    final visual = tester.getSize(find.descendant(
      of: hot,
      matching: find.byType(FittedBox),
    ));
    expect(visual.width, lessThanOrEqualTo(32));
    expect(visual.height, lessThanOrEqualTo(24));
    // 槽内左侧空白（开关本体之外）点按=切换：40×40 热区真实生效。
    await tester.tapAt(rect.centerLeft + const Offset(2, 0));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('信任所选（0）'), findsOneWidget,
        reason: '槽内空白处点按可取消勾选（热区不只在开关本体上）');
    expect(app.toggleCalls, isEmpty,
        reason: '热区点击仍是纯本地选择（toggle 命令零调用）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('F1：respond 业务拒绝（ACK failed）不 pop+人话提示',
      (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _HookApp();
    app.respondResult = {'status': 'failed', 'reasonCode': 'snapshot_mismatch'};
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: InteractionBanner(state: app.convState, sessionId: 's1'),
          ),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey('hook-review-entry-hr-1')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey('hook-review-trust')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 红点：页面仍在（不 pop），失败人话在场。
    expect(find.byKey(const ValueKey('hook-review-body')), findsOneWidget,
        reason: '业务拒绝不得当成功 pop（对抗审查中②）');
    expect(find.textContaining('信任未生效'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('F1：hook 与提问共存——提问卡不被吞+hook 入口在场',
      (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _HookApp();
    // 在 hook 前面再插一条提问（hook 不再是 first）。
    (app.convState.snapshot!['pendingInteractions'] as List).insert(
      0,
      {
        'interactionId': 'q-1',
        'kind': 'userInput',
        'anchorRowId': null,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'payload': {
          'kind': 'userInput',
          'prompt': 'Tool AskUserQuestion requires user interaction',
          'freeText': true,
          'toolName': 'AskUserQuestion',
          'questions': [
            {
              'question': '先答这个',
              'header': '方案',
              'multiSelect': false,
              'options': [
                {'value': 'a', 'label': 'A'},
              ],
            },
          ],
        },
      },
    );
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: InteractionBanner(state: app.convState, sessionId: 's1'),
          ),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 红点：提问卡（通用渲染）与 hook 入口卡同屏共存。
    expect(find.textContaining('先答这个'), findsOneWidget,
        reason: '官方 V4InteractionDialogs :120-131——hook 不吞提问');
    expect(
        find.byKey(const ValueKey('hook-review-entry-hr-1')), findsOneWidget);
    expect(find.textContaining('还有'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Hook 审核：入口卡→审核页→默认勾选待信任→信任所选发命令',
      (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _HookApp();
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: InteractionBanner(state: app.convState, sessionId: 's1'),
          ),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 红点①：专用入口卡（旧=通用渲染白板）。
    expect(find.byKey(const ValueKey('hook-review-entry-hr-1')), findsOneWidget);
    expect(find.textContaining('1 项待信任'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('hook-review-entry-hr-1')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 红点②：审核页（源文件/清单/计数）——嵌套夹具经生产
    // {...interaction, ...payload} 压平后所有顶层字段可用。
    expect(find.byKey(const ValueKey('hook-review-body')), findsOneWidget);
    // 「源文件」节头 + 「不可写盘（配置由来源文件维护）」标注都含该词。
    expect(find.textContaining('源文件'), findsWidgets);
    expect(find.textContaining('check.sh'), findsOneWidget);
    expect(find.textContaining('已信任'), findsWidgets,
        reason: 'trusted 项徽标（「已信任的钩子」名称与徽标都含该词）');
    expect(find.textContaining('待信任'), findsOneWidget);
    // 官方闭集「已信任」=trusted_persistent——旧判 'trusted' 永不命中，
    // 已信任项被渲染成红色危险色（红=此处色值=destructive）。
    final spec = buildAppTheme().extension<AppThemeSpec>()!;
    final trustedBadge = tester.widget<Text>(find.text('已信任'));
    expect(trustedBadge.style?.color, spec.colors.foregroundSubtle,
        reason: 'trusted_persistent 不得渲染成危险红（旧判 trusted 永不命中）');
    expect(trustedBadge.style?.color, isNot(spec.colors.destructive));
    // 默认勾选=仅待信任项（it-1）。
    expect(find.textContaining('信任所选（1）'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('hook-review-trust')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // F1 补：默认勾选=三态（pending_trust/revoked/stale_digest）。
    // 红点③：决策命令（trust_selected + 默认选择集）。
    expect(app.respondCalls, hasLength(1));
    expect(app.respondCalls.single['sessionId'], 's1');
    expect(app.respondCalls.single['reviewItemIds'], ['it-1']);
    final target =
        app.respondCalls.single['target'] as Map<String, dynamic>;
    expect(target['reviewFlowId'], 'flow-1');
    expect(target['bundleDigest'], 'a' * 64);
    expect(tester.takeException(), isNull);
  });

  // 官方语义：editable 只约束写配置（toggle 命令），trust_selected 只要求
  // reviewItemIds 是 items 子集——非 editable 待信任项也必须可勾选/可提交
  //（红=旧实现按 editable 禁用开关，默认勾选却无法取消=强制信任）。
  testWidgets('非 editable 待信任项：可勾选可提交 + 不可写盘小字标注', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _HookApp(interaction: _interactionWithLockedPending());
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: InteractionBanner(state: app.convState, sessionId: 's1'),
          ),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey('hook-review-entry-hr-1')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 默认勾选=两条 pending（含不可写盘项）。
    expect(find.textContaining('信任所选（2）'), findsOneWidget);
    final card = find.byKey(const ValueKey('hook-item-it-3'));
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.textContaining('不可写盘')),
      findsOneWidget,
      reason: '非 editable 项加不可写盘视觉标注',
    );
    final sw = find.descendant(of: card, matching: find.byType(Switch));
    expect(tester.widget<Switch>(sw).onChanged, isNotNull,
        reason: '不可写盘项仍可切换选择（选择≠写配置）');

    await tester.tap(sw);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('信任所选（1）'), findsOneWidget,
        reason: '不可写盘项可取消勾选（旧实现强制勾选无法取消）');
    await tester.tap(sw);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('信任所选（2）'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('hook-review-trust')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(app.respondCalls, hasLength(1));
    expect(app.respondCalls.single['reviewItemIds'], ['it-1', 'it-3']);
    final target =
        app.respondCalls.single['target'] as Map<String, dynamic>;
    // 压平路径实证：payload 内的 target 字段全部到达命令 target。
    expect(target['sessionId'], 's1');
    expect(target['runId'], 'r1');
    expect(tester.takeException(), isNull);
  });

  // §5b H2 体量态（human-eye-retro-1109）：大型 hook 审核（35 项/5 源文件）
  // 必须有界滚动+默认选择计数正确——防「2 项夹具全绿、35 项真机占满
  // 全窗」类（bgworks 51 条同型）。
  testWidgets('体量：35 项审核清单有界滚动+默认勾选计数', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final payloadItems = <Map<String, dynamic>>[
      for (var i = 1; i <= 30; i++)
        {
          'reviewItemId': 'vol-p-$i',
          'event': 'PreToolUse',
          'type': 'command',
          'displayName': '批量钩子 $i',
          'displayCommand': 'bash .zcode/hooks/gen-$i.sh',
          'sourcePath': '.zcode/hooks/gen-$i.sh',
          'executionMode': 'foreground',
          'resolvedTimeoutMs': 30000,
          'resolvedMaxOutputBytes': 1024,
          'configuredEnabled': true,
          'editable': true,
          'trustState': 'pending_trust',
        },
      for (var i = 1; i <= 5; i++)
        {
          'reviewItemId': 'vol-t-$i',
          'event': 'Stop',
          'type': 'process',
          'displayName': '历史钩子 $i',
          'displayCommand': 'node done-$i.js',
          'sourcePath': '.zcode/hooks/legacy-$i.sh',
          'executionMode': 'background',
          'resolvedTimeoutMs': 60000,
          'resolvedMaxOutputBytes': 1024,
          'configuredEnabled': true,
          'editable': false,
          'trustState': 'trusted_persistent',
        },
    ];
    final now = DateTime.now().millisecondsSinceEpoch;
    final interaction = {
      'interactionId': 'hr-vol',
      'kind': 'workspaceHookReview',
      'anchorRowId': null,
      'createdAt': now,
      'payload': {
        'kind': 'workspaceHookReview',
        'reviewFlowId': 'flow-vol',
        'generation': 1,
        'interactionId': 'hr-vol',
        'sessionId': 's1',
        'taskId': 't1',
        'runId': 'r1',
        'workspaceIdentity': 'ws-1',
        'workspaceLabel': '体量项目',
        'bundleDigest': 'b' * 64,
        'createdAt': now,
        'deadlineAt': now + 600000,
        'sourceFiles': [
          for (var i = 1; i <= 5; i++)
            {
              'path': '.zcode/hooks/gen-$i.sh',
              'displayPath': '.zcode/hooks/gen-$i.sh',
              'editable': true,
            },
        ],
        'summary': {'eventCount': 35, 'hookCount': 35, 'pendingCount': 30},
        'warningCode': 'workspace_hooks_execute_code',
        'items': payloadItems,
      },
    };
    final app = _HookApp();
    // 页面消费压平形态（InteractionBanner 的 {...interaction, ...payload}
    // spread 后路由）；直连页面须自行压平——同生产路径。
    final flattened = <String, dynamic>{
      ...interaction,
      ...(interaction['payload'] as Map<String, dynamic>),
    };
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: WorkspaceHookReviewPage(
            interaction: flattened,
          ),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('hook-review-body')), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '35 项无布局异常=有界滚动');
    // 默认勾选=30 条 pending_trust。
    expect(find.textContaining('信任所选（30）'), findsOneWidget);
    // 首屏可见第一条；深处条目须滚动到达（证明列表真实有界分页渲染）。
    expect(find.text('批量钩子 1').hitTestable(), findsOneWidget);
    expect(find.text('历史钩子 5').hitTestable(), findsNothing,
        reason: '35 项远超一屏，末项初始不在视口');
    await tester.scrollUntilVisible(
      find.text('历史钩子 5'),
      200,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('hook-review-body')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('历史钩子 5').hitTestable(), findsOneWidget,
        reason: '滚动可达末项');
    expect(tester.takeException(), isNull);
  });
}

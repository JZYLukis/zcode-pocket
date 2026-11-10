// 2026-10-23 用户反馈批⑦（回填律）：「电脑端计划模式可与其他模式并行
// （计划+完全访问），手机端不行；且桌面完全访问是橙色的」。
// refs 实证（V4ComposerModeControls.tsx:40/63/148-165）：计划=独立
// CheckboxItem 与权限 RadioGroup 并行；e2e 断言 {mode:'yolo',
// planEnabled:true} 可叠加；yolo 药丸 text-warning 橙（#ff8a30 深色，
// 用户截图实锤）。本文件锁：sheet 结构（开关+4 权限单选）、计划标记
// 药丸、yolo 橙、并行共存、旧 mode=plan 折算。
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/cache_policy.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

class _SendTestBridge implements BridgeSession {
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
  ChannelClient get channels => throw UnimplementedError();
  @override
  String? get workspaceKey => 'ws-send-test';
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

class _RowsApp extends AppState {
  // 断网排队批（2026-10-29）：无桥发送会改道入队——这些用例的语义是
  // 「已连接但发送失败/在途」，补桥保持原路径。
  @override
  BridgeSession? get bridge => _SendTestBridge();

  _RowsApp(this.rows, {this.config, this.noSnapshotControl = false});
  final List<Map<String, dynamic>> rows;
  final Map<String, dynamic>? config;

  /// true=缓存条目不带 snapshotControl（模拟快照未就绪—— 超时兜底
  /// 用例：乐观写回落空，挂起只能靠 15s 兜底退位）。
  final bool noSnapshotControl;

  /// 测试驾驶记录：sendText 提交的载荷（断言 planEnabled/mode 随提交）。
  final List<Map<String, dynamic>> sentPayloads = [];

  /// 切档命令回执（默认 accepted；stale 用例可改）。
  String switchStatus = 'accepted';

  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  Future<dynamic> switchCollaborationMode(String sessionId, String mode) async =>
      {'status': switchStatus};

  @override
  Future<dynamic> sendText(
    String sessionId,
    String text, {
    Map<String, dynamic>? modelSelection,
    String? mode,
    bool? planEnabled,
    List<Map<String, dynamic>>? attachments,
    String? heldQueueDisposition,
    List<String>? expectedHeldQueueItemIds,
    String? replayCommandId,
  }) async {
    sentPayloads.add({
      'text': text,
      'mode': mode,
      'planEnabled': planEnabled,
    });
    return {'status': 'accepted'};
  }

  @override
  Future<SessionCacheEntry?> readSessionCache(String id) async =>
      SessionCacheEntry(
        deviceSid: 'd1',
        sessionId: id,
        rows: rows,
        logEpoch: 'e1',
        lastSeq: rows.length,
        firstRowId: 1,
        totalCount: rows.length,
        snapshotControl: noSnapshotControl
            ? null
            : {
                'title': '模式并行',
                'control': {'phase': 'idle'},
                if (config != null) 'config': config,
                'usage': {
                  'contextWindow': {'usedTokens': 12000, 'maxTokens': 1000000},
                },
              },
        savedAt: DateTime.now().millisecondsSinceEpoch,
        byteSize: 1024,
      );
}

Widget _host(AppState app, Widget page, {Brightness b = Brightness.light}) =>
    AppStateScope(
      app: app,
      child: MaterialApp(
        theme:
            b == Brightness.dark ? buildAppTheme(Brightness.dark) : buildAppTheme(),
        home: page,
      ),
    );

Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

List<Map<String, dynamic>> _rows() => [
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      {'rowId': 2, 'kind': 'turnHeader', 'state': 'completedSuccess'},
      {'rowId': 3, 'kind': 'assistantText', 'state': 'complete', 'text': 'ok'},
    ];

void main() {
  testWidgets('模式面板结构：计划=独立开关+4 权限单选（无计划单选项）',
      (tester) async {
    await tester.pumpWidget(_host(
        _RowsApp(_rows(), config: {'mode': 'build'}),
        const ConversationPage(sessionId: 's1', title: '模式并行')));
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('mode-switch')));
    await _pump(tester);
    // 计划=开关行（非单选项）。
    final sw = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('plan-switch')),
    );
    expect(sw.value, isFalse, reason: '默认计划关');
    // 权限 4 档单选（计划不在单选组——官方 permissions 排除 plan）。
    for (final m in const ['build', 'edit', 'guarded', 'yolo']) {
      expect(find.byKey(ValueKey('mode-$m')), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('mode-plan')), findsNothing,
        reason: '计划不再作为互斥单选项');
    expect(find.text('权限'), findsOneWidget);
  });

  testWidgets('切计划开关：出「计划」标记药丸（不动权限档）', (tester) async {
    await tester.pumpWidget(_host(
        _RowsApp(_rows(), config: {'mode': 'yolo'}),
        const ConversationPage(sessionId: 's1', title: '模式并行')));
    await _pump(tester);
    expect(find.byKey(const ValueKey('plan-marker')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('mode-switch')));
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('plan-switch')));
    await _pump(tester);
    // 关闭弹层（点遮罩），开关已即时挂起。
    await tester.tapAt(const Offset(10, 10));
    await _pump(tester);
    expect(find.byKey(const ValueKey('plan-marker')), findsOneWidget,
        reason: '计划开启→模式药丸右侧出标记（官方 plan marker）');
    expect(find.text('计划'), findsOneWidget);
    // 权限档不受影响（仍是完全访问）。
    expect(find.text('完全访问'), findsOneWidget);
  });

  testWidgets('完全访问：药丸图标+文字 warning 橙（对齐桌面截图）',
      (tester) async {
    await tester.pumpWidget(_host(
        _RowsApp(_rows(), config: {'mode': 'yolo'}),
        const ConversationPage(sessionId: 's1', title: '模式并行')));
    await _pump(tester);
    final icon = tester.widget<Icon>(find.byIcon(Icons.gpp_maybe_outlined));
    expect(icon.color, AppThemeSpec.light.colors.warning,
        reason: '官方 yolo 选中→text-warning（浅色 AA 加深档 #B45309）');
    final label = tester.widget<Text>(find.text('完全访问'));
    expect(label.style!.color, AppThemeSpec.light.colors.warning);
  });

  testWidgets('并行：完全访问+计划同屏共存（e2e {yolo,planEnabled:true}）',
      (tester) async {
    await tester.pumpWidget(_host(
        _RowsApp(_rows(), config: {'mode': 'yolo', 'planEnabled': true}),
        const ConversationPage(sessionId: 's1', title: '模式并行')));
    await _pump(tester);
    expect(find.text('完全访问'), findsOneWidget);
    expect(find.byKey(const ValueKey('plan-marker')), findsOneWidget,
        reason: '批⑦核心：计划与权限档并行，不再互斥');
  });

  testWidgets('旧 config.mode=plan 折算：权限回 build+计划标记亮',
      (tester) async {
    await tester.pumpWidget(_host(
        _RowsApp(_rows(), config: {'mode': 'plan'}),
        const ConversationPage(sessionId: 's1', title: '模式并行')));
    await _pump(tester);
    expect(find.text('变更前确认'), findsOneWidget,
        reason: '官方 resolveExecutionState：mode=plan→build+planEnabled');
    expect(find.byKey(const ValueKey('plan-marker')), findsOneWidget);
  });

  testWidgets('深色：完全访问橙=官方 warning #FF8A30', (tester) async {
    await tester.pumpWidget(_host(
        _RowsApp(_rows(), config: {'mode': 'yolo'}),
        const ConversationPage(sessionId: 's1', title: '模式并行'),
        b: Brightness.dark));
    await _pump(tester);
    final label = tester.widget<Text>(find.text('完全访问'));
    expect(label.style!.color, const Color(0xFFFF8A30),
        reason: '深色 warning=官方 #FF8A30（用户截图实测值）');
  });

  group('A3+A5 修复批（2026-10-24）：乐观写回+水位清理+超时兜底', () {
    testWidgets('A3：切档 accepted 即写回 config——药丸显示提交档（写回目标=缓存预渲层）',
        (tester) async {
      final app = _RowsApp(_rows(), config: {'mode': 'build'});
      await tester.pumpWidget(_host(
          app, const ConversationPage(sessionId: 's1', title: '模式并行')));
      await _pump(tester);
      expect(find.text('变更前确认'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mode-switch')));
      await _pump(tester);
      await tester.tap(find.byKey(const ValueKey('mode-yolo')));
      await _pump(tester);
      // accepted → 乐观写回 config.mode=yolo（缓存预渲层）→ 挂起清空
      // 药丸仍显示提交档——不再依赖永不失效的 _appliedMode 记账。
      expect(find.text('完全访问'), findsOneWidget,
          reason: 'accepted 写回后 config 承载显示值');
    });

    testWidgets('A5：计划开关随消息提交后不回摆（修复前红=accepted 清挂起→config 旧值→标记消失）',
        (tester) async {
      final app = _RowsApp(_rows(), config: {'mode': 'yolo'});
      await tester.pumpWidget(_host(
          app, const ConversationPage(sessionId: 's1', title: '模式并行')));
      await _pump(tester);
      // 计划开关挂起 true。
      await tester.tap(find.byKey(const ValueKey('mode-switch')));
      await _pump(tester);
      await tester.tap(find.byKey(const ValueKey('plan-switch')));
      await _pump(tester);
      await tester.tapAt(const Offset(10, 10));
      await _pump(tester);
      expect(find.byKey(const ValueKey('plan-marker')), findsOneWidget);
      // 发消息提交 planEnabled=true → accepted。
      await tester.enterText(find.byType(TextField), 'go');
      await _pump(tester);
      await tester.tap(find.byKey(const ValueKey('send-button')));
      await _pump(tester);
      expect(app.sentPayloads.single['planEnabled'], isTrue,
          reason: '挂起计划值随提交携带');
      expect(find.byKey(const ValueKey('plan-marker')), findsOneWidget,
          reason: 'accepted 即写回 config.planEnabled=true——标记由 config '
              '承载，无回显前窗口期回摆（旧实现此断言红）');
    });

    testWidgets('A5 超时兜底：快照未就绪写回落空→挂起保留显示→15s 后退位 config',
        (tester) async {
      final app = _RowsApp(_rows(), noSnapshotControl: true);
      await tester.pumpWidget(_host(
          app, const ConversationPage(sessionId: 's1', title: '模式并行')));
      await _pump(tester);
      await tester.tap(find.byKey(const ValueKey('mode-switch')));
      await _pump(tester);
      await tester.tap(find.byKey(const ValueKey('plan-switch')));
      await _pump(tester);
      await tester.tapAt(const Offset(10, 10));
      await _pump(tester);
      expect(find.byKey(const ValueKey('plan-marker')), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'go');
      await _pump(tester);
      await tester.tap(find.byKey(const ValueKey('send-button')));
      await _pump(tester);
      // 写回落空（无快照可写）→ 挂起保留：标记仍显示，不闪回。
      expect(find.byKey(const ValueKey('plan-marker')), findsOneWidget,
          reason: '写回落空时挂起作显示载体');
      // 15s 兜底：回显永远不来（测试无活订阅），挂起退位给 config。
      await tester.pump(const Duration(seconds: 16));
      expect(find.byKey(const ValueKey('plan-marker')), findsNothing,
          reason: '超时兜底退位——挂起不永驻');
    });
  });

  group('A3 机制（L1）：writeBackConfig 与快照整体替换', () {
    Map<String, dynamic> snapFrame(Map<String, dynamic> config, int toSeq) => {
          'toSeq': toSeq,
          'payload': {
            'kind': 'snapshot',
            'snapshot': {
              'logEpoch': 'e1',
              'control': {'phase': 'idle'},
              'config': config,
              'rows': {
                'window': <Map<String, dynamic>>[],
                'totalCount': 0,
              },
            },
          },
        };

    test('写进既有 config/bump dataVersion/空值不动/无快照 false/config 缺失新建',
        () {
      final st = ConversationState()
        ..snapshot = {
          'config': <String, dynamic>{'mode': 'build', 'provider': 'p1'},
          'control': {'phase': 'idle'},
        };
      final v0 = st.dataVersion;
      expect(st.writeBackConfig({'mode': 'yolo', 'planEnabled': true}), isTrue);
      expect(
        st.config,
        {'mode': 'yolo', 'provider': 'p1', 'planEnabled': true},
      );
      expect(st.dataVersion, v0 + 1, reason: '引用级记忆化必须失效');
      expect(st.writeBackConfig({}), isFalse);
      expect(ConversationState().writeBackConfig({'mode': 'x'}), isFalse,
          reason: '快照未就绪=写回落空（调用方保留挂起作显示载体）');
      final st2 = ConversationState()..snapshot = {'control': {}};
      expect(st2.writeBackConfig({'mode': 'edit'}), isTrue);
      expect(st2.config?['mode'], 'edit');
    });

    test('外部改档快照（R6 整体替换）覆盖写回值——config 是唯一生效源，无 _appliedMode 滞留面',
        () {
      final st = ConversationState();
      st.applyFrame(snapFrame({'mode': 'build'}, 5), onGap: () {});
      st.writeBackConfig({'mode': 'yolo'});
      expect(st.currentMode, 'yolo');
      // 桌面端外部改档 → 新快照到达 → config 跟随（病灶=旧实现
      // _appliedMode 永不失效，药丸滞留旧值）。
      st.applyFrame(snapFrame({'mode': 'edit'}, 6), onGap: () {});
      expect(st.currentMode, 'edit');
    });
  });
}

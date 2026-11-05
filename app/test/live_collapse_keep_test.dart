// H11 窄修红绿（2026-10-25 ，用户拍板"只修手动收起"）：
// 运行中手动收起的回合，完成边沿不得按"末轮默认展开"强行弹开——
// "手动收起不变"承诺的补落地。动态路径（区别于既有静态首帧
// 夹具）：真 ConversationState + applySeed 推演，先点收起再推完成帧。
// "上轮失去末轮身份自动收起"不在本修范围（用户拍板接受现状）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

class _LiveSub implements ConversationSubscription {
  @override
  final String sessionId = 's-live';
  @override
  final ConversationState state = ConversationState();
  @override
  bool get hasLiveFrames => true;
  @override
  String? get subscriptionId => 'sub-live';
  @override
  bool get isDisposed => false;
  @override
  String get topic => 'conversation/s-live';
  @override
  Future<void> dispose() async {}

  void reseed(List<Map<String, dynamic>> rows, {required String phase}) {
    state.applySeed(ConversationSeed(
      rows: rows,
      logEpoch: 'e1',
      seq: rows.length,
      firstRowId: 1,
      totalCount: rows.length,
      snapshot: {'control': {'phase': phase}},
    ));
  }

 /// 时序对齐生产（每步之间必须真实泵帧，同步重播种会被合并构建）：
 /// ①同内容重播种→壳脱落（一次性结构重挂，State 重建）；
 /// ②再推一帧运行中增量→重建后的 State 经 didUpdateWidget 置
 /// _wasRunning（生产中流式帧天然完成此事）。
  Future<void> primeRunning(
    WidgetTester tester,
    List<Map<String, dynamic>> rows,
  ) async {
    for (var i = 0; i < 2; i++) {
      reseed(rows, phase: 'running');
      for (var k = 0; k < 15; k++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
  }
}

class _LiveApp extends AppState {
  _LiveApp(this.sub);
  final _LiveSub sub;

  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  Future<ConversationSubscription> ensureConversation(
    String sessionId, {
    Object? seedCacheEntry,
  }) async => sub;
}

Widget _host(AppState app) => AppStateScope(
      app: app,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: const ConversationPage(sessionId: 's-live', title: '收起保持'),
      ),
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 两个工具行：收起态（运行中）只显示最新活跃子工具摘要（官方折叠
/// 语义），展开两个都可见；完成收起态两个都不可见——三轮信号可区分。
List<Map<String, dynamic>> _rows(String headerState, String toolStatus) => [
      {'rowId': 2, 'kind': 'turnHeader', 'state': headerState},
      {'rowId': 3, 'kind': 'userInput', 'text': '第一问'},
      {
        'rowId': 4,
        'kind': 'toolCall',
        'toolName': 'Read',
        'status': toolStatus,
        'inputText': '{"file_path":"live-keep-a.dart"}',
        'output': const {'text': 'ok'},
      },
      {
        'rowId': 6,
        'kind': 'toolCall',
        'toolName': 'Bash',
        'status': toolStatus,
        'inputText': '{"command":"cat live-keep-b.dart"}',
        'output': const {'text': 'ok'},
      },
      if (headerState != 'running')
        {'rowId': 5, 'kind': 'assistantText', 'state': 'success', 'text': '答'},
    ];

void main() {
  testWidgets('运行中手动收起→完成仍收起（修复前红=完成即弹开）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final sub = _LiveSub()..reseed(_rows('running', 'running'), phase: 'running');
    await tester.pumpWidget(_host(_LiveApp(sub)));
    await _settle(tester);

    await sub.primeRunning(tester, _rows('running', 'running'));

 // 运行中默认展开：两个工具行都可见。
    expect(find.textContaining('live-keep-a.dart'), findsWidgets);
    expect(find.textContaining('live-keep-b.dart'), findsWidgets);

 // 用户点回合条收起（运行分支）：步骤全部收起（收起态=状态条+
 // 外置正文，运行中尚无正文可显）。
    await tester.tap(find.textContaining('工作中').first);
    await _settle(tester);
    expect(
      find.textContaining('live-keep-a.dart'),
      findsNothing,
      reason: '运行中手动收起后步骤应不可见',
    );
    expect(find.textContaining('live-keep-b.dart'), findsNothing);

 // 完成帧到达（异常终态=failed 强开档）——H11：手动收起仍优先。
 // 2026-10-26 语义下正常完成本就收起，failed 强开是唯一冲突档。
    sub.reseed(_rows('failed', 'success'), phase: 'idle');
    await _settle(tester);
    expect(
      find.textContaining('live-keep-b.dart'),
      findsNothing,
      reason: 'H11：运行中手动收起=用户选择，异常终态强开也不得覆盖',
    );
  });

  testWidgets('无手动操作：正常完成→收起（只剩最后回复）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final sub = _LiveSub()..reseed(_rows('running', 'running'), phase: 'running');
    await tester.pumpWidget(_host(_LiveApp(sub)));
    await _settle(tester);

    await sub.primeRunning(tester, _rows('running', 'running'));

    sub.reseed(_rows('completedSuccess', 'success'), phase: 'idle');
    await _settle(tester);
    expect(
      find.textContaining('live-keep-b.dart'),
      findsNothing,
      reason: '运行完后收起只剩最后回复（2026-10-26 用户澄清语义）',
    );
    expect(find.text('答'), findsOneWidget, reason: '外置正文仍可见');
  });

  testWidgets('无手动操作：异常终态完成→强开档展开（失败可见）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final sub = _LiveSub()..reseed(_rows('running', 'running'), phase: 'running');
    await tester.pumpWidget(_host(_LiveApp(sub)));
    await _settle(tester);

    await sub.primeRunning(tester, _rows('running', 'running'));

    sub.reseed(_rows('failed', 'success'), phase: 'idle');
    await _settle(tester);
    expect(
      find.textContaining('live-keep-b.dart'),
      findsWidgets,
      reason: '失败轮默认展开（官方 forceOpen 三条件不变）',
    );
  });
}

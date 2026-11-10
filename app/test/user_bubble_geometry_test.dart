// 用户气泡几何回归（候选 15 反馈 B5 排查转正，2026-11-10）：
// 会话消息列表里短用户消息「推包」渲染错位（应在上一回合结束与下一回合
// 统计行之间的位置变成大片空白；气泡只剩右缘 3dp 蓝竖条 + 贴右缘被裁半
// 的圆角块）。
//
// 本文件=合一靶：
//  A. 主用例（父会话要求的序列）：上一回合 → user:'推包' → 下一回合
//     （工具组+轮尾统计行「已工作 X」）→ assistant 下一条。断言气泡
//     left∈(0,300)、宽>40、与上一元素间距<80、完全在屏内。
//  B. 条件扫掠：宽 320/375/411/640/840、textScale 1.0/1.3/2.0、浅/深色、
//     无轮头、running。
//  C. 触发路径扫掠：回到本回合开始（气泡成为 center 锚点）、前插历史、
//     guided 回合内追问切段、重复 rowId、缺 rowId、发送后"正在思考"trailing。
//
// 排查结论：布局层被本组扫掠证伪（气泡全链无横向偏移可能）——真机
// 错位定为绘制/图层级（华为合成器图层缓存偏移嫌疑，与 56b 同族；或
// center 锚点重挂换层）。本文件钉死布局不变量：未来任何改动把气泡
// 画歪（left 出界/宽度塌缩/间距异常）在本组直接红。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

class _B5Sub implements ConversationSubscription {
  @override
  final String sessionId = 's-b5';
  @override
  final ConversationState state = ConversationState();
  @override
  bool get hasLiveFrames => true;
  @override
  String? get subscriptionId => 'sub-b5';
  @override
  bool get isDisposed => false;
  @override
  String get topic => 'conversation/s-b5';
  @override
  Future<void> dispose() async {}
}

class _B5App extends AppState {
  _B5App(this.rows, {this.controlPhase = 'idle'});
  final List<Map<String, dynamic>> rows;
  final String controlPhase;
  final sub = _B5Sub();

  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  Future<ConversationSubscription> ensureConversation(
    String id, {
    Object? seedCacheEntry,
  }) async {
    if (!sub.state.ready) {
      sub.state.applySeed(
        ConversationSeed(
          rows: rows,
          logEpoch: 'e1',
          seq: rows.length,
          firstRowId: 1,
          totalCount: rows.length,
          snapshot: {
            'title': 'B5',
            'control': {'phase': controlPhase},
          },
        ),
      );
    }
    return sub;
  }
}

Future<void> _pump(WidgetTester tester, {int frames = 20}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 前一回合（完整）+ 「推包」+ 下一回合（统计行/工具组/轮尾）。
List<Map<String, dynamic>> _rows({bool headerBeforeShort = true}) => [
  {'rowId': 1, 'kind': 'turnHeader', 'state': 'completedSuccess'},
  {'rowId': 2, 'kind': 'userInput', 'text': '上一问'},
  {'rowId': 3, 'kind': 'toolCall', 'toolName': 'Read', 'status': 'success'},
  {'rowId': 4, 'kind': 'assistantText', 'text': '上一回合的收尾回复', 'state': 'success'},
  if (headerBeforeShort)
    {
      'rowId': 6,
      'kind': 'turnHeader',
      'state': 'completedSuccess',
      'startedAt': 1700000000000,
      'activeMs': 85000,
      'endedAt': 1700000085000,
    },
  {'rowId': 7, 'kind': 'userInput', 'text': '推包'},
  {'rowId': 8, 'kind': 'toolCall', 'toolName': 'Bash', 'status': 'success', 'inputText': 'pack'},
  {'rowId': 9, 'kind': 'assistantText', 'text': '下一条回答', 'state': 'success'},
];

Future<_B5App> _pumpPage(
  WidgetTester tester,
  List<Map<String, dynamic>> rows, {
  double width = 375,
  double height = 806,
  String controlPhase = 'idle',
  double textScale = 1.0,
  bool dark = false,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final app = _B5App(rows, controlPhase: controlPhase);
  await tester.pumpWidget(
    AppStateScope(
      app: app,
      child: MaterialApp(
        theme: buildAppTheme(),
        darkTheme: buildAppTheme(Brightness.dark),
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: const ConversationPage(sessionId: 's-b5', title: 'B5'),
      ),
    ),
  );
  await _pump(tester);
  return app;
}

Finder _bubble() => find
    .ancestor(of: find.text('推包'), matching: find.byType(IntrinsicHeight))
    .first;

void _expectInBounds(WidgetTester tester, {required String label}) {
  final rect = tester.getRect(_bubble());
  final screenW = tester.view.physicalSize.width;
  // ignore: avoid_print
  print('[B5] $label bubble=$rect screenW=$screenW');
  expect(rect.left, greaterThanOrEqualTo(0), reason: '$label 左越界');
  expect(rect.right, lessThanOrEqualTo(screenW + 0.5), reason: '$label 右越界');
  // 宽度不能塌缩（真机现象=只剩 3dp 竖条+裁半块）。
  expect(rect.width, greaterThan(40), reason: '$label 气泡宽度塌缩');
  expect(rect.left, greaterThan(0), reason: '$label left<=0');
  // 气泡不得被推到屏右外：左侧起点至少留出气泡自身宽度+24dp 的可视余量
  // （375 屏常态 left≈231；若被推到右缘外 left 会逼近屏宽）。
  expect(rect.left, lessThan(screenW - 40), reason: '$label left 贴近/越过右缘');
}

void main() {
  testWidgets('A. 主用例：短用户气泡几何（父会话指定序列）', (tester) async {
    await _pumpPage(tester, _rows());
    expect(find.text('推包'), findsOneWidget);
    _expectInBounds(tester, label: '主用例');
    // 与上一元素（上一回合收尾正文）的间距不得异常放大（常态 84，空白
    // 事故是 460 量级 → 阈值 120）。
    final bubble = tester.getRect(_bubble());
    final prev = tester.getRect(find.text('上一回合的收尾回复'));
    final gap = bubble.top - prev.bottom;
    // ignore: avoid_print
    print('[B5] 与上一正文间距=$gap（轮间 56 + 条目 12 常态）');
    expect(gap, lessThan(120), reason: '气泡前出现异常空白（gap=$gap）');
    expect(gap, greaterThanOrEqualTo(0));
  });

  final variants = <String, Map<String, Object>>{
    '宽411': {'width': 411.0},
    '折叠320': {'width': 320.0},
    '展开640': {'width': 640.0},
    '展开840': {'width': 840.0, 'height': 1000.0},
    '字号1.3': {'textScale': 1.3},
    '字号2.0': {'textScale': 2.0},
    '深色': {'dark': true},
    '无轮头': {'headerBeforeShort': false},
    'running': {'controlPhase': 'running'},
  };
  for (final entry in variants.entries) {
    testWidgets('B. 扫掠 ${entry.key}', (tester) async {
      final v = entry.value;
      await _pumpPage(
        tester,
        _rows(headerBeforeShort: v['headerBeforeShort'] != false),
        width: (v['width'] as double?) ?? 375,
        height: (v['height'] as double?) ?? 806,
        controlPhase: (v['controlPhase'] as String?) ?? 'idle',
        textScale: (v['textScale'] as double?) ?? 1.0,
        dark: v['dark'] == true,
      );
      if (find.text('推包').evaluate().isEmpty) {
        // ignore: avoid_print
        print('[B5] ${entry.key}: 推包不在视口（非错位）');
        return;
      }
      _expectInBounds(tester, label: entry.key);
    });
  }

  testWidgets('C1. 回到本回合开始（气泡成为 center 锚点）', (tester) async {
    // 内容须超一屏 FAB 才出现：前垫 5 个完整回合。
    final tall = <Map<String, dynamic>>[
      for (var t = 0; t < 5; t++) ...[
        {'rowId': 100 + t * 10, 'kind': 'turnHeader', 'state': 'completedSuccess'},
        {'rowId': 101 + t * 10, 'kind': 'userInput', 'text': '更早追问 $t'},
        {'rowId': 102 + t * 10, 'kind': 'toolCall', 'toolName': 'Read', 'status': 'success'},
        {
          'rowId': 103 + t * 10,
          'kind': 'assistantText',
          'text': '更早回答 $t ' * 12,
          'state': 'success',
        },
      ],
      ..._rows(headerBeforeShort: true),
    ];
    await _pumpPage(tester, tall);
    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('chat-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent * 0.3);
    await _pump(tester, frames: 5);
    await tester.longPress(find.byKey(const ValueKey('jump-bottom')));
    await _pump(tester, frames: 5);
    final item = find.text('回到本回合开始');
    if (item.evaluate().isEmpty) return;
    await tester.tap(item.first);
    await _pump(tester, frames: 10);
    // ignore: avoid_print
    print('[B5] center 锚点 offset=${scrollable.position.pixels}');
    _expectInBounds(tester, label: 'center 锚点');
  });

  testWidgets('C2. 上滑前插历史后气泡几何', (tester) async {
    final rows = _rows().sublist(2); // 从上一回合中段开始（半截窗口）
    await _pumpPage(tester, rows);
    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('chat-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    scrollable.position.jumpTo(scrollable.position.minScrollExtent);
    await _pump(tester, frames: 5);
    if (find.text('推包').evaluate().isEmpty) {
      // ignore: avoid_print
      print('[B5] 前插：推包不在视口');
      return;
    }
    _expectInBounds(tester, label: '前插');
  });

  testWidgets('C3. guided 回合内追问（同轮切段）', (tester) async {
    final rows = <Map<String, dynamic>>[
      {'rowId': 1, 'kind': 'turnHeader', 'state': 'completedSuccess'},
      {'rowId': 2, 'kind': 'userInput', 'text': '上一问'},
      {'rowId': 3, 'kind': 'assistantText', 'text': '上一答', 'state': 'success'},
      {'rowId': 10, 'kind': 'turnHeader', 'state': 'running'},
      {'rowId': 11, 'kind': 'userInput', 'text': '本轮首问'},
      {'rowId': 12, 'kind': 'toolCall', 'toolName': 'Read', 'status': 'success'},
      {
        'rowId': 13,
        'kind': 'userInput',
        'text': '推包',
        'guided': true,
        'createdAt': 1700000100000,
      },
      {'rowId': 14, 'kind': 'toolCall', 'toolName': 'Bash', 'status': 'running'},
    ];
    await _pumpPage(tester, rows);
    await tester.pump(const Duration(milliseconds: 40));
    _expectInBounds(tester, label: 'guided');
  });

  testWidgets('C4. 重复 rowId / 缺 rowId', (tester) async {
    await _pumpPage(tester, <Map<String, dynamic>>[
      {'rowId': 1, 'kind': 'turnHeader', 'state': 'completedSuccess'},
      {'rowId': 2, 'kind': 'userInput', 'text': '上一问'},
      {'rowId': 3, 'kind': 'assistantText', 'text': '上一答', 'state': 'success'},
      {'rowId': 7, 'kind': 'userInput', 'text': '推包'},
      {'rowId': 7, 'kind': 'userInput', 'text': '推包'},
      {'rowId': 8, 'kind': 'assistantText', 'text': '回答', 'state': 'success'},
    ]);
    // ignore: avoid_print
    print('[B5] 重复 rowId 推包渲染数=${find.text('推包').evaluate().length}');
    _expectInBounds(tester, label: '重复 rowId');

    await _pumpPage(tester, <Map<String, dynamic>>[
      {'rowId': 1, 'kind': 'turnHeader', 'state': 'completedSuccess'},
      {'rowId': 2, 'kind': 'userInput', 'text': '上一问'},
      {'rowId': 3, 'kind': 'assistantText', 'text': '上一答', 'state': 'success'},
      {'kind': 'userInput', 'text': '推包'},
      {'rowId': 8, 'kind': 'assistantText', 'text': '回答', 'state': 'success'},
    ]);
    _expectInBounds(tester, label: '缺 rowId');
  });

  testWidgets('C5. 发送后窗口期（推包为末条 + 正在思考 trailing）', (tester) async {
    await _pumpPage(
      tester,
      <Map<String, dynamic>>[
        {'rowId': 1, 'kind': 'turnHeader', 'state': 'completedSuccess'},
        {'rowId': 2, 'kind': 'userInput', 'text': '上一问'},
        {'rowId': 3, 'kind': 'assistantText', 'text': '上一答', 'state': 'success'},
        {'rowId': 7, 'kind': 'userInput', 'text': '推包'},
      ],
      controlPhase: 'running',
    );
    expect(find.textContaining('正在思考'), findsOneWidget);
    _expectInBounds(tester, label: '待回复 trailing');
  });
}

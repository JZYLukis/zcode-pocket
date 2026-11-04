// 会话子代理列表（2026-10-26 批④拍板⑥，官方 SubagentSessionSidePane
// 手机化）：分段渲染（运行中/已结束）、endedCursor 分页加载、
// childSessionId 下钻只读会话、空/错误态。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';
import 'package:zcode_pocket/ui/subagent_list_sheet.dart';

Map<String, dynamic> _item(
  String id,
  String title, {
  String? status,
  String? summary,
}) =>
    {
      'childSessionId': id,
      'subagentType': 'general-purpose',
      'title': title,
      if (summary != null) 'summary': summary,
      if (status != null) 'status': status,
      'startedAt': 1700000000000,
    };

class _FakeApp extends AppState {
  final Map<String, dynamic>? Function(String sessionId,
      {String? endedCursor, int endedLimit}) impl;
  _FakeApp(this.impl);

  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  Future<Map<String, dynamic>?> sessionSubagents(
    String sessionId, {
    String? endedCursor,
    int endedLimit = 20,
  }) async =>
      impl(sessionId,
          endedCursor: endedCursor, endedLimit: endedLimit);
}

Widget _host(AppState app) => AppStateScope(
      app: app,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => TextButton(
            key: const ValueKey('open'),
            onPressed: () => showSubagentListSheet(
              context,
              sessionId: 's-main',
              openSession: (context, {required sessionId, required title, required readOnly}) async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ConversationPage(
                      sessionId: sessionId,
                      title: title,
                      readOnly: readOnly,
                    ),
                  ),
                );
              },
            ),
            child: const Text('开'),
          ),
        ),
      ),
    );

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('open')));
  await tester.pumpAndSettle();
}

void main() {
  // 正常手机视口（默认 800×600 偏矮致弹层布局断言失真）。
  void setPhoneView(WidgetTester tester) {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('分段渲染：运行中+已结束（含失败红标），下钻只读会话',
      (tester) async {
    setPhoneView(tester);
    final app = _FakeApp((s, {endedCursor, endedLimit = 20}) => {
          'revision': 1,
          'childSessionIds': const ['c1', 'c2', 'c3'],
          'running': [_item('c1', '勘察工作区', summary: '正在读目录')],
          'ended': {
            'total': 2,
            'items': [
              _item('c2', '检索用法', status: 'success'),
              _item('c3', '写报告', status: 'failed'),
            ],
          },
        });
    await tester.pumpWidget(_host(app));
    await _open(tester);

    expect(find.text('运行中'), findsOneWidget);
    expect(find.text('已结束 2'), findsOneWidget);
    expect(find.textContaining('勘察工作区'), findsOneWidget);
    expect(find.textContaining('写报告 · 失败'), findsOneWidget,
        reason: '失败条目须有可读信号（红标题+失败后缀）');

    // 下钻：点运行中条目 → 推入只读会话页（标题=子代理标题）。
    // 有界泵：下钻页加载转圈是无限动画（pumpAndSettle 必超时）。
    await tester.tap(find.textContaining('勘察工作区'));
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('勘察工作区'), findsWidgets,
        reason: '下钻页顶栏标题=子代理标题');
    expect(Navigator.of(tester.element(find.text('勘察工作区').first)).canPop(),
        isTrue);
  });

  testWidgets('分页：加载更多用 endedCursor 换页', (tester) async {
    final calls = <String?>[];
    final app = _FakeApp((s, {endedCursor, endedLimit = 20}) {
      calls.add(endedCursor);
      return {
        'revision': 1,
        'childSessionIds': const [],
        'running': const [],
        'ended': endedCursor == null
            ? {
                'total': 3,
                'items': [
                  _item('c1', '第一页甲'),
                  _item('c2', '第一页乙'),
                ],
                'nextCursor': 'cursor-1',
              }
            : {
                'total': 3,
                'items': [_item('c3', '第二页丙')],
              },
      };
    });
    await tester.pumpWidget(_host(app));
    await _open(tester);

    expect(find.byKey(const ValueKey('subagents-load-more')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('subagents-load-more')));
    await tester.pumpAndSettle();
    expect(calls, [null, 'cursor-1'], reason: '第二页带 endedCursor');
    expect(find.textContaining('第二页丙'), findsOneWidget);
    expect(find.byKey(const ValueKey('subagents-load-more')), findsNothing,
        reason: '无更多页时加载更多退场');
  });

  testWidgets('空态', (tester) async {
    setPhoneView(tester);
    final app = _FakeApp((s, {endedCursor, endedLimit = 20}) => {
          'revision': 0,
          'childSessionIds': const [],
          'running': const [],
          'ended': {'total': 0, 'items': const []},
        });
    await tester.pumpWidget(_host(app));
    await _open(tester);
    expect(find.textContaining('还没有子智能体'), findsOneWidget);
  });

  testWidgets('错误态可重试：恢复后显示完整空态面板', (tester) async {
    setPhoneView(tester);
    var calls = 0;
    final app = _FakeApp((s, {endedCursor, endedLimit = 20}) {
      calls++;
      if (calls == 1) return null;
      return {
        'revision': 0,
        'childSessionIds': const [],
        'running': const [],
        'ended': {'total': 0, 'items': const []},
      };
    });
    await tester.pumpWidget(_host(app));
    await _open(tester);
    expect(find.textContaining('加载失败'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('subagents-retry')));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.byKey(const ValueKey('subagents-empty')), findsOneWidget);
    expect(find.textContaining('主智能体创建子智能体后'), findsOneWidget);
  });
}

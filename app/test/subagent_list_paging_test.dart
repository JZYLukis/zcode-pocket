// 会话子代理列表分页失败回归（对抗审查中⑤）：分页失败必须页脚行内
// 错误+重试（保留已加载列表、游标续传），不得整页替换成错误态；追加
// 按 childSessionId 去重。红=旧实现 catch 写 _error，整页换成错误面板。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';
import 'package:zcode_pocket/ui/subagent_list_sheet.dart';

Map<String, dynamic> _item(String id, String title) => {
      'childSessionId': id,
      'subagentType': 'general-purpose',
      'title': title,
      'status': 'success',
      'startedAt': 1700000000000,
    };

class _PagingApp extends AppState {
  _PagingApp(this.impl);

  final Future<Map<String, dynamic>?> Function(String? cursor) impl;

  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  Future<Map<String, dynamic>?> sessionSubagents(
    String sessionId, {
    String? endedCursor,
    int endedLimit = 20,
  }) =>
      impl(endedCursor);
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
              openSession: (
                context, {
                required sessionId,
                required title,
                required readOnly,
              }) async {
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

void main() {
  testWidgets('分页失败：页脚行内错误+重试保留列表；重试游标续传并去重', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final calls = <String?>[];
    var failedOnce = false;
    final app = _PagingApp((cursor) async {
      calls.add(cursor);
      if (cursor == null) {
        return {
          'revision': 1,
          'childSessionIds': const ['c1', 'c2'],
          'running': const [],
          'ended': {
            'total': 3,
            'items': [
              _item('c1', '第一页甲'),
              _item('c2', '第一页乙'),
            ],
            'nextCursor': 'cursor-1',
          },
        };
      }
      if (!failedOnce) {
        failedOnce = true;
        throw StateError('网络抖动');
      }
      return {
        'revision': 2,
        'childSessionIds': const ['c1', 'c2', 'c3'],
        'running': const [],
        'ended': {
          'total': 3,
          'items': [
            // 游标窗口内服务端新条目插入导致的重复页首：必须去重。
            _item('c2', '第一页乙（重复）'),
            _item('c3', '第二页丙'),
          ],
        },
      };
    });

    await tester.pumpWidget(_host(app));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    expect(find.textContaining('第一页甲'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('subagents-load-more')));
    await tester.pumpAndSettle();

    // 红点：整页错误面板不得出现；已加载列表保留；页脚行内错误+重试。
    expect(find.textContaining('第一页甲'), findsOneWidget,
        reason: '分页失败不得清空已加载列表');
    expect(find.textContaining('加载更多失败'), findsOneWidget);
    expect(find.byKey(const ValueKey('subagents-load-more-retry')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('subagents-load-more')), findsNothing,
        reason: '错误态下只留重试，不叠加载更多按钮');

    await tester.tap(find.byKey(const ValueKey('subagents-load-more-retry')));
    await tester.pumpAndSettle();

    expect(calls, [null, 'cursor-1', 'cursor-1'],
        reason: '重试必须按原游标续传');
    expect(find.textContaining('第二页丙'), findsOneWidget);
    expect(find.textContaining('第一页乙（重复）'), findsNothing,
        reason: '追加按 childSessionId 去重');
    expect(find.byKey(const ValueKey('subagents-load-more-retry')),
        findsNothing);
    expect(tester.takeException(), isNull);
  });
}

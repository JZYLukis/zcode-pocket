// 展开类交互吸底断言清单（AGENTS 工作规则 7"交互模式横向清单"配套，
// 2026-10-24 立；源起：文件卡展开不吸底真机实锤——思考条吸底先例存在
// 但同类交互从未横向扫全）。已知模式：思考条/工具行/文件卡/分组行四类
// 展开交互，展开后目标内容须滚入可视区（底部对齐语义）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/cache_policy.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

class _LongApp extends AppState {
  _LongApp(this.rows, this.changes);
  final List<Map<String, dynamic>> rows;
  final Map<String, dynamic> changes;

  @override
  LinkPhase get phase => LinkPhase.online;

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
        snapshotControl: {
          'title': '吸底清单',
          'control': {'phase': 'idle'},
          'usage': {
            'contextWindow': {'usedTokens': 12000, 'maxTokens': 1000000},
          },
        },
        savedAt: DateTime.now().millisecondsSinceEpoch,
        byteSize: 1024,
      );

  @override
  Future<dynamic> fileChanges(
    String sessionId, {
    required Map<String, dynamic> target,
  }) async => changes;
}

Widget _host(AppState app) => AppStateScope(
      app: app,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: const ConversationPage(sessionId: 's1', title: '吸底清单'),
      ),
    );

Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 目标 widget 的底边是否已滚入可视区（吸底语义）。
bool bottomVisible(WidgetTester tester, Finder f) {
  final elements = f.evaluate();
  if (elements.isEmpty) return false;
  final box = elements.first.findRenderObject() as RenderBox;
  final bottom = box.localToGlobal(Offset.zero).dy + box.size.height;
  final view = tester.view;
  final h = view.physicalSize.height / view.devicePixelRatio;
  return bottom <= h + 0.5;
}

/// 前置：把主消息列表滚到底（模拟用户看最新内容的常态——缓存会话
/// 打开不保证初始就在底部）。
Future<void> scrollListToBottom(WidgetTester tester) async {
  final scroll = tester.state<ScrollableState>(
    find.descendant(
      of: find.byKey(const ValueKey('chat-scroll')),
      matching: find.byType(Scrollable),
    ),
  );
  scroll.position.jumpTo(scroll.position.maxScrollExtent);
  await tester.pump(const Duration(milliseconds: 100));
}

/// 长内容垫片：把目标行压出首屏。
List<Map<String, dynamic>> filler(int n) => [
      for (var i = 0; i < n; i++)
        {
          'rowId': 1000 + i,
          'kind': 'userInput',
          'text': '垫片消息 $i ' * 3,
        },
    ];

void main() {
  testWidgets('思考条展开：滚入可视区', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _LongApp([
      ...filler(12),
      {'rowId': 2, 'kind': 'turnHeader', 'state': 'running'},
      {
        'rowId': 3,
        'kind': 'reasoning',
        'state': 'streaming',
        'text': List.filled(60, '思考内容行').join('\n'),
      },
    ], {});
    await tester.pumpWidget(_host(app));
    await _pump(tester);
    await scrollListToBottom(tester);
    await tester.tap(find.byIcon(Icons.psychology_outlined));
    await _pump(tester);
    expect(bottomVisible(tester, find.byIcon(Icons.psychology_outlined)), isTrue,
        reason: '展开后思考条须滚入可视区（吸底清单#1）');
  });

  testWidgets('工具行展开：滚入可视区', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _LongApp([
      ...filler(12),
      {'rowId': 2, 'kind': 'turnHeader', 'state': 'completedSuccess'},
      {
        'rowId': 3,
        'kind': 'toolCall',
        'toolName': 'Read',
        'status': 'success',
        'inputText': '{"file_path":"a.dart"}',
        'output': {'text': List.filled(40, '输出行').join('\n')},
      },
    ], {});
    await tester.pumpWidget(_host(app));
    await _pump(tester);
    await scrollListToBottom(tester);
    // 单轮会话=末轮默认展开（2026-10-25 问题②拍板）——直接展开工具行。
    await tester.tap(find.textContaining('a.dart'));
    await _pump(tester);
    expect(bottomVisible(tester, find.textContaining('a.dart')), isTrue,
        reason: '展开后工具行须滚入可视区（吸底清单#2）');
  });

  testWidgets('文件卡展开：明细到达后滚入可视区（首展异步加载路径）',
      (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final changes = {
      'items': [
        for (var i = 0; i < 20; i++)
          {'path': 'lib/src/file_$i.dart', 'additions': 3, 'deletions': 1},
      ],
    };
    final app = _LongApp([
      ...filler(12),
      {
        'rowId': 2,
        'kind': 'turnHeader',
        'state': 'completedSuccess',
        'entityId': 'e2',
        'fileChanges': {'files': 20, 'additions': 60, 'deletions': 20},
      },
      {
        'rowId': 3,
        'kind': 'assistantText',
        'state': 'success',
        'text': '改完了',
        'entityId': 'e3',
      },
    ], changes);
    await tester.pumpWidget(_host(app));
    await _pump(tester);
    await scrollListToBottom(tester);
    await tester.tap(find.byKey(const ValueKey('file-summary-card-2')));
    // 明细异步到达（fileChanges 桩）→补吸底→内容滚入。
    await _pump(tester);
    expect(
      bottomVisible(tester, find.byKey(const ValueKey('file-summary-card-2'))),
      isTrue,
      reason: '首次展开（明细异步加载）后文件卡须滚入可视区（吸底清单#3，'
          '2026-10-24 真机实锤"有时不吸底"的回归靶）',
    );
    expect(find.textContaining('file_19.dart'), findsWidgets,
        reason: '明细行=文件名+全路径两处命中');
  });

  testWidgets('分组行展开：滚入可视区', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _LongApp([
      ...filler(12),
      {'rowId': 2, 'kind': 'turnHeader', 'state': 'completedSuccess'},
      for (var i = 0; i < 4; i++)
        {
          'rowId': 10 + i,
          'kind': 'toolCall',
          'toolName': 'Read',
          'status': 'success',
          'inputText': '{"file_path":"f$i.dart"}',
          'output': {'text': 'ok' * 30},
        },
    ], {});
    await tester.pumpWidget(_host(app));
    await _pump(tester);
    await scrollListToBottom(tester);
    // 末轮默认展开（2026-10-25 问题②拍板）——直接点分组行。
    await tester.tap(find.textContaining('查阅'));
    await _pump(tester);
    expect(bottomVisible(tester, find.textContaining('查阅')), isTrue,
        reason: '展开后分组行须滚入可视区（吸底清单#4）');
  });
}

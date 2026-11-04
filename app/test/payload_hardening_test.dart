// 载荷守卫红绿矩阵（开源审查批C 组3：build/投影路径裸 as 断言守卫铺满）。
//
// 威胁模型：协议 zod 保证 number，但服务端形态漂移（数字字段变 String、
// List/Map 互换、字段缺失）会让裸 `as num?`/`as Map?`/`as List?`/`used!`
// 在 build 期抛 TypeError——release 下整页灰屏。守卫单源=
// core/payload_guard.dart（numOf/intOf/intOrZero/mapOf/listOf）。
//
// 本文件按受影响文件逐个钉畸形形态：修复前抛异常（红，另经临时回退
// 单点实证），修复后安全兜底（默认值/跳过/容忍解析，绿）。正常路径
// 行为与显示零变化由既有测试族保证（turn_model/paseo/usage 等）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/payload_guard.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/task_list.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/ui/conversation_composer_meta.dart';
import 'package:zcode_pocket/ui/conversation_file_summary_card.dart';
import 'package:zcode_pocket/ui/conversation_tool_tiles.dart';
import 'package:zcode_pocket/ui/conversation_turn_view.dart';
import 'package:zcode_pocket/ui/diff_viewer_page.dart';
import 'package:zcode_pocket/ui/task_home.dart';
import 'package:zcode_pocket/ui/turn_model.dart';
import 'package:zcode_pocket/ui/usage_page.dart';

Future<void> _openSession(
  BuildContext context, {
  required String sessionId,
  required String title,
  required bool readOnly,
}) async {}

class _ChangesApp extends AppState {
  _ChangesApp(this.changes);
  final Map<String, dynamic>? changes;

  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  Future<dynamic> fileChanges(
    String sessionId, {
    required Map<String, dynamic> target,
  }) async => changes;
}

Widget _host(Widget body, {AppState? app}) => AppStateScope(
  app: app ?? AppState(),
  child: MaterialApp(theme: buildAppTheme(), home: Scaffold(body: body)),
);

Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('payload_guard 纯函数矩阵', () {
    test('畸形形态逐档兜底，正常形态零变化', () {
      // num：原样。
      expect(numOf(3), 3);
      expect(numOf(3.5), 3.5);
      // String 数字（形态漂移）：容忍解析。
      expect(numOf('123'), 123);
      expect(numOf(' 42 '), 42);
      expect(numOf('12.5'), 12.5);
      // 非数字 String/bool/null/容器：null。
      expect(numOf('abc'), isNull);
      expect(numOf(''), isNull);
      expect(numOf(true), isNull);
      expect(numOf(null), isNull);
      expect(numOf({'a': 1}), isNull);
      expect(numOf([1]), isNull);
      // int 化（与旧 `(v as num?)?.toInt()` 同语义，含取整）。
      expect(intOf(3.9), 3);
      expect(intOf('900'), 900);
      expect(intOf(<String, dynamic>{}), isNull);
      expect(intOrZero('x'), 0);
      expect(intOrZero(null), 0);
      // Map/List 判型。
      expect(mapOf({'a': 1})!['a'], 1);
      expect(mapOf('x'), isNull);
      expect(mapOf([1]), isNull);
      expect(mapOf(null), isNull);
      expect(listOf(<dynamic>[1]), isNotNull);
      expect(listOf({'a': 1}), isNull);
      expect(listOf(5), isNull);
      expect(listOf(null), isNull);
    });
  });

  group('turn_model（B1 P2-2/B2-5/B3 P3）', () {
    test('String 数字时间戳/工时不打断投影且容忍解析', () {
      final items = buildChatItems([
        {
          'rowId': '1',
          'kind': 'userInput',
          'text': 'hi',
          'createdAt': '100',
        },
        {
          'rowId': '2',
          'kind': 'turnHeader',
          'state': 'completedSuccess',
          'startedAt': '1000',
          'endedAt': '62000',
          'activeMs': '61000',
          'createdAt': '1000',
          'entityId': 'e1',
          // fileChanges 漂移成 String：非 Map 兜底，不再 TypeError。
          'fileChanges': 'x',
        },
        {
          'rowId': '3',
          'kind': 'toolCall',
          'toolName': 'Read',
          'status': 'success',
          'inputText': 'a.dart',
        },
      ]);
      final bar = items.whereType<TurnBarItem>().first;
      expect(bar.work.startedAtMs, 1000);
      expect(bar.work.activeMs, 61000);
      expect(bar.work.fileChanges, isNull, reason: '非 Map fileChanges 兜底 null');
      expect(workBarLabel(bar.work), contains('已工作'));
      expect(turnHeaderCreatedAt(bar.work.header), 1000);
      // 旧实现 `('61000' as num?)` 直接 TypeError（红）——此处不抛即绿。
    });

    test('fileChanges.files 为 String 数字：轮尾文件卡照发且计数正确', () {
      final items = buildChatItems([
        {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
        {
          'rowId': 2,
          'kind': 'turnHeader',
          'state': 'completedSuccess',
          'entityId': 'e1',
          'fileChanges': {'files': '3'},
        },
      ]);
      final card = items.whereType<FileSummaryItem>().single;
      expect(card.fileChanges?['files'], '3');
    });

    test('rowId 为 String 数字：锚迁移与配对判定不抛', () {
      final items = buildChatItems([
        {'rowId': '1', 'kind': 'userInput', 'text': 'hi'},
        {
          'rowId': '2',
          'kind': 'turnHeader',
          'state': 'completedSuccess',
          'entityId': 'e1',
        },
        {
          'rowId': '7',
          'kind': 'toolCall',
          'toolName': 'Read',
          'status': 'success',
          'inputText': 'a.dart',
        },
      ]);
      expect(
        () => migrateAnchorIndexAfterPrepend('turn-tail-7', items),
        returnsNormally,
      );
      expect(migrateAnchorIndexAfterPrepend('turn-tail-7', items), 1);
      expect(reasoningDurationMs({'durationMs': '8000'}), 8000);
    });
  });

  group('conversation_turn_view（_endedClock/_turnId，B2-5）', () {
    testWidgets('endedAt/rowId 形态漂移不崩且时刻仍显示', (tester) async {
      final endedAt = DateTime(2026, 1, 1, 10, 17).millisecondsSinceEpoch;
      final work = buildChatItems([
        {'rowId': '1', 'kind': 'userInput', 'text': '跑'},
        {
          'rowId': '2',
          'kind': 'turnHeader',
          'state': 'completedSuccess',
          'activeMs': '253000',
          'endedAt': '$endedAt',
        },
        {
          'rowId': '3',
          'kind': 'toolCall',
          'toolName': 'Read',
          'status': 'success',
          'inputText': 'a.dart',
        },
      ]).whereType<TurnBarItem>().first.work;
      await tester.pumpWidget(
        _host(
          TurnBar(
            work: work,
            showTools: true,
            firstSeenOf: (_) => null,
            toolOpen: const {},
            elapsedMsOf: (_) => null,
            openSession: _openSession,
          ),
        ),
      );
      await _pump(tester);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('10:17'), findsOneWidget,
          reason: 'String 数字 endedAt 容忍解析，结束时刻不退档');
    });
  });

  group('conversation_composer_meta（D1 P2/D2-06/D3 P2-1 P2-2）', () {
    testWidgets('InfoRow：usedTokens 缺失而 maxTokens>0 不再 used! 崩溃',
        (tester) async {
      final state = ConversationState()
        ..snapshot = {
          'usage': {
            'contextWindow': {'maxTokens': 200000},
          },
        };
      await tester.pumpWidget(
        _host(InfoRow(state: state, modeLabel: '默认')),
      );
      await _pump(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('0/200k'), findsOneWidget,
          reason: 'used 缺失按 0 兜底（与 ContextDetailsCard 同款防御）');
    });

    testWidgets('ContextDetailsCard：usedTokens String 数字与 limits 非 List 不崩',
        (tester) async {
      final state = ConversationState()
        ..snapshot = {
          'usage': {
            'contextWindow': {'usedTokens': '5000', 'maxTokens': '200000'},
          },
        };
      await tester.pumpWidget(
        _host(
          ContextDetailsCard(
            state: state,
            // limits 漂移成计数（非 List）；重置机会漂移成 String。
            entitlement: {
              'quota': {'limits': 5},
            },
            resetStatus: {'availableFiveHourResets': 'no'},
          ),
        ),
      );
      await _pump(tester);
      expect(tester.takeException(), isNull,
          reason: 'quota 卡按无 limits 兜底跳过，不灰屏');
    });
  });

  group('usage_page（N1 P3/N2-5/N3 P2-1）', () {
    testWidgets('UsageHeatmapView：weeks 非 List 安全退空态', (tester) async {
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 390,
            child: UsageHeatmapView({
              'startDate': '2026-10-01',
              'endDate': '2026-10-02',
              'maxTokens': 1,
              'weeks': {'oops': 1},
            }),
          ),
        ),
      );
      await _pump(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('暂无活动数据'), findsOneWidget);
    });
  });

  group('conversation_file_summary_card（C1 P2-1）', () {
    testWidgets('fileChanges 数字字段 String 化不崩且计数正确', (tester) async {
      await tester.pumpWidget(
        _host(
          FileSummaryCard(
            sessionId: 's1',
            header: const {
              'rowId': 9,
              'entityId': 'e1',
              'state': 'active',
            },
            fileChanges: {'files': '3', 'additions': '10', 'deletions': '2'},
            openByCard: {},
            itemsByCard: const {},
            openSession: _openSession,
          ),
        ),
      );
      await _pump(tester);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('3 个文件已更改'), findsOneWidget);
    });
  });

  group('diff_viewer_page（C1 P2-1）', () {
    testWidgets('汇总与条目增删字段 String 化不崩且目录合计正确',
        (tester) async {
      final app = _ChangesApp({
        'files': '2',
        'additions': '9',
        'deletions': '3',
        'items': [
          {'path': 'src/a.dart', 'additions': '5', 'deletions': '1'},
          {'path': 'src/b.dart', 'additions': '4', 'deletions': '2'},
        ],
      });
      await tester.pumpWidget(
        _host(const DiffViewerPage(sessionId: 's1'), app: app),
      );
      await _pump(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('+9/-3'), findsOneWidget,
          reason: '目录级增删合计容忍解析 String 数字');
    });
  });

  group('conversation_tool_tiles（C1 P2-1）', () {
    testWidgets('file_diffs 增删 String 数字不崩且 +N/-M 正确', (tester) async {
      await tester.pumpWidget(
        _host(
          ToolCallTile(
            row: {
              'rowId': 1,
              'kind': 'toolCall',
              'toolName': 'Edit',
              'status': 'success',
              'inputText': '{"file_path":"a.dart"}',
              'output': {
                'display': {
                  'kind': 'file_diffs',
                  'files': [
                    {'additions': '5', 'deletions': '2'},
                  ],
                },
              },
            },
            openByRow: const {},
          ),
        ),
      );
      await _pump(tester);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('+5'), findsOneWidget);
      expect(find.textContaining('-2'), findsOneWidget);
    });

    testWidgets('progress.fraction 为 String 数字不崩（按 null 走 indeterminate）',
        (tester) async {
      await tester.pumpWidget(
        _host(
          ToolCallTile(
            row: {
              'rowId': 1,
              'kind': 'toolCall',
              'toolName': 'Bash',
              'status': 'running',
              'inputText': '{"command":"ls"}',
              'progress': {'fraction': '0.5', 'message': 'm'},
            },
            openByRow: const {},
            turnRunning: true,
          ),
        ),
      );
      await _pump(tester);
      expect(tester.takeException(), isNull);
    });
  });

  group('task_home（L1 P3-7）', () {
    test('goalStatus 非 String 与时间戳 String 数字安全兜底', () {
      final card = taskHomeEntry({
        'taskId': 't1',
        'title': 'T',
        'goalStatus': 5,
        'homeUpdatedAt': '900',
        'updatedAt': '800',
        'createdAt': '700',
      });
      expect(card.goalStatus, isNull, reason: '非 String goalStatus 兜 null');
      expect(card.lastActivityAt, 900);
      expect(card.createdAt, 700);
    });
  });

  group('task_list（J3 P2-2）', () {
    test('mergeTaskSources：updatedAt/createdAt String 数字不抛且解析', () {
      final cards = mergeTaskSources(
        sessions: const [],
        channelTasks: [
          {
            'taskId': 't1',
            'title': 'A',
            'status': 'idle',
            'updatedAt': '123',
            'createdAt': '45',
          },
        ],
        pinnedIds: const {},
        archivedIds: const {},
      );
      expect(cards, hasLength(1));
      expect(cards.single.lastActivityAt, 123);
      expect(cards.single.createdAt, 45);
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/ui/anchored_chat_list.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';
import 'package:zcode_pocket/ui/turn_model.dart';

/// 用户真机反馈「上滑偶发跳转/入会话闪动」（2026-10-29）——锚定列表
/// 前插稳定性复现靶：内容稳定键（逻辑 id）＋变高条目，验证拖拽进行中
/// 前插（真实时序：上滑触发预取、网络返回落在手势中）视口既有条目
/// 不被清空。
void main() {
  test('chatItemKey 稳定性：前插后既有键不漂；半截回合一次性切换可迁移（跳转根因回归）', () {
    final partialWork = [
      {'rowId': 5, 'kind': 'toolCall', 'name': 'Read', 'status': 'complete'},
      {'rowId': 6, 'kind': 'toolCall', 'name': 'Edit', 'status': 'complete'},
    ];
    final windowA = [
      ...partialWork,
      {'rowId': 7, 'kind': 'turnHeader', 'state': 'completedSuccess'},
      {'rowId': 8, 'kind': 'assistantText', 'text': '好', 'state': 'complete'},
      {'rowId': 9, 'kind': 'userInput', 'text': '第二问'},
    ];
    final windowB = [
      {'rowId': 1, 'kind': 'turnHeader', 'state': 'completedSuccess'},
      {'rowId': 2, 'kind': 'toolCall', 'name': 'Bash', 'status': 'complete'},
      {'rowId': 3, 'kind': 'userInput', 'text': '旧一问'},
      {'rowId': 4, 'kind': 'turnHeader', 'state': 'completedSuccess'},
      {'rowId': 40, 'kind': 'toolCall', 'name': 'Grep', 'status': 'complete'},
      ...partialWork,
      {'rowId': 7, 'kind': 'turnHeader', 'state': 'completedSuccess'},
      {'rowId': 8, 'kind': 'assistantText', 'text': '好', 'state': 'complete'},
      {'rowId': 9, 'kind': 'userInput', 'text': '第二问'},
    ];
    final itemsA = buildChatItems(windowA);
    final itemsB = buildChatItems(windowB);

    String keyAt(ChatItem it, int i) => chatItemKey(it, i);
    final keysA = [
      for (var i = 0; i < itemsA.length; i++) keyAt(itemsA[i], i),
    ];
    final keysB = {
      for (var i = 0; i < itemsB.length; i++) keyAt(itemsB[i], i),
    };

    // 1) 除半截回合 bar（tail→h 一次性切换）外全部键保持。
    final partialBarKey = keysA.firstWhere((k) => k.startsWith('turn-tail-'));
    for (final k in keysA) {
      if (k == partialBarKey) continue;
      expect(keysB.contains(k), isTrue, reason: '前插后键漂移：$k');
    }

    // 2) 半截回合的 tail 键虽切换，但尾行号能在 B 中找回（迁移可用）。
    final migrated = migrateAnchorIndexAfterPrepend(partialBarKey, itemsB);
    expect(migrated, greaterThanOrEqualTo(0),
        reason: '尾行迁移必须找回补齐后的同回合条目');
    expect(keyAt(itemsB[migrated], migrated), startsWith('turn-h4'),
        reason: '找回的正是补齐头部的原半截回合');

    // 3) 两窗口键各自无重复（重复=元素复用错乱闪动源）。
    expect(keysA.toSet().length, keysA.length);
    final listB = [
      for (var i = 0; i < itemsB.length; i++) keyAt(itemsB[i], i),
    ];
    expect(listB.toSet().length, listB.length);

    // 4) 有头回合键不受 append 影响（流式追加不改键）。
    final turnKeysBefore = itemsA
        .whereType<TurnBarItem>()
        .map((t) => keyAt(t, 0))
        .toSet();
    final grown = buildChatItems([
      ...windowA.sublist(0, windowA.length - 1),
      {'rowId': 85, 'kind': 'toolCall', 'name': 'Write', 'status': 'complete'},
      windowA.last,
    ]);
    final turnKeysAfter = grown
        .whereType<TurnBarItem>()
        .map((t) => keyAt(t, 0))
        .toSet();
    expect(turnKeysBefore.difference(turnKeysAfter), isEmpty,
        reason: 'append 工作行不得改既有回合键');
  });

  test('无头运行回合：流式追加不改条目键（review-fix #12）', () {
    List<Map<String, dynamic>> rows({required int extra}) => [
      {'rowId': 5, 'kind': 'toolCall', 'name': 'Read', 'status': 'complete'},
      {
        'rowId': 6,
        'kind': 'assistantText',
        'text': '前半',
        'state': 'streaming',
      },
      for (var i = 0; i < extra; i++)
        {
          'rowId': 7 + i,
          'kind': 'reasoning',
          'text': '思考',
          'state': 'streaming',
        },
    ];
    final before = buildChatItems(
      rows(extra: 0),
    ).whereType<TurnBarItem>().single;
    final after = buildChatItems(
      rows(extra: 2),
    ).whereType<TurnBarItem>().single;
    expect(before.work.header, isNull);
    expect(chatItemKey(before, 0), '早前批次');
    expect(
      chatItemKey(after, 0),
      chatItemKey(before, 0),
      reason: '无头运行回合 append 流式行不得换键（整回合重挂/折叠态丢失根因）',
    );
  });

  test('官方 turnHeader/assistantText 终态枚举：中断/失败档语义（#19）', () {
    final interrupted = buildChatItems([
      {'rowId': 1, 'kind': 'turnHeader', 'state': 'completedInterrupted'},
      {'rowId': 2, 'kind': 'toolCall', 'toolName': 'Read', 'status': 'success'},
    ]).whereType<TurnBarItem>().single.work;
    expect(workBarLabel(interrupted), '已停止');
    expect(interrupted.completedOk, isFalse);

    final failed = buildChatItems([
      {'rowId': 1, 'kind': 'turnHeader', 'state': 'failed'},
      {
        'rowId': 2,
        'kind': 'assistantText',
        'state': 'interrupted',
        'text': '断',
      },
    ]).whereType<TurnBarItem>().single.work;
    expect(workBarLabel(failed), '失败');
    expect(failed.completedOk, isFalse);
    expect(
      failed.visibleTextRow,
      isNotNull,
      reason: '官方 assistantText 枚举含 interrupted——仍作为可见正文',
    );
  });

  test('guided 多段回合键唯一（早前批次 A3：共享 header rowId 不得碰撞）', () {
    // 同轮 header（rowId=7）的两个 guided 段，段序 0/1——修复前两段的
    // TurnBarItem 键同为 'turn-h7'（debug 抛 Duplicate keys）。
    final seg0 = TurnBarItem(TurnWork(
      {'rowId': 7, 'kind': 'turnHeader', 'state': 'completedSuccess'},
      segmentIndex: 0,
    ));
    final seg1 = TurnBarItem(TurnWork(
      {'rowId': 7, 'kind': 'turnHeader', 'state': 'completedSuccess'},
      segmentIndex: 1,
    ));
    expect(chatItemKey(seg0, 0), 'turn-h7');
    expect(chatItemKey(seg1, 1), 'turn-h7-seg1');
    expect(chatItemKey(seg0, 0), isNot(chatItemKey(seg1, 1)));

    // 段序不随前插漂移：同段键在两窗口保持。
    final plain = TurnBarItem(TurnWork(
      {'rowId': 7, 'kind': 'turnHeader', 'state': 'completedSuccess'},
      segmentIndex: 0,
    ));
    expect(chatItemKey(plain, 0), 'turn-h7',
        reason: '单段/首段键与既有格式保持（锚迁移语义不变）');
  });

  test('零距离程序化滚动不登记豁免（#14 低修）', () {
    expect(shouldMarkProgrammaticScroll(10, 10), isFalse,
        reason: 'jumpTo 目标==当前偏移不产生 ScrollEnd——预登记=泄漏一次豁免');
    expect(shouldMarkProgrammaticScroll(10, 11), isTrue);
  });

  testWidgets('拖拽进行中前插历史：视口内容不跳变', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var ids = List<int>.generate(40, (i) => i + 20);
    late StateSetter hostSetState;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) {
            hostSetState = setState;
            return AnchoredChatList(
              controller: ScrollController(),
              centerIndex: ids.indexOf(59),
              itemCount: ids.length,
              itemBuilder: (context, idx) {
                final id = ids[idx];
                return Container(
                  key: ValueKey('item-$id'),
                  height: [40.0, 120.0, 300.0][id % 3],
                  alignment: Alignment.center,
                  child: Text(
                    'item-$id',
                    style: const TextStyle(fontSize: 12),
                  ),
                );
              },
            );
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();

    List<String> visible() => tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => '${t.data}')
        .where((t) => t.startsWith('item-'))
        .toList();

    // 手势中段：按下并连续上滑（不抬指、不 settle）。
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(AnchoredChatList)),
    );
    await gesture.moveBy(const Offset(0, 200));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 200));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 300));
    await tester.pump();

    final visibleBefore = visible();
    expect(visibleBefore, isNotEmpty);

    // 网络返回：前插 20 条落在手势进行中（逻辑 id 不变，index 后移）。
    hostSetState(() {
      ids = List<int>.generate(60, (i) => i);
    });
    await tester.pump();

    final visibleAfter = visible().toSet();
    final kept = visibleBefore.where(visibleAfter.contains).toList();
    // ignore: avoid_print
    print('[probe-drag] before=${visibleBefore.length} kept=$kept');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(kept, isNotEmpty,
        reason: '手势中前插不得清空原视口内容——真机"突然跳转"复现靶');
  });
}

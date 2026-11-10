import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/ui/conversation_view_store.dart';

void main() {
  setUp(ConversationViewStore.resetToolFoldMemory);

  test('工具折叠按会话隔离，匿名草稿共用既有匿名桶', () {
    final store = ConversationViewStore();
    final a = store.toolOpenFor('session-a');
    final b = store.toolOpenFor('session-b');
    a[1] = true;
    b[1] = false;
    expect(store.toolOpenFor('session-a')[1], isTrue);
    expect(store.toolOpenFor('session-b')[1], isFalse);
    store.toolOpenFor(null)[2] = true;
    expect(store.toolOpenFor(null)[2], isTrue);
    expect(a.containsKey(2), isFalse);
  });

  test('容量裁剪只驱逐其他会话，保留当前会话状态', () {
    final store = ConversationViewStore();
    for (var i = 0; i < 101; i++) {
      store.toolOpenFor('session-$i')[i] = true;
    }
    final current = store.toolOpenFor('session-current');
    current[999] = true;
    expect(current[999], isTrue);
    expect(store.toolOpenFor('session-current'), same(current));
    expect(store.toolOpenFor('session-0'), isNot(contains(0)));
  });

  test('reasoning 首见取 createdAt，终态定格一次且不被后续覆盖', () {
    var now = DateTime.fromMillisecondsSinceEpoch(5000);
    final store = ConversationViewStore(now: () => now);
    final streaming = {
      'rowId': 1,
      'kind': 'reasoning',
      'state': 'streaming',
      'createdAt': 1000,
    };
    expect(
      store.firstSeenOf(streaming),
      DateTime.fromMillisecondsSinceEpoch(1000),
    );
    final complete = {...streaming, 'state': 'complete'};
    store.captureReasoningElapsed([complete]);
    expect(store.reasoningElapsedOf(complete), 4000);

    now = DateTime.fromMillisecondsSinceEpoch(9000);
    store.captureReasoningElapsed([complete]);
    expect(store.reasoningElapsedOf(complete), 4000);
    expect(store.firstSeenOf(complete), DateTime.fromMillisecondsSinceEpoch(1000));
  });

  test('reasoning 无 createdAt 时退当前时刻；文件卡/已见行/live collapse 可读写', () {
    final now = DateTime.fromMillisecondsSinceEpoch(7000);
    final store = ConversationViewStore(now: () => now);
    final row = {'rowId': 2, 'kind': 'reasoning', 'state': 'streaming'};
    expect(store.firstSeenOf(row), now);
    store.fileCardOpen[3] = true;
    store.fileCardItems[3] = [
      {'path': 'a.dart'},
    ];
    store.liveCollapsedByRow[4] = true;
    store.seenRowKeys.add('row-5');
    expect(store.fileCardOpen[3], isTrue);
    expect(store.fileCardItems[3]?.single['path'], 'a.dart');
    expect(store.liveCollapsedByRow[4], isTrue);
    expect(store.seenRowKeys, contains('row-5'));
  });
}

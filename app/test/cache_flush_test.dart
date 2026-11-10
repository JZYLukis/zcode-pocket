import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/cache_policy.dart';
import 'package:zcode_pocket/state/local_cache.dart';
import 'package:zcode_pocket/transport/conversation.dart';

Map<String, dynamic> _row(int id, String text) => {
      'rowId': id,
      'kind': 'assistantText',
      'text': text,
    };

ConversationState _consistentState(List<Map<String, dynamic>> rows) =>
    ConversationState()
      ..ready = true
      ..logEpoch = 'e1'
      ..rows = rows;

/// writeSession 带闸门的 store（在途写窗口可控）。
class _GatedStore extends LocalCacheStore {
  _GatedStore(super.baseDir);
  Completer<void>? gate;

  @override
  Future<void> writeSession(SessionCacheEntry entry) async {
    final g = gate;
    if (g != null) await g.future;
    await super.writeSession(entry);
  }
}

void main() {
  test('B2 在途写期间到达的更新快照必须补写（原静默跳过落旧值）', () async {
    final dir = await Directory.systemTemp.createTemp('cache-b2');
    addTearDown(() => dir.delete(recursive: true));
    final store = _GatedStore(dir);
    final gate = Completer<void>();
    store.gate = gate;

    final state = _consistentState([_row(1, 'a'), _row(2, 'b')]);
    final writer = SessionCacheWriter(
      store: store,
      deviceSid: 'd1',
      sessionId: 's1',
      onLog: (_) {},
    );
    writer.attach(state); // attach 起 3s debounce timer——测试直接走 flush
    try {
      final first = writer.flush(); // 第一次写：卡在闸门
      await Future<void>.delayed(Duration.zero);
      // 在途期间状态前进（新行到达，一致水位仍满足）
      state.rows = [_row(1, 'a'), _row(2, 'b'), _row(3, 'c')];
      state.seq = 5;
      state.dataVersion++;
      state.notifyListeners();
      final second = writer.flush(); // 旧实现：_writing=true → 静默跳过
      gate.complete();
      await first;
      await second;
      // 补写在 finally 里 unawaited 启动——轮询等它落盘。
      SessionCacheEntry? entry;
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        entry = await store.readSession('d1', 's1');
        if (entry != null && entry.rows.length == 3) break;
      }
      expect(entry, isNotNull, reason: '缓存条目未落盘');
      expect(entry!.rows.length, 3, reason: '在途写后的新快照被静默丢弃（B2）');
      expect(entry.lastSeq, 5);
    } finally {
      writer.detach();
    }
  });

  test('B2 基线语义保留：不一致水位（流式中）flush 仍跳过', () async {
    final dir = await Directory.systemTemp.createTemp('cache-b2b');
    addTearDown(() => dir.delete(recursive: true));
    final store = LocalCacheStore(dir);
    final state = _consistentState([_row(1, 'a')]);
    state.rows = [
      {..._row(2, 'x'), 'state': 'streaming'},
    ]; // 流式中=中间态
    final writer = SessionCacheWriter(
      store: store,
      deviceSid: 'd1',
      sessionId: 's2',
      onLog: (_) {},
    );
    writer.attach(state);
    try {
      await writer.flush();
      final entry = await store.readSession('d1', 's2');
      expect(entry, isNull, reason: '流式中间态不得落盘（设计语义）');
    } finally {
      writer.detach();
    }
  });
}

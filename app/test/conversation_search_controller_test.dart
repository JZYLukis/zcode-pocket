import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/ui/conversation_search.dart';
import 'package:zcode_pocket/ui/turn_model.dart';

class _Harness {
  _Harness({List<Map<String, dynamic>>? rows, this.loader}) {
    state = ConversationState()
      ..rows = rows ?? [_row(1, 'needle'), _row(2, 'needle'), _row(3, 'needle')]
      ..firstRowId = rows?.first['rowId'] as int? ?? 1
      ..totalCount = rows?.length ?? 3;
    controller = ConversationSearchController(
      stateProvider: () => state,
      itemsProvider: (s) => buildChatItems(s.rows),
      loadOlder: _loadOlder,
      isAlive: () => alive,
      onNotify: () => notifications++,
      onLocate: (match) async => located.add(match),
      onAnchorMigrate: (previous, current) => migrations.add((previous, current)),
    );
  }

  late final ConversationState state;
  late final ConversationSearchController controller;
  final Future<bool> Function()? loader;
  final located = <ConversationSearchMatch>[];
  final migrations = <(String, String)>[];
  bool alive = true;
  int notifications = 0;
  int loadCalls = 0;

  Future<bool> _loadOlder() async {
    loadCalls++;
    if (loader != null) return loader!();
    state.prependOlderRows([_row(0, 'older needle')], 0, hasMore: false);
    return true;
  }

  void dispose() {
    alive = false;
    controller.dispose();
  }
}

Map<String, dynamic> _row(int id, String text) => {
  'rowId': id,
  'kind': 'userInput',
  'text': text,
};

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待搜索状态超时');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('打开/关闭返回当前命中并清空状态，上一处下一处循环', () {
    final h = _Harness();
    h.controller.controller.text = 'needle';
    h.controller.open();
    expect(h.controller.isOpen, isTrue);
    expect(h.controller.matches, hasLength(3));
    expect(h.controller.activeIndex, 0);
    h.controller.step(1);
    expect(h.controller.activeIndex, 1);
    h.controller.step(-1);
    h.controller.step(-1);
    expect(h.controller.activeIndex, 2);

    final result = h.controller.close();
    expect(result.activeMatch?.rowId, 3);
    expect(h.controller.isOpen, isFalse);
    expect(h.controller.matches, isEmpty);
    expect(h.controller.activeIndex, -1);
    expect(h.controller.query, isEmpty);
    h.dispose();
  });

  test('历史补拉刷新匹配并触发定位，重锚保持 identity', () async {
    final h = _Harness(rows: [_row(2, 'needle')]);
    h.state.firstRowId = 1;
    h.state.totalCount = 3;
    h.controller.isOpen = true;
    h.controller.controller.text = 'needle';
    await h.controller.pumpHistory();
    expect(h.loadCalls, 1);
    expect(h.controller.matches.map((m) => m.rowId), contains(0));
    expect(h.located, isNotEmpty);

    final identity = h.controller.activeMatch?.identity;
    h.controller.refresh();
    expect(h.controller.activeMatch?.identity, identity);
    h.dispose();
  });

  test('达到行数上限标记截断，不再补拉', () async {
    final rows = List.generate(1200, (i) => _row(i + 1, 'needle'));
    final h = _Harness(rows: rows);
    h.state.firstRowId = 0;
    h.state.totalCount = 1400;
    h.controller.isOpen = true;
    h.controller.controller.text = 'needle';
    h.controller.refresh();
    await h.controller.pumpHistory();
    expect(h.controller.truncated, isTrue);
    expect(h.loadCalls, 0);
    h.dispose();
  });

  test('无进展且仍有历史标记 stalled；运行中给仅已加载提示', () async {
    final h = _Harness(loader: () async => false);
    h.state.firstRowId = 0;
    h.state.totalCount = 10;
    h.controller.isOpen = true;
    h.controller.controller.text = 'needle';
    await h.controller.pumpHistory();
    expect(h.controller.stalled, isTrue);
    expect(h.controller.partialNotice, contains('已加载范围'));

    h.state.snapshot = {
      'control': {'phase': 'running'},
    };
    expect(h.controller.partialNotice, contains('运行结束后自动补查'));
    h.dispose();
  });

  test('历史错误可重试，成功后清错误并恢复匹配', () async {
    var calls = 0;
    final h = _Harness(
      loader: () async {
        calls++;
        if (calls == 1) throw StateError('offline');
        return false;
      },
    );
    h.state.firstRowId = 0;
    h.state.totalCount = 10;
    h.controller.isOpen = true;
    h.controller.controller.text = 'needle';
    await h.controller.pumpHistory();
    expect(h.controller.error, contains('offline'));
    h.controller.retry();
    await _until(() => calls == 2 && !h.controller.loading);
    expect(h.controller.error, isNull);
    expect(h.controller.matches, isNotEmpty);
    h.dispose();
  });

  test('旧查询的迟到错误不得污染已清空的新查询', () async {
    final gate = Completer<bool>();
    final h = _Harness(loader: () => gate.future);
    h.state.firstRowId = 0;
    h.state.totalCount = 10;
    h.controller.isOpen = true;
    h.controller.controller.text = 'old';
    final pumping = h.controller.pumpHistory();
    h.controller.controller.clear();
    h.controller.change('');
    gate.completeError(StateError('old failure'));
    await pumping;
    await _until(() => h.controller.error == null);
    expect(h.controller.query, isEmpty);
    expect(h.controller.error, isNull);
    h.dispose();
  });

  test('dispose 后不再打开或重试', () async {
    final h = _Harness();
    h.dispose();
    h.controller.open();
    h.controller.retry();
    expect(h.controller.isOpen, isFalse);
    expect(h.loadCalls, 0);
  });
}

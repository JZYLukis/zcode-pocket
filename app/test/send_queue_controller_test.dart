import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/send_queue_controller.dart';
import 'package:zcode_pocket/state/send_queue_store.dart';
import 'package:zcode_pocket/transport/companion_client.dart';

class _MemoryStore extends SendQueueStore {
  _MemoryStore() : super(File('nul'));
  final data = <String, List<SendQueueEntry>>{};

  // 红绿：记录"钉 ID 后尚未 flush"状态——
  // replay 发起前必须已落盘（flush 清零），否则崩溃窗内重启换新 ID
  // 重放=同消息双发。
  int flushes = 0;
  bool pinPendingFlush = false;

  @override
  Future<void> add(SendQueueBucket bucket, SendQueueEntry entry) async {
    data.putIfAbsent(bucket.key, () => []).add(entry);
  }

  @override
  Future<List<SendQueueEntry>> entries(SendQueueBucket bucket) async =>
      List.of(data[bucket.key] ?? const []);

  @override
  Future<void> remove(SendQueueBucket bucket, String id) async {
    data[bucket.key]?.removeWhere((e) => e.id == id);
  }

  @override
  Future<void> flush() async {
    flushes++;
    pinPendingFlush = false;
  }

  @override
  Future<void> setCommandId(
    SendQueueBucket bucket,
    String id,
    String commandId,
  ) async {
    final list = data[bucket.key];
    if (list == null) return;
    final index = list.indexWhere((e) => e.id == id);
    if (index < 0) return;
    final old = list[index];
    list[index] = SendQueueEntry(
      id: old.id,
      text: old.text,
      config: old.config,
      queuedAt: old.queuedAt,
      commandId: commandId,
    );
    pinPendingFlush = true;
  }
}

class _Bridge implements BridgeSession {
  @override
  final ValueNotifier<String?> degraded = ValueNotifier(null);
  @override
  final ValueNotifier<int> recovered = ValueNotifier(0);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _App extends AppState {
  _App(this.queueStore) {
    sendQueue = queueStore;
  }
  final SendQueueStore queueStore;
  LinkPhase currentPhase = LinkPhase.online;
  final BridgeSession currentBridge = _Bridge();
  @override
  LinkPhase get phase => currentPhase;
  @override
  BridgeSession? get bridge => currentBridge;
}

const _bucket = SendQueueBucket(
  deviceSid: 'device',
  accountId: 'account',
  workspaceKey: 'workspace',
  scopeId: 'session:s1',
);

SendQueueEntry _entry(String id, {String? commandId}) =>
    SendQueueEntry(id: id, text: 'text-$id', queuedAt: 1, commandId: commandId);

class _Harness {
  // 对抗审查 M3（双盲乙）：默认 20ms 真时钟档在全量负载下与断言赛跑
  // （乙实测 5 轮全量红 1 次）。默认拉长到不可能触发的档位，重试路径
  // 由测试显式 drain() 驱动；真实 15s 定时器接线由页面级
  // send_queue_test「15s 兜底重试」用例覆盖。
  _Harness({Duration retryDelay = const Duration(seconds: 30)}) {
    app = _App(store);
    host = OfflineQueueHost(
      bucketProvider: () => bucketReady ? _bucket : null,
      isAlive: () => alive,
      readOnly: () => readOnly,
      sending: () => sending,
      replay: _replay,
      onNotify: () => notifications++,
      scheduleDrain: (action) => action(),
    );
    controller = OfflineSendQueueController(
      host: host,
      retryDelay: retryDelay,
      interEntryDelay: Duration.zero,
    );
  }

  final store = _MemoryStore();
  late final _App app;
  late final OfflineQueueHost host;
  late final OfflineSendQueueController controller;
  final sent = <String>[];
  final commandIds = <String?>[];
  bool alive = true;
  bool readOnly = false;
  bool sending = false;
  bool failNext = false;

  /// 页面 _draftIdentity 在 draftRestore 内部
  /// 异步就绪——arm 的同步 refresh 读 bucket 为 null（false=模拟未就绪）。
  bool bucketReady = true;

  /// 单条 replay 抛意外异常（页面退页后收尾异常等）。
  bool throwNext = false;
  bool expectFlushedBeforeReplay = false;
  int notifications = 0;

  Future<bool> _replay(SendQueueEntry entry) async {
    if (throwNext) {
      throwNext = false;
      throw StateError('replay exploded');
    }
    if (failNext) {
      failNext = false;
      return false;
    }
    if (expectFlushedBeforeReplay) {
      expect(
        store.pinPendingFlush,
        isFalse,
        reason: 'replay 发起前钉住的 commandId 必须已 flush 落盘'
            '（只改内存不等盘尾=崩溃窗内重启换新 ID 重放，双发红线）',
      );
    }
    sent.add(entry.text);
    commandIds.add(entry.commandId);
    return true;
  }

  void dispose() {
    alive = false;
    controller.dispose();
  }
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待队列状态超时');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  test('顺序发送、失败即停、commandId 持久化并复用；重试路径显式驱动', () async {
    final h = _Harness();
    await h.store.add(_bucket, _entry('m1'));
    await h.store.add(_bucket, _entry('m2'));
    h.failNext = true;
    h.controller.arm(h.app);
    await _until(
      () =>
          h.store.data[_bucket.key]?.first.commandId != null &&
          !h.controller.draining,
    );
    expect(h.sent, isEmpty, reason: '首条失败即停，第二条不得连发');
    final firstId = h.store.data[_bucket.key]!.first.commandId;
    expect(firstId, isNotNull);

    // 重试路径显式驱动（不再与定时器赛跑）：同一 commandId 按序补发。
    await h.controller.drain();
    expect(h.sent, ['text-m1', 'text-m2']);
    expect(h.commandIds.first, firstId, reason: '重试沿用首次 commandId');
    expect(h.controller.entries, isEmpty);
    h.dispose();
  });

  test('离线不 drain；online 边沿自动补发', () async {
    final h = _Harness();
    h.app.currentPhase = LinkPhase.reconnecting;
    await h.store.add(_bucket, _entry('offline'));
    h.controller.arm(h.app);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(h.sent, isEmpty);

    h.app.currentPhase = LinkPhase.online;
    h.app.notifyListeners();
    await _until(() => h.sent.isNotEmpty);
    expect(h.sent, ['text-offline']);
    h.dispose();
  });

  test('canReplay=false（发送占用/只读）不发送，解除后可 drain', () async {
    final h = _Harness();
    h.sending = true;
    await h.store.add(_bucket, _entry('busy'));
    h.controller.arm(h.app);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(h.sent, isEmpty);
    h.sending = false;
    await h.controller.drain();
    expect(h.sent, ['text-busy']);

    final readOnly = _Harness();
    readOnly.readOnly = true;
    await readOnly.store.add(_bucket, _entry('readonly'));
    readOnly.controller.arm(readOnly.app);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(readOnly.sent, isEmpty);
    h.dispose();
    readOnly.dispose();
  });

  test('dispose 后不再重试，也不再响应 online 边沿', () async {
    final h = _Harness();
    h.failNext = true;
    await h.store.add(_bucket, _entry('failure'));
    h.controller.arm(h.app);
    await _until(() => h.controller.entries.isNotEmpty);
    h.dispose();
    h.app.currentPhase = LinkPhase.reconnecting;
    h.app.currentPhase = LinkPhase.online;
    h.app.notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(h.sent, isEmpty);
  });

  test('逐条撤销与展开状态由 Controller 单源维护', () async {
    final h = _Harness();
    h.sending = true;
    await h.store.add(_bucket, _entry('cancel'));
    h.controller.arm(h.app);
    await _until(() => h.controller.entries.isNotEmpty);
    h.controller.toggleExpanded();
    expect(h.controller.expanded, isTrue);
    await h.controller.cancel(h.controller.entries.single);
    expect(h.controller.entries, isEmpty);
    h.dispose();
  });

  // （离线开页死锁）：bucketProvider 依赖页面
  // _draftIdentity——它在 draftRestore 内部异步就绪，arm 的同步 refresh
  // 必然空跑；老实现 draftRestore 完成后只调 drain，离线早退不 refresh，
  // 已持久化的排队消息既不显示（排队条隐身）也永不补发（online 边沿以
  // 内存 entries.isNotEmpty 为门恒 false）。
  test('离线开页 identity 晚就绪：恢复完成后装载（排队条可见），online 边沿补发', () async {
    final h = _Harness();
    h.app.currentPhase = LinkPhase.reconnecting;
    h.bucketReady = false;
    await h.store.add(_bucket, _entry('ghost'));
    final restore = Completer<void>();
    h.controller.arm(h.app, draftRestore: restore.future);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    // 复现死端起点：arm 同步 refresh 读不到 bucket（identity 未就绪）。
    expect(h.controller.entries, isEmpty);

    // 恢复完成：identity 就绪 → 装载（离线也显示，排队条可见可撤销），
    // drain 离线早退不发送。
    h.bucketReady = true;
    restore.complete();
    await _until(() => h.controller.entries.isNotEmpty);
    expect(h.sent, isEmpty, reason: '离线不补发');

    // online 边沿：老实现内存 entries 门在此场景恒 false=永久隐身；
    // 新实现先查 store 重载再判 drain。
    h.app.currentPhase = LinkPhase.online;
    h.app.notifyListeners();
    await _until(() => h.sent.isNotEmpty);
    expect(h.sent, ['text-ghost']);
    h.dispose();
  });

  test('bucket 晚就绪时 drain 离线早退也装载 entries（排队条可见）', () async {
    final h = _Harness();
    h.app.currentPhase = LinkPhase.reconnecting;
    h.bucketReady = false;
    await h.store.add(_bucket, _entry('visible'));
    h.controller.arm(h.app);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(h.controller.entries, isEmpty);
    h.bucketReady = true;
    await h.controller.drain();
    expect(h.controller.entries, isNotEmpty,
        reason: '离线早退前装载——已排队消息必须可见/可撤销');
    expect(h.sent, isEmpty);
    h.dispose();
  });

  // 重放收尾异常（页面退页 setState-after-dispose 等）
  // 曾外泄为 zone 未处理错误并跳过 store.remove——条目留存再次重放=
  // 重复建会话。单条异常按失败同语义处理（不外泄、条目留存、
  // commandId 幂等保护下重试）。
  test('单条 replay 意外异常不外泄：条目留存按失败重试', () async {
    final h = _Harness();
    h.throwNext = true;
    await h.store.add(_bucket, _entry('boom'));
    h.controller.arm(h.app);
    await _until(() => !h.controller.draining);
    expect(h.controller.entries, isNotEmpty,
        reason: '结果未知的条目保留（不 remove）');
    await h.controller.drain();
    expect(h.sent, ['text-boom']);
    expect(h.controller.entries, isEmpty);
    h.dispose();
  });

  // （双发红线）：setCommandId 只等内存不等盘尾
  // 即发起 replay——进程在「服务端已接受该 commandId」后、落盘 rename
  // 完成前被杀，重启后磁盘条目无 commandId，drain 分配新 UUID 重放=
  // 同消息双发，击穿 「永不自动重发已尝试发送」。
  test('钉 commandId 后、replay 前必须 await store.flush()（先落盘后发送）', () async {
    final h = _Harness();
    h.sending = true; // 压住 arm 的自动 drain，由本用例显式驱动
    await h.store.add(_bucket, _entry('pin-me'));
    h.controller.arm(h.app);
    await _until(() => h.controller.entries.isNotEmpty);
    h.sending = false;
    h.expectFlushedBeforeReplay = true;
    await h.controller.drain();
    h.expectFlushedBeforeReplay = false;
    expect(h.sent, ['text-pin-me']);
    expect(h.store.flushes, greaterThanOrEqualTo(1),
        reason: '钉 ID 后必须至少 flush 一次再发起发送');
    h.dispose();
  });
}

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/cache_policy.dart';
import 'package:zcode_pocket/state/conversation_registry.dart';
import 'package:zcode_pocket/state/local_cache.dart';
import 'package:zcode_pocket/state/session_errors.dart';
import 'package:zcode_pocket/transport/conversation.dart';

class _ControlledConversation implements ConversationTransport {
  final gates = <Completer<ConversationSubscription>>[];
  final seeds = <ConversationSeed?>[];
  int parkCalls = 0;
  int resumeCalls = 0;
  int resumeTrueCalls = 0;

  /// 模拟协议层驻留态：park 落地前 resume 返回 false（
  /// 的静默 no-op 病灶形态）。
  bool parked = false;

  @override
  Future<ConversationSubscription> subscribe(
    String sessionId, {
    ConversationSeed? seed,
  }) {
    seeds.add(seed);
    final gate = Completer<ConversationSubscription>();
    gates.add(gate);
    return gate.future;
  }

  @override
  Future<void> parkConversationSubscriptionsForBackground() async {
    parkCalls++;
    parked = true;
  }

  @override
  Future<bool> resumeParkedConversation(String sessionId) async {
    resumeCalls++;
    if (!parked) return false;
    resumeTrueCalls++;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestState extends ConversationState {
  bool get hasAnyListeners => hasListeners;
}

/// writeSession 可闸门的存储（制造 demote flush 的确定性 await 窗口）。
class _GatedWriteStore extends LocalCacheStore {
  _GatedWriteStore(super.baseDir);
  Completer<void>? writeGate;

  @override
  Future<void> writeSession(SessionCacheEntry entry) async {
    final gate = writeGate;
    if (gate != null) await gate.future;
    await super.writeSession(entry);
  }
}

class _Sub implements ConversationSubscription {
  _Sub(this.sessionId);
  @override
  final String sessionId;
  @override
  final _TestState state = _TestState();
  int disposeCalls = 0;
  bool _disposed = false;

  @override
  bool get hasLiveFrames => true;
  @override
  bool get isDisposed => _disposed;
  @override
  String? get subscriptionId => 'sub-$sessionId';
  @override
  String get topic => 'conversation/$sessionId';
  @override
  Future<void> dispose() async {
    disposeCalls++;
    _disposed = true;
  }
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待订阅调用超时');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  late _ControlledConversation current;
  late ConversationRegistry registry;

  setUp(() {
    current = _ControlledConversation();
    registry = ConversationRegistry(
      cache: null,
      deviceSid: () => 'sid-registry',
      transportProvider: () => current,
      siDormantProvider: () => false,
      retrySessionsIndex: () async {},
      disposedProvider: () => false,
      onLog: (_) {},
    );
  });

  test('demote/close 在飞竞态：迟到订阅 dispose 且不回注册', () async {
    final pending = registry.ensureConversation('s-demote');
    await _until(() => current.gates.isNotEmpty);
    await registry.demote();
    final sub = _Sub('s-demote');
    current.gates.single.complete(sub);
    // 对抗审查 ：迟到订阅必须以错误收场，不得静默返回死订阅。
    await expectLater(pending, throwsStateError);
    expect(registry.subscriptionOf('s-demote'), isNull);
    expect(sub.disposeCalls, 1);

    final closing = registry.ensureConversation('s-close');
    await _until(() => current.gates.length == 2);
    await registry.close();
    final late = _Sub('s-close');
    current.gates[1].complete(late);
    await expectLater(closing, throwsStateError);
    expect(registry.conversationStates, isEmpty);
    expect(late.disposeCalls, 1);
  });

  test('transport 身份变化即使未显式 demote 也拒绝旧订阅回注册', () async {
    final initial = current;
    final pending = registry.ensureConversation('s-transport');
    await _until(() => initial.gates.isNotEmpty);
    current = _ControlledConversation();
    final sub = _Sub('s-transport');
    initial.gates.single.complete(sub);
    await expectLater(pending, throwsStateError);

    expect(registry.conversationStates, isEmpty);
    expect(sub.disposeCalls, 1);
    expect(current.gates, isEmpty);
  });

  test('旧 pending 完成不删除新代际 pending', () async {
    final first = registry.ensureConversation('s-pending');
    await _until(() => current.gates.length == 1);
    await registry.demote();
    final second = registry.ensureConversation('s-pending');
    await _until(() => current.gates.length == 2);
    current.gates[0].complete(_Sub('s-pending'));
    await expectLater(first, throwsStateError);
    final third = registry.ensureConversation('s-pending');
    await Future<void>.delayed(Duration.zero);
    expect(current.gates, hasLength(2));
    final sub = _Sub('s-pending');
    current.gates[1].complete(sub);
    expect(await second, same(sub));
    expect(await third, same(sub));
  });

  test('writer 生命周期与 park/resume 保持，dispose 使在飞订阅失效', () async {
    final dir = await Directory.systemTemp.createTemp('conversation-registry');
    addTearDown(() => dir.delete(recursive: true));
    registry = ConversationRegistry(
      cache: LocalCacheStore(dir),
      deviceSid: () => 'sid-registry',
      transportProvider: () => current,
      siDormantProvider: () => false,
      retrySessionsIndex: () async {},
      disposedProvider: () => false,
      onLog: (_) {},
    );
    final pending = registry.ensureConversation('s-writer');
    await _until(() => current.gates.isNotEmpty);
    final sub = _Sub('s-writer');
    current.gates.single.complete(sub);
    await pending;
    expect(sub.state.hasAnyListeners, isTrue);
    await registry.suspendForBackground();
    expect(current.parkCalls, 1);
    expect(await registry.ensureConversation('s-writer'), same(sub));
    expect(current.resumeCalls, 1);
    await registry.demote();
    expect(sub.state.hasAnyListeners, isFalse);

    final latePending = registry.ensureConversation('s-dispose');
    await _until(() => current.gates.length == 2);
    registry.dispose();
    final late = _Sub('s-dispose');
    current.gates[1].complete(late);
    await expectLater(latePending, throwsStateError);
    expect(late.disposeCalls, 1);
    expect(registry.conversationStates, isEmpty);
  });

  test('demote 的 flush 窗口内新发起的注册不残留（对抗审查 M2）', () async {
    final dir = await Directory.systemTemp.createTemp('conversation-registry-window');
    addTearDown(() => dir.delete(recursive: true));
    final store = _GatedWriteStore(dir);
    registry = ConversationRegistry(
      cache: store,
      deviceSid: () => 'sid-registry',
      transportProvider: () => current,
      siDormantProvider: () => false,
      retrySessionsIndex: () async {},
      disposedProvider: () => false,
      onLog: (_) {},
    );
    // 先落一个带一致水位的活订阅（demote 时 writer.flush 会进
    // store.writeSession 的闸门=制造确定性 await 窗口）。
    final seeded = registry.ensureConversation('s-a');
    await _until(() => current.gates.isNotEmpty);
    final live = _Sub('s-a');
    live.state
      ..ready = true
      ..logEpoch = 'e1'
      ..rows = [
        {'rowId': 1, 'kind': 'assistantText', 'text': 'a'},
      ];
    current.gates.single.complete(live);
    await seeded;

    store.writeGate = Completer<void>();
    final demoting = registry.demote();
    // 给 demote 进入 flush 闸门一拍（微任务链落定）。
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    // 窗口内（三轮审查）：demote 还卡在 flush，此时新发起的注册
    // 捕获的是已递增的 epoch——旧两段失效修法下它会"先落地交付、再被
    // 收尾悄悄 dispose"（页面拿到死订阅哑弹）。_closing 同步闸门让它在
    // 预检即抛错（连注定作废的 subscribe 都不发），交给包装层重试。
    final windowPending = registry.ensureConversation('s-window');
    await expectLater(windowPending, throwsStateError,
        reason: '窗口内注册必须以错误收场，不得交付即将被收尾 dispose 的订阅');
    expect(current.gates.length, 1,
        reason: '清场窗口内不得再发注定作废的 subscribe');

    store.writeGate!.complete();
    await demoting;

    expect(registry.conversationStates, isEmpty,
        reason: 'demote 收尾后注册表必须干净');
    expect(live.disposeCalls, 1);
  });

  test('quiesce 等待进行中的 demote 落地；无清场时立即返回', () async {
    // 无清场在飞：立即完成。
    var quiesceDone = false;
    unawaited(registry.quiesce().then((_) => quiesceDone = true));
    await Future<void>.delayed(Duration.zero);
    expect(quiesceDone, isTrue);

    // 先落一个带一致水位的活订阅（demote 时 writer.flush 进写盘闸门=
    // 制造可观测的清场窗口）。
    final dir = await Directory.systemTemp.createTemp('conversation-registry-quiesce');
    addTearDown(() => dir.delete(recursive: true));
    final store = _GatedWriteStore(dir);
    registry = ConversationRegistry(
      cache: store,
      deviceSid: () => 'sid-registry',
      transportProvider: () => current,
      siDormantProvider: () => false,
      retrySessionsIndex: () async {},
      disposedProvider: () => false,
      onLog: (_) {},
    );
    final seeded = registry.ensureConversation('s-q');
    await _until(() => current.gates.isNotEmpty);
    final live = _Sub('s-q');
    live.state
      ..ready = true
      ..logEpoch = 'e1'
      ..rows = [
        {'rowId': 1, 'kind': 'assistantText', 'text': 'q'},
      ];
    current.gates.single.complete(live);
    await seeded;

    store.writeGate = Completer<void>();
    final demoting = registry.demote();
    await Future<void>.delayed(Duration.zero);
    quiesceDone = false;
    unawaited(registry.quiesce().then((_) => quiesceDone = true));
    for (var i = 0; i < 5 && !quiesceDone; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(quiesceDone, isFalse, reason: 'demote 未落地时 quiesce 不得返回');
    store.writeGate!.complete();
    await demoting;
    await registry.quiesce();
    expect(quiesceDone, isTrue);
  });

  test('flush 窗口内回前台的 ensure：pending resume 在 park 落地后自动重放（开源审查 G2 P2-6/G3 P2-2）', () async {
    final dir = await Directory.systemTemp.createTemp('registry-park-window');
    addTearDown(() => dir.delete(recursive: true));
    final store = _GatedWriteStore(dir);
    registry = ConversationRegistry(
      cache: store,
      deviceSid: () => 'sid-registry',
      transportProvider: () => current,
      siDormantProvider: () => false,
      retrySessionsIndex: () async {},
      disposedProvider: () => false,
      onLog: (_) {},
    );
    // 活订阅 s-a（suspend 时 writer.flush 进写盘闸门=确定性窗口）。
    final seeded = registry.ensureConversation('s-a');
    await _until(() => current.gates.isNotEmpty);
    final live = _Sub('s-a');
    live.state
      ..ready = true
      ..logEpoch = 'e1'
      ..rows = [
        {'rowId': 1, 'kind': 'assistantText', 'text': 'a'},
      ];
    current.gates.single.complete(live);
    await seeded;

    store.writeGate = Completer<void>();
    final suspending = registry.suspendForBackground();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    // flush 窗口内（快切回前台）：onAppResumed 对 viewing 会话 ensure——
    // 旧实现驻留集合未登记，静默返回；随后 suspend 继续 park 它=帧永久
    // 冻结且无恢复触发。
    final ensured = await registry.ensureConversation('s-a');
    expect(ensured, same(live));
    expect(current.resumeCalls, 1,
        reason: '窗口内 ensure 命中先行登记的驻留集合，触发过一次 resume');

    store.writeGate!.complete();
    await suspending;
    expect(current.parkCalls, 1);
    // 红：旧实现 resume 的 false 被吞且集合已摘牌——此后无任何恢复触发。
    expect(current.resumeTrueCalls, 1,
        reason: 'park 落地后 pending resume 自动重放，前台会话不冻结');
    // 摘牌发生在成功重放之后：再次 ensure 不再重复 resume。
    await registry.ensureConversation('s-a');
    expect(current.resumeTrueCalls, 1);
    await registry.demote();
  });

  test('flush 窗口内新落地的注册收尾对账补 park（开源审查 I2 P2-1：无后台常驻活订阅）', () async {
    final dir = await Directory.systemTemp.createTemp('registry-park-leak');
    addTearDown(() => dir.delete(recursive: true));
    final store = _GatedWriteStore(dir);
    registry = ConversationRegistry(
      cache: store,
      deviceSid: () => 'sid-registry',
      transportProvider: () => current,
      siDormantProvider: () => false,
      retrySessionsIndex: () async {},
      disposedProvider: () => false,
      onLog: (_) {},
    );
    final seeded = registry.ensureConversation('s-a');
    await _until(() => current.gates.isNotEmpty);
    final live = _Sub('s-a');
    live.state
      ..ready = true
      ..logEpoch = 'e1'
      ..rows = [
        {'rowId': 1, 'kind': 'assistantText', 'text': 'a'},
      ];
    current.gates.single.complete(live);
    await seeded;

    store.writeGate = Completer<void>();
    final suspending = registry.suspendForBackground();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    // flush 窗口内新会话注册完成（退后台前点开、subscribe 慢落地）。
    final newPending = registry.ensureConversation('s-new');
    await _until(() => current.gates.length == 2);
    current.gates[1].complete(_Sub('s-new'));
    await newPending;

    store.writeGate!.complete();
    await suspending;
    // 红：旧实现无收尾对账——漏网订阅保持全速活订阅在后台收帧。
    expect(current.parkCalls, 2, reason: '对账对漏网订阅补一轮 park（幂等）');
    // 补登记后进入页面 ensure 命中驻留集合，惰性恢复可达。
    final before = current.resumeCalls;
    await registry.ensureConversation('s-new');
    expect(current.resumeCalls, before + 1,
        reason: '漏网订阅已入驻留集合，进入页面触发 resume');
    await registry.demote();
  });

  test('会话缓存 seed 原样传入 subscribe', () async {
    final dir = await Directory.systemTemp.createTemp('conversation-registry-seed');
    addTearDown(() => dir.delete(recursive: true));
    final store = LocalCacheStore(dir);
    await store.writeSession(
      SessionCacheEntry(
        deviceSid: 'sid-registry',
        sessionId: 's-seed',
        rows: const [
          {'rowId': 1, 'kind': 'assistantText', 'text': 'cached'},
        ],
        logEpoch: 'epoch-1',
        lastSeq: 7,
        firstRowId: 1,
        totalCount: 1,
        snapshotControl: const {'title': 'cached'},
        savedAt: 1,
        byteSize: 1,
      ),
    );
    registry = ConversationRegistry(
      cache: store,
      deviceSid: () => 'sid-registry',
      transportProvider: () => current,
      siDormantProvider: () => false,
      retrySessionsIndex: () async {},
      disposedProvider: () => false,
      onLog: (_) {},
    );
    final pending = registry.ensureConversation('s-seed');
    await _until(() => current.gates.isNotEmpty);
    expect(current.seeds.single?.logEpoch, 'epoch-1');
    expect(current.seeds.single?.seq, 7);
    expect(current.seeds.single?.rows.single['text'], 'cached');
    current.gates.single.complete(_Sub('s-seed'));
    await pending;
    await registry.demote();
  });

  // 状态层批：demote/close 在飞时快路径此前直接返回旧订阅——调用方拿到
  // 即将被收尾 dispose 的引用（页面挂监听后帧永久停止）。改为抛 erro，
  // 由 ComputerStack 包装层 quiesce 后重试。
  test('demote 在飞时 ensure 已存在会话：抛出交上层重试，清场后重试成功', () async {
    final pending = registry.ensureConversation('s-closing');
    await _until(() => current.gates.isNotEmpty);
    final first = _Sub('s-closing');
    current.gates[0].complete(first);
    await pending;

    final demoting = registry.demote();
    // 红：修复前此处返回 first（随后被 demote 收尾 dispose）。
    await expectLater(
      registry.ensureConversation('s-closing'),
      throwsA(isA<SessionSubscriptionResetError>()),
    );
    await demoting;

    final retryPending = registry.ensureConversation('s-closing');
    await _until(() => current.gates.length == 2);
    final fresh = _Sub('s-closing');
    current.gates[1].complete(fresh);
    expect(await retryPending, same(fresh), reason: '清场后重试拿到活订阅');
  });
}

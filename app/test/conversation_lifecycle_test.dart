import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/computer_stack.dart';
import 'package:zcode_pocket/state/local_cache.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/z_transport.dart';

class _ControlledConversation implements ConversationTransport {
  final subscribeGates = <Completer<ConversationSubscription>>[];
  int parkCalls = 0;
  int resumeCalls = 0;

  @override
  Future<ConversationSubscription> subscribe(
    String sessionId, {
    ConversationSeed? seed,
  }) {
    final gate = Completer<ConversationSubscription>();
    subscribeGates.add(gate);
    return gate.future;
  }

  @override
  Future<void> parkConversationSubscriptionsForBackground() async {
    parkCalls++;
  }

  @override
  Future<bool> resumeParkedConversation(String sessionId) async {
    resumeCalls++;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestConversationState extends ConversationState {
  bool get hasAnyListeners => hasListeners;
}

class _FakeSubscription implements ConversationSubscription {
  _FakeSubscription(this.sessionId);

  @override
  final String sessionId;
  @override
  final _TestConversationState state = _TestConversationState();
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

ComputerStack _stack(_ControlledConversation conv, {LocalCacheStore? cache}) {
  final stack = ComputerStack(
    profile: AccountV2Profile(
      deviceSid: 'sid-lifecycle',
      label: '测试桌面',
      addedAt: DateTime(2026),
    ),
    cache: cache,
    onLog: (_) {},
    onFailure: (_, _) {},
  );
  stack.debugSeedConversationTransportForTest(conv);
  return stack;
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待订阅调用超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  group('会话注册代际：在飞 subscribe 不得跨生命周期回注册', () {
    test('demote 时 subscribe 在飞：迟到订阅作废，包装层自动重试恢复（三轮审查 C1 M1）', () async {
      final dir = await Directory.systemTemp.createTemp('lifecycle-writer');
      addTearDown(() => dir.delete(recursive: true));
      final conv = _ControlledConversation();
      final stack = _stack(conv, cache: LocalCacheStore(dir));
      final pending = stack.ensureConversation('s-demote');
      await _until(() => conv.subscribeGates.isNotEmpty);

      await stack.demote();
      final late = _FakeSubscription('s-demote');
      conv.subscribeGates[0].complete(late);
      // 迟到订阅以错误收场（不回注册不挂 writer）→ 包装层捕获后等清场
      // 重试一次 → 第二次订阅在稳定代际落地。
      await _until(() => conv.subscribeGates.length == 2);
      final fresh = _FakeSubscription('s-demote');
      conv.subscribeGates[1].complete(fresh);
      final delivered = await pending;

      expect(delivered, same(fresh), reason: '重试后交付活订阅（不再交付死订阅哑弹）');
      expect(fresh.isDisposed, isFalse);
      expect(stack.subscriptionOf('s-demote'), same(fresh));
      expect(late.disposeCalls, 1);
      // 真断言（状态层批）：注入缓存后成功交付的订阅一定挂上 writer
      // （hasListeners=true）；迟到订阅不得挂——旧断言在无缓存下恒真。
      expect(fresh.state.hasAnyListeners, isTrue,
          reason: '成功交付的订阅挂上缓存 writer');
      expect(late.state.hasAnyListeners, isFalse, reason: '迟到订阅未挂 writer');
      stack.dispose();
    });

    test('close 时 subscribe 在飞：迟到结果 dispose，重试后无工作区→以错误收场', () async {
      final dir = await Directory.systemTemp.createTemp('lifecycle-writer-close');
      addTearDown(() => dir.delete(recursive: true));
      final conv = _ControlledConversation();
      final stack = _stack(conv, cache: LocalCacheStore(dir));
      final pending = stack.ensureConversation('s-close');
      await _until(() => conv.subscribeGates.isNotEmpty);

      await stack.suspend();
      final late = _FakeSubscription('s-close');
      conv.subscribeGates.single.complete(late);
      // 迟到订阅作废 → 包装层重试 → conv 已被关栈置空 → "no active
      // workspace" 错误向上传播（页面错误态，可重开）。
      await expectLater(pending, throwsStateError);

      expect(stack.subscriptionOf('s-close'), isNull);
      expect(stack.conversationStates, isEmpty);
      expect(late.disposeCalls, 1);
      expect(late.state.hasAnyListeners, isFalse, reason: '迟到订阅未挂 writer');
      stack.dispose();
    });

    test('disposeStack 同样使在飞订阅代际失效', () async {
      final dir = await Directory.systemTemp.createTemp('lifecycle-writer-dispose');
      addTearDown(() => dir.delete(recursive: true));
      final conv = _ControlledConversation();
      final stack = _stack(conv, cache: LocalCacheStore(dir));
      final pending = stack.ensureConversation('s-dispose');
      await _until(() => conv.subscribeGates.isNotEmpty);

      await stack.disposeStack();
      final late = _FakeSubscription('s-dispose');
      conv.subscribeGates.single.complete(late);
      // 迟到订阅作废 → 包装层重试 → 栈已 disposed → 错误向上传播。
      await expectLater(pending, throwsStateError);

      expect(stack.conversationStates, isEmpty);
      expect(late.disposeCalls, 1);
      expect(late.state.hasAnyListeners, isFalse, reason: '迟到订阅未挂 writer');
    });

    test('旧 pending 完成不得删除新代际 pending；旧调用经包装层重试挂到新 pending', () async {
      final conv = _ControlledConversation();
      final stack = _stack(conv);
      final first = stack.ensureConversation('s-pending');
      await _until(() => conv.subscribeGates.length == 1);
      await stack.demote();
      final second = stack.ensureConversation('s-pending');
      await _until(() => conv.subscribeGates.length == 2);

      final oldSub = _FakeSubscription('s-pending');
      conv.subscribeGates[0].complete(oldSub);
      // 旧代际作废后，包装层的重试经 pending 去重挂到 second 的 future
      // 上——不发起第三次订阅。
      final third = stack.ensureConversation('s-pending');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        conv.subscribeGates.length,
        2,
        reason: '旧 Future 的 whenComplete 不得删掉新代际 pending；重试也不得绕过去重另开订阅',
      );
      final newSub = _FakeSubscription('s-pending');
      conv.subscribeGates[1].complete(newSub);
      expect(await second, same(newSub));
      expect(await third, same(newSub));
      expect(await first, same(newSub),
          reason: '旧调用经包装层重试去重后与新调用同获一个活订阅');
      expect(oldSub.disposeCalls, 1);
      stack.dispose();
    });
  });

  group('缓存 writer 与后台驻留行为守恒', () {
    test('demote 后 writer flush/detach，状态监听归零', () async {
      final dir = await Directory.systemTemp.createTemp('conversation-lifecycle');
      addTearDown(() => dir.delete(recursive: true));
      final conv = _ControlledConversation();
      final stack = _stack(conv, cache: LocalCacheStore(dir));
      final pending = stack.ensureConversation('s-writer');
      await _until(() => conv.subscribeGates.isNotEmpty);
      final sub = _FakeSubscription('s-writer');
      conv.subscribeGates.single.complete(sub);
      await pending;
      expect(sub.state.hasAnyListeners, isTrue);

      await stack.demote();
      expect(sub.state.hasAnyListeners, isFalse);
      stack.dispose();
    });

    test('后台 park/resume 不使注册代际失效，恢复原订阅', () async {
      final conv = _ControlledConversation();
      final stack = _stack(conv);
      final pending = stack.ensureConversation('s-park');
      await _until(() => conv.subscribeGates.isNotEmpty);
      final sub = _FakeSubscription('s-park');
      conv.subscribeGates.single.complete(sub);
      await pending;

      await stack.suspendConversationSubscriptions();
      expect(conv.parkCalls, 1);
      expect(await stack.ensureConversation('s-park'), same(sub));
      expect(conv.resumeCalls, 1);
      expect(stack.subscriptionOf('s-park'), same(sub));
      expect(sub.disposeCalls, 0);
      stack.dispose();
    });
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/draft_store.dart';
import 'package:zcode_pocket/state/send_queue_store.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';
import 'package:zcode_pocket/transport/z_transport.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

/// 断网消息排队（6.6②，2026-10-29 批次）：断连期发送入队+重连自动
/// 发出+重启存活。旅程用内存桩（testWidgets 假区里真 IO 永不完成——
/// DraftStore 测试同款纪律）；磁盘往返在纯逻辑组用真文件（plain test
/// 真异步区）覆盖。

class _StubBridge implements BridgeSession {
  @override
  Map<String, dynamic>? get projectIntent => null;
  @override
  Map<String, dynamic>? get taskIntent => null;
  @override
  final ValueNotifier<String?> degraded = ValueNotifier(null);
  @override
  final ValueNotifier<int> recovered = ValueNotifier(0);
  @override
  Future<void> waitHealthy({
    Duration timeout = const Duration(seconds: 45),
  }) async {}
  @override
  Map<String, dynamic> get bridge => const {};
  @override
  RpcFrameTransport get transport => throw UnimplementedError();
  @override
  ChannelClient get channels => throw UnimplementedError();
  @override
  String? get workspaceKey => 'ws-queue-test';
  @override
  String? get initialTaskId => null;
  @override
  ConversationTransport conversation(
    Map<String, dynamic> scope, {
    void Function(String line)? onLog,
  }) => throw UnimplementedError();
  @override
  void dispose() {}
}

class _MemoryDraftStore extends DraftStore {
  _MemoryDraftStore() : super(Directory.systemTemp);
  @override
  Future<ComposerDraft?> read(DraftIdentity identity) async => null;
  @override
  Future<void> save(ComposerDraft draft) async {}
  @override
  Future<void> delete(DraftIdentity identity, {int? expectedRevision}) async {}
  @override
  Future<void> flush() async {}
}

/// 内存队列桩：与真存储同 API 同语义；fork 共享底图=模拟磁盘往返
///（页面重新读回）。
class _MemorySendQueueStore extends SendQueueStore {
  _MemorySendQueueStore(this._data) : super(File('nul'));
  final Map<String, List<SendQueueEntry>> _data;
  _MemorySendQueueStore fork() => _MemorySendQueueStore(_data);

  @override
  Future<List<SendQueueEntry>> entries(SendQueueBucket bucket) async =>
      List.unmodifiable(_data[bucket.key] ?? const []);

  @override
  Future<void> add(SendQueueBucket bucket, SendQueueEntry entry) async {
    _data.putIfAbsent(bucket.key, () => []).add(entry);
  }

  @override
  Future<void> setCommandId(
    SendQueueBucket bucket,
    String entryId,
    String commandId,
  ) async {
    final list = _data[bucket.key];
    if (list == null) return;
    final idx = list.indexWhere((e) => e.id == entryId);
    if (idx < 0) return;
    list[idx] = SendQueueEntry(
      id: list[idx].id,
      text: list[idx].text,
      config: list[idx].config,
      queuedAt: list[idx].queuedAt,
      commandId: commandId,
    );
  }

  @override
  Future<void> remove(SendQueueBucket bucket, String id) async {
    _data[bucket.key]?.removeWhere((e) => e.id == id);
  }

  // 桶键格式耦合钉子：removeSession/removeDevice 按
  // jsonEncode 数组的 [0]=deviceSid / [3]=scope 位置解析——这是生产
  // SendQueueStore 的内部约定，此处复制了一份；键格式改动须同步此处
  // （真存储纯逻辑组在同文件，格式漂移会让那边先红，此处旅程组是第二道）。
  @override
  Future<void> removeSession(String deviceSid, String sessionId) async {
    final scope = 'session:$sessionId';
    _data.removeWhere((key, list) {
      final parts = (jsonDecode(key) as List).map((e) => '$e').toList();
      return parts[0] == deviceSid && parts[3] == scope;
    });
  }

  @override
  Future<void> removeDevice(String deviceSid) async {
    _data.removeWhere((key, list) {
      final parts = (jsonDecode(key) as List).map((e) => '$e').toList();
      return parts[0] == deviceSid;
    });
  }

  @override
  Future<void> flush() async {}
}

class _QueueSub implements ConversationSubscription {
  _QueueSub(this.sessionId);
  final String sessionId;
  @override
  ConversationState get state => ConversationState()
    ..snapshot = const {
      'title': '排队测试',
      'control': {'phase': 'completed'},
    };
  @override
  String get topic => 'conversation/$sessionId';
  @override
  String get subscriptionId => 'sub-q-$sessionId';
  @override
  bool get isDisposed => false;
  @override
  bool get hasLiveFrames => false;
  @override
  Future<void> dispose() async {}
}

class _QueueApp extends AppState {
  _QueueApp(this.queueStore) : super(draftStore: _MemoryDraftStore()) {
    activeProfile = AccountV2Profile(
      deviceSid: 'device-q',
      accountId: 'account-q',
      label: '测试电脑',
      addedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
    sendQueue = queueStore;
  }

  final SendQueueStore queueStore;
  BridgeSession? bridgeOverride;

  /// 18076 反馈#6：模拟 relay 重连档（桥保留、链路断）。
  bool reconnectingOverride = false;
  /// 18077 验收#12：默认在线（无栈假体 super.phase=offline，而 drain
  /// 现要求 online 才重放）；离线行为由 reconnectingOverride 显式模拟。
  bool onlineOverride = true;
  final sendTexts = <String>[];
  final sentCommandIds = <String?>[];
  var failNextSend = false;

  /// A2-P1-2：createSession 闸门——挂起期间可模拟退页
  ///（重放建会话的网络往返窗口）。
  Completer<void>? createSessionGate;

  @override
  BridgeSession? get bridge => bridgeOverride;
  @override
  LinkPhase get phase => reconnectingOverride
      ? LinkPhase.reconnecting
      : (onlineOverride ? LinkPhase.online : super.phase);

  @override
  Map<String, dynamic>? get activeWorkspace => const {
    'workspaceIdentity': 'workspace-q',
    'workspacePath': '/queue-test',
  };

  @override
  Future<ConversationSubscription> ensureConversation(String sessionId) async =>
      _QueueSub(sessionId);

  int createSessionCalls = 0;

  @override
  Future<String> createSession(
    String? firstText, {
    Map<String, dynamic>? config,
  }) async {
    createSessionCalls++;
    final gate = createSessionGate;
    if (gate != null) await gate.future;
    return 's-created';
  }

  @override
  Future<dynamic> sendText(
    String sessionId,
    String text, {
    Map<String, dynamic>? modelSelection,
    String? mode,
    bool? planEnabled,
    List<Map<String, dynamic>>? attachments,
    String? heldQueueDisposition,
    List<String>? expectedHeldQueueItemIds,
    String? replayCommandId,
  }) async {
    sentCommandIds.add(replayCommandId);
    if (failNextSend) {
      failNextSend = false;
      throw StateError('inject send failure');
    }
    sendTexts.add(text);
    return const {'status': 'accepted'};
  }
}

Widget _host(_QueueApp app, {String? sessionId}) => AppStateScope(
  app: app,
  child: MaterialApp(
    theme: buildAppTheme(),
    home: ConversationPage(
      sessionId: sessionId,
      title: sessionId == null ? '草稿' : '排队测试',
    ),
  ),
);

Future<void> _pump(WidgetTester tester, [int frames = 12]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SendQueueStore 纯逻辑（真文件）', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('send_queue_test');
    });
    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    const bucket = SendQueueBucket(
      deviceSid: 'd1',
      accountId: 'a1',
      workspaceKey: 'w1',
      scopeId: 'session:s1',
    );

    SendQueueEntry e(String text) =>
        SendQueueEntry(id: 'id-$text', text: text, queuedAt: 1);

    test('追加有序；消费一条互不影响', () async {
      final store = SendQueueStore(File('${tmp.path}/q.json'));
      await store.add(bucket, e('m1'));
      await store.add(bucket, e('m2'));
      var entries = await store.entries(bucket);
      expect(entries.map((x) => x.text), ['m1', 'm2']);
      await store.remove(bucket, 'id-m1');
      entries = await store.entries(bucket);
      expect(entries.map((x) => x.text), ['m2']);
    });

    test('持久化往返（重启存活）+ 桶隔离', () async {
      final file = File('${tmp.path}/q.json');
      final s1 = SendQueueStore(file);
      await s1.add(bucket, e('重启后也要发'));
      await s1.flush();
      final s2 = SendQueueStore(file);
      final other = await s2.entries(
        const SendQueueBucket(
          deviceSid: 'd1',
          accountId: 'a1',
          workspaceKey: 'w1',
          scopeId: 'session:s2',
        ),
      );
      expect(other, isEmpty, reason: '桶隔离');
      final same = await s2.entries(bucket);
      expect(same.map((x) => x.text), ['重启后也要发']);
    });

    test('删任务/删电脑联动清队列', () async {
      final store = SendQueueStore(File('${tmp.path}/q.json'));
      await store.add(bucket, e('m'));
      await store.removeSession('d1', 's1');
      expect(await store.entries(bucket), isEmpty);
      await store.add(bucket, e('m2'));
      await store.removeDevice('d1');
      expect(await store.entries(bucket), isEmpty);
    });

    test('畸形条目跳过不拖垮整库', () async {
      final file = File('${tmp.path}/q.json');
      final bucketKey = jsonEncode(['d1', 'a1', 'w1', 'session:s1']);
      await file.writeAsString(
        jsonEncode({
          'version': 1,
          'buckets': {
            bucketKey: [
              {'id': 'ok', 'text': '好条目', 'queuedAt': 1},
              {'bad': 1},
              {'id': 'x', 'text': ''},
            ],
          },
        }),
      );
      final store = SendQueueStore(file);
      final entries = await store.entries(bucket);
      expect(entries.map((x) => x.text), ['好条目']);
    });

    // P2-2：close 只置 _closed 不等盘尾——dispose→进程退出
    // 窗口里最后一次 add/remove 的落盘可丢。对齐 DraftStore.close（内部
    // 先 await flush）。
    test('close 先等盘尾写完成再关门（收尾不丢最后一次落盘）', () async {
      final file = File('${tmp.path}/q.json');
      final store = SendQueueStore(file);
      await store.add(bucket, e('收尾消息'));
      // 不显式 flush——close 自身必须等已入链的盘尾写。
      await store.close();
      expect(file.existsSync(), isTrue,
          reason: 'close 返回时已入链的盘尾写须已完成');
      final reopened = SendQueueStore(file);
      final entries = await reopened.entries(bucket);
      expect(entries.map((x) => x.text), ['收尾消息'],
          reason: 'close 后重开库能读回最后一条（未关门先落盘）');
    });
  });

  group('断网排队旅程（会话页，内存桩）', () {
    testWidgets('relay 重连中发送→立即入队不发起 RPC（18076 反馈#6）', (tester) async {
    final app = _QueueApp(_MemorySendQueueStore({}));
    await tester.pumpWidget(_host(app, sessionId: 's1'));
    await _pump(tester);

    // 模拟飞行模式：桥仍在（恢复保留）但 relay 已进重连档——旧条件
    // 只看 bridge==null，会走 45s waitHealthy 超时；新条件秒级入队。
    app.reconnectingOverride = true;
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '飞行模式消息');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('send-button')));
    await _pump(tester, 6);

    expect(find.byKey(const ValueKey('send-queue-strip')), findsOneWidget,
        reason: '重连档立即入队（不等 RPC 超时）');
    expect(app.sendTexts, isEmpty, reason: '断连期不得发起注定失败的发送');
  });

  testWidgets('断网发送→入队条可见、输入清空、无错误横幅', (tester) async {
      final app = _QueueApp(_MemorySendQueueStore({}));
      await tester.pumpWidget(_host(app, sessionId: 's1'));
      await _pump(tester);

      await tester.enterText(
        find.byKey(const ValueKey('chat-input')),
        '断网消息',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('send-button')));
      await _pump(tester);

      expect(find.byKey(const ValueKey('send-queue-strip')), findsOneWidget);
      expect(find.textContaining('已排队待发送'), findsOneWidget);
      expect(find.textContaining('发送失败'), findsNothing,
          reason: '断网入队不是错误');
      expect(app.sendTexts, isEmpty, reason: '断连期不得发起 RPC 发送');
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('chat-input')))
            .controller!
            .text,
        '',
        reason: '入队后输入清空（消息由队列接管）',
      );
    });

    testWidgets('重放钉 commandId：重试用同一 ID（review-fix-1 双发红线）', (tester) async {
      final store = _MemorySendQueueStore({});
      final app = _QueueApp(store);
      await tester.pumpWidget(_host(app, sessionId: 's1'));
      await _pump(tester);
      await tester.enterText(find.byKey(const ValueKey('chat-input')), '重放消息');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('send-button')));
      await _pump(tester);
      expect(app.sendTexts, isEmpty);

      // 半途失败一次（accepted 前崩溃窗口的等价模拟）→ 条目留队且已带 ID。
      app.failNextSend = true;
      app.bridgeOverride = _StubBridge();
      app.notifyListeners();
      await _pump(tester, 25);
      // 直接从内存桩数据取（唯一桶的唯一条目）。
      final allEntries = [
        for (final list in store._data.values) ...list,
      ];
      final pinned = allEntries.first.commandId;
      expect(pinned, isNotNull, reason: '首次尝试前必须钉住并持久化 commandId');
      expect(app.sentCommandIds.single, pinned,
          reason: '发送携带的就是钉住的 ID');
      final firstId = pinned;

      // 恢复后再次 drain——沿用同一 commandId（服务端幂等去重）。
      app.bridgeOverride = _StubBridge();
      app.notifyListeners();
      await _pump(tester, 25);
      expect(app.sendTexts, ['重放消息']);
      expect(app.sentCommandIds.last, firstId,
          reason: '崩溃窗口后重放必须同 ID（新 ID=服务端视为新消息双投递）');
    });

    testWidgets('桥恢复→按序自动发出、队列条消失', (tester) async {
      final app = _QueueApp(_MemorySendQueueStore({}));
      await tester.pumpWidget(_host(app, sessionId: 's1'));
      await _pump(tester);

      for (final msg in ['第一条', '第二条']) {
        await tester.enterText(
          find.byKey(const ValueKey('chat-input')),
          msg,
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('send-button')));
        await _pump(tester, 4);
      }
      expect(app.sendTexts, isEmpty);

      app.bridgeOverride = _StubBridge();
      app.notifyListeners();
      await _pump(tester, 25);

      expect(app.sendTexts, ['第一条', '第二条'], reason: '重连后按入队序发出');
      expect(find.byKey(const ValueKey('send-queue-strip')), findsNothing,
          reason: '队列清空后条消失');
    });

    testWidgets('重启存活：新页面读回持久化队列并自动补发', (tester) async {
      final store = _MemorySendQueueStore({});
      final app1 = _QueueApp(store);
      await tester.pumpWidget(_host(app1, sessionId: 's1'));
      await _pump(tester);
      await tester.enterText(
        find.byKey(const ValueKey('chat-input')),
        '跨重启的消息',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('send-button')));
      await _pump(tester);
      expect(app1.sendTexts, isEmpty);
      await tester.pumpWidget(const SizedBox());

      final app2 = _QueueApp(store.fork())..bridgeOverride = _StubBridge();
      await tester.pumpWidget(_host(app2, sessionId: 's1'));
      await _pump(tester, 25);

      expect(app2.sendTexts, ['跨重启的消息'],
          reason: '重启后队列存活，连接在场即自动补发');
    });

    testWidgets('开源审查 A2-P1-2：重放建会话期间退页——不抛异常且条目被消费（不重复建会话）', (tester) async {
      tester.view.physicalSize = const Size(375, 806);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final store = _MemorySendQueueStore({});
      final app = _QueueApp(store)
        ..bridgeOverride = _StubBridge()
        ..createSessionGate = Completer<void>();
      // 预置带挂起选型 config 的草稿条目（离线排队新建条目形态——
      // 重放进 _sendText 草稿路径：createSession 网络往返期间退页）。
      await store.add(
        const SendQueueBucket(
          deviceSid: 'device-q',
          accountId: 'account-q',
          workspaceKey: 'workspace-q',
          scopeId: 'draft:workspace',
        ),
        SendQueueEntry(
          id: 'replay-leave',
          text: '退页窗口的建会话消息',
          queuedAt: 1,
          config: {'provider': 'prov-a', 'model': 'm-1'},
        ),
      );
      await tester.pumpWidget(_host(app, sessionId: null)); // 草稿页
      await _pump(tester, 20); // drain 重放 → createSession 等闸门

      // 重放期间退出页面（createSession 仍在途）。
      await tester.pumpWidget(const SizedBox());
      app.createSessionGate!.complete();
      await _pump(tester, 25);

      // 修复前：unmounted 分支不清挂起选型 → _replayQueuedSend finally
      // 对已 dispose 的 State setState 抛异常 → drain 跳过 store.remove
      // → 条目留存再次重放=重复建会话+重复首条消息。
      final all = [for (final list in store._data.values) ...list];
      expect(all, isEmpty,
          reason: '重放已成功（createSession 消费正文）——条目必须 remove');
      expect(app.createSessionCalls, 1,
          reason: '不因异常跳过 remove 而再次重放建会话');
      expect(tester.takeException(), isNull,
          reason: '退页后收尾不得 setState-after-dispose');
    });

    testWidgets('逐条撤销排队', (tester) async {
      final app = _QueueApp(_MemorySendQueueStore({}));
      await tester.pumpWidget(_host(app, sessionId: 's1'));
      await _pump(tester);
      await tester.enterText(
        find.byKey(const ValueKey('chat-input')),
        '要撤销的',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('send-button')));
      await _pump(tester);

      // 单条排队：无展开钮，条目直接可见可撤销（条目 Text 为
      // translate:false 的本地化 Text，按 strip 内 IconButton 定位）。
      final btn = find.descendant(
        of: find.byKey(const ValueKey('send-queue-strip')),
        matching: find.byType(IconButton),
      );
      expect(btn, findsOneWidget);
      await tester.tap(btn.first);
      await _pump(tester);
      expect(find.byKey(const ValueKey('send-queue-strip')), findsNothing);
      expect(app.sendTexts, isEmpty);
    });

    testWidgets('半途失败：条目留队停止连发，恢复后再发', (tester) async {
      final app = _QueueApp(_MemorySendQueueStore({}))..failNextSend = true;
      await tester.pumpWidget(_host(app, sessionId: 's1'));
      await _pump(tester);
      for (final msg in ['会失败的', '跟随着的']) {
        await tester.enterText(
          find.byKey(const ValueKey('chat-input')),
          msg,
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('send-button')));
        await _pump(tester, 4);
      }

      app.bridgeOverride = _StubBridge();
      app.notifyListeners();
      await _pump(tester, 25);

      expect(app.sendTexts, isEmpty, reason: '首条失败即停，第二条不连发');
      expect(find.byKey(const ValueKey('send-queue-strip')), findsOneWidget,
          reason: '失败条目留在队列可见');
      expect(find.textContaining('发送失败'), findsOneWidget,
          reason: '错误横幅照常呈现');

      // 15s 失败退避到点自动重试（E3-P2-3：非边沿 notify 不得旁路退避，
      // 由 _retryTimer 统一驱动）。桥/phase 未变=不是恢复边沿。
      await tester.pump(const Duration(seconds: 16));
      await _pump(tester, 25);
      expect(app.sendTexts, ['会失败的', '跟随着的']);
      expect(find.byKey(const ValueKey('send-queue-strip')), findsNothing);
    });
  });

  group('18077 验收#12：离线不白挂 + 重连边沿 + 失败重试', () {
    testWidgets('离线期（桥保留+reconnecting）drain 不发起 RPC、按钮不转圈（Bug J）', (tester) async {
      final app = _QueueApp(_MemorySendQueueStore({}));
      await tester.pumpWidget(_host(app, sessionId: 's1'));
      await _pump(tester);

      // 飞行模式形态：桥为恢复保留 + relay 重连档。
      app.bridgeOverride = _StubBridge();
      app.reconnectingOverride = true;
      await tester.enterText(
        find.byKey(const ValueKey('chat-input')),
        '离线期消息',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('send-button')));
      await _pump(tester, 6);
      expect(find.byKey(const ValueKey('send-queue-strip')), findsOneWidget);

      // 入队后 app 状态变化（notify）→ 旧实现 drain 会立即重放：真发送
      // 走 waitHealthy 挂 45s（_sending=true：按钮转圈、第二条被吞）。
      app.notifyListeners();
      await _pump(tester, 20);
      expect(app.sendTexts, isEmpty, reason: '离线期 drain 不得发起注定失败的 RPC');
      // 发送键可用（非 _sending 转圈态）：再发第二条应能入队。
      await tester.enterText(
        find.byKey(const ValueKey('chat-input')),
        '第二条离线消息',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('send-button')));
      await _pump(tester, 6);
      expect(app.sendTexts, isEmpty, reason: '两条都在队、零外发');
      final allEntries = [
        for (final list in (app.queueStore as _MemorySendQueueStore)._data.values) ...list,
      ];
      expect(allEntries.length, 2, reason: '第二条未被 _sending 守卫吞掉');
    });

    testWidgets('重连恢复边沿（reconnecting→online）自动按序发出（Bug K）', (tester) async {
      final app = _QueueApp(_MemorySendQueueStore({}));
      await tester.pumpWidget(_host(app, sessionId: 's1'));
      await _pump(tester);

      app.bridgeOverride = _StubBridge();
      app.reconnectingOverride = true;
      for (final msg in ['恢复消息一', '恢复消息二']) {
        await tester.enterText(
          find.byKey(const ValueKey('chat-input')),
          msg,
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('send-button')));
        await _pump(tester, 4);
      }
      expect(app.sendTexts, isEmpty);

      // 重连成功：phase 边沿 + 一次 notify（恢复横幅那次更新）。
      app.reconnectingOverride = false;
      app.notifyListeners();
      await _pump(tester, 25);
      expect(app.sendTexts, ['恢复消息一', '恢复消息二'],
          reason: '恢复边沿触发 drain 按序发出');
      expect(find.byKey(const ValueKey('send-queue-strip')), findsNothing);
    });

    testWidgets('在线重放失败→15s 兜底重试成功（不等下一次 notify）', (tester) async {
      final app = _QueueApp(_MemorySendQueueStore({}))..failNextSend = true;
      await tester.pumpWidget(_host(app, sessionId: 's1'));
      await _pump(tester);

      await tester.enterText(
        find.byKey(const ValueKey('chat-input')),
        '要重试的消息',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('send-button')));
      await _pump(tester, 4);

      // 在线+桥在：drain 立即跑但首次失败（failNextSend）→ 条目留队。
      app.bridgeOverride = _StubBridge();
      app.notifyListeners();
      await _pump(tester, 25);
      expect(app.sendTexts, isEmpty, reason: '首试失败条目留队');
      expect(find.byKey(const ValueKey('send-queue-strip')), findsOneWidget);

      // 不再 notify——15s 兜底 timer 自行重试（failNextSend 已复位）。
      await tester.pump(const Duration(seconds: 16));
      await _pump(tester, 10);
      expect(app.sendTexts, ['要重试的消息'], reason: '失败后 15s 自动重试发出');
      expect(find.byKey(const ValueKey('send-queue-strip')), findsNothing);
    });
  });
}

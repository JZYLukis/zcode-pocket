import 'dart:async';

import '../transport/conversation.dart';
import 'cache_policy.dart';
import 'local_cache.dart';
import 'session_errors.dart';

/// 一台电脑的会话订阅注册表：live/pending/parked、缓存 writer 与注册代际。
/// 工作区与任务目录只通过窄回调接入，本模块不依赖 ComputerStack/AppState。
class ConversationRegistry {
  ConversationRegistry({
    required LocalCacheStore? cache,
    required String Function() deviceSid,
    required ConversationTransport? Function() transportProvider,
    required bool Function() siDormantProvider,
    required Future<void> Function() retrySessionsIndex,
    required bool Function() disposedProvider,
    required void Function(String line) onLog,
  }) : _cache = cache,
       _deviceSid = deviceSid,
       _transportProvider = transportProvider,
       _siDormantProvider = siDormantProvider,
       _retrySessionsIndex = retrySessionsIndex,
       _disposedProvider = disposedProvider,
       _onLog = onLog;

  final LocalCacheStore? _cache;
  final String Function() _deviceSid;
  final ConversationTransport? Function() _transportProvider;
  final bool Function() _siDormantProvider;
  final Future<void> Function() _retrySessionsIndex;

  /// 宿主栈的 dispose 态（disposeStack 只走 close/epoch，
  /// 不置注册表自身 _disposed——栈级守卫须经回调保持 HEAD 语义）。
  final bool Function() _disposedProvider;
  final void Function(String line) _onLog;

  final _conversations = <String, ConversationSubscription>{};
  final _pendingConversations = <String, Future<ConversationSubscription>>{};
  final _parkedConversations = <String>{};
  final _cacheWriters = <String, SessionCacheWriter>{};
  int _epoch = 0;
  bool _disposed = false;

  ConversationSubscription? subscriptionOf(String sessionId) {
    final sub = _conversations[sessionId];
    return (sub != null && !sub.isDisposed) ? sub : null;
  }

  Map<String, ConversationState> get conversationStates => {
    for (final e in _conversations.entries) e.key: e.value.state,
  };

  Future<SessionCacheEntry?> readSessionCache(String sessionId) async {
    final store = _cache;
    if (store == null) return null;
    return store.readSession(_deviceSid(), sessionId);
  }

  void _attachCacheWriter(String sessionId, ConversationState state) {
    final store = _cache;
    if (store == null) return;
    // 覆盖旧条目先 detach：「交付即死」重试路径生成
    // 新 writer 覆盖 map 条目时，旧 writer 的 3s 落盘定时器还挂在已
    // dispose 的 state 上无人回收——多写一次陈旧快照+小对象滞留。
    final old = _cacheWriters[sessionId];
    if (old != null) old.detach();
    final writer = SessionCacheWriter(
      store: store,
      deviceSid: _deviceSid(),
      sessionId: sessionId,
      onLog: _onLog,
    );
    _cacheWriters[sessionId] = writer;
    writer.attach(state);
  }

  /// fire-and-forget 落盘（awaitWrites=false 路径抛出的 flush）收集处：
  /// demote 在飞合并时，后到且要求等盘的调用方靠它补齐等待（见 demote）。
  final _outstandingFlushes = <Future<void>>[];

  Future<void> _flushCacheWriters({bool awaitWrites = true}) async {
    // 快照迭代 + 逐条摘除（三轮审查）：flush 的 await 窗口内新
    // 注册会经 _attachCacheWriter 插入新条目——直接迭代 values 会抛
    // "Concurrent modification during iteration"，而末尾整体 clear() 会
    // 把窗口内新挂的 writer 无 flush 无 detach 地丢掉（监听泄漏）。改为
    // 按身份逐条移除：窗口内新挂的留给 demote 收尾的 detach 循环处理。
    for (final entry in _cacheWriters.entries.toList()) {
      final writer = entry.value;
      if (awaitWrites) {
        try {
          await writer.flush();
        } on Object {
          // 缓存 flush 失败不阻塞主流程。
        }
      } else {
        _outstandingFlushes.add(writer.flush().catchError((_) {}));
      }
      writer.detach();
      if (identical(_cacheWriters[entry.key], writer)) {
        _cacheWriters.remove(entry.key);
      }
    }
  }

  /// [seedCacheEntry]（2026-11-05 反馈②C）：调用方（页面缓存预渲）已
  /// 读过同一会话缓存时传入复用——首开免同文件二次读/解码（两次均在
  /// 主 isolate）；null=照旧自读。
  Future<ConversationSubscription> ensureConversation(
    String sessionId, {
    SessionCacheEntry? seedCacheEntry,
  }) async {
    _onLog('ensureConversation: $sessionId');
    if (_disposedProvider() || _disposed) {
      throw StateError('computer stack disposed');
    }
    final existing = _conversations[sessionId];
    if (existing != null && !existing.isDisposed) {
      // （状态层批）：快路径同样过 _closing 闸门——demote/close
      // 在飞时直接返回旧订阅会让调用方拿到"即将被收尾 dispose"的引用
      // （页面挂监听后帧永久停止）。抛给 ComputerStack 包装层 quiesce
      // 后重试，与新注册路径的失效语义对齐。
      if (_closing) throw SessionSubscriptionResetError();
      if (_parkedConversations.contains(sessionId)) {
        _resumeParkedIfNeeded(sessionId);
      }
      return existing;
    }
    final pending = _pendingConversations[sessionId];
    if (pending != null) return pending;
    final conv = _transportProvider();
    if (conv == null) throw StateError('no active workspace');
    final epoch = _epoch;
    bool isStale() =>
        _disposed || epoch != _epoch || !identical(_transportProvider(), conv);

    late final Future<ConversationSubscription> future;
    future = () async {
      ConversationSeed? seed;
      SessionCacheEntry? entry = seedCacheEntry;
      if (entry == null) {
        try {
          entry = await readSessionCache(sessionId);
        } on Object {
          // 缓存读取失败=普通订阅。
        }
      }
      if (entry != null && entry.rows.isNotEmpty && entry.logEpoch != null) {
        final trusted = entry.historyTrusted;
        seed = ConversationSeed(
          rows: entry.rows,
          logEpoch: entry.logEpoch,
          seq: entry.lastSeq,
          firstRowId: trusted ? entry.firstRowId : null,
          totalCount: trusted ? entry.totalCount : 0,
          snapshot: entry.snapshotControl,
        );
        _onLog(
          '[cache] session seed: rows=${entry.rows.length} '
          'epoch=${entry.logEpoch} seq=${entry.lastSeq}'
          '${trusted ? '' : ' history-untrusted(v1)'}',
        );
      }
      if (isStale() || _closing) {
        throw SessionSubscriptionResetError();
      }
      final sub = await conv.subscribe(sessionId, seed: seed);
      if (isStale() || _closing) {
        // （双盲甲乙一致）：静默返回已 dispose 的订阅=页面
        // 拿到哑弹（addListener 挂在已 dispose 的 ChangeNotifier 上，
        // release 下永久空白无重试入口）。与缓存读取阶段的 stale 分支
        // 一致：先释放再抛人话错误，调用方走既有错误态（可重开）。
        // _closing覆盖两段失效之间落地又被收尾清理 dispose 的
        // 竞态——此类"交付即死"由 ComputerStack 包装层重试兜底。
        await sub.dispose();
        throw SessionSubscriptionResetError();
      }
      _conversations[sessionId] = sub;
      _attachCacheWriter(sessionId, sub.state);
      if (_siDormantProvider()) unawaited(_retrySessionsIndex());
      return sub;
    }().whenComplete(() {
      if (identical(_pendingConversations[sessionId], future)) {
        _pendingConversations.remove(sessionId);
      }
    });
    _pendingConversations[sessionId] = future;
    return future;
  }

  //park 进行中标志（ //，对照 demote
  /// 的 `_closing` 同步闸门范式）：suspendForBackground 在任何 await 之前
  /// 同步置位并先行登记驻留集合。旧实现先 await 全部 writer flush 再
  /// addAll——flush 窗口内回前台的 ensureConversation 查不到集合直接返回，
  /// 随后 suspend 继续把正开着的前台会话驻留且无任何恢复触发（页面冻结
  /// 到下次后台/前台循环）。同步置位后，窗口内的 resume 命中集合；park
  /// 未落地时（transport 返回 false）记入 [_resumeAfterPark]，收尾对账
  /// 补 park 后自动重放。
  bool _parking = false;
  final _resumeAfterPark = <String>{};

  void _resumeParkedIfNeeded(String sessionId) {
    final conv = _transportProvider();
    if (conv == null) return;
    unawaited(
      conv.resumeParkedConversation(sessionId).then((resumed) {
        if (resumed) {
          // 只在 resume 确有触发时摘牌（：旧实现先摘牌
          // 再吞掉 false——park 循环随后把它真正驻留，前台会话帧永久停止）。
          _parkedConversations.remove(sessionId);
          _onLog('[battery] parked conversation resuming: $sessionId');
          return;
        }
        if (_parking) {
          // park 尚未落地（suspend 的 park 循环未轮到它）：排队等收尾
          // 对账补 park 后重放。
          _resumeAfterPark.add(sessionId);
        }
        // 非 parking 态的 false（如订阅对象换代不在驻留态）：零副作用。
      }, onError: (Object _) {
        // resume 失败：驻留标记保留，transport 3s 重试链自愈；下次进入
        // 页面 ensure 再触发（"已摘牌但未续订"死态）。
      }),
    );
  }

  Future<void> suspendForBackground() async {
    if (_disposedProvider() || _disposed) return;
    // 驻留集合先行（见 _parking 注释）：flush 的 await 窗口内回前台的
    // ensure 才能命中集合。
    _parking = true;
    _parkedConversations.addAll(_conversations.keys);
    for (final writer in _cacheWriters.values.toList()) {
      try {
        await writer.flush();
      } on Object {
        // 缓存 flush 失败不阻塞驻留。
      }
    }
    final conv = _transportProvider();
    if (conv != null) await conv.parkConversationSubscriptionsForBackground();
    // 收尾对账（/ registry 面）：flush/park 的
    // await 窗口内新落地的注册既不在驻留集合也不曾被 park——保活分支下
    // 它是后台常驻的全速活订阅（电量红线，本机制要消灭的形态）。补登记
    // +补 park（幂等：已驻留的零副作用）。
    final leaked = [
      for (final sid in _conversations.keys)
        if (!_parkedConversations.contains(sid)) sid,
    ];
    if (leaked.isNotEmpty) {
      _parkedConversations.addAll(leaked);
      final c = _transportProvider();
      if (c != null) await c.parkConversationSubscriptionsForBackground();
    }
    _parking = false;
    // park 全部落地后重放窗口内到达的 resume 请求（前台正开的会话——
    // onAppResumed 已消费、页面不会再发 ensure，不重放即冻结）。park
    // 已落地，重放必然触发恢复——**同步摘牌**（fire-and-forget 的 then
    // 微任务实测晚于调用方的下一次 ensure，依赖它会造成重复 resume），
    // 失败/意外再回补标记。
    final pendingResumes = _resumeAfterPark.toList();
    _resumeAfterPark.clear();
    for (final sid in pendingResumes) {
      if (_closing || !_conversations.containsKey(sid)) continue;
      _parkedConversations.remove(sid);
      final conv = _transportProvider();
      if (conv == null) continue;
      unawaited(
        conv.resumeParkedConversation(sid).then((resumed) {
          _onLog('[battery] parked conversation resuming (replay): $sid');
          if (!resumed) {
            // 意外（park 已落地却未触发，如订阅对象换代）：回补标记，
            // 下次进入页面 ensure 重试。
            _parkedConversations.add(sid);
          }
        }, onError: (Object _) {
          _parkedConversations.add(sid);
        }),
      );
    }
    _onLog('[battery] conversation subscriptions parked for background');
  }

  /// demote/close 进行中标志（三轮审查 ：两段失效之间的窗口里，
  /// 落地的注册会"先成功交付、再被收尾清理悄悄 dispose"——页面拿到
  /// 死订阅且无错误提示。_closing 在**任何 await 之前**同步置位，窗口
  /// 内的落地在注册时即抛错，交给 ComputerStack 包装层等清场后重试）。
  bool _closing = false;
  Future<void>? _closingFuture;

  /// 等待进行中的 demote/close 落地（无则立即返回）。
  Future<void> quiesce() => _closingFuture ?? Future.value();

  Future<void> demote({bool awaitWrites = true}) {
    final inFlight = _closingFuture;
    if (inFlight != null) {
      // 在飞合并语义：清场以先到者的
      // awaitWrites 执行——后到者要求等待落盘而先到者没有时（切工作区
      // 的 close(false) 在飞、suspend 路径 demote(true) 到达），追加等待
      // 已抛出的 fire-and-forget flush（_outstandingFlushes），保证
      // 「任一调用方要求 await 即等到写盘完成」；反向（先 true 后 false）
      // 多等一次落盘，无正确性问题。
      if (!awaitWrites) return inFlight;
      final flushes = List.of(_outstandingFlushes);
      return inFlight.then((_) => Future.wait(flushes));
    }
    _closing = true;
    return _closingFuture = _doDemote(awaitWrites: awaitWrites).whenComplete(() {
      _closing = false;
      _closingFuture = null;
      _outstandingFlushes.clear();
    });
  }

  Future<void> _doDemote({bool awaitWrites = true}) async {
    _epoch++;
    _pendingConversations.clear();
    await _flushCacheWriters(awaitWrites: awaitWrites);
    _disposeAllConversations();
    // （双盲乙）：flush 的 await 窗口内新发起的注册捕获的是
    // 已递增的 epoch，若其 subscribe 在上方 clear 之后落地，isStale 恒假
    // → 订阅挂上垂死传输。结尾再失效+清一遍，把窗口内漏网的注册一并
    // 收掉（幂等：通常第二遍为空）。这批是已作废代际，writer 只摘挂
    // 不落盘（不必为被丢弃的订阅阻塞关栈）。
    _epoch++;
    _pendingConversations.clear();
    _disposeAllConversations();
    for (final writer in _cacheWriters.values.toList()) {
      writer.detach();
    }
    _cacheWriters.clear();
  }

  void _disposeAllConversations() {
    for (final sub in _conversations.values) {
      unawaited(sub.dispose());
    }
    _conversations.clear();
    _parkedConversations.clear();
  }

  Future<void> close({bool awaitWrites = true}) => demote(awaitWrites: awaitWrites);

  /// 同步测试收尾只使在飞注册失效；完整异步清理由 close/demote 负责。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _epoch++;
    _pendingConversations.clear();
  }
}

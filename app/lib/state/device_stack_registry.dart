import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../transport/connection_params.dart';
import '../transport/relay_client.dart';
import '../transport/z_transport.dart';
import 'account_store.dart';
import 'computer_stack.dart';
import 'link_phase.dart';
import 'local_cache.dart';
import 'notify_coordinator.dart';
import 'profile_store.dart';

typedef DeviceStackFactory =
    ComputerStack Function(
      DeviceProfile profile,
      void Function(ComputerStack stack, RelayFailure failure) onFailure,
    );

/// 设备档案与 ComputerStack 生命周期注册表。
/// AppState 通过回调提供运行期依赖；本模块不持有 AppState 本体。
class DeviceStackRegistry {
  DeviceStackRegistry({
    required this.store,
    required this.accountStore,
    required LocalCacheStore? Function() cacheProvider,
    required NotifyCoordinator? Function() notifyCoordinatorProvider,
    required LinkPhase Function() phaseProvider,
    required void Function(String line) onLog,
    required void Function() onNotify,
    required void Function() onStackChanged,
    required Future<void> Function(DeviceProfile profile) onPersistProfile,
    Future<void> Function(String deviceSid)? onRemoveDeviceData,
    DeviceStackFactory? stackFactory,
  }) : _cacheProvider = cacheProvider,
       _notifyCoordinatorProvider = notifyCoordinatorProvider,
       _phaseProvider = phaseProvider,
       _onLog = onLog,
       _onNotify = onNotify,
       _onStackChanged = onStackChanged,
       _onPersistProfile = onPersistProfile,
       _onRemoveDeviceData = onRemoveDeviceData,
       _stackFactory = stackFactory;

  final ProfileStore store;
  final AccountStore accountStore;
  final LocalCacheStore? Function() _cacheProvider;
  final NotifyCoordinator? Function() _notifyCoordinatorProvider;
  final LinkPhase Function() _phaseProvider;
  final void Function(String line) _onLog;
  final void Function() _onNotify;
  final void Function() _onStackChanged;
  final Future<void> Function(DeviceProfile profile) _onPersistProfile;
  final Future<void> Function(String deviceSid)? _onRemoveDeviceData;
  final DeviceStackFactory? _stackFactory;

  List<DeviceProfile> profiles = const [];
  DeviceProfile? activeProfile;
  int corruptedProfiles = 0;

  final _stacks = <String, ComputerStack>{};
  String? activeSid;
  ComputerStack? get active => activeSid == null ? null : _stacks[activeSid!];
  Map<String, ComputerStack> get stacks => _stacks;
  bool _disposed = false;

  String? _lastRelayFailReason;
  String? _lastRelayFailMessage;
  DateTime? _lastRelayFailAt;
  String? get lastRelayFailReason => _lastRelayFailReason;
  String? get lastRelayFailMessage => _lastRelayFailMessage;
  DateTime? get lastRelayFailAt => _lastRelayFailAt;

  final _failureBySid =
      <String, ({String reason, String? message, DateTime at})>{};

  /// 正在拆除的 sid（状态层批）：removeComputer 先摘表 await dispose 的
  /// 窗口内，_doActivate 可能为同 sid 建新活栈，随后收尾按 sid 摘协调器
  /// 把新栈摘掉/尾巴 removeWhere 误删（M5 家族的同款缺口）。拆栈期间
  /// 登记，activate 直接拒绝——删除完成后用户再点即可。
  final _deleting = <String>{};

  /// 建栈时闭包捕获的账号 id（与 accountJwtProvider 同源）：栈复用/改绑
  /// 时校验凭据归属——变了必须重建，旧栈永远拿旧账号 JWT。
  final _stackAccountBySid = <String, String?>{};

  static String? _accountOf(DeviceProfile profile) =>
      profile is AccountV2Profile ? profile.accountId : null;

  DeviceStackFactory get _createStack =>
      _stackFactory ??
      (profile, onFailure) {
        final account = profile is AccountV2Profile ? profile.accountId : null;
        return ComputerStack(
          profile: profile,
          onLog: _onLog,
          onFailure: onFailure,
          cache: _cacheProvider(),
          accountJwtProvider: () => accountStore.readJwtFor(account),
        );
      };

  void updateRelayFailure(String? reason, String? message) {
    _lastRelayFailReason = reason;
    _lastRelayFailMessage = message;
    _lastRelayFailAt = reason == null ? null : DateTime.now();
    _onNotify();
  }

  ({String title, String hint})? get relayDiagnosis {
    final at = _lastRelayFailAt;
    final reason = _lastRelayFailReason;
    if (at == null || reason == null) return null;
    if (DateTime.now().difference(at) > const Duration(minutes: 2)) return null;
    final phase = _phaseProvider();
    // auth-required 的处置=拆栈，活跃栈没了
    // phase 必落 offline——相位门若只放行 reconnecting/error，重登引导
    // 文案在它唯一的真实触发场景（服务端 401）里永不可达（横幅只在拆栈
    // 的短暂 await 窗口内闪现）。offline 档对 auth-required 放行。
    final diagnoseOffline =
        phase == LinkPhase.offline && reason == 'auth-required';
    if (!diagnoseOffline &&
        phase != LinkPhase.reconnecting &&
        phase != LinkPhase.error) {
      return null;
    }
    final (title, hint) = switch (reason) {
      'network-dns' => (
        '域名解析失败，正在重试',
        'zcode.z.ai 解析不出服务器地址。若在用 VPN：切换节点、把 z.ai 设为直连或暂时关闭；网络恢复后约 1 秒自动重连',
      ),
      'network-timeout' => ('连接中继服务器超时，正在重试', '若在用 VPN：试试切换节点；网络恢复后约 1 秒自动重连'),
      'network-refused' => ('连接被拒绝，正在重试', '中继服务或当前网络路径不可用，稍候自动重连'),
      'network-auth' => ('账号鉴权失败', '请到「添加电脑」重新登录账号'),
      'auth-required' => (
        '账号登录凭据已失效',
        '该账号的登录凭据不存在或已过期（可能刚被删除）。到「设置 · 账号管理」'
            '重新登录该账号后，电脑会自动接回',
      ),
      'relay-unavailable' => ('中继服务暂不可用', '服务端暂时异常，稍候自动重连；持续出现可重启桌面端试试'),
      'desktop-disconnected' => (
        '等待桌面端上线',
        '电脑上的 ZCode 不在线——在电脑端打开 ZCode 后自动恢复',
      ),
      'device-not-owned' => (
        '这台电脑属于另一个账号',
        '电脑端 ZCode 登录的账号和当前用于连接的账号不一致。点下方「换账号重连」'
            '登录电脑端所用账号后自动重试',
      ),
      _ => (_lastRelayFailMessage ?? '连接失败，正在重试', '网络恢复后约 1 秒自动重连'),
    };
    return (title: title, hint: hint);
  }

  LinkPhase statusOf(DeviceProfile profile) =>
      _stacks[profile.deviceSid]?.computeStatus() ??
      (profile.invalid ? LinkPhase.invalid : LinkPhase.offline);

  DeviceProfile? profileOf(String deviceSid) =>
      profiles.where((p) => p.deviceSid == deviceSid).firstOrNull;

  String deviceLabelOf(String deviceSid) => _stacks[deviceSid]?.profile.label ?? '';

  //持久活跃指针写入：串行链+陈旧
  /// 核对+失败留痕。unawaited 裸写有两笔账：①快速 A→B 切换（或删账号
  /// 收尾与并发 activate 交错）时写入与内存 activeSid 的最终一致性无
  /// 守卫，冷启动可能恢复到较旧的一台；②写入抛错是无主异步错误，重启
  /// 回退无日志可查。陈旧核对=写盘前内存指针又变了就让位（新值自有
  /// 后续写，终态恒与内存一致）。
  Future<void> _activeSidWriteChain = Future<void>.value();
  /// 返回写链 future（内部已 contain 异常）：拆栈收尾路径 await 它，
  /// 保证 await 完成时持久 sid 已落定（测试可确定性断言；其余热路径
  /// 用 unawaited 不阻塞 UI）。
  Future<void> _persistActiveDeviceSid(String? sid) {
    final write = _activeSidWriteChain.then((_) async {
      if (activeSid != sid) return;
      try {
        await store.setActiveDeviceSid(sid);
      } catch (e) {
        _onLog('persist active device sid failed (contained): $e');
      }
    });
    _activeSidWriteChain = write.then((_) {}, onError: (Object _) {});
    return write;
  }

  Future<void> retryActiveProfileWithNewAccount() async {
    final profile = activeProfile;
    if (profile is! AccountV2Profile || _disposed) return;
    // 批2 配套：lastUsed 不再随登录切换——用「最近保存的账号」
    // （刚登录的账号=列表首项）识别改绑目标。
    final accountId = await accountStore.mostRecentAccountId;
    if (accountId == null || accountId == profile.accountId) return;
    final updated = profile.copyWith(accountId: accountId);
    await store.updateProfile(updated);
    final sid = updated.deviceSid;
    final old = _stacks.remove(sid);
    _stackAccountBySid.remove(sid);
    if (old != null) {
      _deleting.add(sid);
      try {
        old.removeListener(_onStackChanged);
        // 换账号重连的拆栈收尾（对齐 disposeStacksFor
        // Account）：逐栈容错 + coordinator detach + 失败记录/设备缓存
        // 数据同步清——设备缓存按 deviceSid 分桶不带账号维度，不清则新
        // 账号接回同电脑首帧闪上一账号的任务缓存；_failureBySid 残留则
        // 2 分钟回捞窗把旧账号诊断横幅复活到新账号会话。
        try {
          await old.disposeStack();
        } catch (e) {
          _onLog('dispose stack on retry with new account failed (contained): $e');
        }
        _notifyCoordinatorProvider()?.detachStack(sid, ifStack: old);
        _failureBySid.remove(sid);
        try {
          await _onRemoveDeviceData?.call(sid);
        } catch (e) {
          _onLog('remove device data on retry failed (contained): $e');
        }
      } finally {
        _deleting.remove(sid);
      }
    }
    _lastRelayFailReason = null;
    _lastRelayFailMessage = null;
    await reloadProfiles();
    await activate(updated);
  }

  Future<void> addComputer(String rawUrl, {String? label}) async {
    final params = CompanionConnectionParams.parse(rawUrl);
    if (params == null) {
      throw const FormatException('无法解析远控链接（需要 https/wss 且含 sid/hash/t 参数）');
    }
    final profile = await store.upsertProfile(
      RelayProfile(
        params: params,
        label: (label == null || label.trim().isEmpty)
            ? (params.deviceName ?? '桌面')
            : label.trim(),
        addedAt: DateTime.now(),
      ),
    );
    await reloadProfiles();
    await activate(profile);
  }

  Future<void> addV2Profile(
    CompanionV2Params params, {
    String? label,
    String? accountId,
    bool forceRebind = false,
  }) async {
    // multi-account-ux-1 批2（2026-11-04 拍板）：同一台电脑改绑到另一个
    // 账号属破坏性操作（旧账号的连接将失效）——已绑定且账号将变时抛
    // [AccountRebindRequired] 由调用方弹确认，确认后 forceRebind 重调。
    final probeSid = params.deviceSid?.trim() ?? '';
    if (probeSid.isNotEmpty && !forceRebind) {
      final existing = profileOf(probeSid);
      final nextAccount = accountId ?? await accountStore.lastUsedAccountId;
      if (existing is AccountV2Profile &&
          existing.accountId != null &&
          nextAccount != null &&
          existing.accountId != nextAccount) {
        throw AccountRebindRequired(
          deviceSid: probeSid,
          deviceLabel: existing.label,
          fromAccountId: existing.accountId!,
          toAccountId: nextAccount,
        );
      }
    }
    final sid = params.deviceSid?.trim() ?? '';
    if (sid.isEmpty) {
      throw const FormatException('V2 连接缺少设备 sid（请从设备列表选择电脑）');
    }
    final boundAccount = accountId ?? await accountStore.lastUsedAccountId;
    final profile = await store.upsertProfile(
      AccountV2Profile(
        deviceSid: sid,
        deviceMid: params.deviceMid,
        deviceName: params.deviceName,
        appVersion: params.appVersion,
        accountId: boundAccount,
        label: (label == null || label.trim().isEmpty)
            ? (params.deviceName?.trim().isNotEmpty == true
                  ? params.deviceName!
                  : sid)
            : label.trim(),
        addedAt: DateTime.now(),
      ),
    );
    await reloadProfiles();
    await activate(profile);
  }

  Future<void> renameComputer(DeviceProfile profile, String label) async {
    final updated = profile.copyWith(label: label.trim());
    await store.updateProfile(updated);
    _stacks[profile.deviceSid]?.profile = updated;
    await reloadProfiles();
  }

  Future<void> removeComputer(DeviceProfile profile) async {
    final sid = profile.deviceSid;
    // 档案删除先行（状态层批）：removeProfile 内部备份写失败会抛（中止
    // 删除）——旧实现先拆栈再写档案，备份失败留下"连接已拆但档案还在"
    // 的半途态（用户重试时这台电脑已不在线）。
    await store.removeProfile(sid);
    _deleting.add(sid);
    final stack = _stacks.remove(sid);
    _stackAccountBySid.remove(sid);
    try {
      if (stack != null) {
        stack.removeListener(_onStackChanged);
        try {
          await stack.disposeStack();
        } catch (e) {
          // 逐栈容错（状态层批）：单栈 dispose 抛出不阻断档案/数据清理。
          _onLog('dispose stack on removeComputer failed (contained): $e');
        }
        // 按栈身份摘协调器：dispose await 窗口内同 sid 可能已建新栈。
        _notifyCoordinatorProvider()?.detachStack(sid, ifStack: stack);
      }
      try {
        await _onRemoveDeviceData?.call(sid);
      } catch (e) {
        _onLog('remove device data failed (contained): $e');
      }
      // 失败诊断记录同步清：2 分钟回捞窗内不闪已删设备的旧横幅。
      _failureBySid.remove(sid);
      if (activeSid == sid) {
        activeSid = null;
        activeProfile = null;
        // 全局失败横幅一并清（与 disposeStacksForAccount 收尾对齐）：
        // 删掉的就是当前电脑时，旧诊断（"等待桌面端上线"等）没有对象了。
        _lastRelayFailReason = null;
        _lastRelayFailMessage = null;
        _lastRelayFailAt = null;
        // 先 reload 再挑下一台：早退路径此前
        // 跳过 reloadProfiles，内存 profiles 滞留已删档案=幽灵条目（点按
        // 可为已删设备重建栈并持久化 activeDeviceSid）；从删除前的陈旧
        // 列表选 next 还会命中排首的被删档案自身（PF-4 自复活面）。
        await reloadProfiles();
        final next = profiles.where((p) => !p.invalid).firstOrNull;
        if (next != null) {
          await activate(next);
          return;
        }
        // 无其余可用档案：持久指针同步清（对齐
        // disposeStacksForAccount 收尾）——冷启虽有 profileOf miss 兜底，
        // 对齐欠账清掉防恢复到已删档案。
        unawaited(_persistActiveDeviceSid(null));
      }
      await reloadProfiles();
      _onNotify();
    } finally {
      _deleting.remove(sid);
    }
  }

  Future<void> reloadProfiles() async {
    try {
      final r = await store.listProfilesDetailed();
      profiles = r.profiles;
      corruptedProfiles = r.skipped;
    } catch (e) {
      _onLog('profile reload failed (contained): $e');
    }
    final sid = activeSid;
    if (sid != null) activeProfile = profileOf(sid) ?? activeProfile;
    _onNotify();
  }

  /// 并发 activate 串行链：单次 activate 的指针
  /// 写入段本就同步原子（两指针间无 await），但尾部 `await prev.demote()`
  /// 与后续 activate 的执行段交错时，多个 demote 的执行序不受控。整链
  /// 排队消灭该类交错；不改变最终归属（后到者仍然后写指针）。链本身
  /// 吞错（排队者的错误仍由各自调用方收到）。
  Future<void>? _activateChain;

  Future<void> activate(DeviceProfile profile) {
    final wait = _activateChain;
    final run = wait == null
        ? _doActivate(profile)
        : wait.then((_) => _doActivate(profile));
    _activateChain = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  Future<void> _doActivate(DeviceProfile profile) async {
    if (profile.invalid) {
      // 无效档案不建栈；指针二相一致：旧实
      // 现只写 activeProfile 不动 activeSid——「当前电脑」短暂指向无效
      // 档案而真实活跃栈还是旧电脑（draft 身份读 activeProfile、数据面
      // 读 _active，两相分叉直到下次栈 notify 才被覆盖回去）。就地选中
      // =诚实离线：两指针一致清位（phase 落 offline/invalid），旧活跃栈
      // 降级释放会话订阅。
      final prev = active;
      activeSid = null;
      activeProfile = profile;
      // P3-10（D-8 批2）：持久指针同步清位——否则冷启动自动激活旧设备，
      // 用户本次"选中失效档案"的语义在重启后被撤销（三处收尾同款）。
      unawaited(_persistActiveDeviceSid(null));
      _onNotify();
      if (prev != null) await prev.demote();
      return;
    }
    final sid = profile.deviceSid;
    if (_deleting.contains(sid)) {
      // 拆栈窗口（removeComputer 等）：拒绝激活——否则收尾按 sid 摘表/
      // detach 会把窗口内新建的活栈误伤成僵尸（连接在、注册表查不到）。
      throw StateError('device is being removed (sid=$sid)');
    }
    var prev = active;
    activeSid = sid;
    unawaited(_persistActiveDeviceSid(sid));

    var stack = _stacks[sid];
    // 目标档案以注册表为准（调用方可能持有旧 profile 对象：UI 面板在
    // reloadProfiles 前抓的引用）；建栈闭包同源取它。
    final targetProfile = profileOf(sid) ?? profile;
    // 凭据归属校验（状态层批）：栈在构造期闭包捕获账号 id，
    // accountJwtProvider 永远用旧账号——复用旧栈的"改绑账号"只会换档案
    // 标签不换凭据（addV2Profile forceRebind 的实测洞）。目标账号变了
    // 就走与 retryActiveProfileWithNewAccount 同款拆栈收尾后重建。
    if (stack != null &&
        !stack.disposed &&
        _stackAccountBySid.containsKey(sid) &&
        _stackAccountBySid[sid] != _accountOf(targetProfile)) {
      final stale = stack;
      _stacks.remove(sid);
      _stackAccountBySid.remove(sid);
      stale.removeListener(_onStackChanged);
      if (identical(prev, stale)) prev = null;
      try {
        await stale.disposeStack();
      } catch (e) {
        _onLog('dispose stack on account rebind failed (contained): $e');
      }
      _notifyCoordinatorProvider()?.detachStack(sid, ifStack: stale);
      _failureBySid.remove(sid);
      stack = null;
    }
    if (stack == null || stack.disposed) {
      _stacks.remove(sid);
      final stackProfile = targetProfile;
      stack = _createStack(stackProfile, onStackFailure);
      _stackAccountBySid[sid] = _accountOf(stackProfile);
      stack.onPersistProfile = _onPersistProfile;
      stack.addListener(_onStackChanged);
      _stacks[sid] = stack;
      _notifyCoordinatorProvider()?.attachStack(stack);
      activeProfile = stack.profile;
      _onNotify();
      unawaited(
        stack.start().catchError((Object e) {
          _onLog('stack start error (contained): $e');
        }),
      );
    } else {
      stack.profile = targetProfile;
      activeProfile = stack.profile;
      final recent = _failureBySid[sid];
      if (recent != null &&
          DateTime.now().difference(recent.at) <= const Duration(minutes: 2)) {
        updateRelayFailure(recent.reason, recent.message);
      }
      _onNotify();
      unawaited(
        stack.pokeOrResume().catchError((Object e) {
          _onLog('stack resume error (contained): $e');
        }),
      );
      // 对抗审查遗留核实修（2026-11-07）：keepAlive 后台全栈退订
      // tasks-index、回前台只恢复活跃栈——此后切到「保活中的另一栈」
      // 走本分支 pokeOrResume→poke（连接在、不重开工作区），该栈
      // tasks-index 永不补订→首页停更。就地补订（幂等：已订阅 no-op；
      // 悬挂栈 resume 走 start→开工作区→自然订阅，此处同 no-op）。
      unawaited(
        stack
            .resumeTasksIndexFromBackground()
            .then((_) {}, onError: (Object e) {
          _onLog('tasks-index resume on activate (contained): $e');
        }),
      );
    }
    if (prev != null && prev != stack) await prev.demote();
  }

  Future<void> debugStackFailure(ComputerStack stack, RelayFailure f) =>
      onStackFailure(stack, f);

  void debugRegisterStackForTest(ComputerStack stack) {
    final sid = stack.profile.deviceSid;
    _stacks[sid] = stack;
    _stackAccountBySid[sid] = _accountOf(stack.profile);
  }

  /// 测试缝：用生产建栈工厂构造一条未注册栈（JWT 读取器归属红绿用，
  /// 不 start、不发起连接）。
  @visibleForTesting
  ComputerStack debugCreateStackForTest(DeviceProfile profile) =>
      _createStack(profile, (_, _) {});

  ({String reason, String? message, DateTime at})? debugFailureRecordForTest(
    String sid,
  ) => _failureBySid[sid];

  void debugAgeStackFailureForTest(String sid, Duration age) {
    final f = _failureBySid[sid];
    if (f == null) return;
    _failureBySid[sid] = (
      reason: f.reason,
      message: f.message,
      at: DateTime.now().subtract(age),
    );
  }

  /// 按账号拆除其名下全部栈（18079 真机反馈②：设置删除账号只清凭据，
  /// 旧账号的连接栈带着内存里的 JWT 继续活——僵尸连接让"删号后重登"
  /// 状态错乱。2026-11-03 两轮对抗审查补全收尾：同步摘表先行（消灭
  /// dispose await 窗口内新栈入表又被 removeWhere 误删的竞态）、失败
  /// 记录/设备缓存数据同步清（防下一账号连同一台电脑先闪上一账号的
  /// 诊断与任务缓存=跨账号数据残留）、活跃指针与持久 activeDeviceSid
  /// 收尾对齐 removeComputer。档案保留（删除对话框明示"档案保留，
  /// 重新登录即恢复"）——重登后的接回编排见 AppState.
  /// reattachAfterAccountLogin）。
  ///
  /// [lastUsedBefore]：删账号**之前**的 lastUsed（由调用方在读凭据删除
  /// 前捕获传入）——legacy 档案 accountId==null 的凭据取 lastUsed
  /// （ 启动迁移只在唯一账号时绑定），此刻 store 里的 lastUsed
  /// 已被 removeAccount 改写，直接读会漏拆正用该账号凭据的 legacy 栈。
  Future<void> disposeStacksForAccount(
    String accountId, {
    String? lastUsedBefore,
  }) async {
    final lastUsed = lastUsedBefore ?? await accountStore.lastUsedAccountId;
    bool matches(DeviceProfile p) =>
        p is AccountV2Profile &&
        (p.accountId == accountId ||
            (p.accountId == null && lastUsed == accountId));
    // 同步快照+摘表先行：await disposeStack 期间 activate() 新建的栈
    // 不应被后续 removeWhere 误删（对抗审查 M5）。
    final doomed = <String, ComputerStack>{};
    for (final entry in List.of(_stacks.entries)) {
      if (matches(entry.value.profile)) {
        doomed[entry.key] = entry.value;
        entry.value.removeListener(_onStackChanged);
        _stacks.remove(entry.key);
        _stackAccountBySid.remove(entry.key);
      }
    }
    // 拆栈窗口登记（状态层批）：逐栈 dispose 的 await 期间 activate 同
    // sid 被拒绝，收尾不致误伤窗口内新栈。
    _deleting.addAll(doomed.keys);
    try {
      for (final entry in doomed.entries) {
        final sid = entry.key;
        try {
          await entry.value.disposeStack();
        } catch (e) {
          _onLog('dispose stack for account failed (contained): $e');
        }
        _notifyCoordinatorProvider()?.detachStack(sid, ifStack: entry.value);
        // 失败诊断记录同步清（L4）：2 分钟回捞窗内不闪已删账号的横幅。
        _failureBySid.remove(sid);
        // 设备缓存/草稿/排队数据（M3/乙）：缓存按 deviceSid 分目录不带
        // 账号维度——不清则下一账号连同一台电脑会先渲染上一账号的任务
        // 标题与正文片段（跨账号数据残留）。档案本身保留。
        try {
          await _onRemoveDeviceData?.call(sid);
        } catch (e) {
          _onLog('remove device data for account failed (contained): $e');
        }
      }
    } finally {
      _deleting.removeAll(doomed.keys);
    }
    // 活跃指针+持久 sid 收尾（对齐 removeComputer :218-226）：删的是
    // 当前活跃账号时清指针；**其他账号**有可用档案才切过去（本账号
    // 档案虽保留但凭据已删，激活它只会吃 auth-required）；都没有则
    // 显式离线（持久 sid 清掉，防冷启自动激活已删凭据的档案；重登后
    // 的接回由 reattachAfterAccountLogin 负责）。
    if (activeSid != null && doomed.containsKey(activeSid)) {
      activeSid = null;
      activeProfile = null;
      // 全局失败横幅一并清（审查 L4 补）：2 分钟回捞窗内不闪已删账号
      // 的诊断文案。
      _lastRelayFailReason = null;
      _lastRelayFailMessage = null;
      _lastRelayFailAt = null;
      final next =
          profiles.where((p) => !p.invalid && !matches(p)).firstOrNull;
      if (next != null) {
        await activate(next);
      } else {
        unawaited(_persistActiveDeviceSid(null));
      }
    }
    // 早退不再跳过尾部 reload：activate 内部不刷
    // profiles 列表，统一走此处兜底一次。
    await reloadProfiles();
  }

  Future<void> onStackFailure(ComputerStack stack, RelayFailure f) async {
    _onLog('failure: ${f.reason} ${f.message ?? ''}');
    final sid = stack.profile.deviceSid;
    _failureBySid[sid] = (
      reason: f.reason,
      message: f.message,
      at: DateTime.now(),
    );
    if (sid != activeSid) {
      _onLog('failure from inactive stack ignored (sid=$sid)');
    } else {
      updateRelayFailure(f.reason, f.message);
    }
    switch (f.reason) {
      case 'auth-required':
        // （//K1 P2-3 三路）：auth-required
        // 收窄（「只清失败账号+只拆其名下栈」）此前被 null 旁路
        // 击穿——accountId==null 的 V2 档案（迁移未绑定的存量形态）凭据
        // 实际取 lastUsed，旧实现把 null 传给 clearAccount 触发全清（一次
        // 401 清光全部账号凭据+拆全部 V2 栈，多账号用户被整体登出）。
        // ①lastUsed 在 clearAccount **之前**捕获（clear 会改写 lastUsed，
        //   对照 disposeStacksForAccount 的 lastUsedBefore 语义）；
        // ②null 档案回落 lastUsed 精确点名；
        // ③兜底后仍无账号（零账号配对态）则不动凭据库、只拆本栈。
        final failedLastUsed = await accountStore.lastUsedAccountId;
        final failedAccount =
            (stack.profile is AccountV2Profile
                ? (stack.profile as AccountV2Profile).accountId
                : null) ??
            failedLastUsed;
        if (failedAccount != null) {
          await accountStore.clearAccount(failedAccount);
        }
        bool matchesAccount(DeviceProfile p) =>
            failedAccount != null &&
            p is AccountV2Profile &&
            (p.accountId == failedAccount ||
                (p.accountId == null && failedLastUsed == failedAccount));
        // 同步快照+摘表先行（对照 disposeStacksForAccount 已修范式，开源
        // 审查 /：旧实现"先 await dispose 后 removeWhere"的
        // 窗口内 activate 新建的栈会被尾部谓词摘表成孤儿——连接活着但
        // 注册表查不到且永远拆不掉）。本栈恒拆（兜底失败也拆）。
        final doomed = <String, ComputerStack>{};
        for (final entry in List.of(_stacks.entries)) {
          if (matchesAccount(entry.value.profile) ||
              identical(entry.value, stack)) {
            doomed[entry.key] = entry.value;
            entry.value.removeListener(_onStackChanged);
            _stacks.remove(entry.key);
            _stackAccountBySid.remove(entry.key);
          }
        }
        _deleting.addAll(doomed.keys);
        try {
          for (final entry in doomed.entries) {
            final doomedSid = entry.key;
            try {
              await entry.value.disposeStack();
            } catch (e) {
              // 逐栈容错：单栈 dispose 抛出不得中断其余
              // 匹配栈的拆除（否则僵尸栈带着已清凭据继续重连循环）。
              _onLog('dispose stack on auth-required failed (contained): $e');
            }
            _notifyCoordinatorProvider()
                ?.detachStack(doomedSid, ifStack: entry.value);
            _failureBySid.remove(doomedSid);
          }
        } finally {
          _deleting.removeAll(doomed.keys);
        }
        // 活跃指针+持久 sid 收尾（对齐 disposeStacksFor
        // Account 的指针段）：拆的是活跃栈时清指针——防冷启自动激活凭据
        // 已失效的档案（重复"连→401→拆"循环）。失败横幅保留（2 分钟窗），
        // relayDiagnosis 对 auth-required 放行 offline 档（见该 getter），
        // 重登引导可达；档案保留，重登后的接回由 reattachAfterAccountLogin
        // 负责。
        if (activeSid != null && doomed.containsKey(activeSid)) {
          activeSid = null;
          activeProfile = null;
          // 收尾即确定落定：await 持久 sid 清（冷启不自动激活失效档案）。
          await _persistActiveDeviceSid(null);
        }
      case 'session-not-found':
      case 'session-expired':
      case 'invalid-mobile-connection':
      case 'auth-failed':
        final profile = profileOf(sid) ?? stack.profile;
        final updated = profile.copyWith(invalid: true);
        _stacks.remove(sid);
        _stackAccountBySid.remove(sid);
        stack.removeListener(_onStackChanged);
        // 逐栈容错+收尾对齐：dispose 抛出
        // 此前会中断后续 store/reload 收尾；detachStack/_failureBySid 清
        // 理对齐 removeComputer（残留仅卫生账：协调器侧重挂幂等自愈，
        // _failureBySid 2 分钟自过期）。
        _deleting.add(sid);
        try {
          await stack.disposeStack();
        } catch (e) {
          _onLog('dispose stack on invalid-connection failed (contained): $e');
        } finally {
          _deleting.remove(sid);
        }
        _notifyCoordinatorProvider()?.detachStack(sid, ifStack: stack);
        _failureBySid.remove(sid);
        await store.updateProfile(updated);
        await reloadProfiles();
      case 'device-not-owned':
      case 'kicked':
      case 'desktop-disconnected':
        break;
      default:
        break;
    }
    if (_disposed) return;
    _onNotify();
  }

  /// 释放注册表（状态层批：返回 Future——AppState.dispose 需在全部栈
  /// disposeStack/flush 落定后再关缓存）。逐栈容错：单栈抛出不阻断其余。
  /// 各栈 dispose 先同步启动（测试/调用方丢弃 Future 时 disposeCalls 仍
  /// 立即计数），再统一等待落定。
  Future<void> dispose() {
    if (_disposed) return Future<void>.value();
    _disposed = true;
    final stacks = List<ComputerStack>.of(_stacks.values);
    _stacks.clear();
    _stackAccountBySid.clear();
    final futures = <Future<void>>[];
    for (final stack in stacks) {
      stack.removeListener(_onStackChanged);
      futures.add(
        stack.disposeStack().catchError((Object e) {
          _onLog('dispose stack on registry dispose failed (contained): $e');
        }),
      );
    }
    return Future.wait(futures).then((_) {});
  }
}

/// 换账号重扫同一台电脑时的确认需求（multi-account-ux-1 批2）。
/// 调用方捕获后弹「该电脑当前绑定 {旧账号}，改为 {新账号}？」；确认后
/// 以 `addV2Profile(..., forceRebind: true)` 重调完成改绑。
class AccountRebindRequired implements Exception {
  const AccountRebindRequired({
    required this.deviceSid,
    required this.deviceLabel,
    required this.fromAccountId,
    required this.toAccountId,
  });
  final String deviceSid;
  final String deviceLabel;
  final String fromAccountId;
  final String toAccountId;
}

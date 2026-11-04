import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart' hide Text;

import '../core/l10n.dart';
import '../core/localized_text.dart';
import '../core/payload_guard.dart';
import '../core/theme.dart';
import '../core/usage_format.dart';
import '../core/usage_timezone.dart';
import '../state/app_state.dart';
import '../state/app_state_scope.dart';
import '../transport/channel_client.dart';
import '../transport/companion_client.dart';
import 'coding_plan_reset.dart';
import 'usage_charts.dart';

/// 用量数据短缓存（2026-10-26 真机验收④）：此前 cp/app 缓存按档**永久**
/// 命中（进页拉一次后不再更新，除非手动下拉）——用户体感"统计不是实时的"。
/// 改为带 TTL 的 SWR 缓存 + 页面停留期周期性非强制刷新；纯类供单测。
class UsageSnapshotCache<T> {
  UsageSnapshotCache(this.ttl);
  final Duration ttl;
  final Map<String, (T, DateTime)> _entries = {};

  /// 命中返回未过期值；过期/缺失返回 null（调用方重拉）。
  T? get(String key, DateTime now) {
    final e = _entries[key];
    if (e == null) return null;
    if (now.difference(e.$2) >= ttl) return null;
    return e.$1;
  }

  /// 不看 TTL 的渲染兜底（SWR：刷新窗口期继续显示旧值，不闪空页）。
  T? peek(String key) => _entries[key]?.$1;

  void put(String key, T value, DateTime now) {
    _entries[key] = (value, now);
  }

  /// 全量清空（ N2-7：系统时区变化后缓存键整体失效——按键
  /// 隔离的旧时区条目不会再被命中，但清掉省内存且防 peek 兜底取旧时区值）。
  void clear() => _entries.clear();
}

/// 使用统计页（③重构，2026-10-17，对齐桌面端两栏结构）。
///
/// 数据源（全部经 usage-stats 通道，官方 refs/ZCode 源码核实）：
/// - getEntitlementSnapshot：须带 preferredProviderId+accountAccess（静态访问
///   类别 {type:zhipu-account, accountType, mode, entitled}）——缺失时官方
///   resolveAuthorization 对 coding plan provider 直接返回 null（此前
///   not_configured 的根因，bigmodelUsageQuotaProvider.ts:861）。
/// - getCodingPlanUsageSnapshot：活跃度/热力图/模型趋势（monitor 接口）。
/// - getAppUsageSnapshot：agent 数据库真实统计（累计/峰值/连续天数等）。
///
/// 展示口径：quota percentage=已使用占比，剩余=100-已用（官方
/// codingPlanQuotaPresentation.getQuotaRemainingPercentage）。
class UsagePage extends StatefulWidget {
  const UsagePage({super.key});

  @override
  State<UsagePage> createState() => _UsagePageState();
}

class _UsagePageState extends State<UsagePage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  // ── 个人套餐 tab ──
  Map<String, dynamic>? _ent;
  Map<String, dynamic>? _cp;

  /// 额度卡成功但图表聚合拉取失败且无旧图可保留（首载即失败）时置位，
  /// 出内联提示而非静默空白（H15-2，2026-10-29 批次）。
  bool _cpChartFailed = false;
  bool _cpLoading = true;
  String? _cpError;
  String _family = 'bigmodel';
  bool _familyFallbackTried = false;

  /// 套餐来源（2026-10-27 用户其他需求④）：个人套餐 / Start Plan。
  String _planKind = 'individual-coding-plan';

  /// A4（2026-10-24 修复批）stale-while-revalidate：已有数据时切档/
  /// 刷新不整页转圈——保留旧值渲染，列表顶部细进度条示刷新中；
  /// entitlement 成功态短期缓存（2min 内切档复用，只拉档聚合）。
  bool _cpRefreshing = false;
  DateTime? _entLoadedAt;
  static const _entCacheTtl = Duration(minutes: 2);

  /// 批①（2026-10-23）：个人套餐范围三档（官方 CodingPlanUsageRange
  /// today/7d/30d——原写死 30d，用户想看今日/近一周被堵死）；按档缓存。
  /// ④（2026-10-26 真机验收）：改 60s TTL——旧实现按档永久命中，统计
  /// 不再更新（"不是实时的"根因）；SWR 语义不变（命中渲染旧值不转圈）。
  final UsageSnapshotCache<Map<String, dynamic>> _cpCache = UsageSnapshotCache(
    const Duration(seconds: 60),
  );
  String _cpRange = '30d';
  String get _cpCacheKey => usageCacheKey('$_cpRange-$_planKind', _timeZone);

  // ── 应用用量 tab ──
  final UsageSnapshotCache<Map<String, dynamic>> _appCache = UsageSnapshotCache(
    const Duration(seconds: 60),
  );
  String _appRange = '30d';
  String get _appCacheKey => usageCacheKey(_appRange, _timeZone);
  bool _appLoading = true;
  String? _appError;

  /// 请求代际号（ N2-2）：_loadPlan/_loadApp 各自单调递增，在途
  /// 响应携带的代际落后当前时整体丢弃（防旧档数据落新档缓存/覆盖 UI）。
  int _planGeneration = 0;
  int _appGeneration = 0;

  /// ④：页面停留期周期刷新（60s 与缓存 TTL 同频——非强制，命中缓存时
  /// 是空操作，过期才真拉；SWR 不打断阅读）。手动下拉仍 force 立即拉。
  Timer? _refreshTimer;

  // ── 重置额度礼包（2026-10-26 用户："手机端现在是看不见重置的"）──
  /// 桌面 quota-reset 复刻：状态 60s TTL + 单机会倒计时秒针（仅页面
  /// 打开期间走表）；申领新机会只在开页时问一次（10min 节流对齐官方
  /// 协调器冷却档——桌面常驻轮询挂机收礼包的形态不搬，电量红线）。
  CodingPlanResetStatus? _resetStatus;
  DateTime? _resetLoadedAt;
  static const _resetCacheTtl = Duration(seconds: 60);
  DateTime? _opportunityAskedAt;

  /// 使用中忙态（ValueNotifier：底部弹层与确认框都在别的 route 上，
  /// 页面 setState 不会重建它们——按钮禁用走 notifier 监听）。
  final ValueNotifier<bool> _resetBusy = ValueNotifier(false);

  /// 每日趋势柱状图点选：null=默认末柱（最新一天）；_trendShowTotal=true
  /// 为取消选中态（明细行显示区间合计）。切换时间范围时两者一并重置。
  int? _trendSelected;
  bool _trendShowTotal = false;

  /// 应用用量「按模型趋势」点选：末点默认/再点同点=区间合计。
  int? _modelTrendSelected;
  bool _modelTrendShowTotal = false;

  /// 批①：个人套餐折线图点选（默认末点/取消=区间合计）与应用用量
  /// 饼图切片点选（null=合计提示行）。随范围切换重置。
  int? _lineSelected;
  bool _lineShowTotal = false;
  int? _pieSelected;

  bool _initialLoadPending = true;

  /// 本地 IANA 时区（应用用量/个人套餐按自然日归桶；缓存同键隔离）。
  String? _timeZone;

  // AppStateScope.of 不能在 initState 里同步调用（阶段 1 根因陷阱）。
  @override
  void initState() {
    super.initState();
    // 电量速赢（battery-measure 2026-10-28 静态排查嫌疑②）：退后台暂停
    // 60s 刷新/秒针定时器——桥活着时每次刷新都是一次 radio 唤醒。
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialLoadPending) {
      _initialLoadPending = false;
      _deriveFamily();
      unawaited(_initializeUsagePage());
    }
    // 18077 验收#18（Bug R）：网络恢复自动重试——错误态下连接回到
      // online 边沿即重拉两档，不再要求用户退出重进。
    _armRecoveryWatch();
  }

  // ── 恢复重试（Bug R）──────────────────────────────────────────
  AppState? _recoveryAppRef;
  LinkPhase? _lastSeenPhase;

  void _armRecoveryWatch() {
    if (_recoveryAppRef != null || !mounted) return;
    final app = AppStateScope.of(context);
    _recoveryAppRef = app;
    _lastSeenPhase = app.phase;
    app.addListener(_onAppChangedForRecovery);
  }

  void _onAppChangedForRecovery() {
    final app = _recoveryAppRef;
    if (app == null || !mounted) return;
    final phase = app.phase;
    final backOnline =
        _lastSeenPhase != LinkPhase.online && phase == LinkPhase.online;
    _lastSeenPhase = phase;
    if (!backOnline) return;
    // N1 P3-8：后台的重连边沿不 force 双拉（每次 4 个 RPC 绕过
    // 两级缓存=无线电唤醒，电量红线同族漏网口）——回前台时 resumed 分支
    // 的常规刷新已兜住错误态重试（失败态不落缓存，非 force 也会真拉）。
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    final hasError = _appError != null || _cpError != null;
    final stuckLoading = _appLoading || _cpLoading;
    if (hasError || stuckLoading) {
      debugPrint('[usage] back online -> auto retry');
      _loadPlan(force: true);
      _loadApp(force: true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _armRefreshTimers();
      unawaited(_maybeRefreshTimeZone());
      // 回前台立即刷一轮（SWR：用户回来看新数据，不等下一个 60s 拍）。
      _loadPlan();
      _loadApp();
    } else if (state == AppLifecycleState.paused) {
      _refreshTimer?.cancel();
      _refreshTimer = null;
    }
  }

  /// 回前台重读系统时区（ N2-7）：页面在导航栈长驻时 _timeZone
  /// 此前终身只读一次——出差改时区后缓存键与请求仍用旧时区（归桶偏移
  /// 与时区隔离修复都被绕过）。变化时清缓存 force 重拉。
  Future<void> _maybeRefreshTimeZone() async {
    final tz = await readDeviceTimeZone();
    if (!mounted || tz == _timeZone) return;
    debugPrint('[usage] timezone changed $_timeZone -> $tz, re-pull');
    _timeZone = tz;
    _cpCache.clear();
    _appCache.clear();
    _loadPlan(force: true);
    _loadApp(force: true);
  }

  /// 重建周期定时器（首载与回前台共用；重复调用前先取消旧定时器）。
  void _armRefreshTimers() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!mounted) return;
      // N2-4：页面被其他路由覆盖时（State 不 dispose、mounted
      // 恒真）不空转双路 RPC——电量红线同族漏网档。
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) return;
      _loadPlan();
      _loadApp();
    });
  }

  Future<void> _initializeUsagePage() async {
    _timeZone = await readDeviceTimeZone();
    if (!mounted) return;
    _loadPlan();
    _loadApp();
    _armRefreshTimers();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recoveryAppRef?.removeListener(_onAppChangedForRecovery);
    _refreshTimer?.cancel();
    // N3 P3-7：ChangeNotifier 处置惯例（监听者随弹层卸载，无
    // 实际泄漏，补齐 dispose 契约）。
    _resetBusy.dispose();
    _tabs.dispose();
    super.dispose();
  }

  void _selectPlanKind(String kind) {
    if (kind == _planKind) return;
    setState(() {
      _planKind = kind;
      _ent = null;
      _cp = null;
      _cpError = null;
      _entLoadedAt = null;
      _resetStatus = null;
      _resetLoadedAt = null;
      // N1 P3-7/N3 P3-8：切换套餐来源复位家族回退标记——否则
      // 一次回退后终身置位，换档后应换族重试的场景被拦死成「未开通」。
      _familyFallbackTried = false;
    });
    _loadPlan(force: true);
  }

  /// 从活跃会话的 config.provider 推断家族（zai/bigmodel），无会话时默认
  /// bigmodel；entitlement 不可用时再回退尝试另一家族。
  void _deriveFamily() {
    final app = AppStateScope.of(context);
    for (final state in app.conversationStates.values) {
      final cfg = state.snapshot?['config'];
      final provider = cfg is Map ? '${cfg['provider'] ?? ''}' : '';
      if (provider.contains('zai')) {
        _family = 'zai';
        return;
      }
      if (provider.contains('bigmodel')) {
        _family = 'bigmodel';
        return;
      }
    }
  }

  String get _providerId => 'account:$_family-$_planKind';

  Map<String, dynamic> get _accountAccess =>
      codingPlanScope(_family, _planKind)['accountAccess']
          as Map<String, dynamic>;

  Future<void> _loadPlan({bool force = false}) async {
    // 请求代际（ N2-2）：弱网在途窗口（12s 超时）内切档，旧档
    // 响应按"新档缓存键"落盘会把 7 天数据写进 30 天桶——代际号+缓存键
    // 在 await 前捕获，过期响应整体丢弃。
    final gen = ++_planGeneration;
    final cacheKey = _cpCacheKey;
    final app = AppStateScope.of(context);
    final bridge = app.bridge;
    if (!mounted || bridge == null) {
      setState(() {
        // SWR 保旧值（对齐失败分支 H15-2 语义）：栈被拆时已有数据不翻
        // 「未连接电脑」错误页顶掉在屏内容；仅首载无数据才出错误页。
        if (_ent == null) _cpError = '未连接电脑';
        _cpLoading = false;
        _cpRefreshing = false;
      });
      return;
    }
    // A4：entitlement 短期缓存命中（成功态且 2min 内）不重拉——切档
    // 只取档聚合；force（手动刷新/下拉）绕过。
    final entCached =
        !force &&
        _ent != null &&
        _entLoadedAt != null &&
        DateTime.now().difference(_entLoadedAt!) < _entCacheTtl;
    setState(() {
      // A4 SWR：已有数据不整页转圈（修复前档缓存命中也全页 spinner
      // 挡住已渲染内容）；仅首载无数据时全页 spinner。
      _cpLoading = _ent == null && _cp == null;
      _cpRefreshing = true;
      _cpError = null;
    });
    try {
      Map<String, dynamic>? ent = _ent;
      var reason = '';
      if (entCached) {
        reason = ''; // 缓存的必为成功态（失败态不落 _entLoadedAt）
      } else {
        ent = await _callEntitlement(bridge);
        reason = ent == null
            ? 'no_bridge'
            : '${ent['unavailableReason'] ?? ''}';
        debugPrint(
          '[usage] entitlement family=$_family reason=$reason '
          'provider=${ent?['provider']}',
        );
        // N3 P2-3：entitlement 最长 12s，期间用户可能已退出页面
        // ——回退递归前先查 mounted（递归入口的 AppStateScope.of 会作用于
        // defunct element）。
        if (!mounted) return;
        if ((reason == 'not_configured' || reason == 'no_plan') &&
            !_familyFallbackTried) {
          // 家族猜错（如 zai 账号但活跃会话在 bigmodel provider 上）→ 换族重试一次。
          _family = _family == 'bigmodel' ? 'zai' : 'bigmodel';
          _familyFallbackTried = true;
          debugPrint(
            '[usage] entitlement unavailable -> fallback family=$_family',
          );
          await _loadPlan();
          return;
        }
      }
      Map<String, dynamic>? cp;
      if (reason.isEmpty) {
        cp =
            (!force ? _cpCache.get(cacheKey, DateTime.now()) : null) ??
            await _callCodingPlanUsage(bridge, range: _cpRange);
        // 只缓存成功态（问题② 2026-10-25）：失败 null 也落缓存时，一次
        // 瞬时失败（中继超时等）后该档永远空图表，切档也不会重试，只能
        // 手动下拉——个人套餐热力图「不显示」的持久化路径。
        // put 用捕获键+完成时刻（ N2-2/N1：避免慢响应按请求时刻
        // 计 TTL 缩短有效新鲜度）。
        if (cp != null && gen == _planGeneration) {
          _cpCache.put(cacheKey, cp, DateTime.now());
        }
      }
      if (!mounted || gen != _planGeneration) return;
      if (!mounted) return;
      setState(() {
        if (reason.isEmpty) {
          _ent = ent;
          _entLoadedAt = entCached ? _entLoadedAt : DateTime.now();
          // N2-10/N3 P3-8：成功态复位家族回退标记——下次失败
          // （换 provider 后猜错家族）允许再回退一次，而非页面终身一次。
          _familyFallbackTried = false;
          // H15-2（2026-10-29 批次）：额度卡成功但图表聚合失败（cp=null，
          // _callCodingPlanUsage 吞异常降级）时保留旧图，对齐 _ent 的
          // 失败保留策略——强刷失败不再清空已渲染的图表；仅首载无旧图
          // 才置图表失败位出内联提示。
          if (cp != null) {
            _cp = cp;
            _cpChartFailed = false;
          } else if (_cp == null) {
            _cpChartFailed = true;
          }
          _cpError = null;
        } else {
          // 失败态不缓存；已有旧数据时保留旧值（SWR 不翻错误页遮内容），
          // 仅首载失败出错误页。
          _entLoadedAt = null;
          if (_ent == null) {
            _cpError = switch (reason) {
              'not_configured' =>
                _planKind == 'start-plan'
                    ? '当前账号未开通 Start Plan（可切回个人套餐查看）。'
                    : '未找到已连接的编程套餐账号（桌面端登录智谱账号后可查看）。',
              'not_authenticated' => '登录后查看剩余额度。',
              'no_plan' => '暂无有效编程套餐。',
              'unavailable' => '额度服务暂不可用，稍后重试。',
              _ => '暂无可展示的权益数据。',
            };
          }
        }
        _cpLoading = false;
        _cpRefreshing = false;
      });
      // 重置额度礼包与套餐档同源同路（bridge 已在上方非空短路；失败
      // 静默不扰套餐面）。 N2-6：礼包是增益面（自带静默失败），
      // 不再 await 拖住 RefreshIndicator——force 下两段 RPC 各 15s 超时
      // 会让转圈在额度卡就绪后再挂 15-30s。
      unawaited(_loadResetStatus(bridge, force: force));
    } catch (e) {
      debugPrint('[usage] plan load error: $e');
      if (mounted) {
        setState(() {
          // SWR：已有数据保留旧值+顶部指示消失，不整页翻错。
          if (_ent == null) {
            // 18077 验收#18 + N2-12/N3 P3-6：超时/断连/其它异常
            // 统一人话分类，原始异常只进日志。
            _cpError =
                '${_friendlyLoadError(e)}\n'
                '${tr('（桌面需访问账号服务获取用量，网络不佳时会超时）')}';
          }
          _cpLoading = false;
          _cpRefreshing = false;
        });
      }
    }
  }

  /// 加载异常→人话（ N2-12/N3 P3-6）：TimeoutException/断连/
  /// ChannelRpcError 分档；原始异常串只进 debugPrint，不上屏。
  String _friendlyLoadError(Object e) {
    if (e is TimeoutException) return tr('网络不佳，加载超时');
    if (e is ChannelRpcError) return tr('额度服务暂不可用，稍后重试。');
    final msg = '$e';
    if (msg.contains('Socket') || msg.contains('Connection') || msg.contains('Network')) {
      return tr('网络连接不可用，请检查网络');
    }
    return tr('加载失败，请稍后重试');
  }

  Map<String, dynamic> get _resetScope => {
    'preferredProviderId': _providerId,
    'accountAccess': _accountAccess,
  };

  /// 重置额度礼包：申领（开页一次，10min 节流）→ 状态（60s TTL）。
  /// 两步都失败静默——礼包是增益面，不出错误页不扰套餐主内容。
  Future<void> _loadResetStatus(
    BridgeSession bridge, {
    required bool force,
  }) async {
    final now = DateTime.now();
    if (!force &&
        _resetLoadedAt != null &&
        now.difference(_resetLoadedAt!) < _resetCacheTtl) {
      return;
    }
    if (_opportunityAskedAt == null ||
        now.difference(_opportunityAskedAt!) >= const Duration(minutes: 10)) {
      try {
        await bridge.channels.call(
          Channels.usageStats,
          'requestCodingPlanResetOpportunity',
          [
            {
              ..._resetScope,
              'idempotencyKey': createResetIdempotencyKey(Random(), now),
            },
          ],
          timeout: const Duration(seconds: 15),
        );
        // N3 P3-10：成功后才吃掉 10min 节流——请求发出前置位时，
        // 瞬时失败（超时/断连）也会错过整个礼品窗；服务端本有 next_try_at
        // 冷却兜底，失败重发无害。
        _opportunityAskedAt = DateTime.now();
      } catch (_) {}
    }
    try {
      final res = await bridge.channels.call(
        Channels.usageStats,
        'getCodingPlanResetStatus',
        [_resetScope],
        timeout: const Duration(seconds: 15),
      );
      if (!mounted) return;
      setState(() {
        _resetStatus = res is Map
            ? CodingPlanResetStatus.parse(res.cast<String, dynamic>())
            : null;
        _resetLoadedAt = DateTime.now();
      });
    } catch (_) {}
  }

  /// 使用一次重置（官方 useCodingPlanReset：幂等键防重，resetType 二值）。
  /// N1/N2/N3（P1）：RPC 在飞最长 15s——期间确认框被系统返回键等关掉后，
  /// 旧实现的无条件双 pop 会把底部弹层连同用量页本体一起弹穿；改为按
  /// 路由栈实际形态逐层收口（只弹自己打开的那两层）。
  Future<void> _useReset(
    String resetType,
    BuildContext dialogContext,
    BuildContext sheetContext,
  ) async {
    final app = AppStateScope.of(context);
    final bridge = app.bridge;
    if (bridge == null || _resetBusy.value) return;
    final messenger = ScaffoldMessenger.of(context);
    _resetBusy.value = true;
    try {
      final res = await bridge.channels.call(
        Channels.usageStats,
        'useCodingPlanReset',
        [
          {
            ..._resetScope,
            'idempotencyKey': createResetIdempotencyKey(
              Random(),
              DateTime.now(),
            ),
            'resetType': resetType,
          },
        ],
        timeout: const Duration(seconds: 15),
      );
      final used = res is Map && res['used'] == true;
      if (!mounted) return;
      _popRouteIfCurrent(dialogContext); // 关确认框
      _popRouteIfCurrent(sheetContext); // 关弹层
      _resetLoadedAt = null; // 状态与额度都强制重拉
      messenger.showSnackBar(
        SnackBar(content: Text(used ? '重置成功' : '重置失败，请重试')),
      );
      unawaited(_loadPlan(force: true));
    } catch (_) {
      if (!mounted) return;
      _popRouteIfCurrent(dialogContext); // 关确认框
      messenger.showSnackBar(const SnackBar(content: Text('重置失败，请重试')));
    } finally {
      _resetBusy.value = false;
    }
  }

  /// 只在该 context 的路由仍是栈顶时才 pop——路由已被关掉（返回键/
  /// 手势）或页面已弹走时不误弹别的层（N1/N2/N3 双 pop 修复的收口）。
  void _popRouteIfCurrent(BuildContext routeContext) {
    if (!routeContext.mounted) return;
    final route = ModalRoute.of(routeContext);
    if (route == null || route.isFirst || !route.isCurrent) return;
    Navigator.of(routeContext).pop();
  }

  void _confirmReset(
    String resetType,
    String typeLabel,
    BuildContext sheetContext,
  ) {
    final label = tr(typeLabel);
    showDialog<void>(
      context: context,
      // N1/N2/N3：RPC 在飞期（最长 15s）确认框不可点屏障关闭——barrier
      // 关掉后成功路径的 pop 会与栈形态错位；取消钮同接 busy 态禁点。
      barrierDismissible: false,
      builder: (dialogContext) => ListenableBuilder(
        listenable: _resetBusy,
        builder: (dialogContext, _) => AlertDialog(
          title: Text('重置$label？'),
          content: Text('将消耗 1 次重置机会，立即重置$label的已用额度。'),
          actions: [
            TextButton(
              onPressed: _resetBusy.value
                  ? null
                  : () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: _resetBusy.value
                  ? null
                  : () => _useReset(resetType, dialogContext, sheetContext),
              child: const Text('重置'),
            ),
          ],
        ),
      ),
    );
  }

  void _showResetSheet() {
    final status = _resetStatus;
    if (status == null || !status.hasAny) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.colors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.card),
        ),
      ),
      builder: (sheetContext) => SafeArea(
        child: ListenableBuilder(
          listenable: _resetBusy,
          builder: (sheetContext, _) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 32,
                    height: 4,
                    decoration: BoxDecoration(
                      color: context.colors.border,
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(0, 12, 0, 4),
                  child: Text(
                    '可重置额度',
                    style: TextStyle(
                      fontSize: AppType.uiBase,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  '重置会立即清空对应窗口的已用额度；每次消耗 1 次重置机会。',
                  style: TextStyle(
                    fontSize: AppType.uiXs,
                    color: context.colors.foregroundSubtle,
                  ),
                ),
                const SizedBox(height: 8),
                _resetSheetRow(
                  sheetContext,
                  '5 小时额度重置',
                  status.fiveHourCount,
                  status.fiveHourExpireAts,
                  'FIVE_HOUR',
                ),
                _resetSheetRow(
                  sheetContext,
                  '周额度重置',
                  status.weekCount,
                  status.weekExpireAts,
                  'WEEK',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _resetSheetRow(
    BuildContext sheetContext,
    String title,
    int count,
    List<int> expireAts,
    String resetType,
  ) {
    final now = DateTime.now();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: const TextStyle(fontSize: AppType.uiBase)),
      subtitle: Text(
        resetRowSubtitle(count, expireAts, now),
        style: TextStyle(
          fontSize: AppType.uiXs,
          color: context.colors.foregroundSubtle,
        ),
      ),
      trailing: FilledButton(
        onPressed: count > 0 && !_resetBusy.value
            ? () => _confirmReset(
                resetType,
                title.replaceAll('额度重置', ''),
                sheetContext,
              )
            : null,
        // N3 P3-9：40<44dp 触控纪律下限。
        style: FilledButton.styleFrom(minimumSize: const Size(64, 44)),
        child: const Text('重置'),
      ),
    );
  }

  Future<Map<String, dynamic>?> _callEntitlement(BridgeSession bridge) async {
    // 18077 验收#18（Bug Q）：页面级 12s 超时——断网时 transport 层
    // 挂死不抛错（RPC 30s 也不触发），用户永远转圈。
    final res = await bridge.channels
        .call(
          Channels.usageStats,
          'getEntitlementSnapshot',
          [
            {
              'includeSubscription': true,
              'preferredProviderId': _providerId,
              'accountAccess': _accountAccess,
              'allowDisabledPreferredProvider': true,
            },
          ],
          timeout: const Duration(seconds: 30),
        )
        .timeout(const Duration(seconds: 12));
    return res is Map ? res.cast<String, dynamic>() : null;
  }

  Future<Map<String, dynamic>?> _callCodingPlanUsage(
    BridgeSession bridge, {
    String range = '30d',
  }) async {
    try {
      // 18077 验收#18（Bug Q）：同 _callEntitlement 的页面级超时。
      final res = await bridge.channels
          .call(
            Channels.usageStats,
            'getCodingPlanUsageSnapshot',
            [
              {
                'range': range,
                'preferredProviderId': _providerId,
                'accountAccess': _accountAccess,
                if (_timeZone != null) 'timeZone': _timeZone,
              },
            ],
            timeout: const Duration(seconds: 30),
          )
          .timeout(const Duration(seconds: 12));
      return res is Map ? res.cast<String, dynamic>() : null;
    } catch (e) {
      // 额度卡可用而图表聚合失败时只降级图表，不拖垮整页。
      debugPrint('[usage] coding plan usage failed: $e');
      return null;
    }
  }

  Future<void> _loadApp({bool force = false}) async {
    // 请求代际+缓存键捕获（ N2-2：在途切档防旧档数据落新档桶）。
    final gen = ++_appGeneration;
    final cacheKey = _appCacheKey;
    // ④：60s TTL 内非强制命中直接返回（旧实现永久命中——统计不更新根因）。
    if (!force && _appCache.get(cacheKey, DateTime.now()) != null) {
      // N1 P3-11：命中早退顺带清残留错误行——错误态下缓存条目
      // 仍在 TTL 内时（重试成功过一档），周期 tick 早退会让旧错误行挂到
      // 下一拍。
      if (_appError != null) setState(() => _appError = null);
      return;
    }
    final app = AppStateScope.of(context);
    final bridge = app.bridge;
    if (!mounted || bridge == null) {
      setState(() {
        // 错误行由 build 内联在旧数据下方（SWR 保旧值，对齐套餐 tab）
        // ——栈被拆时不整段顶掉已在屏的图表。
        // N1 P2-1：预译（渲染端 '加载失败：{x}' 走 pattern，
        // 占位不递归——赋值处先 tr 防止捕获段残留中文）。
        _appError = tr('未连接电脑');
        _appLoading = false;
      });
      return;
    }
    setState(() {
      _appLoading = true;
      _appError = null;
    });
    try {
      // 18077 验收#18（Bug Q）：页面级 12s 超时——断网时 transport 挂死
      // 连 RPC 30s 都不触发，永远转圈；超时进错误态（人话+重试钮）。
      final res = await bridge.channels
          .call(
            Channels.usageStats,
            'getAppUsageSnapshot',
            [appUsageParams(_appRange, _timeZone)],
            timeout: const Duration(seconds: 30),
          )
          .timeout(const Duration(seconds: 12));
      final data = res is Map ? res.cast<String, dynamic>() : null;
      debugPrint(
        '[usage] app range=$_appRange tz=${data?['timeZone']} '
        'end=${mapOf(data?['heatmap'])?['endDate']} '
        'peak=${mapOf(data?['summary'])?['peakDayTokens']}',
      );
      if (!mounted || gen != _appGeneration) return;
      setState(() {
        // 只缓存成功态（对齐个人套餐档：失败态落缓存会把一次瞬时失败
        // 钉成永久空页）。
        if (data != null) {
          _appCache.put(cacheKey, data, DateTime.now());
        } else if (_appCache.peek(cacheKey) == null) {
          // N2-11：空体/非 Map 响应不再静默——无旧值可渲染时
          // 给人话错误（此前页面只剩档位 chip 的静默空白）。
          _appError = tr('数据为空，请稍后重试');
        }
        _appLoading = false;
      });
    } catch (e) {
      debugPrint('[usage] app load error: $e');
      if (mounted) {
        setState(() {
          // N1/N2/N3（SWR 对齐套餐 tab H15-2）：重验失败不整段顶掉在屏
          // 内容——错误行由 build 内联在 peek 旧值下方，仅首载无旧值时
          // 独占展示。
          // 18077 验收#18 + N2-12/N3 P3-6：异常人话分类。
          _appError = _friendlyLoadError(e);
          _appLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('使用统计', style: TextStyle(fontSize: AppType.uiLg)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _loadPlan(force: true);
              _loadApp(force: true);
            },
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          labelColor: context.colors.foreground,
          unselectedLabelColor: context.colors.foregroundSubtle,
          indicatorColor: context.colors.foreground,
          dividerColor: context.colors.border,
          tabs: [
            Tab(child: Text('个人套餐')),
            Tab(child: Text('应用用量')),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [_buildPlanTab(), _buildAppTab()],
      ),
    );
  }

  // ── 个人套餐 ────────────────────────────────────────────────

  Widget _buildPlanTab() {
    if (_cpLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 28,
              width: 28,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(height: 12),
            Text(
              '正在获取额度（需访问账号服务，网络不佳时较慢）',
              style: TextStyle(
                fontSize: AppType.uiCaption,
                color: context.colors.foregroundSubtle,
              ),
            ),
          ],
        ),
      );
    }
    if (_cpError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                // N1 P2-1：去掉 translate:false——五条 reason
                // 人话均已入词典（超时分支赋值处已预译为纯英文，tr 对无
                // CJK 串原样返回，不受影响）。
                _cpError!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppType.uiCaption,
                  color: context.colors.foregroundSubtle,
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _loadPlan, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _loadPlan(force: true),
      child: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(16),
        children: [
          // A4 SWR 局部刷新指示：切档/重验证期细进度条（旧值仍在下方渲染）。
          if (_cpRefreshing)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          // 批①：范围三档（官方 CodingPlanUsageRange；今日档下折线为
          // 小时粒度）。切换即取档缓存/拉取，折线点选重置。
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final r in const [
                ('today', '今日'),
                ('7d', '近 7 天'),
                ('30d', '近 30 天'),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(r.$2),
                    selected: _cpRange == r.$1,
                    onSelected: (_) {
                      if (_cpRange == r.$1) return;
                      setState(() {
                        _cpRange = r.$1;
                        _lineSelected = null;
                        _lineShowTotal = false;
                      });
                      _loadPlan();
                    },
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 8,
              children: [
                for (final entry in const [
                  ('individual-coding-plan', '个人套餐'),
                  ('start-plan', 'Start Plan'),
                ])
                  ChoiceChip(
                    key: ValueKey('plan-kind-${entry.$1}'),
                    label: Text(entry.$2),
                    selected: _planKind == entry.$1,
                    onSelected: (_) => _selectPlanKind(entry.$1),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _buildQuotaCards(),
          if (_resetStatus?.hasAny == true) ...[
            const SizedBox(height: 8),
            Center(
              // N1 P3-4/N3 P3-1：秒针收进徽标自带 Timer——此前
              // 页面级 1Hz setState 重建整页（双 tab 全部子树）；多机会/
              // 小时以上档每秒产物相同，30s 一拍足够。
              child: _ResetBadge(status: _resetStatus!, onPressed: _showResetSheet),
            ),
          ],
          if (_subscriptionLine() != null) ...[
            const SizedBox(height: 8),
            _subscriptionLine()!,
          ],
          if (_cpChartFailed) ...[
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 14,
                    color: context.colors.foregroundSubtle,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      tr('图表数据获取失败，额度卡不受影响；下拉可重试'),
                      style: TextStyle(
                        fontSize: AppType.uiCaption,
                        color: context.colors.foregroundSubtle,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          // N1 P3-3：section 构建函数只调一次（原 null 检查+
          // 取值各调一次，解析/排序/建序列全部翻倍）。
          if (_activitySection() case final activity?) ...[
            const SizedBox(height: 14),
            activity,
          ],
          if (_cpHeatmap() case final heat?) ...[
            const SizedBox(height: 14),
            heat,
          ],
          if (_cpTrend() case final trend?) ...[const SizedBox(height: 14), trend],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// 剩余额度四卡：5 小时窗口 / 每周 / 每月工具 / ZCode MCP
  /// （官方 CodingPlanUsagePanel cards + resolveMcpQuotaLimit 同构）。
  Widget _buildQuotaCards() {
    final quota = _ent?['quota'];
    final limits = quota is Map ? listOf(quota['limits']) : null;
    final mcpAggregate = () {
      final mcp = _ent?['mcpQuota'];
      return mcp is Map ? mcp['aggregate'] : null;
    }();
    final cards = <({String label, Map<String, dynamic>? limit, Color color})>[
      (
        label: '5 小时窗口',
        limit: findQuotaLimit(limits, tokenKind: true, unit: 3, number: 5),
        color: context.charts.series[0],
      ),
      (
        label: '每周用量',
        limit: findQuotaLimit(limits, tokenKind: true, unit: 6),
        color: context.charts.series[1],
      ),
      (
        label: '每月工具调用',
        limit: findQuotaLimit(limits, tokenKind: false),
        color: context.charts.series[2],
      ),
      (
        label: 'ZCode MCP',
        limit: mcpAggregate is Map
            ? mcpAggregate.cast<String, dynamic>()
            : null,
        color: context.charts.series[3],
      ),
    ]..removeWhere((c) => c.limit == null);
    if (cards.isEmpty) {
      final remaining = _ent?['remaining'];
      if (remaining is Map && remaining['isShow'] == true) {
        return _quotaCard(
          '剩余额度',
          remaining.cast<String, dynamic>(),
          context.charts.series[0],
        );
      }
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '剩余额度',
                style: TextStyle(
                  fontSize: AppType.uiBase,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              '刷新于 ${_refreshedAt()}',
              style: TextStyle(
                fontSize: AppType.uiSm,
                color: context.colors.foregroundSubtlest,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final c in cards) ...[
          _quotaCard(c.label, c.limit!, c.color),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  String _refreshedAt() {
    // 数字守卫（ N2-5）：serverTime/generatedAt 漂移成 ISO 字符串
    // 时不再整段抛错，安全退 '-'。
    final ms =
        numOf(_ent?['serverTime']) ?? numOf(_ent?['generatedAt']);
    // 上界守卫（ N1 P3-5）：超 Dart epoch 合法域（±8.64e15ms）
    // 的畸形值在 build 链上抛 ArgumentError——退 '-'。
    if (ms == null || ms < 0 || ms > 8640000000000000) return '-';
    final t = DateTime.fromMillisecondsSinceEpoch(ms.toInt()).toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.month)}/${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  Widget _quotaCard(String label, Map<String, dynamic>? limit, Color color) {
    final remainPct = quotaRemainingPercent(limit);
    final fraction = quotaUsageFraction(limit);
    final reset = formatResetTime(limit?['nextResetTime']);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: context.colors.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: context.colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(fontSize: AppType.uiSm),
                ),
              ),
              Text(
                '${remainPct >= 10 ? remainPct.toStringAsFixed(0) : remainPct.toStringAsFixed(1)}%',
                style: TextStyle(
                  fontSize: AppType.uiLg,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (remainPct / 100).clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: context.colors.sidebar,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            [
              if (fraction != null)
                '${tr('已用')} ${tr(fraction.$1)} / ${tr(fraction.$2)}',
              if (reset.isNotEmpty) '${tr('重置')} $reset',
            ].join(' · '),
            style: TextStyle(
              fontSize: AppType.uiSm,
              color: context.colors.foregroundSubtle,
            ),
          ),
        ],
      ),
    );
  }

  /// 订阅行：完整套餐信息。details[] 是 productName/billingCycle/renewTime/
  /// expireTime 的官方载体（refs usage-stats.ts:132-152），逐条列出（最多
  /// 2 条，更多"等 N 项"）；套餐名按官方规则 quota.level 优先、productName
  /// 回退（formatPlanName）。无订阅/无可展示字段 → 不渲染（兜底分支不变）。
  Widget? _subscriptionLine() {
    final sub = _ent?['subscription'];
    if (sub is! Map) return null;
    final quota = _ent?['quota'];
    final r = subscriptionDetailLines(
      quota is Map ? quota['level'] : null,
      sub.cast<String, dynamic>(),
    );
    if (r.lines.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in r.lines)
            Text(
              line,
              style: TextStyle(
                fontSize: AppType.uiSm,
                color: context.colors.foregroundSubtle,
              ),
            ),
          if (r.totalCount > r.lines.length)
            Text(
              '等 ${r.totalCount} 项',
              style: TextStyle(
                fontSize: AppType.uiSm,
                color: context.colors.foregroundSubtlest,
              ),
            ),
        ],
      ),
    );
  }

  /// 活跃度统计（官方 CodingPlanActivitySummary：累计/峰值/时长/连续天数）。
  Widget? _activitySection() {
    final activity = _cp?['activity'];
    final summary = activity is Map ? activity['summary'] : null;
    if (summary is! Map) return null;
    final rangeLabel = switch (_cpRange) {
      'today' => '今日',
      '7d' => '近 7 天',
      _ => '近 30 天',
    };
    return _sectionCard(
      L10n.resolvedLocale == 'en-US'
          ? '${tr('活跃度统计')} (${tr(rangeLabel)})'
          : '${tr('活跃度统计')}（${tr(rangeLabel)}）',
      _metricGrid([
        _Metric('累计 Token', formatTokens(numOf(summary['totalTokens']) ?? 0)),
        _Metric('单日峰值', formatTokens(numOf(summary['peakDailyTokens']) ?? 0)),
        _Metric(
          '使用时长',
          formatDurationMs(numOf(summary['totalUsageDurationMs']) ?? 0),
        ),
        _Metric(
          '连续天数',
          '${numOf(summary['currentStreakDays']) ?? 0} 天'
              '（最长 ${numOf(summary['longestStreakDays']) ?? 0}）',
        ),
        _Metric('常用模型', '${summary['favoriteModelName'] ?? '-'}'),
      ]),
    );
  }

  Widget? _cpHeatmap() {
    final activity = _cp?['activity'];
    final heatmap = activity is Map ? activity['heatmap'] : null;
    if (heatmap is! Map) return null;
    return _sectionCard('Token 活动热力图', UsageHeatmapView(heatmap));
  }

  /// 用量趋势：modelUsage.modelDataList top3 多折线。
  Widget? _cpTrend() {
    final mu = _cp?['modelUsage'];
    if (mu is! Map) return null;
    // xTime 守卫（ N2-5/N3-P2-1）：cast<String>() 是懒转换，
    // 非 String 元素的异常推迟到 painter 访问处（paint 期崩）——改
    // whereType 即时过滤。
    final xTime =
        listOf(mu['xTime'])?.whereType<String>().toList() ?? const [];
    final rawModels = mu['modelDataList'];
    if (xTime.isEmpty || rawModels is! List || rawModels.isEmpty) return null;
    final models =
        rawModels
            .whereType<Map>()
            .map((m) => m.cast<String, dynamic>())
            .toList()
          ..sort(
            (a, b) => (numOf(b['totalTokens']) ?? 0).compareTo(
              numOf(a['totalTokens']) ?? 0,
            ),
          );
    final top = models.take(3).toList();
    final series = <ChartSeries>[
      for (var i = 0; i < top.length; i++)
        ChartSeries(
          name: '${top[i]['modelName'] ?? '?'}',
          color: context.charts.series[i % context.charts.series.length],
          values: (listOf(top[i]['tokensUsage']) ?? const [])
              .map((v) => (numOf(v) ?? 0).toDouble())
              .toList(),
        ),
    ];
    if (series.isEmpty) return null;
    final n = xTime.length;
    final lastIdx = n - 1;
    final explicit = _lineSelected != null && _lineSelected! <= lastIdx
        ? _lineSelected
        : lastIdx;
    final selected = _lineShowTotal ? null : explicit;
    // 批①：点选明细行（默认末点；再点同点=取消，显示区间合计）。
    final detailText = selected == null
        ? barRangeTotalText(lineRangeTotal(series), formatTokens)
        : linePointDetailLine(
            date: xTime[selected],
            index: selected,
            series: series,
            formatter: formatTokens,
          );
    return _sectionCard(
      '用量趋势',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            detailText,
            style: TextStyle(
              fontSize: AppType.uiSm,
              color: context.colors.foregroundSubtle,
            ),
          ),
          const SizedBox(height: 6),
          UsageLineChartView(
            series: series,
            xLabels: xTime,
            valueFormatter: formatTokens,
            selectedIndex: selected,
            selectedColor: context.colors.foreground,
            onPointTap: (i) {
              final cur = _lineShowTotal ? null : (_lineSelected ?? lastIdx);
              setState(() {
                if (cur == i) {
                  _lineShowTotal = true;
                  _lineSelected = null;
                } else {
                  _lineShowTotal = false;
                  _lineSelected = i;
                }
              });
            },
          ),
          const SizedBox(height: 6),
          _chartLegend(series),
        ],
      ),
    );
  }

  // ── 应用用量 ────────────────────────────────────────────────

  Widget _buildAppTab() {
    // 渲染用 peek（SWR 旧值兜底）；刷新判定走 get（TTL）。
    final data = _appCache.peek(_appCacheKey);
    return RefreshIndicator(
      onRefresh: () => _loadApp(force: true),
      child: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final r in const [
                ('all', '全部'),
                ('7d', '近 7 天'),
                ('30d', '近 30 天'),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(r.$2),
                    selected: _appRange == r.$1,
                    onSelected: (_) {
                      setState(() {
                        _appRange = r.$1;
                        _trendSelected = null;
                        _trendShowTotal = false;
                        _modelTrendSelected = null;
                        _modelTrendShowTotal = false;
                        _pieSelected = null;
                      });
                      _loadApp();
                    },
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          // A4 一致化：无数据加载中才占位 spinner；有数据切档顶部细进度条。
          // N1/N2/N3（P1/P2，SWR 对齐套餐 tab）：重验期（60s 周期==TTL，
          // 每 tick 都会进 loading）与失败期都保留 peek 旧值渲染——进度
          // 条前置叠加、错误行内联在数据下方（同套餐 tab 图表失败提示的
          // 位置语义），不再整段替换已在屏的统计卡（旧 if/else-if 互斥链
          // 约每分钟让内容消失一次）。
          if (_appLoading && data == null)
            const Padding(
              padding: EdgeInsets.only(top: 48),
              child: Center(
                child: SizedBox(
                  height: 26,
                  width: 26,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else ...[
            if (_appLoading)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            if (data != null) ..._buildAppSections(data),
            if (!_appLoading && _appError != null)
              // 优化批 #4：错误行尾补重试按钮（原内联红字无出路）。
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  children: [
                    Expanded(
                      // N1 P2-1：整串交词典走
                      // `^加载失败：([\s\S]+)$` pattern（裸前缀 tr 不命中
                      // 词条；_appError 赋值处已预译）。
                      child: Text(
                        '加载失败：$_appError',
                        style: TextStyle(
                          fontSize: AppType.uiCaption,
                          color: context.colors.destructive,
                        ),
                      ),
                    ),
                    TextButton(onPressed: _loadApp, child: Text(tr('重试'))),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  List<Widget> _buildAppSections(Map<String, dynamic> data) {
    final summary = data['summary'];
    final s = summary is Map ? summary.cast<String, dynamic>() : const {};
    return [
      _sectionCard(
        '统计指标',
        _metricGrid([
          _Metric('累计 Token', formatTokens(numOf(s['totalTokens']) ?? 0)),
          _Metric('单日峰值', formatTokens(numOf(s['peakDailyTokens']) ?? 0)),
          _Metric('最长会话', formatDurationMs(numOf(s['longestSessionMs']) ?? 0)),
          _Metric(
            '连续天数',
            '${numOf(s['currentStreakDays']) ?? 0} 天'
                '（最长 ${numOf(s['longestStreakDays']) ?? 0}）',
          ),
          _Metric('会话数', '${numOf(s['totalSessions']) ?? 0}'),
          _Metric('对话轮次', '${numOf(s['totalTurns']) ?? 0}'),
          _Metric(
            '缓存命中率',
            s['cacheHitRate'] is num
                ? '${_ratePercent((s['cacheHitRate'] as num)).toStringAsFixed(0)}%'
                : '-',
          ),
          _Metric('常用模型', '${mapOf(s['favoriteModel'])?['modelId'] ?? '-'}'),
        ]),
      ),
      if (data['heatmap'] is Map) ...[
        const SizedBox(height: 14),
        _sectionCard(
          '活动热力图',
          UsageHeatmapView(
            data['heatmap'] as Map,
            dailyModelUsage: listOf(data['dailyModelUsage']),
          ),
        ),
      ],
      // N1 P3-3：section 构建函数只调一次（原双调用翻倍重算）。
      if (_appTrend(data) case final trend?) ...[
        const SizedBox(height: 14),
        trend,
      ],
      if (_appModelTrend(data) case final modelTrend?) ...[
        const SizedBox(height: 14),
        modelTrend,
      ],
      if (_appModels(data) case final models?) ...[
        const SizedBox(height: 14),
        models,
      ],
    ];
  }

  /// 按模型趋势（拍板④B，官方 AppUsageDailyModelTrendChart 对位）：
  /// Top6 模型多序列日折线 + 图例（点+名+区间总量）。
  Widget? _appModelTrend(Map<String, dynamic> data) {
    final models =
        listOf(data['models'])
            ?.whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList() ??
        const [];
    final daily =
        listOf(data['dailyModelUsage'])
            ?.whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList() ??
        const [];
    final built = buildModelTrendSeries(
      models: models,
      dailyModelUsage: daily,
      palette: context.charts.series,
    );
    if (built.series.isEmpty || built.dates.isEmpty) return null;
    final lastIdx = built.dates.length - 1;
    final explicit =
        _modelTrendSelected != null && _modelTrendSelected! <= lastIdx
        ? _modelTrendSelected
        : lastIdx;
    final selected = _modelTrendShowTotal ? null : explicit;
    final detailText = selected == null
        ? barRangeTotalText(lineRangeTotal(built.series), formatTokens)
        : linePointDetailLine(
            date: built.dates[selected],
            index: selected,
            series: built.series,
            formatter: formatTokens,
          );
    return _sectionCard(
      '按模型趋势',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            detailText,
            style: TextStyle(
              fontSize: AppType.uiSm,
              color: context.colors.foregroundSubtle,
            ),
          ),
          const SizedBox(height: 6),
          _chartLegend(built.series),
          const SizedBox(height: 8),
          UsageLineChartView(
            series: built.series,
            xLabels: built.dates,
            valueFormatter: formatTokens,
            selectedIndex: selected,
            onPointTap: (i) {
              final cur = _modelTrendShowTotal
                  ? null
                  : (_modelTrendSelected ?? lastIdx);
              setState(() {
                if (cur == i) {
                  _modelTrendShowTotal = true;
                  _modelTrendSelected = null;
                } else {
                  _modelTrendShowTotal = false;
                  _modelTrendSelected = i;
                }
              });
            },
          ),
        ],
      ),
    );
  }

  /// 每日趋势：dailyModelUsage 按日聚合柱状图 + 点选单日明细。
  /// 默认选中最后一天（最新）；再点同一柱=取消选中，明细行显示区间合计。
  Widget? _appTrend(Map<String, dynamic> data) {
    final raw = data['dailyModelUsage'];
    if (raw is! List || raw.isEmpty) return null;
    final days = <_DailyUsage>[];
    for (final d in raw) {
      if (d is! Map) continue;
      var total = 0.0;
      final models = <({String name, num tokens})>[];
      final rawModels = d['models'];
      if (rawModels is List) {
        for (final m in rawModels) {
          if (m is! Map) continue;
          final t = (numOf(m['totalTokens']) ?? 0).toDouble();
          if (t <= 0) continue;
          total += t;
          models.add((name: '${m['modelId'] ?? '未知'}', tokens: t));
        }
      }
      models.sort((a, b) => b.tokens.compareTo(a.tokens));
      days.add(
        _DailyUsage(
          date: '${d['date'] ?? ''}',
          total: total,
          topModels: models.take(3).toList(),
        ),
      );
    }
    if (days.isEmpty) return null;
    final values = [for (final d in days) d.total];
    final dates = [for (final d in days) d.date];
    final lastIdx = days.length - 1;
    final explicit = _trendSelected != null && _trendSelected! <= lastIdx
        ? _trendSelected
        : lastIdx;
    final selected = _trendShowTotal ? null : explicit;
    final detailText = selected == null
        ? barRangeTotalText(values.fold(0.0, (a, b) => a + b), formatTokens)
        : barDayDetailLine(
            date: dates[selected],
            total: values[selected],
            topModels: days[selected].topModels,
            formatter: formatTokens,
          );
    return _sectionCard(
      '每日 Token 趋势',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            detailText,
            style: TextStyle(
              fontSize: AppType.uiSm,
              color: context.colors.foregroundSubtle,
            ),
          ),
          const SizedBox(height: 6),
          UsageBarChartView(
            values: values,
            xLabels: dates,
            valueFormatter: formatTokens,
            selectedIndex: selected,
            onBarTap: (i) {
              final cur = _trendShowTotal ? null : (_trendSelected ?? lastIdx);
              setState(() {
                if (cur == i) {
                  // 再点同一柱 → 取消选中，明细行显示区间合计。
                  _trendShowTotal = true;
                  _trendSelected = null;
                } else {
                  _trendShowTotal = false;
                  _trendSelected = i;
                }
              });
            },
          ),
        ],
      ),
    );
  }

  /// 模型用量环形图（官方范式：totalTokens>0 过滤 → 降序 → 超 6 片合并
  /// "其他"；切片值=totalTokens 实际量，占比由 painter 按值比例计算。
  /// 图例显示实际量而非百分比）。
  Widget? _appModels(Map<String, dynamic> data) {
    final raw = data['models'];
    if (raw is! List || raw.isEmpty) return null;
    final models = raw
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
    final pie = buildModelPieSlices(
      models,
      palette: context.charts.series,
      otherColor: context.colors.foregroundSubtle,
    );
    if (pie.slices.isEmpty) return null;
    // 批①：切片点选（null=合计提示；再点同片=取消）。占比按过滤后
    // 总量重算（官方同口径）。
    final sel = _pieSelected != null && _pieSelected! < pie.slices.length
        ? _pieSelected
        : null;
    final detailText = sel == null
        ? '点击切片查看模型明细'
        : () {
            final v = pie.slices[sel].values.first;
            final pct = pie.totalTokens > 0 ? v / pie.totalTokens * 100 : 0.0;
            return '${pie.slices[sel].name} · ${tr(formatTokens(v))} · '
                '${pct >= 10 ? pct.toStringAsFixed(0) : pct.toStringAsFixed(1)}%';
          }();
    // 18074 验收（桌面对位）：环形图数值全进清单（圆点+模型名+右对齐
    // 百分比 / 第二行数值，行可点=同切片点选，薄切片的触控兜底）；环心
    // 显示总量；宽屏（≥480dp，展开态）环与清单左右分栏（桌面同款内部
    // 结构），窄屏上下排。
    void pick(int i) {
      setState(() {
        _pieSelected = sel == i ? null : i;
      });
    }

    final donut = _DonutView(
      series: pie.slices,
      selectedIndex: sel,
      onSliceTap: pick,
      centerValue: tr(formatTokens(pie.totalTokens)),
    );
    final legendList = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < pie.slices.length; i++) ...[
          if (i > 0)
            Divider(height: 1, thickness: 0.5, color: context.colors.border),
          InkWell(
            // N3 P2-2：键拼入索引——重名切片（modelId 缺失/重复
            // 统一落「未知」）不再产生兄弟重复 key（debug 断言崩溃）。
            key: ValueKey('donut-legend-$i-${pie.slices[i].name}'),
            onTap: () => pick(i),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: pie.slices[i].color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          pie.slices[i].name,
                          translate: false,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: AppType.uiCaption,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      Builder(
                        builder: (ctx) {
                          final pct = pie.totalTokens > 0
                              ? pie.slices[i].values.first /
                                    pie.totalTokens *
                                    100
                              : 0.0;
                          return Text(
                            pct >= 10
                                ? '${pct.toStringAsFixed(0)}%'
                                : '${pct.toStringAsFixed(1)}%',
                            style: TextStyle(
                              fontSize: AppType.uiCaption,
                              color: ctx.colors.foregroundSubtle,
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 15, top: 1),
                    child: Text(
                      '${tr(formatTokens(pie.slices[i].values.first))} tokens',
                      style: TextStyle(
                        fontSize: AppType.uiXs,
                        color: context.colors.foregroundSubtlest,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
    return _sectionCard(
      '模型用量分布',
      LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 480;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                detailText,
                style: TextStyle(
                  fontSize: AppType.uiSm,
                  color: context.colors.foregroundSubtle,
                ),
              ),
              const SizedBox(height: 6),
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(flex: 4, child: donut),
                    const SizedBox(width: 12),
                    Expanded(flex: 6, child: legendList),
                  ],
                )
              else ...[donut, const SizedBox(height: 6), legendList],
            ],
          );
        },
      ),
    );
  }

  // ── 通用件 ──────────────────────────────────────────────────

  Widget _sectionCard(String title, Widget child) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.colors.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: context.colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: AppType.uiBase,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }

  Widget _metricGrid(List<_Metric> metrics) {
    return Column(
      children: [
        for (var i = 0; i < metrics.length; i += 2)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: IntrinsicHeight(
              child: Row(
                children: [
                  Expanded(child: _metricTile(metrics[i])),
                  const SizedBox(width: 6),
                  Expanded(
                    child: i + 1 < metrics.length
                        ? _metricTile(metrics[i + 1])
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _metricTile(_Metric m) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: context.colors.background,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            m.label,
            style: TextStyle(
              fontSize: AppType.uiSm,
              color: context.colors.foregroundSubtle,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            m.value,
            style: const TextStyle(
              fontSize: AppType.uiBase,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  /// 图例：圆点+名称单行横滑（18074 验收，桌面对位）——数值由点选明细
  /// 行与环形清单承载，不内联。 N1 P3-1/N2-9/N3 P3-2：退役的
  /// unit/decimals/valueFormatter/rangeTotals 参数与调用方的无效实参
  /// （rangeTotals 每帧构建后即被丢弃）一并删除。
  Widget _chartLegend(List<ChartSeries> series) {
    return SizedBox(
      height: 22,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < series.length; i++) ...[
              if (i > 0) const SizedBox(width: 14),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: series[i].color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    series[i].name,
                    translate: false,
                    style: TextStyle(
                      fontSize: AppType.uiCaption,
                      color: context.colors.foregroundSubtle,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Metric {
  final String label;
  final String value;
  const _Metric(this.label, this.value);
}

/// 重置礼包徽标（ N1 P3-4：自带倒计时 Timer，秒针只重建本行
/// 而非整页）。多机会/小时以上档倒计时产物每秒相同——降为 30s 一拍；
/// 分秒档（单机会<1h）才逐秒走表。
class _ResetBadge extends StatefulWidget {
  final CodingPlanResetStatus status;
  final VoidCallback onPressed;
  const _ResetBadge({required this.status, required this.onPressed});

  @override
  State<_ResetBadge> createState() => _ResetBadgeState();
}

class _ResetBadgeState extends State<_ResetBadge> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      // 被其他路由覆盖/退后台时不空转 setState（同页级定时器闸门）。
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        return;
      }
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) return;
      // 分秒档（单机会且最早过期<1h）才逐秒重建；否则 30s 一拍。
      final st = widget.status;
      final soonest = st.soonestExpireAt;
      final secondly = st.totalCount == 1 &&
          soonest != null &&
          soonest - DateTime.now().millisecondsSinceEpoch <
              60 * 60 * 1000;
      if (secondly || DateTime.now().second % 30 == 0) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      key: const ValueKey('reset-opportunity-badge'),
      avatar: Icon(
        Icons.redeem_outlined,
        size: 16,
        color: context.colors.interactionAskForeground,
      ),
      label: Text(
        resetBadgeLabel(widget.status, DateTime.now()),
        style: TextStyle(
          fontSize: AppType.uiCaption,
          fontWeight: FontWeight.w500,
          color: context.colors.interactionAskForeground,
        ),
      ),
      onPressed: widget.onPressed,
    );
  }
}

/// 官方 formatCodingPlanRate 量纲兼容：>1 视为已是百分数。
double _ratePercent(num v) => (v > 1 ? v : v * 100).toDouble();

/// 热力图：weeks×7 天格子，横向滚动。批①（2026-10-23）：点选格子→
/// 选中描边+下方明细行（官方 schema 格子带 date/totalTokens/turnCount/
/// toolCallCount，usage-stats.ts:208-214）；再点同格取消。months 不标注
/// ——保持最小。
/// 公开（原 _HeatmapView）：widget 测试需直接泵入周数据断言几何
/// （2026-10-25 问题②回归——触控盒 22px 扩容后容器高仍按视觉格 11px
/// 计算，内容 171.5px 挤进 94.5px 盒子，横向滚动不裁纵向溢出，格子
/// 直接盖到下方明细行与后续区块上）。
class UsageHeatmapView extends StatefulWidget {
  final Map<dynamic, dynamic> heatmap;

  /// 按模型日用量（2026-10-26 拍板④：点选日明细追加按模型拆分；仅
  /// 应用用量快照携带，个人套餐 monitor 接口无此数据）。
  final List<dynamic>? dailyModelUsage;
  const UsageHeatmapView(this.heatmap, {this.dailyModelUsage, super.key});

  @override
  State<UsageHeatmapView> createState() => _UsageHeatmapViewState();
}

/// 热力图档位（2026-11-04 用户拍板「补三档但针对手机屏优化」）。
/// 协议核实：官方 heatmap 仅 tokens 单维度，无「按来源」字段——
/// 按模型档用 dailyModelUsage 按日聚合出当日 top 模型着色；来源档
/// 协议不支持，不伪造（两档即协议上限）。
enum _Heatmode { total, model }

class _UsageHeatmapViewState extends State<UsageHeatmapView> {
  /// 选中格 (weekIndex, dayIndex)；null=未选（提示行）。
  (int, int)? _sel;

  _Heatmode _mode = _Heatmode.total;

  /// 横向滚动：默认停在最右（最近几周）——2026-10-26 真机验收②b：时间
  /// 轴左旧右新，初始停最左要划半屏才见最近用量，不合理。数据换档后
  /// 周数变长也保持贴右。
  final _hScroll = ScrollController();
  int _weeksCount = 0;

  @override
  void initState() {
    super.initState();
    _jumpToLatest();
  }

  @override
  void didUpdateWidget(covariant UsageHeatmapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final weeks = listOf(widget.heatmap['weeks'])?.length ?? 0;
    if (weeks != _weeksCount) _jumpToLatest();
    // 换范围/换时区后旧选中可能已不存在：清掉而不是残留旧明细。
    if (_sel != null) {
      final (w, d) = _sel!;
      final weekList = listOf(widget.heatmap['weeks']) ?? const [];
      final days = w < weekList.length ? weekList[w]['days'] : null;
      final day = days is List && d < days.length ? days[d] : null;
      if (day is! Map) _sel = null;
    }
  }

  void _jumpToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_hScroll.hasClients) return;
      _hScroll.jumpTo(_hScroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _hScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final heatmap = widget.heatmap;
    final weeks =
        listOf(heatmap['weeks'])?.whereType<Map>().toList() ?? const [];
    if (weeks.isEmpty) {
      return Text(
        '暂无活动数据',
        style: TextStyle(
          fontSize: AppType.uiSm,
          color: context.colors.foregroundSubtle,
        ),
      );
    }
    final gap = 2.5;
    // 无用量格底色（2026-10-26 真机验收②a）：深色下 0 级绿（#252B28）
    // 与空格全透明都近乎不可见——参考桌面端：无用量=可辨识的淡灰。
    // 18074 验收：withValues(alpha:) 是覆写不是叠乘——border 自带 10%
    // 透明度被直接改成 50%，实机"灰格太亮"；桌面实测不活跃格仅比底亮
    // 一档（#2B2E33 vs #26282B≈2%白）——取 border 色 6% 贴同档。
    final emptyCell = context.colors.border.withValues(alpha: 0.06);
    _weeksCount = weeks.length;
    // 按模型档：日期 → (top 模型, 该日模型总量占比强度)。
    // 同日多模型取 tokens 最大者为该日代表色（手机窄屏下不做叠色）。
    final modelPalette = context.charts.series;
    final topModelByDate = <String, ({String name, int colorIndex, double share})>{};
    for (final entry in widget.dailyModelUsage ?? const []) {
      if (entry is! Map) continue;
      final date = '${entry['date'] ?? ''}';
      if (date.isEmpty) continue;
      var bestName = '';
      var bestTokens = 0.0;
      var total = 0.0;
      final names = <String>[];
      for (final m in listOf(entry['models']) ?? const []) {
        if (m is! Map) continue;
        final t = (numOf(m['totalTokens']) ?? 0).toDouble();
        total += t;
        if (t > bestTokens) {
          bestTokens = t;
          bestName = '${m['modelId'] ?? '未知'}';
        }
        names.add('${m['modelId'] ?? '未知'}');
      }
      if (bestName.isEmpty) continue;
      // 模型 → 调色板下标（按名字稳定排序，同一模型跨日同色）。
      names.sort();
      final idx = names.toSet().toList().indexOf(bestName) % modelPalette.length;
      topModelByDate[date] = (
        name: bestName,
        colorIndex: modelPalette.isEmpty ? 0 : idx,
        share: total <= 0 ? 0 : bestTokens / total,
      );
    }
    // 容器高按触控命中盒（22）计而非视觉格（11）——B4 触控外扩后每格
    // 实占 24.5（命中盒+下边距），7 行共 171.5；此前按 11 计得 94.5，
    // 内容溢出 77px 且横向滚动视图不裁纵向溢出，格子盖到下方内容
    // （2026-10-25 问题②真机实锤）。
    final hit = 22.0;
    final gridHeight = hit * 7 + gap * 7;
    Map<String, dynamic>? selDay;
    if (_sel != null) {
      final (w, d) = _sel!;
      // 双侧越界守卫（对抗审查 A2）：档间切换周数缩档（已缓存档的
      // State 存活、_sel 残留），week 侧此前无守卫——weeks[w] 直接
      // RangeError 崩溃（release 同崩）。
      final days = w < weeks.length ? weeks[w]['days'] : null;
      final day = days is List && d < days.length ? days[d] : null;
      selDay = day is Map ? day.cast<String, dynamic>() : null;
    }
    // 当日按模型明细（top3，与趋势柱明细同口径）；结构化行展示，
    // 不再把“日期/总量/轮次/模型”挤成两行小字。
    final dayModels = <({String name, num tokens})>[];
    if (selDay != null) {
      final date = '${selDay['date'] ?? ''}';
      for (final d in widget.dailyModelUsage ?? const []) {
        if (d is! Map || '${d['date'] ?? ''}' != date) continue;
        for (final m in listOf(d['models']) ?? const []) {
          if (m is! Map) continue;
          final t = numOf(m['totalTokens']) ?? 0;
          if (t > 0) {
            dayModels.add((name: '${m['modelId'] ?? '未知'}', tokens: t));
          }
        }
        break;
      }
      dayModels.sort((a, b) => b.tokens.compareTo(a.tokens));
    }
    final topModels = dayModels.take(3).toList();
    return LayoutBuilder(
      builder: (context, constraints) {
        // 列宽随可用宽度分配：30d/7d 不再挤在左边；53 周仍按 22px
        // 命中盒横向滚动。视觉格最大 28px，命中区不缩小。
        final available = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : weeks.length * 24.5;
        final hitWidth = (available / weeks.length - gap).clamp(
          22.0,
          double.infinity,
        );
        final visualCell = (hitWidth - 4).clamp(
          11.0,
          // 少周数允许大格子铺满（用户⑤：右侧不再大片空白）；
          // 多周数仍保持小格+横滚。
          weeks.length <= 8 ? double.infinity : 28.0,
        );
        final contentWidth = available > weeks.length * (hitWidth + gap)
            ? available
            : weeks.length * (hitWidth + gap);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: gridHeight,
              child: SingleChildScrollView(
                controller: _hScroll,
                scrollDirection: Axis.horizontal,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                child: SizedBox(
                  width: contentWidth,
                  child: Row(
                    children: [
                      for (var wi = 0; wi < weeks.length; wi++)
                        SizedBox(
                          width: hitWidth + gap,
                          child: Column(
                            children: [
                              for (var d = 0; d < 7; d++)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 2.5),
                                  child: Builder(
                                    builder: (_) {
                                      final days = weeks[wi]['days'];
                                      final day =
                                          days is List && d < days.length
                                          ? days[d]
                                          : null;
                                      final level = day is Map
                                          ? day['level']
                                          : null;
                                      final lvl = level is int ? level : 0;
                                      Color color;
                                      if (_mode == _Heatmode.model) {
                                        final date =
                                            day is Map ? '${day['date'] ?? ''}' : '';
                                        final top = topModelByDate[date];
                                        // 有活动但无按模型明细（个人套餐
                                        // monitor 接口不携带该维度）→ 退回
                                        // 总用量色阶，不显示假色。
                                        if (lvl >= 1 && lvl < 5 && top != null) {
                                          color = modelPalette[top.colorIndex]
                                              .withValues(
                                            alpha: (0.35 + 0.65 * top.share)
                                                .clamp(0.35, 1.0),
                                          );
                                        } else if (lvl >= 1 && lvl < 5) {
                                          color =
                                              context.charts.heatmapGreens[lvl];
                                        } else {
                                          color = emptyCell;
                                        }
                                      } else {
                                        color = lvl >= 1 && lvl < 5
                                            ? context.charts.heatmapGreens[lvl]
                                            : emptyCell;
                                      }
                                      final selected = _sel == (wi, d);
                                      // 命中盒外扩（对抗审查 B4）：视觉格子
                                      // 11px 低于 44 触控纪律——命中区扩大到
                                      // 22×22（含邻缝），视觉尺寸不变。
                                      return GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        // 空格子（day=null）不可选。
                                        onTap: day is! Map
                                            ? null
                                            : () => setState(() {
                                                _sel = selected
                                                    ? null
                                                    : (wi, d);
                                              }),
                                        child: SizedBox(
                                          width: hitWidth,
                                          height: 22,
                                          child: Center(
                                            child: Container(
                                              width: visualCell,
                                              height: visualCell,
                                              decoration: BoxDecoration(
                                                // 无数据格与 0 级格统一淡灰底
                                                //（②a：不再与背景融为一体）。
                                                color: day == null
                                                    ? emptyCell
                                                    : color,
                                                borderRadius:
                                                    BorderRadius.circular(2),
                                                border: selected
                                                    ? Border.all(
                                                        color: context
                                                            .colors
                                                            .foreground,
                                                        width: 1.2,
                                                      )
                                                    : null,
                                              ),
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            // 手机紧凑档位切换（用户拍板：针对窄屏优化）——单行、
            // 小尺寸胶囊，不挤压图例与明细；协议无「按来源」维度故
            // 只提供两档（不伪造第三档）。
            Row(
              children: [
                for (final m in _Heatmode.values) ...[
                  GestureDetector(
                    key: ValueKey('heat-mode-${m.name}'),
                    onTap: () => setState(() => _mode = m),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: _mode == m
                            ? context.colors.brandAccent
                                .withValues(alpha: AppAlpha.faint)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                        border: Border.all(
                          color: _mode == m
                              ? context.colors.brandAccent
                                  .withValues(alpha: 0.35)
                              : context.colors.borderFaint,
                        ),
                      ),
                      child: Text(
                        m == _Heatmode.total ? '总用量' : '按模型',
                        style: TextStyle(
                          fontSize: AppType.uiXs,
                          color: _mode == m
                              ? context.colors.brandAccent
                              : context.colors.foregroundSubtle,
                          fontWeight: _mode == m
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                if (_mode == _Heatmode.model)
                  Expanded(
                    child: Text(
                      '色=当日用量最高模型',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: AppType.uiXs,
                        color: context.colors.foregroundSubtlest,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            if (selDay == null)
              Text(
                '点击格子查看当日明细',
                style: TextStyle(
                  fontSize: AppType.uiSm,
                  color: context.colors.foregroundSubtlest,
                ),
              )
            else
              Container(
                key: const ValueKey('heat-day-detail'),
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: context.colors.surface,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  border: Border.all(color: context.colors.borderFaint),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            chartDayLabel('${selDay['date'] ?? ''}'),
                            style: const TextStyle(
                              fontSize: AppType.uiSm,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          formatTokens(numOf(selDay['totalTokens']) ?? 0),
                          style: const TextStyle(
                            fontSize: AppType.uiBase,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${numOf(selDay['turnCount']) ?? 0} 轮 · '
                      '${numOf(selDay['toolCallCount']) ?? 0} 次工具调用',
                      style: TextStyle(
                        fontSize: AppType.uiXs,
                        color: context.colors.foregroundSubtle,
                      ),
                    ),
                    if (topModels.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        '模型用量',
                        style: TextStyle(
                          fontSize: AppType.uiXs,
                          color: context.colors.foregroundSubtlest,
                        ),
                      ),
                      const SizedBox(height: 4),
                      for (var i = 0; i < topModels.length; i++)
                        Padding(
                          padding: EdgeInsets.only(top: i == 0 ? 0 : 4),
                          child: Row(
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: context
                                      .charts
                                      .series[i % context.charts.series.length],
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  topModels[i].name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: AppType.uiXs,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                formatTokens(topModels[i].tokens),
                                style: const TextStyle(
                                  fontSize: AppType.uiXs,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            const SizedBox(height: 4),
            Row(
              children: [
                Text(
                  '少',
                  style: TextStyle(
                    fontSize: AppType.uiXs, // 批次A：10→11（字阶下限，设计审计 R3）
                    color: context.colors.foregroundSubtlest,
                  ),
                ),
                const SizedBox(width: 4),
                // N2-8：0 级/空格实际渲染 emptyCell（18074 验收
                // 调灰），greens[0] 在图上永不出现——图例首格同步用
                // emptyCell，色样与图面一致。
                for (final c in [
                  emptyCell,
                  ...context.charts.heatmapGreens.skip(1),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 3),
                    child: Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: c,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                Text(
                  '多',
                  style: TextStyle(
                    fontSize: AppType.uiXs, // 批次A：10→11（字阶下限，设计审计 R3）
                    color: context.colors.foregroundSubtlest,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// 折线图（多序列）：3 条横向网格线 + 序列折线 + 首末 x 标签。
/// 批①：点选某点→竖线+圆点高亮（onPointTap 回调下标，命中换算与
/// painter 同款 slot 公式——linePointHitIndex）。
class UsageLineChartView extends StatelessWidget {
  final List<ChartSeries> series;
  final List<String> xLabels;
  final String Function(num) valueFormatter;
  final int? selectedIndex;
  final Color? selectedColor;
  final ValueChanged<int>? onPointTap;
  const UsageLineChartView({
    required this.series,
    required this.xLabels,
    required this.valueFormatter,
    this.selectedIndex,
    this.selectedColor,
    this.onPointTap,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: onPointTap == null
              ? null
              : (d) {
                  final i = linePointHitIndex(
                    d.localPosition.dx,
                    constraints.maxWidth,
                    xLabels.length,
                  );
                  if (i != null) onPointTap!(i);
                },
          child: SizedBox(
            height: 150,
            child: CustomPaint(
              painter: LineChartPainter(
                series: series,
                xLabels: xLabels,
                valueFormatter: valueFormatter,
                selectedIndex: selectedIndex,
                selectedColor: selectedColor,
                labelStyle: TextStyle(
                  fontSize: AppType.uiXs, // 批次A：10→11（字阶下限，设计审计 R3）
                  color: context.colors.foregroundSubtlest,
                ),
                gridColor: context.colors.border,
                textScaler: MediaQuery.textScalerOf(context),
              ),
              size: Size.infinite,
            ),
          ),
        );
      },
    );
  }
}

/// 柱状图：每日 Token 总量；支持点选柱高亮（onBarTap 回调下标，
/// 命中换算与 painter 同款 slot 公式——barHitIndex）。
class UsageBarChartView extends StatelessWidget {
  final List<double> values;
  final List<String> xLabels;
  final String Function(num) valueFormatter;
  final int? selectedIndex;
  final ValueChanged<int>? onBarTap;
  const UsageBarChartView({
    required this.values,
    required this.xLabels,
    required this.valueFormatter,
    this.selectedIndex,
    this.onBarTap,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: onBarTap == null
              ? null
              : (d) {
                  final i = barHitIndex(
                    d.localPosition.dx,
                    constraints.maxWidth,
                    values.length,
                  );
                  if (i != null) onBarTap!(i);
                },
          child: SizedBox(
            height: 140,
            child: CustomPaint(
              painter: BarChartPainter(
                values: values,
                xLabels: xLabels,
                valueFormatter: valueFormatter,
                barColor: context.charts.series[1],
                selectedIndex: selectedIndex,
                selectedColor: context.colors.foreground,
                gridColor: context.colors.border,
                labelStyle: TextStyle(
                  fontSize: AppType.uiXs, // 批次A：10→11（字阶下限，设计审计 R3）
                  color: context.colors.foregroundSubtlest,
                ),
                textScaler: MediaQuery.textScalerOf(context),
              ),
              size: Size.infinite,
            ),
          ),
        );
      },
    );
  }
}

/// 单日聚合（柱状图点选明细用：日期、总 token、当日 top 模型）。
class _DailyUsage {
  final String date;
  final double total;
  final List<({String name, num tokens})> topModels;
  const _DailyUsage({
    required this.date,
    required this.total,
    required this.topModels,
  });
}

/// 环形图：模型实际用量（totalTokens）分布，占比由 painter 按值比例计算。
/// 批①：点选切片高亮加粗+明细行（onSliceTap；命中=角度弧段+环带判定
/// ——donutHitIndex，与 painter 铺片同款）。
class _DonutView extends StatelessWidget {
  final List<ChartSeries> series;
  final int? selectedIndex;
  final ValueChanged<int>? onSliceTap;

  /// 环心总量文案（18074 验收：桌面同款中心两行——总量+tokens；
  /// null=不叠中心）。
  final String? centerValue;
  const _DonutView({
    required this.series,
    this.selectedIndex,
    this.onSliceTap,
    this.centerValue,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: onSliceTap == null
              ? null
              : (d) {
                  // 18074 验收根因修：constraints.biggest 在滚动列里高度
                  // 无界（∞）——中心/半径无穷化后角度退化恒为 0，所有的
                  // 点按都命中第一片（用户实锤"只能点 glm5.3"；测试实证：
                  // 底部点按预期命中第 2 片、实际回弹成取消选择）。改取
                  // 本组件实际布局尺寸（=SizedBox 的 150 高）。
                  final box = context.size;
                  if (box == null || !box.isFinite) return;
                  final i = donutHitIndex(d.localPosition, box, series);
                  if (i != null) onSliceTap!(i);
                },
          child: SizedBox(
            height: 150,
            width: double.infinity,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CustomPaint(
                  painter: DonutPainter(
                    series: series,
                    selectedIndex: selectedIndex,
                  ),
                  size: Size.infinite,
                ),
                if (centerValue != null)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        centerValue!,
                        style: const TextStyle(
                          fontSize: AppType.uiLg,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        'tokens',
                        style: TextStyle(
                          fontSize: AppType.uiXs,
                          color: context.colors.foregroundSubtle,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

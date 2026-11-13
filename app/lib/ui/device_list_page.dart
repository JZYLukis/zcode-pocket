import 'dart:async';

import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import 'app_widgets.dart';
import 'web_fallback_page.dart';

import '../core/theme.dart';
import '../state/app_state_scope.dart';
import '../state/device_stack_registry.dart' show AccountRebindRequired;
import '../transport/connection_params.dart';
import '../transport/relay_v2.dart';
import 'login_page.dart';
import 'settings_accounts_page.dart';

/// 自动落点（官方 resolveAutoConnectSid 简化版）：
/// **恰好一台在线** → 直接连它；否则展示列表让用户选。
/// （官方的"最近 sid/同 mid 唯一在线"完整规则依赖历史偏好持久化——
/// 装机实测批次再补，先保守。）
String? pickAutoConnectDevice(List<RelayV2Device> devices) {
  final online = devices.where((d) => d.online).toList();
  return online.length == 1 ? online.first.deviceSid : null;
}

// 优化批 #3：异常→人话映射（原始异常仍在调用方 debugPrint 留痕）。
String friendlyError(Object e) {
  final msg = '$e';
  if (msg.contains('TimeoutException') || msg.contains('timeout')) {
    return '网络不佳，请稍后再试';
  }
  if (msg.contains('401') || msg.contains('auth')) {
    return '账号凭据失效，请重新登录';
  }
  return '加载失败，请重试';
}

/// V2 设备列表页（登录后/无 sid 二维码进入）：展示指定账号的全部桌面，
/// 点按=建 V2 档案并激活。online=该桌面有活的 device 角色连接（官方
/// 服务端按 ws 连接计算——离线桌面无法连接，列表置灰）。
class DeviceListPage extends StatefulWidget {
  /// 目标账号（多账号批 2026-10-25；null=最近使用账号——历史行为）。
  final String? accountId;

  /// 测试缝：直接注入设备清单并跳过首帧网络加载（改绑取消等交互
  /// 路径的 widget 回归；真实网络在测试环境不可达）。
  @visibleForTesting
  final List<RelayV2Device>? debugDevices;

  const DeviceListPage({super.key, this.accountId, this.debugDevices});

  @override
  State<DeviceListPage> createState() => _DeviceListPageState();
}

class _DeviceListPageState extends State<DeviceListPage> {
  List<RelayV2Device>? _devices;
  String? _error;
  bool _connecting = false;

  /// 401（凭据失效）标记：错误视图给「重新登录」
  /// 出口——按 relay 语义 401=清会话回登录，重试永远再 401。
  bool _authRequired = false;

  //连接失败的条内错误：不再顶掉
  /// 整个设备列表——已加载清单保留，错误以条形提示+人话映射。
  String? _connectError;

  @override
  void initState() {
    super.initState();
    // 测试缝：注入清单即视为已加载（不发起真实网络）。
    if (widget.debugDevices != null) {
      _devices = widget.debugDevices;
    }
    // AppStateScope.of 需在首帧后调用（initState 期间依赖注册非法——
    // debug 断言炸、release 依赖更新不生效）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_resolveAccountChip());
        if (widget.debugDevices == null) unawaited(_load());
      }
    });
  }

  Future<void> _load() async {
    // 连接进行中不重复拉清单（避免并发第二次直连）。
    if (_connecting) return;
    setState(() {
      _error = null;
      _authRequired = false;
      _connectError = null;
    });
    final app = AppStateScope.of(context);
    // 自动落点直连仅限首次加载（_devices 尚空）——
    // 刷新语义=重拉清单确认状态，被自动直连劫持会把页面 pop 掉。
    final firstLoad = _devices == null;
    try {
      final api = RelayV2Api(
        origin: relayV2DefaultOrigin(),
        // 多账号批（2026-10-25）：按指定账号拉清单+建档案。
        jwtProvider: () => app.accountStore.readJwtFor(widget.accountId),
      );
      final devices = await api.listDevices();
      if (!mounted) return;
      debugPrint(
        '[app] [v2-ui] devices=${devices.length} '
        'online=${devices.where((d) => d.online).length}',
      );
      setState(() => _devices = devices);
      // 恰好一台在线：自动落点直连（官方语义，仅首次进入）。
      final auto = firstLoad ? pickAutoConnectDevice(devices) : null;
      debugPrint('[app] [v2-ui] auto-pick=${auto ?? '无（多台/全离线/刷新）'}');
      if (auto != null) {
        final hit = devices.firstWhere((d) => d.deviceSid == auto);
        unawaited(
          _connect(
            CompanionV2Params(
              deviceSid: hit.deviceSid,
              deviceMid: hit.deviceMid,
              deviceName: (hit.meta['name'] as String?)?.trim(),
            ),
          ),
        );
      }
    } on RelayV2AuthRequired {
      debugPrint('[app] [v2-ui] 设备列表 401（凭据失效）');
      if (mounted) {
        setState(() {
          _error = '账号凭据失效，请重新登录';
          _authRequired = true;
        });
      }
    } on Object catch (e) {
      // 优化批 #3：原始异常只进日志，用户可见文案走人话映射。
      debugPrint('[app] [v2-ui] 设备列表失败: $e');
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  /// 401 后重新登录：push 官方登录页，成功后重拉
  /// 清单（save 落库即切 lastUsed，本页 jwtProvider=null=lastUsed 取新凭据）。
  /// 当前拉取所用账号的显示名（批1）：widget.accountId 为空=lastUsed。
  String? _accountChip;

  Future<void> _resolveAccountChip() async {
    if (!mounted) return;
    final app = AppStateScope.of(context);
    try {
      final accounts = await app.accountStore.listAccounts();
      final id = widget.accountId ?? await app.accountStore.lastUsedAccountId;
      final match = accounts.where((a) => a.id == id).firstOrNull;
      final label = match?.displayName;
      if (!mounted) return;
      if (label != _accountChip) setState(() => _accountChip = label);
    } catch (_) {}
  }

  Future<void> _relogin() async {
    final result = await Navigator.of(context).push<Map<String, String>>(
      MaterialPageRoute(builder: (_) => const LoginPage()),
    );
    if (!mounted) return;
    final jwt = result?['jwt'];
    if (jwt is String) {
      // 重登可能换了账号（lastUsed 变）——chip 重解析。
      unawaited(_resolveAccountChip());
      unawaited(_load());
    }
  }

  /// 早前批次 批2：同一台电脑改绑账号需显式确认（破坏性——
  /// 旧账号的连接将失效）。确认后 forceRebind 重调完成改绑。
  ///
  /// 返回 true=档案已添加/已改绑，false=用户取消改绑（调用方不得
  /// 当成功 pop 整页——2026-11-08 对抗审查：此前返回 void，取消后
  /// `_connect` 仍走成功分支把设备列表页关掉）。
  Future<bool> _addProfileResolvingRebind(CompanionV2Params params) async {
    final app = AppStateScope.of(context);
    try {
      await app.addV2Profile(params, accountId: widget.accountId);
      return true;
    } on AccountRebindRequired catch (e) {
      if (!mounted) rethrow;
      final appNow = AppStateScope.of(context);
      final names = <String, String>{};
      try {
        for (final a in await appNow.accountStore.listAccounts()) {
          names[a.id] = a.displayName;
        }
      } catch (_) {}
      final from = names[e.fromAccountId] ?? e.fromAccountId;
      final to = names[e.toAccountId] ?? e.toAccountId;
      if (!mounted) return false;
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('改绑这台电脑的账号？'),
          // 整句插值进不了词表（此前 EN 整段中文）——
          // 拆四段各自 tr 后拼接（词条=前缀/中缀/后缀，见 custom_l10n）。
          content: Text(
            tr('该电脑当前绑定「') +
                from +
                tr('」，将改为「') +
                to +
                tr('」。改绑后旧账号在此电脑上的连接会失效，需要用旧账号时可再改绑回来。'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              key: const ValueKey('account-rebind-ok'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('改绑'),
            ),
          ],
        ),
      );
      if (ok != true) {
        // 用户取消：调用方仅收起连接态，不得 pop 整页。
        return false;
      }
      await app.addV2Profile(
        params,
        accountId: widget.accountId,
        forceRebind: true,
      );
      return true;
    }
  }

  Future<void> _connect(CompanionV2Params params) async {
    debugPrint('[app] [v2-ui] connect sid=${params.deviceSid}');
    if (_connecting) return;
    // （批3）：新连接开始即清上次失败红条，不与之并存到本次结束。
    setState(() {
      _connecting = true;
      _connectError = null;
    });
    try {
      final ok = await _addProfileResolvingRebind(params);
      if (!ok) {
        // 用户取消改绑：保留设备列表，仅收起连接态（不 pop）。
        if (mounted) setState(() => _connecting = false);
        return;
      }
      debugPrint('[app] [v2-ui] profile added, popping');
      if (mounted) Navigator.of(context).pop();
    } on Object catch (e) {
      debugPrint('[app] [v2-ui] connect failed: $e');
      if (mounted) {
        // 连接失败保留列表（条内错误），文案过人话
        // 映射与 _load 同口径（此前裸怼 RelayV2Unavailable 等协议串）。
        setState(() {
          _connecting = false;
          _connectError = '连接失败：${friendlyError(e)}';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final devices = _devices;
    final listBody = devices == null
        // 优化批 #2：同上。
        ? const Center(child: AppLoading('正在加载设备…'))
        : devices.isEmpty
        ? _emptyView()
        : ListView(
            padding: const EdgeInsets.all(12),
            children: [
              // 连接失败条内呈现，设备清单保留。
              if (_connectError != null) ...[
                Container(
                  key: const ValueKey('device-connect-error'),
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: context.colors.destructive.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 16,
                        color: context.colors.destructive,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _connectError!,
                          style: TextStyle(
                            fontSize: AppType.uiCaption,
                            color: context.colors.destructive,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              for (final d in devices)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _DeviceCard(
                    device: d,
                    onTap: d.online
                        ? () => unawaited(
                            _connect(
                              CompanionV2Params(
                                deviceSid: d.deviceSid,
                                deviceMid: d.deviceMid,
                                deviceName: (d.meta['name'] as String?)?.trim(),
                              ),
                            ),
                          )
                        : null,
                  ),
                ),
            ],
          );
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        backgroundColor: context.colors.background,
        surfaceTintColor: Colors.transparent,
        // 早前批次 批1（2026-11-04 拍板）：显式标注「以哪个
        // 账号拉取」——accountId 为空=最近使用账号（历史行为）。
        // 显示名异步解析（备注名优先），解析前不占位。
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('选择电脑'),
            if (_accountChip != null)
              Flexible(
                child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: GestureDetector(
                  key: const ValueKey('device-list-account-chip'),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const SettingsAccountsPage(),
                    ),
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: context.colors.brandAccent
                          .withValues(alpha: AppAlpha.faint),
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.account_circle_outlined,
                          size: 12,
                          color: context.colors.brandAccent,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            '以 $_accountChip 拉取',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: AppType.uiXs,
                              color: context.colors.brandAccent,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                ),
              ),
          ],
        ),
        actions: [
          // 网页备用入口（阶段 4.2 最小版 / -8B，2026-10-29 批次）：
          // 零协议依赖逃生舱——协议漂移/握手失败时仍可用官方 Web 远控。
          IconButton(
            key: const ValueKey('web-fallback-entry'),
            tooltip: tr('用网页版打开（备用通道）'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const WebFallbackPage()),
            ),
            icon: const Icon(Icons.open_in_new, size: 20),
          ),
          IconButton(
            key: const ValueKey('device-list-refresh'),
            onPressed: _connecting ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _connecting
          // 优化批 #2：裸转圈换带说明的 AppLoading（等待语义可读）。
          ? const Center(child: AppLoading('正在加载设备…'))
          : _error != null
          ? _errorView()
          : listBody,
    );
  }

  Widget _errorView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$_error'),
          const SizedBox(height: 12),
          // 401=凭据失效（JWT 无本地过期信号，重试
          // 必然再 401）——给「重新登录」出口，对齐 relay「401=清会话回
          // 登录」语义。
          if (_authRequired) ...[
            FilledButton(
              key: const ValueKey('device-list-relogin'),
              onPressed: _relogin,
              child: const Text('重新登录'),
            ),
            const SizedBox(height: 8),
          ],
          FilledButton(onPressed: _load, child: const Text('重试')),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const ValueKey('web-fallback-entry-error'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const WebFallbackPage()),
            ),
            child: const Text('用网页版打开（备用通道）'),
          ),
        ],
      ),
    );
  }

  Widget _emptyView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          '账号下还没有电脑在线\n请在电脑端 ZCode 开启手机连接（3.16+），'
          '或用同一账号登录桌面端',
          textAlign: TextAlign.center,
          style: TextStyle(color: context.colors.foregroundSubtle),
        ),
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  final RelayV2Device device;
  final VoidCallback? onTap;

  const _DeviceCard({required this.device, this.onTap});

  @override
  Widget build(BuildContext context) {
    final name = ((device.meta['name'] as String?) ?? '').trim().isNotEmpty
        ? (device.meta['name'] as String).trim()
        : device.deviceMid;
    final platform = '${device.meta['platform'] ?? ''}'.trim();
    return Container(
      decoration: BoxDecoration(
        color: context.colors.card,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: context.colors.border),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('device-card-${device.deviceSid}'),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                Icon(
                  Icons.computer,
                  size: 20,
                  color: device.online
                      ? context.colors.success
                      : context.colors.foregroundSubtle,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name.isEmpty ? '未命名电脑' : name,
                        translate: name.isEmpty,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                      if (platform.isNotEmpty)
                        Text(
                          platform,
                          translate: false,
                          style: TextStyle(
                            fontSize: AppType.uiCaption,
                            color: context.colors.foregroundSubtle,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  device.online ? '在线' : '离线',
                  style: TextStyle(
                    fontSize: AppType.uiCaption,
                    color: device.online
                        ? context.colors.success
                        : context.colors.foregroundSubtle,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

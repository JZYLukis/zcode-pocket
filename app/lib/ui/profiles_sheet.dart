import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';

import '../core/theme.dart';
import '../state/app_state.dart';
import '../state/app_state_scope.dart';
import '../transport/z_transport.dart';
import 'app_widgets.dart';
import 'pairing_page.dart';

/// 电脑档案管理面板（裁决：档案切换为一级入口）。
/// 列表 + 添加 + 状态点 + 重命名/删除；两形态同款（折叠态顶栏、展开态图标轨顶部进入）。
Future<void> showProfilesSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    // 官方侧栏宽度 min(88vw, 448px)（ui-references）
    constraints: const BoxConstraints(maxWidth: 448),
    isScrollControlled: true,
    builder: (_) => const _ProfilesSheet(),
  );
}

class _ProfilesSheet extends StatefulWidget {
  const _ProfilesSheet();

  @override
  State<_ProfilesSheet> createState() => _ProfilesSheetState();
}

class _ProfilesSheetState extends State<_ProfilesSheet> {
  bool _switching = false;

  /// 多账号批（2026-10-25）：账号 id→短标签；>1 账号时电脑卡显示所属
  /// 账号徽标（单账号不显示——避免噪音）。
  Map<String, String> _accountLabels = const {};
  bool _labelsFetchInFlight = false;

  //徽标映射改为 build 期惰性补拉（在飞
  /// 去重）——弹层停留期间在别处添加/删除账号时，新绑定档案的徽标
  /// 此前永远显示不出来（只在打开时算一次）。
  void _maybeRefreshLabels(AppState app) {
    if (_labelsFetchInFlight) return;
    final needs = app.profiles.any(
      (p) =>
          p is AccountV2Profile &&
          p.accountId != null &&
          !_accountLabels.containsKey(p.accountId),
    );
    if (!needs) return;
    _labelsFetchInFlight = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (!mounted) return;
        final accounts = await app.accountStore.listAccounts();
        if (!mounted) return;
        // 已删账号的档案（match==null）此前不写入映射 →
        // needs 条件（!containsKey）每帧重新触发 listAccounts+setState
        // 循环。为全部已知 accountId 写入哨兵（已删 → '账号已删除'）。
        final knownIds = <String>{
          for (final p in app.profiles)
            if (p is AccountV2Profile && p.accountId != null) p.accountId!,
        };
        setState(() {
          // multi-account-ux-1 批1（2026-11-04 拍板）：徽标始终显示所属
          // 账号（不再只在多账号时显示），备注名优先。
          _accountLabels = {
            for (final a in accounts) a.id: a.displayName,
            for (final id in knownIds)
              if (!accounts.any((a) => a.id == id)) id: '账号已删除',
          };
        });
      } finally {
        _labelsFetchInFlight = false;
      }
    });
  }

  /// 波次 3a：切换 = 换活跃栈指针——后台保活的栈秒切（无重连等待）；
  /// 休眠栈（首次激活）建栈连接，任务中心横幅显示其连接进度。
  Future<void> _activate(AppState app, DeviceProfile profile) async {
    if (_switching) return;
    if (profile.deviceSid == app.activeProfile?.deviceSid) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _switching = true);
    try {
      await app.activate(profile);
    } catch (_) {
      // 连接失败不阻塞：任务中心会显示状态横幅
    }
    if (mounted) {
      setState(() => _switching = false);
      Navigator.of(context).pop();
    }
  }

  Future<void> _rename(AppState app, DeviceProfile profile) async {
    final controller = TextEditingController(text: profile.label);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名电脑'),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(fontSize: AppType.mobileInputSafe),
          decoration: InputDecoration(
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    // 对话框关闭后释放（批次1 顺手：原泄漏——每 rename 一次漏一个）。
    // showDialog 的 future 在 pop 瞬间完成，退场动画
    //（~200ms）里 dialog 树仍存活——延后到动画结束后再 dispose，防
    // 动画期编辑事件触碰已 dispose 的 controller。
    Future.delayed(const Duration(milliseconds: 400), controller.dispose);
    if (name != null && name.isNotEmpty) {
      try {
        await app.renameComputer(profile, name);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('已重命名'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('重命名失败：$e')));
        }
      }
    }
  }

  Future<void> _remove(AppState app, DeviceProfile profile) async {
    final ok = await showConfirmDialog(
      context,
      title: '删除「${profile.label}」？',
      message: '仅移除本机保存的连接档案，不影响电脑端。需要时可重新扫码添加。',
    );
    if (ok) {
      try {
        await app.removeComputer(profile);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('已删除'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('删除失败：$e')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    _maybeRefreshLabels(app);
    final list = app.profiles;
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              '我的电脑',
              style: TextStyle(
                fontSize: AppType.uiSm,
                fontWeight: FontWeight.w600,
                color: context.colors.foregroundSubtle,
              ),
            ),
          ),
          if (list.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                '还没有电脑。扫码添加第一台。',
                style: TextStyle(
                  color: context.colors.foregroundSubtle,
                  fontSize: AppType.uiCaption,
                ),
              ),
            ),
          // （2026-10-19 审查）：坏档案条目已跳过（不再全清空），提示
          // 用户有损坏数据——重扫该电脑可覆盖恢复。
          if (app.corruptedProfiles > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 14,
                    color: context.colors.warning,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '有 ${app.corruptedProfiles} 个档案数据损坏已跳过（重扫该电脑可恢复）',
                      style: TextStyle(
                        fontSize: AppType.uiXs,
                        color: context.colors.warning,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          for (final profile in list)
            _ProfileTile(
              profile: profile,
              accountBadge: profile is AccountV2Profile
                  ? (profile.accountId == null
                      // 未绑定（迁移前的存量形态）：凭据实际取 lastUsed。
                      ? '跟随当前账号'
                      : (_accountLabels[profile.accountId] ?? '账号已删除'))
                  : null,
              active: profile.deviceSid == app.activeProfile?.deviceSid,
              // 波次 3a：各电脑实时状态（后台保活栈显示真实连接态）
              phase: app.statusOf(profile),
              switching:
                  _switching &&
                  profile.deviceSid == app.activeProfile?.deviceSid,
              onTap: () => _activate(app, profile),
              onRename: () => _rename(app, profile),
              onRemove: () => _remove(app, profile),
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const PairingPage()));
            },
            icon: const Icon(Icons.add),
            label: const Text('添加电脑'),
          ),
        ],
      ),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  final DeviceProfile profile;

  /// 所属账号短标签（多账号批 2026-10-25；null=单账号/未绑定=不显示）。
  final String? accountBadge;

  /// 弱化徽标（"跟随当前账号"=非确定归属，用更淡前景）。
  bool get _badgeMuted => accountBadge == '跟随当前账号';
  final bool active;
  final LinkPhase phase;
  final bool switching;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onRemove;

  const _ProfileTile({
    required this.profile,
    this.accountBadge,
    required this.active,
    required this.phase,
    required this.switching,
    required this.onTap,
    required this.onRename,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final (dot, statusText) = _statusOf(context, phase);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: active ? context.colors.selected : context.colors.card,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(
          color: active ? context.colors.borderHover : context.colors.border,
        ),
      ),
      // Material 缓冲：有色 Container 直接包 ListTile 会藏墨水涟漪
      //（debug 断言拦截，官方建议包一层透明 Material——release 不受
      // 影响但补齐语义）。
      child: Material(
        color: Colors.transparent,
        child: ListTile(
          onTap: onTap,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          leading: switching
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
          title: Row(
            children: [
              Flexible(
                child: Text(
                  profile.label,
                  translate: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.uiBase,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              if (active) ...[
                const SizedBox(width: 6),
                Text(
                  '当前',
                  style: TextStyle(
                    fontSize: AppType.uiXs,
                    color: context.colors.foregroundSubtlest,
                  ),
                ),
              ],
              if (accountBadge != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: context.colors.sidebar,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    border: Border.all(color: context.colors.borderFaint),
                  ),
                  child: Text(
                    accountBadge!,
                    style: TextStyle(
                      fontSize: AppType.uiXs,
                      color: _badgeMuted
                          ? context.colors.foregroundSubtlest
                          : context.colors.foregroundSubtle,
                    ),
                  ),
                ),
              ],
            ],
          ),
          subtitle: statusText == null
              ? null
              : Text(
                  statusText,
                  style: TextStyle(
                    fontSize: AppType.uiXs,
                    color: context.colors.foregroundSubtlest,
                  ),
                ),
          trailing: PopupMenuButton<String>(
            // 激活等待期禁用重命名/删除——删除正在
            // 激活的档案会与 _createStack/start 竞态（registry 层有兜底
            // 但不该放行）。
            enabled: !switching,
            onSelected: (v) => v == 'rename'
                ? onRename()
                : v == 'remove'
                ? onRemove()
                : null,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('重命名')),
              PopupMenuItem(value: 'remove', child: Text('删除')),
            ],
          ),
        ),
      ),
    );
  }

  (Color, String?) _statusOf(BuildContext context, LinkPhase phase) =>
      switch (phase) {
        LinkPhase.online => (context.colors.success, null),
        LinkPhase.connecting ||
        LinkPhase.waitingDesktop ||
        LinkPhase.reconnecting => (context.colors.linkBlue, '连接中'),
        LinkPhase.kicked => (context.colors.destructive, '被其他设备接管'),
        LinkPhase.invalid => (context.colors.warning, '凭据失效，需重扫'),
        LinkPhase.error => (context.colors.destructive, '连接失败'),
        LinkPhase.offline => (context.colors.idleTask, null),
      };
}

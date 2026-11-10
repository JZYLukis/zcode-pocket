import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/l10n.dart';

import '../core/theme.dart';
import '../state/account_store.dart';
import '../state/app_state.dart';
import '../state/app_state_scope.dart';
import '../transport/z_transport.dart';
import 'app_widgets.dart';
import 'login_page.dart';
import 'pairing_page.dart';

/// 账号管理页（多账号批 2026-10-25，multi-account-plan §4.4）：账号
/// 清单（provider+短标签+绑定电脑数）、添加账号（官方 OAuth）、设为
/// 当前（扫码配对/设备列表跟随当前账号）、删除（其名下电脑档案提示）。
///
/// 语义提醒：删除账号只清凭据不动电脑档案——档案会在下次连接时按
/// 绑定账号取凭据，账号已删则连不上（诊断会提示重新登录）。
class SettingsAccountsPage extends StatefulWidget {
  const SettingsAccountsPage({super.key});

  @override
  State<SettingsAccountsPage> createState() => _SettingsAccountsPageState();
}

class _SettingsAccountsPageState extends State<SettingsAccountsPage> {
  /// 重命名对话框 controller 归 State 托管（ P2-6：此前取消路径
  /// 在退场动画中立即 dispose、保存路径永不 dispose——同 branch_sheet
  /// 批D 教训，统一列表+dispose 清理）。
  final _dialogControllers = <TextEditingController>[];

  @override
  void dispose() {
    for (final c in _dialogControllers) {
      c.dispose();
    }
    super.dispose();
  }
  List<StoredAccount> _accounts = const [];
  String? _lastUsed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reload();
    });
  }

  Future<void> _reload() async {
    final app = AppStateScope.of(context);
    final accounts = await app.accountStore.listAccounts();
    final last = await app.accountStore.lastUsedAccountId;
    if (!mounted) return;
    setState(() {
      _accounts = accounts;
      _lastUsed = last;
    });
  }

  Future<void> _addAccount() async {
    final result = await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const LoginPage()));
    // await 后先查 mounted 再做 inherited 查找
    //（防 defunct element 上的 dependOnInheritedWidget 断言）。
    if (!mounted) return;
    final app = AppStateScope.of(context);
    if (result is Map && result['jwt'] is String) {
      // 18079 反馈②审查根因收尾：删号后重登只写凭据不接回电脑=永久
      // 离线死态（只能大退 app 靠冷启兜底）。登录成功即编排接回
      //（改绑/激活绑定该账号的档案）。
      try {
        await app.reattachAfterAccountLogin();
      } catch (_) {}
      if (!mounted) return;
      await _reload();
      if (!mounted) return;
      // 批2：显式告知「当前账号未变」（消除"加了账号=换账号"错觉）。
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('账号已添加，当前账号未变')),
      );
    } else {
      // 登录页在 save 落盘与 pop 之间被用户按返回时
      // pop(null)，但账号可能已写进 store——一律按“用户取消”处理会跳过
      // reload/reattach（删号重登场景复现“凭据在、连接全无”死态）。
      // null 也兜底刷新列表；reattach 幂等（活跃栈健在时 no-op 无副作用）。
      await _reload();
      try {
        await app.reattachAfterAccountLogin();
      } catch (_) {}
    }
  }

  Future<void> _removeAccount(StoredAccount account, AppState app) async {
    final boundComputers = app.profiles
        .where((p) => p is AccountV2Profile && p.accountId == account.id)
        .length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('删除账号 ${account.shortLabel}？'),
        content: L10n.resolvedLocale == 'en-US'
            ? SingleChildScrollView(
                child: Text(
                  boundComputers > 0
                      ? '该账号名下有 $boundComputers 台电脑档案。删除后这些电脑将无法'
                            '连接（档案保留，重新登录该账号即可恢复）。'
                      : '删除后需要重新登录才能连接该账号的电脑。',
                ),
              )
            : Text(
                boundComputers > 0
                    ? '该账号名下有 $boundComputers 台电脑档案。删除后这些电脑将无法'
                          '连接（档案保留，重新登录该账号即可恢复）。'
                    : '删除后需要重新登录才能连接该账号的电脑。',
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: ValueKey('account-remove-ok'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // 18079 反馈②：走 AppState 完整编排（先删凭据、拆该账号全部连接
    // 栈+设备数据、活跃指针收尾）。WebView 的 Cookie 不在这里清——
    // 登录页每次进页都会平台级三清（Cookie/localStorage/Cache），在
    // 这里全局清 Cookie 反而会把同时活着的网页备用入口
    // 静默踢下线（审查 L2）。
    // 编排内 accountStore 的 secure storage
    // 多次读写（华为机型 Keystore 损坏并不罕见）抛出时兜底——人话报错
    // 并刷新列表反映真实状态（此前对话框已关、零反馈、“点了没反应”）。
    try {
      await app.removeAccount(account.id);
    } catch (e) {
      debugPrint('[app] removeAccount failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('删除账号失败，请重试'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
    if (!mounted) return;
    await _reload();
  }

  int _boundComputersOf(AppState app, String accountId) => app.profiles
      .where((p) => p is AccountV2Profile && p.accountId == accountId)
      .length;

  /// 活跃电脑是否绑定该账号（「连接中」标记）。
  bool _activeSidBoundTo(AppState app, String accountId) {
    final active = app.activeProfile;
    return active is AccountV2Profile && active.accountId == accountId;
  }

  /// 2026-11-05 反馈③重构：ListTile.trailing 按内在宽度先布局，
  /// 「设为当前」TextButton+双 IconButton（合计 ~180dp）把标题列挤到
  /// 断词（bigm/odel）+副标题不可读。改自定义行：文本列 Expanded 恒定
  /// 占宽 + 紧凑「设为当前」chip + 重命名/删除收进 ⋮ 菜单——当前/非
  /// 当前行列宽栅格一致，标题/副标题各一行 ellipsis。
  Widget _buildAccountRow(AppState app, StoredAccount account) {
    final isCurrent = account.id == _lastUsed;
    final bound = _boundComputersOf(app, account.id);
    return Padding(
      key: ValueKey('account-${account.id}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(
            Icons.account_circle_outlined,
            size: 22,
            color: context.colors.foregroundSubtle,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  // multi-account-ux-1 批1：备注名优先（如「公司订阅」），
                  // 未设置回退 provider；备注名是用户自定内容不翻译。
                  account.label.trim().isNotEmpty
                      ? account.label.trim()
                      : (account.provider.isEmpty ? '未知账号' : account.provider),
                  translate: account.label.trim().isEmpty &&
                      account.provider.isEmpty,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: AppType.uiBase,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  // 批1：电脑数 + 活跃电脑所属行「连接中」标记。
                  '${isCurrent ? '当前账号' : account.shortLabel}'
                  '${bound > 0 ? ' · $bound 台电脑' : ''}'
                  '${_activeSidBoundTo(app, account.id) ? ' · 连接中' : ''}',
                  translate: true,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.uiCaption,
                    color: context.colors.foregroundSubtle,
                  ),
                ),
              ],
            ),
          ),
          if (!isCurrent) ...[
            const SizedBox(width: 8),
            // en-w320s13 极端档（大字号英文）下 chip 单行内在宽会超行
            //（游览防溢出断言红）：TextButton 在无限宽下内在布局不换行，
            // Flexible 参与 flex 分配又会反向压缩文本列——ConstrainedBox
            // 封顶 120（正常档中英文内在宽均低于此值=布局零变化），
            // 极端档内两行换行收纳。
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: TextButton(
                key: ValueKey('account-use-${account.id}'),
                onPressed: () async {
                  await app.accountStore.setLastUsed(account.id);
                  if (!mounted) return;
                  await _reload();
                },
                style: TextButton.styleFrom(
                  minimumSize: const Size(56, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text(
                  '设为当前',
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: AppType.uiCaption),
                ),
              ),
            ),
          ],
          PopupMenuButton<String>(
            key: ValueKey('account-menu-${account.id}'),
            icon: Icon(
              Icons.more_vert,
              size: 20,
              color: context.colors.foregroundSubtle,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            onSelected: (v) {
              if (v == 'connect') {
                // 多账号配对（2026-11-08 对抗审查）：给指定账号配电脑
                // ——进配对页时把目标账号显式带下去，扫码/V2 直连/设备
                // 列表都按该账号建档案（此前只能落 lastUsed）。
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PairingPage(accountId: account.id),
                  ),
                );
              } else if (v == 'rename') {
                _renameAccount(account, app);
              } else if (v == 'remove') {
                _removeAccount(account, app);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'connect',
                key: ValueKey('account-connect-${account.id}'),
                child: Text(tr('连接该账号的电脑')),
              ),
              PopupMenuItem(value: 'rename', child: Text(tr('重命名账号'))),
              PopupMenuItem(value: 'remove', child: Text(tr('删除账号'))),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _renameAccount(StoredAccount account, AppState app) async {
    final controller = TextEditingController(text: account.label);
    _dialogControllers.add(controller);
    final label = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重命名账号'),
        content: TextField(
          key: const ValueKey('account-rename-input'),
          controller: controller,
          autofocus: true,
          maxLength: 20,
          decoration: InputDecoration(
            hintText: tr('如「公司订阅」「个人号」（仅本机保存）'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('account-rename-ok'),
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    // controller 释放归 State.dispose（见 _dialogControllers 注释）。
    if (label == null) return;
    try {
      await app.accountStore.renameAccount(account.id, label);
    } catch (_) {}
    if (!mounted) return;
    await _reload();
    if (!mounted) return;
    // force：改名后 sid+accountId 短路缓存会挡住同键刷新（fullsweep-1108）。
    app.refreshActiveAccountLabel(force: true);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('账号管理')),
      body: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(16),
        children: [
          const AppSectionHeader('账号'),
          for (final account in _accounts) _buildAccountRow(app, account),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const ValueKey('account-add'),
            onPressed: _addAccount,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('添加账号（官方登录）'),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '「当前账号」用于新扫码配对与设备列表。已配对的电脑始终用其绑定的'
              '账号连接；账号不符的电脑会在连接处提示换账号重连。',
              style: TextStyle(
                fontSize: AppType.uiCaption,
                color: context.colors.foregroundSubtle,
                height: 1.6,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

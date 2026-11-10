import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';

import '../core/theme.dart';
import '../state/git_branch_service.dart';

/// 分支切换弹层（阶段 6.2 选分支，2026-10-24）。
///
/// 官方语义=工作区级 git switch（GitBranchSwitcher 手机对等物）：切分支
/// 对该工作区全部并发会话全局生效——有运行中任务时先二次确认（官方无
/// 此守卫，手机端稳妥裁量）；阻塞码（未提交改动会被覆盖等）转人话指路
/// 桌面端。会话页顶栏副行分支标签点按进入；draft 态切完再发消息=会话
/// 跑在新分支上（"开工前切分支"）。
///
/// 数据走 [GitCall] 缝（生产=活跃桥 ChannelClient；测试注入夹具）。
Future<void> showBranchSheet(
  BuildContext context, {
  required GitCall call,
  required String workspacePath,
  required String workspaceLabel,
  required int runningTaskCount,
  void Function(String? currentBranch)? onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: context.colors.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.card)),
    ),
    isScrollControlled: true,
    builder: (_) => _BranchSheet(
      call: call,
      workspacePath: workspacePath,
      workspaceLabel: workspaceLabel,
      runningTaskCount: runningTaskCount,
      onChanged: onChanged,
    ),
  );
}

class _BranchSheet extends StatefulWidget {
  const _BranchSheet({
    required this.call,
    required this.workspacePath,
    required this.workspaceLabel,
    required this.runningTaskCount,
    this.onChanged,
  });

  final GitCall call;
  final String workspacePath;
  final String workspaceLabel;
  final int runningTaskCount;
  final void Function(String? currentBranch)? onChanged;

  @override
  State<_BranchSheet> createState() => _BranchSheetState();
}

class _BranchSheetState extends State<_BranchSheet> {
  /// 新建分支对话框的输入控制器（：不漏释放）。
  /// 由 State 托管而非延迟 Timer——退场动画期间的 TextField 仍可用，
  /// 页面销毁时统一 dispose（FakeAsync 下无悬挂 Timer）。
  final _dialogControllers = <TextEditingController>[];

  @override
  void dispose() {
    for (final c in _dialogControllers) {
      c.dispose();
    }
    super.dispose();
  }
  GitRepoOverview? _overview;
  String? _error;
  bool _loading = true;
  bool _switching = false;
  String? _switchingBranch;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final overview = await fetchGitOverview(
        widget.call,
        widget.workspacePath,
      );
      if (!mounted) return;
      setState(() {
        _overview = overview;
        _loading = false;
      });
      widget.onChanged?.call(overview.currentBranch);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _handleMutationResult(
    Map<dynamic, dynamic> res,
    String successLabel,
  ) async {
    final issues = res['issues'];
    final hasIssues = issues is List && issues.isNotEmpty;
    if (res['ok'] == true && !hasIssues) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已切换到 $successLabel')));
      await _reload();
      return;
    }
    // 官方失败形态：ok=false + issues[]（阻塞码全集）。
    final message = hasIssues ? branchIssuesMessage(issues) : '切换失败，请稍后重试';
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('无法切换'),
        content: Text(message),
        actions: [
          TextButton(
            key: const ValueKey('branch-issue-ok'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _switchTo(GitBranch branch) async {
    if (_switching || branch.isCurrent) return;
    // 全局生效守卫：工作区有运行中任务时二次确认（官方无此守卫）。
    // 注：runningTaskCount 是弹层打开时刻的快照（ 注明
    // 取舍）——弹层短命且确认框紧随点按，窗口内计数翻转概率极低。
    if (widget.runningTaskCount > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('切换分支？'),
          content: Text(
            '该工作区有 ${widget.runningTaskCount} 个运行中任务。切分支对整个'
            '工作区全局生效（官方语义），运行中的会话也会受影响。确定切换到'
            '「${branch.name}」？',
          ),
          actions: [
            TextButton(
              key: const ValueKey('branch-confirm-cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              key: const ValueKey('branch-confirm-ok'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('切换'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() {
      _switching = true;
      _switchingBranch = branch.name;
    });
    try {
      final res = await switchGitBranch(
        widget.call,
        widget.workspacePath,
        branch.name,
      );
      if (!mounted) return;
      setState(() {
        _switching = false;
        _switchingBranch = null;
      });
      await _handleMutationResult(res, branch.name);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _switching = false;
        _switchingBranch = null;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('切换失败，请重试：$e')));
    }
  }

  Future<void> _createBranch() async {
    if (_switching) return;
    final controller = TextEditingController();
    _dialogControllers.add(controller);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('新建分支并切换'),
        content: TextField(
          key: const ValueKey('branch-create-input'),
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: tr('分支名，如 feature/x')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('branch-create-ok'),
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    final branchName = (name ?? '').trim();
    // 释放归 State.dispose（见 _dialogControllers 声明）——不在此处
    // 延迟 dispose，避免退场动画期间的悬挂 Timer（FakeAsync 断言）。
    if (branchName.isEmpty) return;
    setState(() {
      _switching = true;
      _switchingBranch = branchName;
    });
    try {
      final res = await createAndSwitchGitBranch(
        widget.call,
        widget.workspacePath,
        branchName,
      );
      if (!mounted) return;
      setState(() {
        _switching = false;
        _switchingBranch = null;
      });
      await _handleMutationResult(res, branchName);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _switching = false;
        _switchingBranch = null;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('创建失败，请重试：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final overview = _overview;
    final maxHeight = MediaQuery.of(context).size.height * 0.7;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
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
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '分支',
                          style: TextStyle(
                            fontSize: AppType.uiBase,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          widget.workspaceLabel,
                          translate: false,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppType.uiXs,
                            color: context.colors.foregroundSubtle,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('branch-create-entry'),
                    tooltip: tr('新建分支并切换'),
                    iconSize: 20,
                    icon: const Icon(Icons.add),
                    onPressed: _overview?.isRepository == true && !_loading
                        ? _createBranch
                        : null,
                  ),
                  IconButton(
                    key: const ValueKey('branch-refresh'),
                    tooltip: tr('刷新'),
                    iconSize: 20,
                    icon: const Icon(Icons.refresh),
                    onPressed: _loading ? null : _reload,
                  ),
                ],
              ),
            ),
            Flexible(child: _buildBody(context, overview)),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, GitRepoOverview? overview) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '分支信息加载失败：$_error',
              style: TextStyle(
                fontSize: AppType.uiSm,
                color: context.colors.foregroundSubtle,
              ),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: _reload, child: const Text('重试')),
          ],
        ),
      );
    }
    if (overview == null || !overview.isRepository) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.folder_off_outlined,
              size: 16,
              color: context.colors.foregroundSubtlest,
            ),
            const SizedBox(width: 6),
            Text(
              '该工作区不是 git 仓库',
              style: TextStyle(
                fontSize: AppType.uiSm,
                color: context.colors.foregroundSubtle,
              ),
            ),
          ],
        ),
      );
    }
    final branches = overview.branches;
    if (branches.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            '暂无本地分支',
            style: TextStyle(
              fontSize: AppType.uiSm,
              color: context.colors.foregroundSubtle,
            ),
          ),
        ),
      );
    }
    return ListView.builder(
      key: const ValueKey('branch-list'),
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      itemCount: branches.length,
      itemBuilder: (context, i) {
        final b = branches[i];
        final busy = _switching && _switchingBranch == b.name;
        return ListTile(
          key: ValueKey('branch-item-${b.name}'),
          dense: true,
          leading: Icon(
            b.isCurrent ? Icons.check_circle : Icons.call_split_outlined,
            size: 18,
            color: b.isCurrent
                ? context.colors.linkBlue
                : context.colors.foregroundSubtlest,
          ),
          title: Text(
            b.name,
            translate: false,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppType.uiBase,
              fontWeight: b.isCurrent ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          subtitle: b.upstreamName != null
              ? Text(
                  b.upstreamName!,
                  translate: false,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.uiXs,
                    color: context.colors.foregroundSubtlest,
                  ),
                )
              : null,
          trailing: busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : (b.isCurrent
                    ? Text(
                        '当前',
                        style: TextStyle(
                          fontSize: AppType.uiXs,
                          color: context.colors.foregroundSubtlest,
                        ),
                      )
                    : null),
          onTap: busy ? null : () => _switchTo(b),
        );
      },
    );
  }
}

import '../transport/channel_client.dart';

/// git 通道分支服务（阶段 6.2 选分支，2026-10-24）。
///
/// 官方契约：官方 3.16.2 源码快照 packages/services/src/git/git.ts:32-55
/// （ServiceChannels.Git = "git"，channels.ts:97；按 workspacePath 寻址，
/// 分支是工作区级状态——任何切换对该工作区全部并发会话全局生效）。
/// 通道放行已由 tools/git-channel-probe.mjs 对真桌面实证（2026-10-24：
/// getWorkspaceRepositoryInfo/getLocalBranches 返回真实数据，~280ms）。
///
/// 调用统一走 [GitCall] 缝（生产=AppState.gitChannelCall 走活跃桥的
/// ChannelClient；测试注入夹具闭包）——多电脑栈隔离由"活跃桥"天然保证。

/// git 通道调用缝：method ∈ getWorkspaceRepositoryInfo/getLocalBranches/
/// switchBranch/createBranchAndSwitch。
typedef GitCall = Future<dynamic> Function(String method, List<Object?> args);

class GitBranch {
  final String name;
  final bool isCurrent;
  final String? upstreamName;
  const GitBranch(this.name, {this.isCurrent = false, this.upstreamName});
}

/// 工作区 git 概览（一次加载合并 repoInfo+branches）。
class GitRepoOverview {
  /// false = 非 git 仓库或 git 不可用（降级门：入口不展示）。
  final bool isRepository;
  final String kind;
  final String? currentBranch;
  final List<GitBranch> branches;
  const GitRepoOverview({
    required this.isRepository,
    this.kind = '',
    this.currentBranch,
    this.branches = const [],
  });
}

/// 纯解析：repoInfo（GitWorkspaceRepositoryInfo）+ branches
/// （GitLocalBranchListResult）→ 概览。测试直接喂夹具。
GitRepoOverview parseGitOverview(Map<dynamic, dynamic>? repoInfo, Map<dynamic, dynamic>? branches) {
  final info = repoInfo ?? const {};
  final kind = '${info['kind'] ?? ''}';
  final gitOk = info['isGitAvailable'] == true;
  final isRepository = gitOk && kind != 'not-repository' && kind.isNotEmpty;
  if (!isRepository) {
    return GitRepoOverview(isRepository: false, kind: kind);
  }
  final list = branches ?? const {};
  final rows = list['branches'];
  final parsed = <GitBranch>[
    if (rows is List)
      for (final r in rows)
        if (r is Map && '${r['name'] ?? ''}'.isNotEmpty)
          GitBranch(
            '${r['name']}',
            isCurrent: r['isCurrent'] == true,
            upstreamName: r['upstreamName'] is String ? r['upstreamName'] as String? : null,
          ),
  ];
  // 当前分支以 result.currentBranchName 为权威（headRefType=detached 时为
  // null——detached HEAD 无分支可切，列表照常展示）。
  final current = list['currentBranchName'] is String
      ? list['currentBranchName'] as String?
      : null;
  return GitRepoOverview(
    isRepository: true,
    kind: kind,
    currentBranch: current,
    branches: parsed,
  );
}

/// 拉取工作区 git 概览（repoInfo 先行，非仓库即短路不再拉分支）。
Future<GitRepoOverview> fetchGitOverview(GitCall call, String workspacePath) async {
  final info = await call('getWorkspaceRepositoryInfo', [
    {'workspacePath': workspacePath},
  ]);
  if (info is! Map) {
    throw const FormatException('getWorkspaceRepositoryInfo 返回异常');
  }
  final quick = parseGitOverview(info, null);
  if (!quick.isRepository) return quick;
  final list = await call('getLocalBranches', [
    {'workspacePath': workspacePath},
  ]);
  return parseGitOverview(info, list is Map ? list : null);
}

/// 切换分支（官方 GitSwitchBranchRequest：workspacePath+targetBranchName）。
/// 返回原始 GitBranchMutationResult（ok/didChange/issues），错误映射见
/// [branchIssuesMessage]。
Future<Map<dynamic, dynamic>> switchGitBranch(
  GitCall call,
  String workspacePath,
  String targetBranchName,
) async {
  final res = await call('switchBranch', [
    {'workspacePath': workspacePath, 'targetBranchName': targetBranchName},
  ]);
  return res is Map ? res : const {};
}

/// 新建分支并切换（官方 GitCreateBranchRequest：branchName+可选 startPoint，
/// 省略=当前 HEAD）。
Future<Map<dynamic, dynamic>> createAndSwitchGitBranch(
  GitCall call,
  String workspacePath,
  String branchName,
) async {
  final res = await call('createBranchAndSwitch', [
    {'workspacePath': workspacePath, 'branchName': branchName},
  ]);
  return res is Map ? res : const {};
}

/// 阻塞码 → 人话（官方 GitBranchMutationIssueCode 全集，
/// shared/git.ts:26-35；手机端不提供官方的"提交后重试"流程，指路桌面端）。
String branchIssuesMessage(List<dynamic> issues) {
  if (issues.isEmpty) return '切换失败，请稍后重试';
  final first = issues.first;
  final code = first is Map ? '${first['code'] ?? ''}' : '';
  final mapped = switch (code) {
    'tracked-changes-would-be-overwritten' => '有未提交改动会被切分支覆盖——请先在桌面端提交或暂存，再回来切换',
    'untracked-changes-would-be-overwritten' => '有未跟踪的新文件会被切分支覆盖——请先在桌面端提交或暂存，再回来切换',
    'conflicts-present' => '仓库里有未解决的冲突——请先在桌面端处理',
    'operation-in-progress' => '另一个 git 操作正在进行中，请稍后重试',
    'branch-in-other-worktree' => '目标分支正被另一个 worktree 占用',
    'target-branch-not-found' => '目标分支不存在——列表可能过期，请刷新后重试',
    'branch-already-exists' => '分支名已存在',
    'invalid-branch-name' => '分支名不合法（含空格/特殊字符/中文斜杠等）',
    _ => null,
  };
  // 兜底不再渲染空括号（「切换失败」——本项目
  // 曾有专案根除史）。优先级：官方 message（服务端人话，信息量最大）→
  // 未知 code（稳定枚举式码，可回溯）→ 通用文案。
  if (mapped != null) return mapped;
  final message = first is Map ? '${first['message'] ?? ''}'.trim() : '';
  if (message.isNotEmpty) return message;
  if (code.trim().isNotEmpty) return '切换失败（$code）';
  return '切换失败，请稍后重试';
}

/// Channels.git 通道名（注册见 app_state.gitChannelCall）。
const gitChannelName = Channels.git;

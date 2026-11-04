/// 工作区项目树（ 工作区列表修复）：官方 IProjectService.readTree
/// 与 workspace-bridge-open project intent 的消费层纯函数。
///
/// 背景：3.16 起 workspace-list 的 workspaces[] 语义="当前窗口 tabs"，
/// 启动只恢复 1 个 tab——项目全集要走 `project` channel 的 readTree；
/// 未开 tab 的项目用 bridge-open 的 project intent 现场准备（桌面
/// prepareProjectWorkspace），不再受"必须在当前窗口 tabs"限制。
///
/// 契约出处（refs/new-snapshot）：
/// - services/src/project/contract.ts:33-37 readTree 签名；
/// - services/src/project-storage/contract.ts:30-65
///   VirtualProject/ProjectTask/ProjectTree 字段（ProjectTask =
///   ZCodeTaskMeta & {projectId, hostId, pinned, archived}）；
/// - shared/src/validation.ts:258-286 project intent 严格校验：
///   与 taskId/fileTreeTaskId 互斥，draftId 仅限 projectId=null；
/// - shared/src/web-remote-control.ts:378-400 ready 桥载荷（本地桥无
///   workspaceIdentity，远程桥必有）；
/// - web/src/main.tsx:1854-1874 官方 web 发起 project 导航时 request
///   workspaceKey 为占位值，真实 target 由桌面解析后随 ready 返回。
library;

/// workspaceKey = workspaceIdentity.trim() || workspacePath
/// （web-remote-control.ts:837-841）。
String? workspaceKeyOf(Map workspace) {
  final identity = workspace['workspaceIdentity'];
  if (identity is String && identity.trim().isNotEmpty) return identity.trim();
  final path = workspace['workspacePath'];
  if (path is String && path.trim().isNotEmpty) return path.trim();
  return null;
}

/// readTree 结果的宽松解析（原样 Map 列表，含已删项目/任务聚合）。
({List<Map<String, dynamic>> projects, List<Map<String, dynamic>> tasks})
parseProjectTree(dynamic result) {
  if (result is! Map) return (projects: const [], tasks: const []);
  List<Map<String, dynamic>> asList(dynamic raw) => [
        for (final e in (raw is List ? raw : const []).whereType<Map>())
          e.cast<String, dynamic>(),
      ];
  return (
    projects: asList(result['projects']),
    tasks: asList(result['tasks']),
  );
}

/// 侧栏可见项目：剔除 deleted，position 升序（缺省排最后，同位按名）。
List<Map<String, dynamic>> visibleProjectsOf(
  List<Map<String, dynamic>> projects,
) {
  final visible = [
    for (final p in projects)
      if (p['deleted'] != true) p,
  ];
  int positionOf(Map<String, dynamic> p) => (p['position'] as num?)?.toInt() ?? 1 << 30;
  visible.sort((a, b) {
    final byPos = positionOf(a).compareTo(positionOf(b));
    if (byPos != 0) return byPos;
    return '${a['name'] ?? ''}'.compareTo('${b['name'] ?? ''}');
  });
  return visible;
}

/// workspace-bridge-open 的 project intent。官方 zod：projectId 非空串、
/// hostId 可选非空串（"local" 合法）；与 taskId 互斥由 openBridge 调用方保证。
Map<String, dynamic> projectIntentOf(Map<String, dynamic> project) {
  final hostId = '${project['hostId'] ?? ''}'.trim();
  return {
    'projectId': '${project['id'] ?? ''}'.trim(),
    if (hostId.isNotEmpty) 'hostId': hostId,
  };
}

/// 项目根目录路径列表（roots[].rootPath，保持顺序）。
List<String> rootPathsOf(Map<String, dynamic> project) {
  final roots = project['roots'];
  if (roots is! List) return const [];
  return [
    for (final r in roots.whereType<Map>())
      if ('${r['rootPath'] ?? ''}'.trim().isNotEmpty)
        '${r['rootPath']}'.trim(),
  ];
}

/// 主根目录（isPrimary 优先，否则第一个 root）——project intent 请求的
/// workspaceKey 占位值（官方 web 用 "project-navigation"，语义等价）。
String? primaryRootOf(Map<String, dynamic> project) {
  final roots = project['roots'];
  if (roots is! List) return null;
  String? first;
  for (final r in roots.whereType<Map>()) {
    final path = '${r['rootPath'] ?? ''}'.trim();
    if (path.isEmpty) continue;
    first ??= path;
    if (r['isPrimary'] == true) return path;
  }
  return first;
}

/// 任务行的 workspace 键（identity 优先，同 workspace-list 条目键序）。
String? taskWorkspaceKey(Map<String, dynamic> task) {
  final identity = '${task['workspaceIdentity'] ?? ''}'.trim();
  if (identity.isNotEmpty) return identity;
  final path = '${task['workspacePath'] ?? ''}'.trim();
  return path.isEmpty ? null : path;
}

/// 按 workspace 键反查所属项目：先匹配任务聚合（projectId 归属），
/// 再退回项目 roots 路径直配（空项目）。null=不属于任何已知项目。
/// PF-3③（2026-10-24 修复批）：同键多任务归属不同项目时取 updatedAt
/// 最新的归属（确定性 tie-break——原实现取数组首个，readTree 行序
/// 漂移会让侧栏分组抖动）。
Map<String, dynamic>? projectForWorkspaceKey({
  required List<Map<String, dynamic>> projects,
  required List<Map<String, dynamic>> tasks,
  required String key,
}) {
  Map<String, dynamic>? latestOwned;
  int latestAt = -1;
  for (final t in tasks) {
    if (taskWorkspaceKey(t) != key) continue;
    final pid = '${t['projectId'] ?? ''}'.trim();
    if (pid.isEmpty) continue; // 未归类任务：不参与归属仲裁
    final at = (t['updatedAt'] as num?)?.toInt() ?? 0;
    if (at > latestAt) {
      latestAt = at;
      latestOwned = t;
    }
  }
  if (latestOwned != null) {
    final pid = '${latestOwned['projectId']}'.trim();
    for (final p in projects) {
      if ('${p['id'] ?? ''}' == pid) return p;
    }
    return null;
  }
  for (final p in projects) {
    if (rootPathsOf(p).contains(key)) return p;
  }
  return null;
}

/// project intent 的 ready 桥载荷 → activeWorkspace 条目（与
/// workspace-list 条目同构；label 取项目名）。本地桥无 identity。
Map<String, dynamic> workspaceFromBridgePayload(
  Map<String, dynamic> bridge, {
  String? label,
}) {
  var path = '${bridge['workspacePath'] ?? ''}'.trim();
  if (path.isEmpty) path = '${bridge['workspaceKey'] ?? ''}'.trim();
  final identity = '${bridge['workspaceIdentity'] ?? ''}'.trim();
  return {
    'workspacePath': path,
    if (identity.isNotEmpty) 'workspaceIdentity': identity,
    if (label != null && label.trim().isNotEmpty) 'label': label,
    'kind': '${bridge['kind'] ?? 'local'}',
  };
}

// ----------------------------------------------- 未归类任务（默认工作区）

/// 未归类任务判定（官方"任务"区=workspacePurpose=conversation 的任务，
/// workspacePurpose.ts:2；projectId 空即无项目归属——官方"全局创建显式
/// 空归属"语义，project-storage/CONTRACT.md）。
bool isUnclassifiedTask(Map<String, dynamic> task) {
  final pid = '${task['projectId'] ?? ''}'.trim();
  if (pid.isNotEmpty) return false;
  return taskWorkspaceKey(task) != null;
}

/// 最新未归类任务（updatedAt 最大；缺省 0）。
Map<String, dynamic>? latestUnclassifiedTask(List<Map<String, dynamic>> tasks) {
  Map<String, dynamic>? best;
  int bestAt = -1;
  for (final t in tasks) {
    if (!isUnclassifiedTask(t)) continue;
    final at = (t['updatedAt'] as num?)?.toInt() ?? 0;
    if (at > bestAt) {
      bestAt = at;
      best = t;
    }
  }
  return best;
}

/// 未归类任务全集（updatedAt 降序）——「任务」列表页数据源（官方桌面
/// "任务"区=全部 projectId=null 任务，跨目录聚合：workspace\default 与
/// 各 `~/.zcode/workspace/<时间戳>-<uuid>` 独立目录并列）。
List<Map<String, dynamic>> unclassifiedTasksOf(
  List<Map<String, dynamic>> tasks,
) {
  final out = [for (final t in tasks) if (isUnclassifiedTask(t)) t];
  int updatedAtOf(Map<String, dynamic> t) =>
      (t['updatedAt'] as num?)?.toInt() ?? 0;
  out.sort((a, b) => updatedAtOf(b).compareTo(updatedAtOf(a)));
  return out;
}

/// 任务 intent 开桥的 request 键（任务 workspace 键，官方
/// webRemoteControlManager.ts:962-972：task.workspaceKey 随 intent 上行）。
String? taskOpenKey(Map<String, dynamic> task) => taskWorkspaceKey(task);

/// 「任务」聚合行实时状态覆盖（2026-10-26 真机验收②）：readTree 行只有
/// 持久终态——运行中的窗口在聚合视图里恒显示上一回合的"完成"（真机
/// 实锤）。活卡（si 合并任务模型，taskId=session id 同键）有该任务的
/// 实时 phase 时覆盖进 displayStatus（_CrossTaskCard 的
/// displayStatus ?? status 取值序天然吃到）；无实时订阅的任务（跨工作区）
/// 维持持久值——协议边界，诚实呈现。纯函数供单测。
List<Map<String, dynamic>> overlayLivePhase(
  List<Map<String, dynamic>> rows,
  Map<String, String> livePhaseByTaskId,
) {
  final out = <Map<String, dynamic>>[];
  for (final t in rows) {
    final id = '${t['taskId'] ?? ''}';
    final live = id.isEmpty ? null : livePhaseByTaskId[id];
    if (live is String) {
      out.add(({...t})..['displayStatus'] = live);
    } else {
      out.add(t);
    }
  }
  return out;
}

/// 「任务」伪项目条目（官方侧栏 workspaceSidebar.conversationsSection=
/// "任务"，zh-CN.ts:2048——桌面同款分区名）。
const String conversationsPseudoProjectId = '__conversations__';

Map<String, dynamic> conversationsPseudoProject() => const {
      'id': conversationsPseudoProjectId,
      'name': '任务',
    };

/// 应用本地项目排序（2026-10-26 拍板③，官方 preferences.reorder 同
/// 语义=客户端本地偏好）：[order] 为用户自定义的项目 id 序；命中的按
/// 序前置，未记录的新项目按 readTree 原序追加在尾部；「任务」伪项目
/// 恒排最后（聚合入口固定尾位）。null/空=原序不动。纯函数供单测。
List<Map<String, dynamic>> applyProjectOrder(
  List<Map<String, dynamic>> entries,
  List<String>? order,
) {
  if (order == null || order.isEmpty) return entries;
  final rank = {for (var i = 0; i < order.length; i++) order[i]: i};
  final pseudo = <Map<String, dynamic>>[];
  final known = <Map<String, dynamic>>[];
  final rest = <Map<String, dynamic>>[];
  for (final e in entries) {
    if ('${e['id'] ?? ''}' == conversationsPseudoProjectId) {
      pseudo.add(e);
    } else if (rank.containsKey('${e['id'] ?? ''}')) {
      known.add(e);
    } else {
      rest.add(e);
    }
  }
  known.sort((a, b) =>
      rank['${a['id'] ?? ''}']!.compareTo(rank['${b['id'] ?? ''}']!));
  return [...known, ...rest, ...pseudo];
}

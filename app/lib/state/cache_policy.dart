/// 阶段 3 缓存策略（纯函数， 的代码化）。
///
/// 三类本地缓存共用的判定/淘汰/对账规则全部集中在此，存储层
/// （local_cache.dart）只做 IO，接线层只做调度——策略可在无 IO 环境
/// 单测（失效协议三分支 / LRU / 预算记账）。
library;

/// 会话缓存条目（序列化形态，与渲染层解耦——存协议行不存渲染模型）。
class SessionCacheEntry {
  /// v2（2026-10-23）：firstRowId/totalCount 的写入端已修复"快照形状
  /// 异常清零+append 重设游标"缺陷——v1 条目可能固化了损坏计数，
  /// 读取端以 [historyTrusted]=false 拒绝信任其历史游标（行数据本身
  /// 照用；水位不变量只依赖 rows/logEpoch/seq，不受影响）。
  static const schemaVersion = 2;

  final String deviceSid;
  final String sessionId;

  /// 协议行（快照 window + 后续 delta 的合并结果，截尾至 [maxCachedRows]）。
  final List<Map<String, dynamic>> rows;

  /// 落盘时的水位：logEpoch + lastSeq（"历史未重写"的一致性锚点）。
  final String? logEpoch;
  final int lastSeq;

  /// 分页游标（恢复 canLoadOlder 判断；截尾后 firstRowId=保留区首行）。
  final int? firstRowId;
  final int totalCount;

  /// v1 条目为 false：历史游标不可信（升级自愈用，见 [schemaVersion]）。
  final bool historyTrusted;

  /// 会话控制块（control/config/queue/usage/goal 等，快照去掉 rows 的
  /// 部分）——恢复 appbar/输入区初始状态用。可能为 null（旧条目）。
  final Map<String, dynamic>? snapshotControl;

  final int savedAt;
  final int byteSize;

  const SessionCacheEntry({
    required this.deviceSid,
    required this.sessionId,
    required this.rows,
    required this.logEpoch,
    required this.lastSeq,
    required this.firstRowId,
    required this.totalCount,
    required this.snapshotControl,
    required this.savedAt,
    required this.byteSize,
    bool? historyTrusted,
  }) : historyTrusted = historyTrusted ?? true;

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'deviceSid': deviceSid,
    'sessionId': sessionId,
    'logEpoch': logEpoch,
    'lastSeq': lastSeq,
    'firstRowId': firstRowId,
    'totalCount': totalCount,
    'snapshotControl': snapshotControl,
    'rows': rows,
    'savedAt': savedAt,
    'byteSize': byteSize,
  };

  static SessionCacheEntry? fromJson(Map<String, dynamic> m) {
    final sid = m['sessionId'];
    final deviceSid = m['deviceSid'];
    if (sid is! String || sid.isEmpty || deviceSid is! String) return null;
    final rowsRaw = m['rows'];
    if (rowsRaw is! List) return null;
    final rows = rowsRaw
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    final v = (m['schemaVersion'] as num?)?.toInt() ?? 1;
    return SessionCacheEntry(
      deviceSid: deviceSid,
      sessionId: sid,
      rows: rows,
      logEpoch: m['logEpoch'] as String?,
      lastSeq: (m['lastSeq'] as num?)?.toInt() ?? 0,
      firstRowId: (m['firstRowId'] as num?)?.toInt(),
      totalCount: (m['totalCount'] as num?)?.toInt() ?? rows.length,
      // P3-9：前向兼容方向——旧读取端遇到未来 v3 条目应按
      // 不可信处理（版本升级的意义恰是"旧读取端别信新写入端"），判定
      // 此前用 >= 会把 v3 误判 trusted。
      historyTrusted: v == schemaVersion,
      snapshotControl: (m['snapshotControl'] as Map?)
          ?.cast<String, dynamic>(),
      savedAt: (m['savedAt'] as num?)?.toInt() ?? 0,
      byteSize: (m['byteSize'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 设备级缓存（工作区/任务列表 + 桥身份，每 deviceSid 一份）。
///
/// 桥缓存红线（phase3-cache-design"桥缓存"节）：这里只存"界面上次呈现
/// 了什么、上次开到哪"——恢复时用于**预渲染**与状态提示；恢复路径本身
/// （bootstrap → workspace-list → workspace-bridge-open → 订阅）一步不减。
class DeviceCacheEntry {
  static const schemaVersion = 1;

  final String deviceSid;

  /// 上次的 workspace-list 结果（工作区栏预渲）。
  final List<Map<String, dynamic>> workspaces;

  /// B 首页增量（2026-10-27 用户⑨）：项目全集、readTree 归属与当前
  /// 窗口全局任务——冷启动直接出最近/项目分组，不等桥与 si。
  /// 均为可选字段，旧缓存缺失时自然为空。
  final List<Map<String, dynamic>> projects;
  final List<Map<String, dynamic>> projectTasks;
  final List<Map<String, dynamic>> workspaceTasks;

  /// 上次成功打开的桥身份（完整 workspace map——含
  /// workspacePath/workspaceIdentity，恢复目标预判与标记用）。
  final Map<String, dynamic>? activeWorkspace;
  final String? desktopAppVersion;

  /// 任务列表呈现所需的双源原始数据（si sessions 原始条目 + 通道三列表
  /// + 已删除墓碑集——负向 join 所需，缺失时旧缓存退化为不过滤）。
  final List<Map<String, dynamic>> sessions;
  final List<Map<String, dynamic>> channelActive;
  final List<String> pinnedIds;
  final List<String> archivedIds;
  final List<String> deletedIds;

  final int savedAt;

  const DeviceCacheEntry({
    required this.deviceSid,
    required this.workspaces,
    this.projects = const [],
    this.projectTasks = const [],
    this.workspaceTasks = const [],
    required this.activeWorkspace,
    required this.desktopAppVersion,
    required this.sessions,
    required this.channelActive,
    required this.pinnedIds,
    required this.archivedIds,
    this.deletedIds = const [],
    required this.savedAt,
  });

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'deviceSid': deviceSid,
    'workspaces': workspaces,
    'projects': projects,
    'projectTasks': projectTasks,
    'workspaceTasks': workspaceTasks,
    'activeWorkspace': activeWorkspace,
    'desktopAppVersion': desktopAppVersion,
    'sessions': sessions,
    'channelActive': channelActive,
    'pinnedIds': pinnedIds,
    'archivedIds': archivedIds,
    'deletedIds': deletedIds,
    'savedAt': savedAt,
  };

  static DeviceCacheEntry? fromJson(Map<String, dynamic> m) {
    final sid = m['deviceSid'];
    if (sid is! String || sid.isEmpty) return null;
    List<Map<String, dynamic>> maps(Object? raw) => raw is List
        ? raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
        : const [];
    // P3-5：null 元素 '${null}' 产生的 "null" 死 id 不再混入
    // pinned/archived/deleted 集合（外来文件防御）。
    List<String> strings(Object? raw) => raw is List
        ? raw.whereType<String>().where((e) => e.isNotEmpty).toList()
        : const [];
    return DeviceCacheEntry(
      deviceSid: sid,
      workspaces: maps(m['workspaces']),
      projects: maps(m['projects']),
      projectTasks: maps(m['projectTasks']),
      workspaceTasks: maps(m['workspaceTasks']),
      activeWorkspace: (m['activeWorkspace'] as Map?)
          ?.cast<String, dynamic>(),
      desktopAppVersion: m['desktopAppVersion'] as String?,
      sessions: maps(m['sessions']),
      channelActive: maps(m['channelActive']),
      pinnedIds: strings(m['pinnedIds']),
      archivedIds: strings(m['archivedIds']),
      deletedIds: strings(m['deletedIds']),
      savedAt: (m['savedAt'] as num?)?.toInt() ?? 0,
    );
  }
}

// ---------------------------------------------------------------- 预算常量

/// 首页任务缓存裁剪（2026-10-27 用户⑨）：只保留展示/归属所需字段，
/// 不缓存 searchSnippet(s) 等正文片段，避免放大体积与隐私面。
/// [sanitizeLive]=true 用于读取预览：running/waiting 清洗为 idle，不冒充
/// 当前仍运行；写入时保留原值，真实数据到达后自然覆盖。
List<Map<String, dynamic>> cacheHomeTaskRows(
  List<Map<String, dynamic>> tasks, {
  bool sanitizeLive = false,
}) {
  const keys = [
    'taskId',
    'title',
    'workspacePath',
    'workspaceIdentity',
    'workspaceLabel',
    'projectId',
    'hostId',
    'createdAt',
    'updatedAt',
    'unreadAt',
    'archived',
    'pinned',
    // F5：B/A 批新字段——离线预览行保留月亮与后台点（run 线对象
    // 较重不入缓存，live 到达即恢复）。
    'offPeakTaskId',
    'hasBackgroundWork',
    'status',
    'displayStatus',
    'hasBackgroundWork',
    'historical',
    'goalStatus',
  ];
  return [
    for (final t in tasks)
      if ('${t['taskId'] ?? ''}'.isNotEmpty)
        () {
          // P3-8：displayStatus 空串此前 `??` 不兜（只兜
          // null）——空串+status=running 时既不命中清洗也不回退 status，
          // 读取预渲会冒充运行态。空串视为缺省回退 status。
          final ds = '${t['displayStatus'] ?? ''}'.trim();
          final effective = ds.isNotEmpty ? ds : '${t['status'] ?? ''}';
          return {
            for (final k in keys)
              if (t.containsKey(k)) k: t[k],
            if (sanitizeLive &&
                (effective == 'running' ||
                    effective == 'prewarming' ||
                    effective == 'waiting'))
              ...{
                'displayStatus': 'idle',
                'status': 'idle',
                'pendingInteraction': null,
              },
          };
        }(),
  ];
}

// ---------------------------------------------------------------- 预算常量

/// 行数上限/会话（设计文档起步值，实测后调：按真实会话观测取 200 行/会话）。
const maxCachedRows = 200;

/// 会话条目数上限/设备（设计文档起步值 20 条）。
const maxSessionEntriesPerDevice = 20;

/// 总体积预算（字节，全设备合计）。设计文档建议 30–50MB，取 40MB。
const maxTotalCacheBytes = 40 * 1024 * 1024;

// ------------------------------------------------------------ 写入判定

/// 会话缓存的一致水位判定（失效协议第 1 条：只缓存一致水位）。
///
/// 仅当：已收到快照（ready）&& logEpoch 已知 && 回合静默（非 running、
/// 无 streaming 行）——即"回合结束/收尾帧"的落盘点。流式中间态、
/// 未落稳的订阅不落盘（R6 快照守门对齐：state.ready 只有快照应用后才
/// 为真，驱逐竞态期的脏帧到不了这里）。
bool shouldWriteSessionCache({
  required bool ready,
  required String? logEpoch,
  required bool isRunning,
  required bool hasStreamingRow,
}) => ready && logEpoch != null && logEpoch.isNotEmpty && !isRunning && !hasStreamingRow;

/// 截尾至最近 [maxRows] 行（行序列单调，保尾部=最新对话）。
/// 返回截尾后的首行 rowId（作缓存条目的 firstRowId），空返回 null。
(int?, List<Map<String, dynamic>>) capRows(
  List<Map<String, dynamic>> rows, {
  int maxRows = maxCachedRows,
}) {
  if (rows.length <= maxRows) return (null, rows);
  final kept = rows.sublist(rows.length - maxRows);
  return ((kept.first['rowId'] as num?)?.toInt(), kept);
}

// ------------------------------------------------------------ 对账判定

/// 打开会话时缓存与新快照的对账（失效协议第 2 条三分支）。
enum CacheReconcile {
  /// 无缓存 / 缓存为空 → 正常快照路径。
  noCache,

  /// 快照未到 → 先渲缓存（本实现的常态：缓存只在快照前渲染）。
  renderUntilSnapshot,

  /// 快照已到且 logEpoch 变了（rewind/编辑/压缩等历史重写）→ 条目作废。
  invalidated,
}

CacheReconcile reconcileSessionCache({
  required SessionCacheEntry? cache,
  required bool liveSnapshotReady,
  required String? liveLogEpoch,
}) {
  if (cache == null || cache.rows.isEmpty) return CacheReconcile.noCache;
  if (!liveSnapshotReady) return CacheReconcile.renderUntilSnapshot;
  // 快照已到：缓存使命结束。logEpoch 不一致时顺带判定条目过时
  //（下一次一致水位落盘会整体覆盖，无需显式删除——此枚举供日志/测试
  // 断言"作废分支"确实发生）。
  if (cache.logEpoch != null && liveLogEpoch != null && cache.logEpoch != liveLogEpoch) {
    return CacheReconcile.invalidated;
  }
  return CacheReconcile.renderUntilSnapshot;
}

// ------------------------------------------------------------ LRU 淘汰

/// 会话条目元信息（淘汰计算输入）。
class SessionCacheMeta {
  final String deviceSid;
  final String sessionId;
  final int savedAt;
  final int byteSize;
  const SessionCacheMeta(this.deviceSid, this.sessionId, this.savedAt, this.byteSize);
}

/// 超预算淘汰：按 savedAt 最旧先删，直到满足 条目数/体积 双约束。
/// 返回应删除的 (deviceSid, sessionId) 列表（最旧在前）。
///
/// 条目数按设备计（每设备 ≤ [maxEntries]），体积按全局计
/// （合计 ≤ [maxTotalBytes]）——多电脑并行下每台电脑保住自己的最近会话。
List<(String, String)> evictSessions(
  List<SessionCacheMeta> entries, {
  int maxEntries = maxSessionEntriesPerDevice,
  int maxTotalBytes = maxTotalCacheBytes,
}) {
  // 先解决单设备条目数：设备内最旧的溢出条目全部入选。
  final byDevice = <String, List<SessionCacheMeta>>{};
  for (final e in entries) {
    byDevice.putIfAbsent(e.deviceSid, () => []).add(e);
  }
  final doomed = <(String, String)>{};
  for (final list in byDevice.values) {
    if (list.length <= maxEntries) continue;
    list.sort((a, b) => a.savedAt.compareTo(b.savedAt));
    for (final m in list.take(list.length - maxEntries)) {
      doomed.add((m.deviceSid, m.sessionId));
    }
  }
  // 再解决全局体积：剩余条目按最旧先删直到入预算（P3-4：
  // remaining 构造时已过滤 doomed，循环内的 contains 恒假死行已删）。
  var remaining = <SessionCacheMeta>[];
  for (final e in entries) {
    if (!doomed.contains((e.deviceSid, e.sessionId))) remaining.add(e);
  }
  var total = remaining.fold<int>(0, (sum, e) => sum + e.byteSize);
  if (total > maxTotalBytes) {
    remaining.sort((a, b) => a.savedAt.compareTo(b.savedAt));
    for (final m in remaining) {
      if (total <= maxTotalBytes) break;
      doomed.add((m.deviceSid, m.sessionId));
      total -= m.byteSize;
    }
  }
  return doomed.toList();
}

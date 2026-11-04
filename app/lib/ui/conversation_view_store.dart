/// 会话页纯内存展示状态：折叠、live collapse、思考计时与文件卡缓存。
/// 不承载协议、发送、持久化或滚动状态。
class ConversationViewStore {
  ConversationViewStore({DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  static final Map<String, Map<int, bool>> _toolOpenBySession = {};

  static void resetToolFoldMemory() => _toolOpenBySession.clear();

  final reasoningFirstSeen = <int, DateTime>{};
  final reasoningElapsedMs = <int, int>{};
  final seenRowKeys = <String>{};
  final fileCardOpen = <int, bool>{};
  final fileCardItems = <int, List<Map<String, dynamic>>>{};
  final liveCollapsedByRow = <int, bool>{};

  Map<int, bool> toolOpenFor(String? sessionId) {
    final sid = sessionId ?? '_anonymous';
    // A2-P3-4/A3-P3-5：旧 >100 一律 wipe-all（第 101 个会话
    // 抹掉其余全部会话的折叠记忆）——改按插入序逐条驱逐至 99（与会话
    // 页生命周期量级匹配，保留其余记忆）。
    while (_toolOpenBySession.length > 100) {
      final oldest = _toolOpenBySession.keys.firstWhere(
        (key) => key != sid,
        orElse: () => sid,
      );
      _toolOpenBySession.remove(oldest);
      if (oldest == sid) break;
    }
    return _toolOpenBySession.putIfAbsent(sid, () => <int, bool>{});
  }

  /// 行数回退（row.removed：编辑重发/回滚）时按当前行裁剪页面级 Map
  /// （ A1-P3-4：六 Map 只增不减，长会话单调增长；行数增长
  /// 不裁——流式常态，裁了会丢思考计时）。[liveKeys]=当前投影条目键
  /// 集（seenRowKeys 用；null=不裁 seenRowKeys）。
  void pruneAfterRowShrink(
    List<Map<String, dynamic>> rows, {
    Set<String>? liveKeys,
  }) {
    final liveRowIds = <int>{};
    for (final row in rows) {
      final id = (row['rowId'] as num?)?.toInt();
      if (id != null && id >= 0) liveRowIds.add(id);
    }
    void pruneInt<K extends int>(Map<K, dynamic> map) {
      if (map.length <= liveRowIds.length) return;
      map.removeWhere((id, _) => !liveRowIds.contains(id));
    }

    pruneInt(reasoningFirstSeen);
    pruneInt(reasoningElapsedMs);
    pruneInt(fileCardOpen);
    pruneInt(fileCardItems);
    pruneInt(liveCollapsedByRow);
    if (liveKeys != null && seenRowKeys.length > liveKeys.length) {
      seenRowKeys.removeWhere((k) => !liveKeys.contains(k));
    }
  }

  void captureReasoningElapsed(List<Map<String, dynamic>> rows) {
    if (reasoningFirstSeen.isEmpty) return;
    for (final row in rows) {
      if (row['kind'] != 'reasoning' || row['state'] == 'streaming') continue;
      final id = (row['rowId'] as num?)?.toInt();
      if (id == null || reasoningElapsedMs.containsKey(id)) continue;
      final seen = reasoningFirstSeen[id];
      if (seen == null) continue;
      reasoningElapsedMs[id] = _now().difference(seen).inMilliseconds;
    }
  }

  int? reasoningElapsedOf(Map<String, dynamic> row) {
    final id = (row['rowId'] as num?)?.toInt();
    return id == null ? null : reasoningElapsedMs[id];
  }

  DateTime? firstSeenOf(Map<String, dynamic> row) {
    final rowId = (row['rowId'] as num?)?.toInt();
    if (rowId == null) return null;
    if (row['state'] == 'streaming') {
      return reasoningFirstSeen.putIfAbsent(rowId, () {
        final created = (row['createdAt'] as num?)?.toInt();
        return created != null && created > 0
            ? DateTime.fromMillisecondsSinceEpoch(created)
            : _now();
      });
    }
    return reasoningFirstSeen[rowId];
  }
}

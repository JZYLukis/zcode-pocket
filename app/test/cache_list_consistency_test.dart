import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/task_list.dart';
import 'package:zcode_pocket/transport/conversation.dart';

/// 列表缓存一致性（phase3-cache-design"测试与验收"节，2026-10-18 增）：
/// 列表操作（置顶/归档/删除/已读）→ 缓存导出 → 重启重建（dormant 预渲
/// 模型）→ 呈现语义保持。重建走与实时路径同一条 mergeTaskSources——
/// 这本身就是一致性的结构性保证，测试钉住它。
void main() {
  SessionsIndexState siState(List<Map<String, dynamic>> sessions) {
    final state = SessionsIndexState();
    for (final raw in sessions) {
      final e = SessionEntry(raw);
      state.sessions[e.sessionId] = e;
    }
    return state;
  }

  TaskListModel build({
    required List<Map<String, dynamic>> sessions,
    required List<Map<String, dynamic>> channelActive,
    required List<String> pinnedIds,
    required List<String> archivedIds,
    List<String> deletedIds = const [],
  }) {
    final model = TaskListModel(
      dormant: true,
      sessions: siState(sessions),
      workspaceKey: 'ws-key',
    );
    model.applyChannelLists(
      active: channelActive,
      pinnedIds: pinnedIds,
      archivedIds: archivedIds,
      deletedIds: deletedIds,
    );
    return model;
  }

  /// 模拟"导出 → 重启重建"（ComputerStack._loadDeviceCache 同款路径）。
  TaskListModel roundtrip(TaskListModel model) => build(
    sessions: model.sessionsForCache,
    channelActive: model.channelTasksForCache,
    pinnedIds: model.pinnedIdsForCache,
    archivedIds: model.archivedIdsForCache,
    deletedIds: model.deletedIdsForCache,
  );

  final sessions = [
    {
      'sessionId': 's_run',
      'title': '运行中任务',
      'phase': 'running',
      'lastActivityAt': 300,
      'createdAt': 100,
    },
    {
      'sessionId': 's_done',
      'title': '已完成任务',
      'phase': 'completedSuccess',
      'lastActivityAt': 200,
      'createdAt': 90,
    },
  ];

  test('往返：重建后卡片集合与字段一致（呈现语义保持）', () {
    final model = build(
      sessions: sessions,
      channelActive: [
        {'taskId': 's_hist', 'title': '历史任务', 'status': 'completed'},
        {'taskId': 's_done', 'unreadAt': 1700000000000},
      ],
      pinnedIds: ['s_done'],
      archivedIds: ['s_arch'],
    );
    final rebuilt = roundtrip(model);
    expect(rebuilt.cards.length, model.cards.length);
    expect(
      rebuilt.cards.map((c) => c.sessionId).toSet(),
      model.cards.map((c) => c.sessionId).toSet(),
    );
    final done = rebuilt.cards.firstWhere((c) => c.sessionId == 's_done');
    expect(done.pinned, true, reason: '置顶语义往返保持');
    expect(done.unread, true, reason: '未读点语义往返保持');
    expect(
      rebuilt.cards.any((c) => c.sessionId == 's_arch'),
      false,
      reason: '归档剔除语义往返保持',
    );
    final hist = rebuilt.cards.firstWhere((c) => c.sessionId == 's_hist');
    expect(hist.historical, true, reason: '历史任务兜底呈现保持');
  });

  test('乐观置顶 → 导出重建后仍置顶（乐观同步进缓存）', () {
    final model = build(
      sessions: sessions,
      channelActive: const [],
      pinnedIds: const [],
      archivedIds: const [],
    );
    expect(model.cards.firstWhere((c) => c.sessionId == 's_run').pinned, false);
    model.togglePinLocally('s_run');
    expect(model.cards.firstWhere((c) => c.sessionId == 's_run').pinned, true);
    final rebuilt = roundtrip(model);
    expect(
      rebuilt.cards.firstWhere((c) => c.sessionId == 's_run').pinned,
      true,
      reason: '乐观置顶必须落进缓存并经重建保持（服务端确认前杀死进程的窗口）',
    );
  });

  test('乐观移除（墓碑）不进缓存导出——防复活由 archivedIds/快照负责', () {
    final model = build(
      sessions: sessions,
      channelActive: const [
        {'taskId': 's_done', 'title': 'x'},
      ],
      pinnedIds: const [],
      archivedIds: const [],
    );
    model.markRemovedLocally('s_done');
    expect(model.cards.any((c) => c.sessionId == 's_done'), false,
        reason: '墓碑窗口期本地剔除');
    // 墓碑 60s 过期语义是运行时防复活；缓存导出存的是双源真值。
    final rebuilt = roundtrip(model);
    expect(rebuilt.cards.any((c) => c.sessionId == 's_done'), true,
        reason: '墓碑不写入缓存——重启后由真实订阅/通道数据裁决，避免永久丢卡');
  });

  test('已删除集往返：离线墓碑化任务重建后仍剔除（不复活）', () {
    final model = build(
      sessions: sessions,
      channelActive: const [],
      pinnedIds: const [],
      archivedIds: const [],
      deletedIds: const ['s_done'],
    );
    expect(
      model.cards.any((c) => c.sessionId == 's_done'),
      false,
      reason: 'si 快照含已删除会话，负向 join 必须剔除',
    );
    final rebuilt = roundtrip(model);
    expect(
      rebuilt.cards.any((c) => c.sessionId == 's_done'),
      false,
      reason: 'deletedIds 是通道真值（listDeletedTaskIds），必须随缓存往返',
    );
  });

  test('si 实时会话条目导出重建后 phase/preview 保持', () {
    final model = build(
      sessions: [
        {
          'sessionId': 's_run',
          'title': '任务A',
          'phase': 'running',
          'lastAssistantPreview': '正在编译…',
          'lastActivityAt': 300,
          'createdAt': 100,
        },
      ],
      channelActive: const [],
      pinnedIds: const [],
      archivedIds: const [],
    );
    final rebuilt = roundtrip(model);
    final card = rebuilt.cards.first;
    expect(card.phase, 'running');
    expect(card.preview, '正在编译…');
  });
}

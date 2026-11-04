import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/task_list.dart';
import 'package:zcode_pocket/transport/conversation.dart';

SessionEntry _session(
  String id, {
  String phase = 'idle',
  String title = '',
  String? preview,
  int lastActivityAt = 0,
  int createdAt = 0,
}) => SessionEntry({
  'sessionId': id,
  'phase': phase,
  'title': title,
  'lastAssistantPreview': ?preview,
  if (lastActivityAt > 0) 'lastActivityAt': lastActivityAt,
  if (createdAt > 0) 'createdAt': createdAt,
});

void main() {
  group('normalizePhase', () {
    test('task.status 词汇映射进 session phase 词汇表', () {
      expect(normalizePhase('completed'), 'completedSuccess');
      expect(normalizePhase('failed'), 'completedInterrupted');
      expect(normalizePhase('cancelled'), 'completedInterrupted');
      expect(normalizePhase('running'), 'running');
      expect(normalizePhase('error'), 'error');
    });
  });

  group('mergeTaskSources', () {
    test('归档任务被剔除（双源都不放行）', () {
      final merged = mergeTaskSources(
        sessions: [_session('a', lastActivityAt: 5), _session('archived-1')],
        channelTasks: const [
          {'taskId': 'archived-1', 'title': '已归档'},
          {'taskId': 'c', 'title': '历史任务', 'updatedAt': 3},
        ],
        pinnedIds: const {},
        archivedIds: const {'archived-1'},
      );
      expect(merged.map((c) => c.sessionId), ['a', 'c']);
    });

    test('sessions-index 实时字段优先，通道元数据兜底历史会话', () {
      final merged = mergeTaskSources(
        sessions: [
          _session(
            'live',
            phase: 'running',
            title: '实时标题',
            preview: 'p',
            lastActivityAt: 200,
            createdAt: 100,
          ),
        ],
        channelTasks: const [
          {
            'taskId': 'hist',
            'title': '历史标题',
            'status': 'completed',
            'updatedAt': 50,
            'createdAt': 10,
          },
        ],
        pinnedIds: const {},
        archivedIds: const {},
      );
      final live = merged.firstWhere((c) => c.sessionId == 'live');
      expect(live.phase, 'running');
      expect(live.title, '实时标题');
      expect(live.preview, 'p');
      expect(live.historical, isFalse);

      final hist = merged.firstWhere((c) => c.sessionId == 'hist');
      expect(hist.phase, 'completedSuccess'); // task.status 映射
      expect(hist.historical, isTrue);
      expect(hist.lastActivityAt, 50);
      expect(hist.createdAt, 10);
    });

    test('同一 id 双源出现：保留较优字段 + 置顶标记', () {
      final merged = mergeTaskSources(
        sessions: [_session('x', phase: 'running', lastActivityAt: 300)],
        channelTasks: const [
          {'taskId': 'x', 'title': '通道标题', 'createdAt': 42},
        ],
        pinnedIds: const {'x'},
        archivedIds: const {},
      );
      final x = merged.single;
      expect(x.title, '通道标题'); // session 无标题，通道兜底
      expect(x.phase, 'running');
      expect(x.createdAt, 42);
      expect(x.lastActivityAt, 300);
      expect(x.pinned, isTrue);
      expect(x.historical, isFalse);
    });

    test('墓碑（removedIds）防推送滞后复活', () {
      final merged = mergeTaskSources(
        sessions: [_session('gone'), _session('keep')],
        channelTasks: const [
          {'taskId': 'gone'},
        ],
        pinnedIds: const {},
        archivedIds: const {},
        removedIds: const {'gone'},
      );
      expect(merged.map((c) => c.sessionId), ['keep']);
    });

    test('已删除集（deletedIds）剔除——官方 si 负向 join，双源都不放行', () {
      // 离线墓碑化实锤场景：si 快照仍含已删除会话，负向 join 必须剔除
      final merged = mergeTaskSources(
        sessions: [_session('killed'), _session('keep')],
        channelTasks: const [
          {'taskId': 'killed', 'title': '已删除'},
        ],
        pinnedIds: const {},
        archivedIds: const {},
        deletedIds: const {'killed'},
      );
      expect(merged.map((c) => c.sessionId), ['keep']);
    });

    test('按 lastActivityAt 倒序', () {
      final merged = mergeTaskSources(
        sessions: [
          _session('old', lastActivityAt: 1),
          _session('new', lastActivityAt: 999),
        ],
        channelTasks: const [],
        pinnedIds: const {},
        archivedIds: const {},
      );
      expect(merged.map((c) => c.sessionId), ['new', 'old']);
    });
  });

  group('stabilizeTaskOrder', () {
    test('可见集合不变时保持当前顺序（running 跳动不重排）', () {
      final current = mergeTaskSources(
        sessions: [
          _session('a', lastActivityAt: 20),
          _session('b', lastActivityAt: 10),
        ],
        channelTasks: const [],
        pinnedIds: const {},
        archivedIds: const {},
      );
      expect(current.map((c) => c.sessionId), ['a', 'b']); // 基线：a 在前
      // b 的 lastActivityAt 跳到 100：若重排 b 会跳到前面
      final merged = mergeTaskSources(
        sessions: [
          _session('a', lastActivityAt: 20),
          _session('b', lastActivityAt: 100),
        ],
        channelTasks: const [],
        pinnedIds: const {},
        archivedIds: const {},
      );
      expect(merged.map((c) => c.sessionId), ['b', 'a']); // 直接排序会跳动
      final stabilized = stabilizeTaskOrder(current, merged);
      expect(stabilized.map((c) => c.sessionId), ['a', 'b']); // 稳序后不跳
      expect(stabilized[1].lastActivityAt, 100); // 字段已刷新
    });

    test('集合变化（新增/删除）时采用新排序', () {
      final current = mergeTaskSources(
        sessions: [_session('a')],
        channelTasks: const [],
        pinnedIds: const {},
        archivedIds: const {},
      );
      final merged = mergeTaskSources(
        sessions: [_session('a'), _session('b', lastActivityAt: 99)],
        channelTasks: const [],
        pinnedIds: const {},
        archivedIds: const {},
      );
      final stabilized = stabilizeTaskOrder(current, merged);
      expect(stabilized.map((c) => c.sessionId), ['b', 'a']);
    });
  });

  group('TaskListModel', () {
    test('applyWorkspaceListTasks：归档推送剔除 + 跨工作区隔离', () {
      final si = SessionsIndexState();
      final model = TaskListModel(sessions: si, workspaceKey: 'ws-identity');
      model.applyChannelLists(
        active: const [
          {'taskId': 't1', 'title': '任务1'},
        ],
        pinnedIds: const [],
        archivedIds: const [],
      );
      // workspace-list-updated：t1 被归档；other 属于别的工作区（新 id 拒绝）
      model.applyWorkspaceListTasks(const [
        {'taskId': 't1', 'archived': true},
        {'taskId': 'other', 'title': '别的工作区'},
      ], 'ws-identity');
      expect(model.cards.map((c) => c.sessionId), isNot(contains('t1')));
      expect(model.cards.map((c) => c.sessionId), isNot(contains('other')));
    });

    test('si 未就绪时卡片为空，就绪后合并', () {
      final si = SessionsIndexState();
      final model = TaskListModel(sessions: si, workspaceKey: 'ws');
      model.applyChannelLists(
        active: const [
          {'taskId': 'hist', 'title': '历史'},
        ],
        pinnedIds: const [],
        archivedIds: const [],
      );
      // 模型只在 si ready 后出卡片（与 UI 加载态约定一致）
      si.ready = true;
      si.applyFrame({
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'sessions': [
              {'sessionId': 'live', 'phase': 'running'},
            ],
          },
        },
        'toSeq': 1,
      }, onGap: () {});
      expect(
        model.cards.map((c) => c.sessionId),
        containsAll(['live', 'hist']),
      );
    });

    test('deletedIds：si 冷快照含已删除会话不复活 + 删除推送进墓碑集', () {
      final si = SessionsIndexState();
      final model = TaskListModel(sessions: si, workspaceKey: 'ws');
      model.applyChannelLists(
        active: const [
          {'taskId': 't_live', 'title': '活任务'},
        ],
        pinnedIds: const [],
        archivedIds: const [],
        deletedIds: const ['t_killed'],
      );
      si.ready = true;
      si.applyFrame({
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'sessions': [
              {'sessionId': 't_killed', 'phase': 'running'},
              {'sessionId': 't_live', 'phase': 'running'},
            ],
          },
        },
        'toSeq': 1,
      }, onGap: () {});
      expect(
        model.cards.map((c) => c.sessionId),
        ['t_live'],
        reason: '官方负向 join：si 快照不排除已删除会话，必须剔除',
      );
      // workspace-list-updated 推 deleted:true → 墓碑集（后续冷快照重放不复活）
      model.applyWorkspaceListTasks(const [
        {'taskId': 't_live', 'deleted': true},
      ], 'ws');
      expect(model.cards, isEmpty);
    });

    test('墓碑过期 + 活跃墓碑并存：过期清理不抛 CME，活跃墓碑仍防复活（J1-1/J2/J3 三路）', () {
      final si = SessionsIndexState();
      // dormant：_rebuild 的墓碑清理分支不依赖 si ready。
      final model = TaskListModel(sessions: si, workspaceKey: 'ws', dormant: true);
      model.applyChannelLists(
        active: const [
          {'taskId': 't-gone', 'title': '过期墓碑'},
          {'taskId': 't-keep', 'title': '活跃墓碑'},
        ],
        pinnedIds: const [],
        archivedIds: const [],
      );
      model.markRemovedLocally('t-gone');
      // 回拨 >60s 后再写一条新墓碑：过期与活跃并存。
      model.debugAgeRemovedTombstonesForTest(const Duration(seconds: 61));
      model.markRemovedLocally('t-keep');
      // 修复前：_recentlyRemoved.keys.where 的谓词内 remove——Map.keys 是
      // 惰性活视图，迭代中改 map 必抛 ConcurrentModificationError（单条
      // 过期也炸）；togglePinLocally 是 UI 直调路径（pin RPC 之前），异常
      // 会把整个置顶动作打断。
      expect(() => model.togglePinLocally('t-gone'), returnsNormally);
      expect(
        model.cards.map((c) => c.sessionId),
        ['t-gone'],
        reason: '过期墓碑按设计放行（60s 后负向 join/重拉接管），活跃墓碑仍剔除',
      );
    });
  });

  group('parseDeletedTaskIds', () {
    // 2026-10-23 真机实锤回归钉：listDeletedTaskIds 官方契约=纯字符串数组，
    // 误用对象列表解析恒空集 → si 负向 join 从未生效（201 卡事故）。
    test('字符串数组直读（官方契约）', () {
      expect(parseDeletedTaskIds(['a', 'b', '']), ['a', 'b']);
    });

    test('对象条目兜底取 taskId + 非法形态防御', () {
      expect(
        parseDeletedTaskIds([
          {'taskId': 'x'},
          {'no': 'id'},
          42,
        ]),
        ['x'],
      );
      expect(parseDeletedTaskIds(null), isEmpty);
      expect(parseDeletedTaskIds('oops'), isEmpty);
      expect(parseDeletedTaskIds(<dynamic>[]), isEmpty);
    });
  });
}

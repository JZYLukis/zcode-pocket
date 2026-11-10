import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/cache_policy.dart';
import 'package:zcode_pocket/state/local_cache.dart';
import 'package:zcode_pocket/transport/conversation.dart';

/// 阶段 3 缓存策略与存储单测（"测试与验收"节）：
/// - 失效协议三分支（水位一致/不一致作废/快照未到先渲）
/// - 一致水位判定（流式中间态/运行中不落盘）
/// - 截尾（200 行/会话）
/// - LRU 淘汰 + 预算记账（条目数/设备 + 全局体积）
/// - 存储读写往返 / 损坏容错 / 配对删除
void main() {
  group('一致水位判定（失效协议第 1 条：只缓存一致快照）', () {
    test('ready+logEpoch+静默 → 可落盘', () {
      expect(
        shouldWriteSessionCache(
          ready: true,
          logEpoch: 'e1',
          isRunning: false,
          hasStreamingRow: false,
        ),
        true,
      );
    });

    test('流式中间态/运行中/无水位 → 不落盘', () {
      for (final combo in [
        (true, 'e1', true, false), // running
        (true, 'e1', false, true), // streaming 行
        (true, null, false, false), // 无 logEpoch
        (true, '', false, false), // 空 logEpoch
        (false, 'e1', false, false), // 快照未到（不应出现，防御）
      ]) {
        expect(
          shouldWriteSessionCache(
            ready: combo.$1,
            logEpoch: combo.$2,
            isRunning: combo.$3,
            hasStreamingRow: combo.$4,
          ),
          false,
          reason: 'ready=${combo.$1} epoch=${combo.$2} '
              'running=${combo.$3} streaming=${combo.$4}',
        );
      }
    });
  });

  group('首页任务缓存白名单（状态层批补覆盖）', () {
    test('offPeakTaskId/hasBackgroundWork 保留；workflowActivity/searchSnippets 有意裁剪', () {
      final rows = cacheHomeTaskRows([
        {
          'taskId': 't1',
          'title': '闲时任务',
          'offPeakTaskId': 'op-1',
          'hasBackgroundWork': true,
          'workflowActivity': {
            'runs': [
              {'runId': 'r1', 'status': 'running'},
            ],
          },
          'searchSnippets': const ['正文片段'],
        },
      ]);
      expect(rows, hasLength(1));
      expect(rows.single['offPeakTaskId'], 'op-1',
          reason: 'B 批月亮标字段白名单已含（此前零覆盖）');
      expect(rows.single['hasBackgroundWork'], true,
          reason: '后台工作点白名单已含（此前零覆盖）');
      // 有意裁剪契约：正文片段与 run 线对象较重，不入设备缓存（live 到达
      // 即恢复）；调用方依赖此形状做体积/隐私守门。
      expect(rows.single.containsKey('searchSnippets'), isFalse);
      expect(rows.single.containsKey('workflowActivity'), isFalse);
    });

    test('sanitizeLive 清洗保留字段同时不丢新白名单字段', () {
      final rows = cacheHomeTaskRows([
        {
          'taskId': 't2',
          'title': '运行中',
          'status': 'running',
          'offPeakTaskId': 'op-2',
        },
      ], sanitizeLive: true);
      expect(rows.single['status'], 'idle');
      expect(rows.single['offPeakTaskId'], 'op-2');
    });
  });

  group('截尾（行数上限）', () {
    List<Map<String, dynamic>> rows(int n) => [
      for (var i = 0; i < n; i++) {'rowId': i, 'kind': 'assistantText', 'text': 'r$i'},
    ];

    test('不足上限原样保留', () {
      final (first, kept) = capRows(rows(10));
      expect(first, null);
      expect(kept.length, 10);
    });

    test('超限保尾部（最新对话）且 firstRowId=保留区首行', () {
      final (first, kept) = capRows(rows(350));
      expect(kept.length, 200);
      expect(first, 150);
      expect(kept.first['rowId'], 150);
      expect(kept.last['rowId'], 349);
    });
  });

  group('对账三分支（失效协议第 2 条）', () {
    final entry = SessionCacheEntry(
      deviceSid: 'd1',
      sessionId: 's1',
      rows: [
        {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      ],
      logEpoch: 'e1',
      lastSeq: 10,
      firstRowId: 1,
      totalCount: 1,
      snapshotControl: null,
      savedAt: 1,
      byteSize: 100,
    );

    test('无缓存 → noCache', () {
      expect(
        reconcileSessionCache(cache: null, liveSnapshotReady: false, liveLogEpoch: null),
        CacheReconcile.noCache,
      );
    });

    test('快照未到 → renderUntilSnapshot（先渲缓存）', () {
      expect(
        reconcileSessionCache(cache: entry, liveSnapshotReady: false, liveLogEpoch: null),
        CacheReconcile.renderUntilSnapshot,
      );
    });

    test('快照已到且 logEpoch 变了（rewind/编辑/压缩）→ invalidated', () {
      expect(
        reconcileSessionCache(cache: entry, liveSnapshotReady: true, liveLogEpoch: 'e2'),
        CacheReconcile.invalidated,
      );
    });

    test('快照已到且水位一致 → 缓存使命结束（续接由订阅层承担）', () {
      expect(
        reconcileSessionCache(cache: entry, liveSnapshotReady: true, liveLogEpoch: 'e1'),
        CacheReconcile.renderUntilSnapshot,
      );
    });
  });

  group('LRU 淘汰与预算记账', () {
    List<SessionCacheMeta> metas(int count, {String device = 'd1', int baseSize = 100}) => [
      for (var i = 0; i < count; i++)
        SessionCacheMeta(device, 's$i', i, baseSize),
    ];

    test('设备内条目数溢出 → 最旧先删', () {
      final doomed = evictSessions(metas(25));
      expect(doomed.length, 5);
      // 最旧的 s0..s4 入选
      expect(doomed.map((e) => e.$2).toSet(), {'s0', 's1', 's2', 's3', 's4'});
    });

    test('多设备互不挤占（每设备各保 20）', () {
      final entries = [
        ...metas(22, device: 'd1'),
        ...metas(3, device: 'd2'),
      ];
      final doomed = evictSessions(entries);
      // 只有 d1 溢出 2 条；d2 的 3 条全保
      expect(doomed.where((e) => e.$1 == 'd2'), isEmpty);
      expect(doomed.where((e) => e.$1 == 'd1').length, 2);
    });

    test('全局体积超预算 → 跨设备最旧先删', () {
      // 25 条 × 2MB = 50MB > 40MB 预算 → 需删约 5 条
      final entries = metas(25, baseSize: 2 * 1024 * 1024);
      final doomed = evictSessions(entries);
      expect(doomed, isNotEmpty);
      // 删完后总体积 ≤ 预算
      final doomedSet = doomed.map((e) => (e.$1, e.$2)).toSet();
      final keptBytes = entries
          .where((m) => !doomedSet.contains((m.deviceSid, m.sessionId)))
          .fold<int>(0, (sum, m) => sum + m.byteSize);
      expect(keptBytes <= maxTotalCacheBytes, true);
    });
  });

  group('存储读写（temp dir）', () {
    late Directory tmp;
    late LocalCacheStore store;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('zcache');
      store = LocalCacheStore(tmp);
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    SessionCacheEntry entry({
      String sid = 's1',
      String epoch = 'e1',
      List<Map<String, dynamic>>? rows,
    }) => SessionCacheEntry(
      deviceSid: 'd1',
      sessionId: sid,
      rows: rows ??
          [
            {'rowId': 1, 'kind': 'userInput', 'text': '看下这张图'},
            {'rowId': 2, 'kind': 'assistantText', 'text': '回复内容'},
          ],
      logEpoch: epoch,
      lastSeq: 42,
      firstRowId: 1,
      totalCount: 2,
      snapshotControl: {
        'control': {'phase': 'completedSuccess'},
        'config': {'model': 'GLM-5.3'},
        'pendingInteractions': [],
      },
      savedAt: 123,
      byteSize: 0,
    );

    test('会话条目读写往返（行/水位/控制块无损）', () async {
      await store.writeSession(entry());
      final loaded = await store.readSession('d1', 's1');
      expect(loaded, isNotNull);
      expect(loaded!.rows.length, 2);
      expect(loaded.rows[0]['text'], '看下这张图');
      expect(loaded.logEpoch, 'e1');
      expect(loaded.lastSeq, 42);
      expect(loaded.snapshotControl?['control']?['phase'], 'completedSuccess');
      // byteSize 由 store 测真值写回
      expect(loaded.byteSize, greaterThan(0));
    });

    test('损坏条目 → 当无缓存（容错）', () async {
      final dir = Directory(
        '${tmp.path}${Platform.pathSeparator}sessions${Platform.pathSeparator}d1',
      )..createSync(recursive: true);
      File('${dir.path}${Platform.pathSeparator}bad.json')
          .writeAsStringSync('{not json');
      expect(await store.readSession('d1', 'bad'), isNull);
    });

    test('配对删除：清该设备全部条目（会话+设备级）', () async {
      await store.writeSession(entry(sid: 's1'));
      await store.writeSession(entry(sid: 's2'));
      await store.writeDevice(DeviceCacheEntry(
        deviceSid: 'd1',
        workspaces: const [],
        activeWorkspace: null,
        desktopAppVersion: null,
        sessions: const [],
        channelActive: const [],
        pinnedIds: const [],
        archivedIds: const [],
        savedAt: 1,
      ));
      await store.removeDevice('d1');
      expect(await store.readSession('d1', 's1'), isNull);
      expect(await store.readSession('d1', 's2'), isNull);
      expect(await store.readDevice('d1'), isNull);
    });

    test('设备级条目读写往返', () async {
      await store.writeDevice(DeviceCacheEntry(
        deviceSid: 'd1',
        workspaces: [
          {'workspacePath': 'G:\\Demo App', 'workspaceIdentity': 'proj'},
        ],
        activeWorkspace: {
          'workspacePath': 'G:\\Demo App',
          'workspaceIdentity': 'proj',
        },
        desktopAppVersion: '3.15.3',
        sessions: [
          {'sessionId': 'sess_x', 'phase': 'running', 'title': '阶段2'},
        ],
        channelActive: [
          {'taskId': 'sess_x', 'title': '阶段2', 'unreadAt': 1700000000000},
        ],
        pinnedIds: ['sess_pinned'],
        archivedIds: ['sess_arch'],
        deletedIds: ['sess_del'],
        savedAt: 99,
      ));
      final loaded = await store.readDevice('d1');
      expect(loaded, isNotNull);
      expect(loaded!.workspaces.length, 1);
      expect(loaded.activeWorkspace?['workspaceIdentity'], 'proj');
      expect(loaded.sessions.first['phase'], 'running');
      expect(loaded.pinnedIds, ['sess_pinned']);
      expect(loaded.archivedIds, ['sess_arch']);
      expect(loaded.deletedIds, ['sess_del']);
      expect(loaded.channelActive.first['unreadAt'], isNotNull);
    });

    test('设备级 B 首页字段往返：项目/归属/全局任务可预渲', () async {
      await store.writeDevice(DeviceCacheEntry(
        deviceSid: 'd1',
        workspaces: const [],
        projects: const [
          {'id': 'p1', 'name': '示例项目'},
        ],
        projectTasks: const [
          {'taskId': 't1', 'projectId': 'p1'},
        ],
        workspaceTasks: const [
          {
            'taskId': 't1',
            'title': '示例任务',
            'displayStatus': 'completed',
            'workspacePath': 'D:/示例项目',
          },
        ],
        activeWorkspace: null,
        desktopAppVersion: null,
        sessions: const [],
        channelActive: const [],
        pinnedIds: const [],
        archivedIds: const [],
        savedAt: 100,
      ));
      final loaded = await store.readDevice('d1');
      expect(loaded, isNotNull);
      expect(loaded!.projects.single['name'], '示例项目');
      expect(loaded.projectTasks.single['projectId'], 'p1');
      expect(loaded.workspaceTasks.single['title'], '示例任务');
    });

    test('设备级首页缓存裁剪：不带正文片段；读取预览清洗运行态', () {
      final raw = {
        'taskId': 't1',
        'title': '示例任务',
        'displayStatus': 'running',
        'pendingInteraction': {'id': 'approval-1'},
        'searchSnippet': '不应入缓存的正文',
        'searchSnippets': ['也不应入缓存'],
      };
      final written = cacheHomeTaskRows([raw]).single;
      expect(written.containsKey('searchSnippet'), isFalse);
      expect(written.containsKey('searchSnippets'), isFalse);
      expect(written['displayStatus'], 'running');

      final preview = cacheHomeTaskRows([raw], sanitizeLive: true).single;
      expect(preview['displayStatus'], 'idle');
      expect(preview['status'], 'idle');
      expect(preview['pendingInteraction'], isNull);
      expect(preview['title'], '示例任务');
    });
  });

  group('会话缓存写入器（回合静默落盘）', () {
    test('流式中 attach → 不落盘；静默+ready → 落盘', () async {
      final tmp = await Directory.systemTemp.createTemp('zcache-w');
      addTearDown(() => tmp.delete(recursive: true));
      final store = LocalCacheStore(tmp);
      final logs = <String>[];
      final writer = SessionCacheWriter(
        store: store,
        deviceSid: 'd1',
        sessionId: 's1',
        onLog: logs.add,
      );
      final state = ConversationState();
      state.applyFrame({
        'toSeq': 5,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'logEpoch': 'e1',
            'revision': 1,
            'control': {'phase': 'completedSuccess'},
            'pendingInteractions': [
              {'interactionId': 'i1', 'kind': 'permission'},
            ],
            'rows': {
              'window': [
                {'rowId': 1, 'kind': 'userInput', 'text': 'q'},
                {'rowId': 2, 'kind': 'assistantText', 'text': 'a', 'state': 'streaming'},
              ],
              'totalCount': 2,
              'firstRowId': 1,
            },
          },
        },
      }, onGap: () => fail('不应 gap'));
      writer.attach(state);
      // streaming 行存在 → 一致水位不成立 → flush 不落盘
      await writer.flush();
      expect(logs.where((l) => l.contains('session saved')), isEmpty);
      // 流式行落定 → flush 落盘
      state.applyFrame({
        'fromSeq': 5,
        'toSeq': 6,
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {
              'op': 'row.upserted',
              'row': {'rowId': 2, 'kind': 'assistantText', 'text': 'a'},
            },
          ],
        },
      }, onGap: () => fail('不应 gap'));
      await writer.flush();
      expect(logs.any((l) => l.contains('session saved')), true);
      final loaded = await store.readSession('d1', 's1');
      expect(loaded!.rows.length, 2);
      expect(loaded.logEpoch, 'e1');
      // 控制块原样保存（官方水位不变量：种子=base 时刻真状态，
      // pendingInteractions 不清洗——清洗只发生在页面预渲层）。
      final pi = loaded.snapshotControl?['pendingInteractions'];
      expect(pi, isA<List>(), reason: 'pendingInteractions 必须原样保留');
      expect((pi as List).first['interactionId'], 'i1');
    });
  });

  group('订阅种子（官方增量续传语义，仲裁 B2）', () {
    ConversationState seededState() {
      final s = ConversationState();
      s.applySeed(ConversationSeed(
        rows: [
          {'rowId': 1, 'kind': 'userInput', 'text': 'q'},
          {'rowId': 2, 'kind': 'assistantText', 'text': 'a'},
        ],
        logEpoch: 'e1',
        seq: 10,
        firstRowId: 1,
        totalCount: 2,
        snapshot: {
          'revision': 3,
          'control': {'phase': 'completedSuccess'},
        },
      ));
      return s;
    }

    test('种子就位：ready+rows+水位（页面立即有内容）', () {
      final s = seededState();
      expect(s.ready, true);
      expect(s.rows.length, 2);
      expect(s.logEpoch, 'e1');
      expect(s.seq, 10);
      expect(s.revision, 3);
    });

    test('同 epoch 续传：delta fromSeq=种子 seq 直接续接（增量对账）', () {
      final s = seededState();
      s.applyFrame({
        'fromSeq': 10,
        'toSeq': 11,
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {
              'op': 'row.appended',
              'row': {'rowId': 3, 'kind': 'assistantText', 'text': '增量'},
            },
          ],
        },
      }, onGap: () => fail('同水位续传不应 gap'));
      expect(s.rows.length, 3);
      expect(s.rows.last['text'], '增量');
      expect(s.seq, 11);
    });

    test('快照到达：整体替换种子（epoch 换代/publisher 重建路径）', () {
      final s = seededState();
      s.applyFrame({
        'toSeq': 5,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'logEpoch': 'e2',
            'revision': 1,
            'rows': {
              'window': [
                {'rowId': 1, 'kind': 'userInput', 'text': '新快照'},
              ],
              'totalCount': 1,
              'firstRowId': 1,
            },
          },
        },
      }, onGap: () => fail('快照不应 gap'));
      expect(s.logEpoch, 'e2');
      expect(s.rows.length, 1);
      expect(s.rows.first['text'], '新快照');
    });

    test('断档 delta（fromSeq≠水位）→ gap 回调触发（resync forceSnapshot 自愈）', () {
      final s = seededState();
      var gaps = 0;
      s.applyFrame({
        'fromSeq': 99,
        'toSeq': 100,
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {
              'op': 'row.appended',
              'row': {'rowId': 3, 'kind': 'assistantText', 'text': 'x'},
            },
          ],
        },
      }, onGap: () => gaps++);
      expect(gaps, 1, reason: '种子状态遇断档必须走 gap 路径');
    });
  });
}

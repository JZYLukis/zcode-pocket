import 'dart:convert';

import 'package:flutter/material.dart' hide Text;
import '../core/localized_text.dart';
import '../core/theme.dart';
import 'turn_model.dart' show toolInputArgs;
import 'workflow_dashboards.dart';
import '../state/app_state.dart';
import '../state/app_state_scope.dart';
import 'app_widgets.dart' show AppLoading;
import 'file_preview.dart' show HtmlPreviewPage;

/// 工作流 run 目录与详情（workflow-runs-1，2026-10-30 用户拍板「更新
/// 工作流及闲时执行部分」）：官方 v4 只读查询族——workflowRuns（run 摘
/// 要，五态）/workflowRunEvents（journal 事件分页）/workflowRunArtifacts
/// （产物清单）/workflowRunArtifactRead（内容产物字节 ≤512KiB 分块，形
/// 状照 attachmentRead）。全部只读、无状态、超时重发安全（transport.ts
/// 注释），手机端为纯消费页。

/// run 状态五态的人话与配色（官方词表 runs 投影同一套）。
({String label, Color color}) workflowRunStatusOf(
  BuildContext context,
  String status,
) => switch (status) {
  'running' => (label: '运行中', color: context.colors.warning),
  'pending' => (label: '排队中', color: context.colors.foregroundSubtle),
  'completed' => (label: '已完成', color: context.colors.success),
  'errored' => (label: '出错', color: context.colors.destructive),
  'stopped' => (label: '已停止', color: context.colors.foregroundSubtle),
  _ => (label: status, color: context.colors.foregroundSubtle),
};

String _shortRunId(String runId) =>
    runId.length <= 10 ? runId : runId.substring(0, 10);

String _relTime(int? epochMs) {
  if (epochMs == null || epochMs <= 0) return '';
  final diff = DateTime.now().millisecondsSinceEpoch - epochMs;
  if (diff < 60_000) return '刚刚';
  if (diff < 3_600_000) return '${diff ~/ 60_000} 分钟前';
  if (diff < 86_400_000) return '${diff ~/ 3_600_000} 小时前';
  return '${diff ~/ 86_400_000} 天前';
}

/// run 摘要联接（目录/详情两入口唯一实现）：优先 runId、回退 toolCallId
///（老 run 没有 toolCallId）。官方 run 目录 schema（transport.ts
/// v4ConversationWorkflowRunSummarySchema，.strict()）**没有**
/// lastEventSequence——最后事件序号只在快照 workflowRuns 投影里
///（workflow-runs.ts:581），run 详情「最新一页」反推必须走投影。
Map<String, dynamic>? joinWorkflowRunProjection(
  List<Map<String, dynamic>> runs, {
  String? runId,
  String? toolCallId,
}) {
  for (final r in runs) {
    if (runId != null &&
        runId.isNotEmpty &&
        '${r['runId'] ?? ''}' == runId) {
      return r;
    }
    if (toolCallId != null &&
        toolCallId.isNotEmpty &&
        '${r['toolCallId'] ?? ''}' == toolCallId) {
      return r;
    }
  }
  return null;
}

/// 会话的 run 目录页。
class WorkflowRunsPage extends StatefulWidget {
  final String sessionId;
  const WorkflowRunsPage({super.key, required this.sessionId});

  @override
  State<WorkflowRunsPage> createState() => _WorkflowRunsPageState();
}

class _WorkflowRunsPageState extends State<WorkflowRunsPage> {
  List<Map<String, dynamic>> _runs = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final app = AppStateScope.of(context);
      final res = await app.workflowRuns(widget.sessionId);
      final runs = (res is Map ? res['runs'] as List? : null) ?? const [];
      if (!mounted) return;
      // lastEventSequence 只在快照投影里（官方目录 schema 无此字段）——
      // 按 runId（回退 toolCallId）联接补进目录行，详情页才有「最新页」
      // 反推依据。
      final projection =
          app.conversationStates[widget.sessionId]?.workflowRunsList ??
          const <Map<String, dynamic>>[];
      setState(() {
        _runs = [
          for (final r in runs.whereType<Map>())
            _withProjectedLastEvent(r.cast<String, dynamic>(), projection),
        ];
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  /// 目录行补投影的最后事件序号（投影优先；投影缺席时保留原值）。
  Map<String, dynamic> _withProjectedLastEvent(
    Map<String, dynamic> run,
    List<Map<String, dynamic>> projection,
  ) {
    final joined = joinWorkflowRunProjection(
      projection,
      runId: '${run['runId'] ?? ''}',
      toolCallId: '${run['toolCallId'] ?? ''}',
    );
    final seq = (joined?['lastEventSequence'] as num?)?.toInt();
    return seq == null ? run : {...run, 'lastEventSequence': seq};
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        backgroundColor: context.colors.background,
        surfaceTintColor: Colors.transparent,
        title: const Text('工作流运行'),
      ),
      body: _loading
          ? const Center(child: AppLoading('正在加载…'))
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr('加载失败：') + _error!,
                    style: TextStyle(
                      fontSize: AppType.uiCaption,
                      color: context.colors.destructive,
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(onPressed: _load, child: const Text('重试')),
                ],
              ),
            )
          : _runs.isEmpty
          ? Center(
              child: Text(
                '本会话没有工作流运行',
                style: TextStyle(
                  fontSize: AppType.uiCaption,
                  color: context.colors.foregroundSubtle,
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                key: const ValueKey('workflow-runs-list'),
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                itemCount: _runs.length,
                separatorBuilder: (_, _) => const SizedBox(height: 6),
                itemBuilder: (context, i) {
                  final run = _runs[i];
                  final status = workflowRunStatusOf(
                    context,
                    '${run['status'] ?? ''}',
                  );
                  final label =
                      '${run['label'] ?? ''}'.trim().isNotEmpty
                      ? '${run['label']}'
                      : _shortRunId('${run['runId'] ?? ''}');
                  return Material(
                    color: context.colors.card,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    child: InkWell(
                      key: ValueKey('workflow-run-${run['runId']}'),
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => WorkflowRunDetailPage(
                            sessionId: widget.sessionId,
                            runId: '${run['runId']}',
                            title: label,
                            // 官方 afterSequence 缺省=从头取（最旧一页）
                            // ——目录行已按投影联接补上 lastEventSequence，
                            // 详情页据此反推最新页。
                            lastEventSequence:
                                (run['lastEventSequence'] as num?)?.toInt(),
                          ),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        child: LayoutBuilder(
                          builder: (context, constraints) => Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      label,
                                    translate: false,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: AppType.uiBase,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  if ('${run['failureMessage'] ?? ''}'
                                      .isNotEmpty)
                                    Text(
                                      '${run['failureMessage']}',
                                      translate: false,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: AppType.uiXs,
                                        color: context.colors.destructive,
                                      ),
                                    )
                                  else
                                    Text(
                                      _shortRunId('${run['runId'] ?? ''}'),
                                      style: TextStyle(
                                        fontSize: AppType.uiXs,
                                        fontFamily: 'monospace',
                                        color: context.colors.foregroundSubtlest,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                              const SizedBox(width: 8),
                              // 视觉补跑必修（human-eye-retro-1109，Visual B
                              // 像素实测）：原先 Flexible(状态) 与 Expanded(标题)
                              // 双分把行宽对半分——状态只画约 55dp、剩余约
                              // 87dp 全落行尾=右缘死区（时间不靠右、不同状态
                              // 起始 x 参差、长标题提前约 10 字省略）。改=标题
                              // 独占弹性，状态/时间为非弹性尾簇（窄屏长状态
                              // 72dp 封顶省略，行尾贴卡片右缘）。
                              ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 72),
                                child: Text(
                                  status.label,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: AppType.uiCaption,
                                    color: status.color,
                                  ),
                                ),
                              ),
                              // 320+1.3 英文档实测右侧
                              // 溢出 100px——窄屏隐藏相对时间（次要信息，
                              // 官方桌面窄侧栏也只留状态）。
                              if (constraints.maxWidth >= 300) ...[
                                const SizedBox(width: 6),
                                Text(
                                  _relTime(
                                    (run['updatedAt'] as num?)?.toInt(),
                                  ),
                                  style: TextStyle(
                                    fontSize: AppType.uiXs,
                                    color: context.colors.foregroundSubtlest,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

/// run 详情页：摘要 + 事件时间线 + 产物清单（内容产物点开分块读取文本
/// 预览；html 走 HtmlPreviewPage 本地渲染）。
class WorkflowRunDetailPage extends StatefulWidget {
  final String sessionId;
  final String runId;
  final String title;

  /// 投影的最后事件序号（用于反推事件「最新一页」；目录/run 卡入口
  /// 从快照 workflowRuns 投影联接传入）。
  final int? lastEventSequence;
  const WorkflowRunDetailPage({
    super.key,
    required this.sessionId,
    required this.runId,
    required this.title,
    this.lastEventSequence,
  });

  @override
  State<WorkflowRunDetailPage> createState() => _WorkflowRunDetailPageState();
}

class _WorkflowRunDetailPageState extends State<WorkflowRunDetailPage> {
  /// 官方事件页上界（条数）：CLI 侧钳 ≤500，字节上界更小。
  static const _eventsPageSize = 500;

  /// 首载自动追平的最大页数（防异常 hasMore 无限翻页）。
  static const _eventsMaxPages = 10;

  List<Map<String, dynamic>> _events = const [];
  List<Map<String, dynamic>> _artifacts = const [];
  bool _loading = true;
  bool _eventsBusy = false;
  bool _eventsHasMore = false;
  String? _eventsMoreError;
  String? _error;

  /// 投影的最后事件序号（快照 workflowRuns 投影；目录/run 卡入口会传，
  /// 没传时首载再从投影按 runId 回捞——官方目录 schema 无此字段）。
  int? _lastEventSequence;

  @override
  void initState() {
    super.initState();
    _lastEventSequence = widget.lastEventSequence;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  /// 反推「最新一页」的依据（显式传入优先，其次投影联接）。
  int? _resolveLastEventSequence(AppState app) {
    if (widget.lastEventSequence != null) return widget.lastEventSequence;
    final runs =
        app.conversationStates[widget.sessionId]?.workflowRunsList ??
        const <Map<String, dynamic>>[];
    final joined = joinWorkflowRunProjection(runs, runId: widget.runId);
    return (joined?['lastEventSequence'] as num?)?.toInt();
  }

  Future<({List<Map<String, dynamic>> events, bool hasMore})>
  _fetchEventsPage(AppState app, int? afterSequence) async {
    final res = await app.workflowRunEvents(
      widget.sessionId,
      widget.runId,
      afterSequence: afterSequence,
    );
    final map = res is Map ? res : const {};
    return (
      events: [
        for (final e in (map['events'] as List? ?? const []))
          if (e is Map) e.cast<String, dynamic>(),
      ],
      hasMore: map['hasMore'] == true,
    );
  }

  /// 事件升序归一（官方 journal 升序；展示层 reversed=最新在前）。
  List<Map<String, dynamic>> _sorted(List<Map<String, dynamic>> events) {
    final out = [...events];
    out.sort(
      (a, b) => ((a['sequence'] as num?)?.toInt() ?? 0).compareTo(
        (b['sequence'] as num?)?.toInt() ?? 0,
      ),
    );
    return out;
  }

  /// 首载追平：有投影序号时从「最后序号-页大小」反推窗口，逐页翻到
  /// events.last.sequence >= lastEventSequence 或 hasMore=false 为止
  ///（容纳字节上界导致的短页）；无投影序号=官方语义从头取最早一页。
  /// 页数上限只影响本次自动翻页，余量交「加载更多」。
  Future<({List<Map<String, dynamic>> events, bool hasMore})>
  _fetchEventsCatchingUp(AppState app, int? lastSequence) async {
    final events = <Map<String, dynamic>>[];
    var afterSequence = lastSequence == null
        ? null
        : lastSequence > _eventsPageSize
        ? lastSequence - _eventsPageSize
        : 0;
    var hasMore = false;
    for (var page = 0; page < _eventsMaxPages; page++) {
      final fetched = await _fetchEventsPage(app, afterSequence);
      events.addAll(fetched.events);
      hasMore = fetched.hasMore;
      if (!hasMore) break;
      // 无投影序号：只取最早一页，更晚事件交按钮（不静默扫全量）。
      if (lastSequence == null) break;
      // 游标=本页最大序号（官方 journal 升序；取 max 防乱序页回退死循环）。
      var tailSequence = 0;
      for (final e in fetched.events) {
        final s = (e['sequence'] as num?)?.toInt() ?? 0;
        if (s > tailSequence) tailSequence = s;
      }
      if (tailSequence == 0 || tailSequence >= lastSequence) break;
      afterSequence = tailSequence;
    }
    return (events: _sorted(events), hasMore: hasMore);
  }

  Future<void> _load() async {
    final app = AppStateScope.of(context);
    setState(() {
      _loading = true;
      _error = null;
      _eventsMoreError = null;
    });
    final lastSequence = _resolveLastEventSequence(app);
    _lastEventSequence = lastSequence;
    try {
      // 两路只读查询并行（事件追平与产物清单无依赖）。
      final results = await Future.wait<dynamic>([
        _fetchEventsCatchingUp(app, lastSequence),
        app.workflowRunArtifacts(widget.sessionId, widget.runId),
      ]);
      if (!mounted) return;
      final page =
          results[0]
              as ({List<Map<String, dynamic>> events, bool hasMore});
      setState(() {
        _events = page.events;
        _eventsHasMore = page.hasMore;
        _artifacts =
            ((results[1] is Map
                        ? results[1]['artifacts'] as List?
                        : null) ??
                    const [])
                .whereType<Map>()
                .map((e) => e.cast<String, dynamic>())
                .toList();
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  /// 「加载更多」：从已加载末条继续向后翻（每次一页）；失败保留现有
  /// 时间线，错误内联在页脚。
  Future<void> _loadMoreEvents() async {
    if (_eventsBusy) return;
    final app = AppStateScope.of(context);
    final after = _events.isEmpty
        ? 0
        : ((_events.last['sequence'] as num?)?.toInt() ?? 0);
    setState(() {
      _eventsBusy = true;
      _eventsMoreError = null;
    });
    try {
      final fetched = await _fetchEventsPage(app, after);
      if (!mounted) return;
      setState(() {
        _events = _sorted([..._events, ...fetched.events]);
        _eventsHasMore = fetched.hasMore;
        _eventsBusy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _eventsBusy = false;
        _eventsMoreError = '$e';
      });
    }
  }

  /// 事件标题的诚实口径：追平（到顶）才敢说「最新」；有投影序号但没有
  /// 更晚事件=最新；无投影序号=官方从头取，只能称「最早」。
  /// 追平档复用既有可翻译标题形态（custom_l10n 的
  /// `^事件（最新 (\d+) 条）$` 模式），英文界面不裸露中文。
  String get _eventsTitle {
    final count = _events.length;
    if (_lastEventSequence == null) {
      return _eventsHasMore ? '最早 $count 条 · 仍有更晚事件未加载' : '最早 $count 条';
    }
    if (!_eventsHasMore) return '事件（最新 $count 条）';
    final newest = _events.isEmpty
        ? null
        : (_events.last['sequence'] as num?)?.toInt();
    return '已加载至 #${newest ?? 0} · 更晚事件未加载';
  }

  /// 看板四类无内容字节（官方注释明示），不可 ArtifactRead。
  bool _artifactReadable(Map<String, dynamic> a) {
    const dashboards = {'chart', 'table', 'metrics', 'board'};
    final kind = '${a['kind'] ?? ''}';
    return kind.isEmpty || !dashboards.contains(kind);
  }

  /// 内容产物分块读取（≤512KiB/块；文本类拼到 8 块止，防超长拖垮 UI）。
  /// ：①行内 busy 防重入（此前可双击叠推两个
  /// 预览页）；②块间字节缓冲——512KiB 边界可能切在多字节字符中间，逐
  /// 块独立 decode 会各出一个替换符；③8 块截断不再静默（预览页顶部
  /// 明示"内容过长已截断"）。
  bool _artifactBusy = false;
  Future<void> _openArtifact(Map<String, dynamic> artifact) async {
    if (_artifactBusy) return;
    final app = AppStateScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _artifactBusy = true);
    try {
      final bytes = <int>[];
      var offset = 0;
      var truncated = false;
      for (var i = 0; i < 8; i++) {
        final res = await app.workflowRunArtifactRead(
          widget.sessionId,
          widget.runId,
          '${artifact['id']}',
          version: (artifact['version'] as num?)?.toInt() ?? 1,
          offset: offset,
          limit: 512 * 1024,
        );
        final b64 = '${(res is Map ? res['dataBase64'] : '') ?? ''}';
        if (b64.isEmpty) break;
        bytes.addAll(base64.decode(b64));
        final next =
            (res is Map ? (res['nextOffset'] as num?)?.toInt() : null) ??
                -1;
        if (next <= offset || next <= 0) break;
        offset = next;
        if (i == 7) truncated = true;
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      if (!mounted) return;
      if (text.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(content: Text('该产物没有可读的文本内容')),
        );
        return;
      }
      final name = truncated
          ? '${artifact['title'] ?? artifact['id']}（${tr('内容过长已截断')}）'
          : '${artifact['title'] ?? artifact['id']}';
      // html 嗅探正则锚定文首（此前 `|` 优先
      // 级让正文任意位置的 <html 字样也会误进 WebView）。
      if (RegExp(r'^\s*(<!doctype html|<html)', caseSensitive: false)
          .hasMatch(text)) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => HtmlPreviewPage(
              title: name,
              htmlContent: text,
            ),
          ),
        );
      } else {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => _ArtifactTextPage(title: name, content: text),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('读取产物失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _artifactBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        backgroundColor: context.colors.background,
        surfaceTintColor: Colors.transparent,
        title: Text(widget.title, translate: false, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: _loading
          ? const Center(child: AppLoading('正在加载…'))
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr('加载失败：') + _error!,
                    style: TextStyle(
                      fontSize: AppType.uiCaption,
                      color: context.colors.destructive,
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(onPressed: _load, child: const Text('重试')),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: [
                if (_events.isNotEmpty) ...[
                  Text(
                    _eventsTitle,
                    style: TextStyle(
                      fontSize: AppType.uiSm,
                      fontWeight: FontWeight.w600,
                      color: context.colors.foregroundSubtle,
                    ),
                  ),
                  const SizedBox(height: 6),
                  for (final e in _events.reversed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '#${e['sequence']}',
                            style: TextStyle(
                              fontSize: AppType.uiXs,
                              fontFamily: 'monospace',
                              color: context.colors.foregroundSubtlest,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${e['type']}'
                              '${e['truncated'] == true ? tr('（已截断）') : ''}',
                              style: const TextStyle(
                                fontSize: AppType.uiCaption,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  // 未追平：手动续页（失败内联，不顶掉已在屏时间线）。
                  if (_eventsMoreError != null)
                    Padding(
                      key: const ValueKey('workflow-events-more-error'),
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '加载更多失败：$_eventsMoreError',
                              style: TextStyle(
                                fontSize: AppType.uiXs,
                                color: context.colors.destructive,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: _eventsBusy ? null : _loadMoreEvents,
                            child: Text(tr('重试')),
                          ),
                        ],
                      ),
                    ),
                  if (_eventsHasMore)
                    Center(
                      child: TextButton(
                        key: const ValueKey('workflow-events-load-more'),
                        onPressed: _eventsBusy ? null : _loadMoreEvents,
                        child: Text(_eventsBusy ? '加载中…' : '加载更多'),
                      ),
                    ),
                ],
                if (_artifacts.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    '产物（${_artifacts.length}）',
                    style: TextStyle(
                      fontSize: AppType.uiSm,
                      fontWeight: FontWeight.w600,
                      color: context.colors.foregroundSubtle,
                    ),
                  ),
                  const SizedBox(height: 6),
                  // VR-6（视觉审查 1109）：产物卡此前零间距叠放+行高
                  // 39.7（低于 44 触控/可读下限），两张卡像一整块。
                  // 修=相邻卡 6dp 间距 + 卡内容 minHeight 44（行高抬到
                  // ≥44，图标/字号不变）。
                  for (var ai = 0; ai < _artifacts.length; ai++)
                    Padding(
                      padding: EdgeInsets.only(top: ai == 0 ? 0 : 6),
                      child: Builder(builder: (_) {
                        final a = _artifacts[ai];
                        return Material(
                          color: context.colors.card,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                          child: InkWell(
                            key: ValueKey('workflow-artifact-${a['id']}'),
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                            // A 批（2026-11-08 拍板⑥）：内容产物=分块字节读取；
                            // 看板四类（chart/table/metrics/board）=数据页渲染
                            //（workflowRunArtifactData + spec 宽松解析）。
                            onTap: _artifactReadable(a)
                                ? () => _openArtifact(a)
                                : () => Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => WorkflowDashboardPage(
                                          sessionId: widget.sessionId,
                                          runId: widget.runId,
                                          artifact: a,
                                        ),
                                      ),
                                    ),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(minHeight: 44),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.description_outlined,
                                      size: 16,
                                      color: context.colors.foregroundSubtle,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        '${a['title'] ?? a['id']}',
                                        translate: false,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: AppType.uiCaption,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      '${a['kind']} · v${a['version'] ?? 1}',
                                      style: TextStyle(
                                        fontSize: AppType.uiXs,
                                        color:
                                            context.colors.foregroundSubtlest,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                ],
                if (_events.isEmpty && _artifacts.isEmpty)
                  Center(
                    child: Text(
                      '该运行没有事件与产物记录',
                      style: TextStyle(
                        fontSize: AppType.uiCaption,
                        color: context.colors.foregroundSubtle,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// 简单文本产物页（等宽只读）。
class _ArtifactTextPage extends StatelessWidget {
  final String title;
  final String content;
  const _ArtifactTextPage({required this.title, required this.content});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        backgroundColor: context.colors.background,
        surfaceTintColor: Colors.transparent,
        title: Text(title, translate: false, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: SelectableText(
          content,
          style: const TextStyle(
            fontSize: AppType.uiCaption,
            fontFamily: 'monospace',
            height: 1.5,
          ),
        ),
      ),
    );
  }
}


// ------------------------------------------------------------ 闲时任务卡

/// OffPeakCreate 工具行输出摘要（官方 readOffPeakCreateTaskOutputSummary
/// 语义：output 可为 JSON 字符串；{task:{…}} 或平铺；缺 offPeakTaskId=
/// 无效回退普通工具行）。
class OffPeakCreateSummary {
  const OffPeakCreateSummary({
    required this.offPeakTaskId,
    this.title,
    this.status,
    this.queuePosition,
  });
  final String offPeakTaskId;
  final String? title;
  final String? status;
  final int? queuePosition;
}

OffPeakCreateSummary? offPeakCreateSummary(Map<String, dynamic> row) {
  dynamic candidate = row['output'];
  if (candidate is String) {
    try {
      candidate = jsonDecode(candidate);
    } catch (_) {
      return null;
    }
  }
  if (candidate is! Map) return null;
  final task = candidate['task'] is Map ? candidate['task']! as Map : candidate;
  final id = '${task['offPeakTaskId'] ?? ''}'.trim();
  if (id.isEmpty) return null;
  final title = '${task['title'] ?? ''}'.trim();
  final status = '${task['status'] ?? ''}'.trim();
  final pos = (task['queuePosition'] as num?)?.toInt();
  return OffPeakCreateSummary(
    offPeakTaskId: id,
    title: title.isEmpty ? null : title,
    status: status.isEmpty ? null : status,
    queuePosition: pos != null && pos > 0 ? pos : null,
  );
}

/// 闲时任务卡（官方 offpeak-create.tsx 对位：标题+「已加入闲时队列
/// （第 N 位）/已加入闲时队列 · 运行在当前会话」状态行）。
class OffPeakTaskCard extends StatelessWidget {
  final Map<String, dynamic> row;
  const OffPeakTaskCard({super.key, required this.row});

  @override
  Widget build(BuildContext context) {
    final s = offPeakCreateSummary(row);
    if (s == null) return const SizedBox.shrink();
    final queueLine = s.queuePosition != null
        ? '已加入闲时队列（第 ${s.queuePosition} 位）'
        : '已加入闲时队列';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: context.colors.card,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: context.colors.border),
        ),
        child: Row(
          children: [
            Icon(
              Icons.schedule_outlined,
              size: 18,
              color: context.colors.brandAccent,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.title ?? tr('闲时任务'),
                    translate: s.title == null,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: AppType.uiBase,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    // 分段本地化；协议 status token 走
                    // 五态映射（原样透传=中英界面都露协议词）。
                    '$queueLine · ${tr('运行在当前会话')}'
                    '${s.status != null ? ' · ${workflowRunStatusOf(context, s.status!).label}' : ''}',
                    style: TextStyle(
                      fontSize: AppType.uiXs,
                      color: context.colors.foregroundSubtle,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A 批（拍板⑧）+ F3 对抗审查返工（高③）：会话内工作流 run 卡。
/// runId/status 权威源=快照 workflowRuns 投影按 toolCallId 联接（官方
/// workflowRunCardJoin.ts:33-51——v4 工具行 output 只有散文，结构化
/// 字段不在行上）；联接不上=只显示名称不可点（官方同款：编不过的
/// CreateWorkflow 走反馈行，不出假卡）。
class WorkflowRunCard extends StatelessWidget {
  final Map<String, dynamic> row;

  /// 快照 workflowRuns 投影（页面传入；null=无投影不联接）。
  final List<Map<String, dynamic>>? runs;
  final String? sessionId;
  const WorkflowRunCard({
    super.key,
    required this.row,
    this.runs,
    this.sessionId,
  });

  static Map<String, dynamic>? _tryJson(String raw) {
    try {
      final v = jsonDecode(raw);
      return v is Map ? v.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  /// toolCallId 联接（官方 buildWorkflowRunByToolCallId 对位）。
  Map<String, dynamic>? _joinedRun() {
    final tcId = '${row['toolCallId'] ?? ''}';
    if (tcId.isEmpty || runs == null) return null;
    for (final r in runs!) {
      if ('${r['toolCallId'] ?? ''}' == tcId) return r;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // 名称取值链与官方 toolCallRowAdapter 同序：结构化 input 优先（进入
    // running 即携带），inputText JSON 兜底——run 早期 inputText 未定稿
    // 时不再让名字退化成「工作流」。
    final input = toolInputArgs(row) ?? _tryJson('${row['inputText'] ?? ''}') ?? const {};
    var name = '${input['name'] ?? ''}'.trim();
    if (name.isEmpty) name = '${input['description'] ?? ''}'.trim();
    final run = _joinedRun();
    // F3：status 只认投影（工具行 status 是 success/error 工具态，
    // 不是 run 态——混用会显示英文原词）。
    final status = '${run?['status'] ?? ''}';
    final runId = '${run?['runId'] ?? ''}';
    final live = status == 'running' || status == 'pending';
    final done = status == 'completed';
    final color = done
        ? context.colors.foregroundSubtle
        : status == 'errored'
        ? context.colors.destructive
        : live
        ? context.colors.running
        : context.colors.foregroundSubtlest;
    final statusLabel =
        status.isEmpty ? tr('工作流') : workflowRunStatusWord(status);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        key: ValueKey('workflow-run-card-${row['rowId'] ?? row['toolCallId'] ?? ''}'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: context.colors.card,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: context.colors.border),
        ),
        child: InkWell(
          onTap: runId.isEmpty || sessionId == null
              ? null
              : () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => WorkflowRunDetailPage(
                        sessionId: sessionId!,
                        runId: runId,
                        title: name.isEmpty ? tr('工作流') : name,
                        // 入口必须传投影序号：官方 run 目录 schema 没有该
                        // 字段，详情页靠它反推「最新一页」。
                        lastEventSequence:
                            (run?['lastEventSequence'] as num?)?.toInt(),
                      ),
                    ),
                  ),
          child: Row(
            children: [
              Icon(
                Icons.account_tree_outlined,
                size: 18,
                color: live ? context.colors.running : color,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name.isEmpty ? tr('工作流') : name,
                      translate: false,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: AppType.uiBase,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      statusLabel,
                      style: TextStyle(fontSize: AppType.uiXs, color: color),
                    ),
                  ],
                ),
              ),
              if (runId.isNotEmpty && sessionId != null)
                Icon(
                  Icons.chevron_right,
                  size: 16,
                  color: context.colors.foregroundSubtlest,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

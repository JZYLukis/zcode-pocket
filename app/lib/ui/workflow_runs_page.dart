import 'dart:convert';

import 'package:flutter/material.dart' hide Text;
import '../core/localized_text.dart';
import '../core/theme.dart';
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
      final res = await AppStateScope.of(context)
          .workflowRuns(widget.sessionId);
      final runs = (res is Map ? res['runs'] as List? : null) ?? const [];
      if (!mounted) return;
      setState(() {
        _runs = runs
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
                            // review-fix-1（workflow 组）：官方 afterSequence
                            // 缺省=从头取（最旧一页）——用 run 的
                            // lastEventSequence 反推最新页。
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
                              // 窄屏长英文状态可省略，不挤标题。
                              Flexible(
                                child: Text(
                                  status.label,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: AppType.uiCaption,
                                    color: status.color,
                                  ),
                                ),
                              ),
                              // review-fix-1：320+1.3 英文档实测右侧
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

  /// run 目录行的 lastEventSequence（用于反推事件最新页）。
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
  List<Map<String, dynamic>> _events = const [];
  List<Map<String, dynamic>> _artifacts = const [];
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
    final app = AppStateScope.of(context);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 两路只读查询并行。review-fix-1（workflow 组）：官方 afterSequence
      // 缺省=从头取（最旧一页，页大小 CLI 钳 ≤500）——此前标题标"最新
      // N 条"实际显示最早事件。用 run 的 lastEventSequence 反推最新页。
      final lastSeq = widget.lastEventSequence;
      final eventsAfter = lastSeq == null ? null : lastSeq > 500 ? lastSeq - 500 : 0;
      final results = await Future.wait<dynamic>([
        app.workflowRunEvents(
          widget.sessionId,
          widget.runId,
          afterSequence: eventsAfter,
        ),
        app.workflowRunArtifacts(widget.sessionId, widget.runId),
      ]);
      if (!mounted) return;
      setState(() {
        _events =
            ((results[0] is Map ? results[0]['events'] as List? : null) ??
                const [])
                .whereType<Map>()
                .map((e) => e.cast<String, dynamic>())
                .toList();
        _artifacts =
            ((results[1] is Map ? results[1]['artifacts'] as List? : null) ??
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

  /// 看板四类无内容字节（官方注释明示），不可 ArtifactRead。
  bool _artifactReadable(Map<String, dynamic> a) {
    const dashboards = {'chart', 'table', 'metrics', 'board'};
    final kind = '${a['kind'] ?? ''}';
    return kind.isEmpty || !dashboards.contains(kind);
  }

  /// 内容产物分块读取（≤512KiB/块；文本类拼到 8 块止，防超长拖垮 UI）。
  /// review-fix-1（workflow 组）：①行内 busy 防重入（此前可双击叠推两个
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
      // review-fix-1（workflow 组）：html 嗅探正则锚定文首（此前 `|` 优先
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
                    '事件（最新 ${_events.length} 条）',
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
                  for (final a in _artifacts)
                    Material(
                      color: context.colors.card,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      child: InkWell(
                        key: ValueKey('workflow-artifact-${a['id']}'),
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        // review-fix-1（workflow 组）：看板四类（chart/
                        // table/metrics/board）无内容字节——ArtifactRead
                        // 必失败，禁点并明示（官方 workflow-artifacts.ts:26）。
                        onTap: _artifactReadable(a)
                            ? () => _openArtifact(a)
                            : () => ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      tr('看板类产物暂不支持在手机查看'),
                                    ),
                                  ),
                                ),
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
                                  color: context.colors.foregroundSubtlest,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
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
                    // review-fix-1（A7）：分段本地化；协议 status token 走
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

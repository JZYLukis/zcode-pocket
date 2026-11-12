// A 批（2026-11-08 拍板⑥）看板产物：预置 spec 宽松解析 + 字段取数 +
// 四渲染器数据准备（官方 presets/spec.ts + workflow-artifacts.ts
// readWorkflowArtifactField 的 Dart 对位）。
//
// 宽松原则（官方同款）：多余键忽略、坏可选字段丢弃、必填缺失才判
// 不可渲染——渲染器绝不因一条畸形 spec 炸整页，降级为「无法渲染」卡。
import 'dart:convert';

import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/theme.dart';
import '../state/app_state_scope.dart';

// ---------- 字段路径取数（协议契约，非工具函数） ----------

/// 按点路径从 report item 取值："timing.after"、"rounds.0.ms"。
/// 规则（官方 readWorkflowArtifactField 逐字对位）：按 `.` 切段；数组段
/// 按非负整数下标；对象按键；走不通（null/标量/越界/缺键）= null。
Object? readArtifactField(Object? item, String path) {
  Object? cursor = item;
  for (final seg in path.split('.')) {
    if (cursor is Map) {
      if (!cursor.containsKey(seg)) return null;
      cursor = cursor[seg];
    } else if (cursor is List) {
      final idx = int.tryParse(seg);
      if (idx == null || idx < 0 || idx >= cursor.length) return null;
      cursor = cursor[idx];
    } else {
      return null;
    }
  }
  return cursor;
}

// ---------- spec 模型与宽松解析 ----------

class ArtifactField {
  final String field;
  final String? label;
  final String? unit;
  const ArtifactField(this.field, {this.label, this.unit});
  String get displayLabel => (label ?? field).trim();
}

bool _isRecord(Object? v) => v is Map && v is! List;
String? _str(Object? v) => v is String && v.trim().isNotEmpty ? v : null;

ArtifactField? _parseField(Object? v) {
  final shorthand = _str(v);
  if (shorthand != null) return ArtifactField(shorthand);
  if (!_isRecord(v)) return null;
  final m = v as Map;
  final field = _str(m['field']);
  if (field == null) return null;
  return ArtifactField(field, label: _str(m['label']), unit: _str(m['unit']));
}

List<ArtifactField>? _parseFieldList(Object? v) {
  if (v is! List) return null;
  final out = <ArtifactField>[];
  for (final e in v) {
    final f = _parseField(e);
    if (f != null) out.add(f);
  }
  return out.isEmpty ? null : out;
}

/// 归一化后的四类 spec；null=不可渲染（调用方降级）。
class DashboardSpec {
  final String kind; // chart|table|metrics|board
  final String title;
  final String description;
  // chart
  final String chartType; // line|bar|scatter
  final ArtifactField? x;
  final List<ArtifactField> ys;
  // table
  final List<ArtifactField>? columns;
  final String? rowKey;
  // metrics
  final List<ArtifactField>? metrics;
  // board
  final String? boardKey;
  final String? boardStatus;
  final List<String> boardColumns;
  final String cardTitle;
  final List<ArtifactField> detail;

  const DashboardSpec({
    required this.kind,
    this.title = '',
    this.description = '',
    this.chartType = 'line',
    this.x,
    this.ys = const [],
    this.columns,
    this.rowKey,
    this.metrics,
    this.boardKey,
    this.boardStatus,
    this.boardColumns = const [],
    this.cardTitle = '',
    this.detail = const [],
  });
}

/// 宽松解析（官方 parseChart/parseTable/parseMetrics/parseBoard 对位）。
DashboardSpec? parseDashboardSpec(String kind, Object? raw) {
  if (!_isRecord(raw)) return null;
  final spec = raw as Map;
  final title = _str(spec['title']) ?? '';
  final description = _str(spec['description']) ?? '';
  switch (kind) {
    case 'chart':
      final x = _parseField(spec['x']);
      if (x == null) return null;
      final yRaw = spec['y'];
      final ys = yRaw is List
          ? (_parseFieldList(yRaw) ?? const <ArtifactField>[])
          : [
              if (_parseField(yRaw) != null) _parseField(yRaw)!,
            ];
      if (ys.isEmpty) return null;
      final type = _str(spec['type']);
      // known-gap：官方 ArtifactChartSpec 还有
      // scale（linear|log 对数轴）与 baseline（参考线字段）——手机版未
      // 实现，解析时忽略（恒线性轴、无参考线）；账本由协调员登记。
      return DashboardSpec(
        kind: kind,
        title: title,
        description: description,
        chartType: type == 'bar' || type == 'scatter' ? type! : 'line',
        x: x,
        ys: ys,
      );
    case 'table':
      final cols = _parseFieldList(spec['columns']);
      if (cols == null) return null;
      return DashboardSpec(
        kind: kind,
        title: title,
        description: description,
        columns: cols,
        rowKey: _str(spec['key']),
      );
    case 'metrics':
      final ms = _parseFieldList(spec['metrics']);
      if (ms == null) return null;
      return DashboardSpec(
        kind: kind,
        title: title,
        description: description,
        metrics: ms,
      );
    case 'board':
      final key = _str(spec['key']);
      final status = _str(spec['status']);
      if (key == null || status == null) return null;
      final cols = <String>[
        for (final c in spec['columns'] is List ? spec['columns'] as List : const [])
          if (_str(c) != null) _str(c)!,
      ];
      return DashboardSpec(
        kind: kind,
        title: title,
        description: description,
        boardKey: key,
        boardStatus: status,
        boardColumns: cols,
        cardTitle: _str(spec['cardTitle']) ?? '',
        detail: _parseFieldList(spec['detail']) ?? const [],
      );
    default:
      return null;
  }
}

// ---------- 渲染数据准备 ----------

class ArtifactDataItem {
  final int sequence;
  final Map<String, dynamic>? item;

  /// （声明 key 但该条缺值时官方用
  /// `siteId@ordinal` 做唯一 id 逐条追加（apply.ts:288-298），我们把
  /// 缺值折叠成 '' 会整组互撞覆盖（数据丢失）。
  final String siteId;
  final int ordinal;
  const ArtifactDataItem(this.sequence, this.item,
      {this.siteId = '', this.ordinal = 0});

  /// 行身份：key 值缺失时的唯一兜底。
  String get fallbackId => '$siteId@$ordinal';
}

/// （中·数字精度）：行 key 用原样字符串（官方
/// formatArtifactValue=String 原样）——toFixed(2) 会把 1.234 与 1.23
/// 两个不同 key 错误合并成同一行。
String _cellKey(Object? v) {
  if (v == null) return '';
  if (v is num) return '$v';
  if (v is bool) return v ? 'true' : 'false';
  if (v is String) return v;
  return jsonEncode(v);
}

String _cellText(Object? v, {String? unit}) {
  if (v == null) return '';
  String s;
  if (v is num) {
    // 官方 formatArtifactValue=String(value) 对位：全精度原样输出。
    // 旧实现 toStringAsFixed(2) 把 1.234 截成 "1.23"（与行 key 的原样
    // 字符串不一致）；整数值去 ".0"（JS String(3.0)==='3'）。
    s = v is double && v.isFinite && v == v.roundToDouble()
        ? v.toInt().toString()
        : '$v';
  } else if (v is bool) {
    s = v ? 'true' : 'false';
  } else if (v is String) {
    s = v;
  } else {
    s = jsonEncode(v);
  }
  if (unit != null && unit.isNotEmpty && s.isNotEmpty) s = '$s $unit';
  return s;
}

/// 折线分段（官方 connectNulls=false 对位）：null=缺测断线。返回每段
/// 连续非空点的 (下标, 值) 列表。
///
/// 旧画笔遇 null 只把 current 置空、从不把已画段落进 segments，循环后
/// 只画最后一段——中段断点整段丢失，末点 null 更是整线消失。分段抽成
/// 纯函数便于穷举（中段断点/末点 null/全 null）。
List<List<({int index, double value})>> splitChartLineSegments(
  List<double?> values,
) {
  final out = <List<({int index, double value})>>[];
  List<({int index, double value})>? current;
  for (var i = 0; i < values.length; i++) {
    final v = values[i];
    if (v == null) {
      if (current != null) {
        out.add(current);
        current = null;
      }
      continue;
    }
    (current ??= <({int index, double value})>[]).add((index: i, value: v));
  }
  if (current != null) out.add(current);
  return out;
}

/// 表格行（key 存在时同 key 后到替换，官方 TableSpec 语义）。
List<List<String>> buildTableRows(DashboardSpec spec, List<ArtifactDataItem> items) {
  final rowsByKey = <String, List<String>>{};
  final list = <List<String>>[];
  for (final it in items) {
    final cells = [
      for (final c in spec.columns!)
        _cellText(readArtifactField(it.item, c.field), unit: c.unit),
    ];
    final rowKey = spec.rowKey;
    if (rowKey != null) {
      final rawKey = readArtifactField(it.item, rowKey);
      // 缺值行用 siteId@ordinal 身份（不折叠互撞）；key 用原样数字。
      final key = rawKey == null ? it.fallbackId : _cellKey(rawKey);
      final prevCells = rowsByKey[key];
      if (prevCells != null) {
        final idx = list.indexOf(prevCells);
        if (idx >= 0) list[idx] = cells;
        rowsByKey[key] = cells;
      } else {
        rowsByKey[key] = cells;
        list.add(cells);
      }
    } else {
      list.add(cells);
    }
  }
  return list;
}

/// 指标瓦片：每字段取「最后一条带该字段的条目」的值。
List<(String, String)> buildMetricTiles(DashboardSpec spec, List<ArtifactDataItem> items) {
  final out = <(String, String)>[];
  for (final m in spec.metrics!) {
    String? value;
    for (final it in items) {
      final v = readArtifactField(it.item, m.field);
      if (v != null) value = _cellText(v, unit: m.unit);
    }
    out.add((m.displayLabel, value ?? '—'));
  }
  return out;
}

/// run 状态词（A 批：官方 status 枚举 → 中文；stopReason 展示留后续）。
String workflowRunStatusWord(String status) => switch (status) {
      'pending' => '等待中',
      'running' => '运行中',
      'completed' => '已完成',
      'errored' => '出错',
      'stopped' => '已停止',
      _ => status,
    };

// ---------- 看板数据页（A 批：workflowRunArtifactData 取数 + 四渲染器） ----------

class WorkflowDashboardPage extends StatefulWidget {
  final String sessionId;
  final String runId;
  final Map<String, dynamic> artifact;
  const WorkflowDashboardPage({
    super.key,
    required this.sessionId,
    required this.runId,
    required this.artifact,
  });

  @override
  State<WorkflowDashboardPage> createState() => _WorkflowDashboardPageState();
}

class _WorkflowDashboardPageState extends State<WorkflowDashboardPage> {
  List<ArtifactDataItem> _items = [];
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  /// 翻页失败（已渲染数据仍在上方，仅页脚报错——不再整页错误）。
  String? _moreError;
  DashboardSpec? _spec;

  String get _artifactId => '${widget.artifact['id'] ?? ''}';
  String get _kind => '${widget.artifact['kind'] ?? ''}';

  @override
  void initState() {
    super.initState();
    _spec = parseDashboardSpec(_kind, widget.artifact['spec']);
    // （·渲染中）：initState 阶段生命周期 created，同步
    // AppStateScope.of 必抛 FlutterError（debug 实锤）——延到首帧后
    //（workflow_runs_page:58 同款纪律）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  /// 解析一页条目（协议形状 {sequence,siteId,ordinal,item|fields}）。
  List<ArtifactDataItem> _parseItems(Map<dynamic, dynamic> map) => [
        for (final e in (map['items'] as List? ?? const []))
          if (e is Map)
            ArtifactDataItem(
              (e['sequence'] as num?)?.toInt() ?? 0,
              e['item'] is Map
                  ? (e['item'] as Map).cast<String, dynamic>()
                  : null,
              siteId: '${e['siteId'] ?? ''}',
              ordinal: (e['ordinal'] as num?)?.toInt() ?? 0,
            ),
      ];

  /// 自动排空续页（游标不前进即停——官方 advanced 守卫）。
  /// 翻页中途失败不再上抛顶掉整页：保留已渲染 _items，错误落页脚
  ///（重试/停止由 _DashboardBody 给出）。
  Future<void> _drain({required int afterSequence}) async {
    if (_loadingMore) return;
    setState(() {
      _loadingMore = true;
      _moreError = null;
    });
    var cursor = afterSequence;
    try {
      while (true) {
        final res = await AppStateScope.of(context)
            .workflowRunArtifactData(
              widget.sessionId,
              widget.runId,
              _artifactId,
              afterSequence: cursor,
            )
            .timeout(const Duration(seconds: 30));
        if (!mounted) return;
        final map = (res as Map?)?.cast<String, dynamic>() ?? const {};
        final items = _parseItems(map);
        // 游标不前进（异常防御）——停，不无限循环。
        if (items.isEmpty || items.last.sequence <= cursor) {
          setState(() {
            _hasMore = false;
            _loadingMore = false;
          });
          return;
        }
        final hasMore = map['hasMore'] == true;
        setState(() {
          _items = [..._items, ...items];
          _hasMore = hasMore;
        });
        cursor = items.last.sequence;
        if (!hasMore) break;
      }
      if (mounted) setState(() => _loadingMore = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        // 保留 _items；hasMore 不动，页脚给重试/停止。
        _moreError = '$e';
      });
    }
  }

  Future<void> _load() async {
    if (_loadingMore) return;
    setState(() {
      _loading = true;
      _error = null;
      _moreError = null;
    });
    try {
      final res = await AppStateScope.of(context)
          .workflowRunArtifactData(widget.sessionId, widget.runId, _artifactId)
          .timeout(const Duration(seconds: 30));
      if (!mounted) return;
      final map = (res as Map?)?.cast<String, dynamic>() ?? const {};
      final items = _parseItems(map);
      setState(() {
        _items = items;
        _hasMore = map['hasMore'] == true;
        _loading = false;
      });
      // （官方 useWorkflowRunArtifactData :119-165）：首帧已渲染后
      // 自动翻页到排空（否则 >200 条的看板指标取的不是最新值）。
      if (_hasMore && items.isNotEmpty) {
        await _drain(afterSequence: items.last.sequence);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // 首载失败才占整页错误；已有数据的失败只落页脚（不顶掉内容）。
        if (_items.isEmpty) {
          _error = '$e';
        } else {
          _moreError = '$e';
        }
      });
    }
  }

  /// 手动「加载更多」：与 _drain 共享 loadingMore 门（互斥）。
  Future<void> _loadMore() async {
    if (_loading || _loadingMore) return;
    await _drain(afterSequence: _items.isEmpty ? 0 : _items.last.sequence);
  }

  /// 页脚「停止」：放弃本页后续续页（不再自动/手动重试）。
  void _stopMore() {
    setState(() {
      _hasMore = false;
      _moreError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final title = '${widget.artifact['title'] ?? _artifactId}';
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        backgroundColor: context.colors.background,
        surfaceTintColor: Colors.transparent,
        title: Text(title,
            translate: false, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('加载失败：$_error',
                          style: TextStyle(
                              fontSize: AppType.uiCaption,
                              color: context.colors.destructive)),
                      const SizedBox(height: 12),
                      OutlinedButton(
                          onPressed: () => _load(), child: const Text('重试')),
                    ],
                  ),
                )
              : _spec == null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          '无法渲染该看板（规格缺失或不完整）',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: AppType.uiCaption,
                              color: context.colors.foregroundSubtle),
                        ),
                      ),
                    )
                  : _DashboardBody(
                      spec: _spec!,
                      items: _items,
                      hasMore: _hasMore,
                      loadingMore: _loadingMore,
                      moreError: _moreError,
                      onLoadMore: _loadMore,
                      onRetryMore: _loadMore,
                      onStopMore: _stopMore,
                    ),
    );
  }
}

class _DashboardBody extends StatelessWidget {
  final DashboardSpec spec;
  final List<ArtifactDataItem> items;
  final bool hasMore;
  final bool loadingMore;

  /// 翻页失败人话（非空=页脚行内错误，保留上方已渲染内容）。
  final String? moreError;
  final VoidCallback onLoadMore;
  final VoidCallback onRetryMore;
  final VoidCallback onStopMore;

  const _DashboardBody({
    required this.spec,
    required this.items,
    required this.hasMore,
    required this.loadingMore,
    required this.moreError,
    required this.onLoadMore,
    required this.onRetryMore,
    required this.onStopMore,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const ValueKey('workflow-dashboard-body'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        if (spec.description.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              spec.description,
              style: TextStyle(
                  fontSize: AppType.uiXs,
                  color: context.colors.foregroundSubtle),
            ),
          ),
        if (spec.kind == 'metrics') _MetricsView(spec: spec, items: items),
        if (spec.kind == 'table') _TableView(spec: spec, items: items),
        if (spec.kind == 'chart') _ChartView(spec: spec, items: items),
        if (spec.kind == 'board') _BoardView(spec: spec, items: items),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                '该看板还没有数据',
                style: TextStyle(
                    fontSize: AppType.uiCaption,
                    color: context.colors.foregroundSubtle),
              ),
            ),
          ),
        if (hasMore)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: moreError == null
                ? Center(
                    child: TextButton(
                      key: const ValueKey('dashboard-load-more'),
                      onPressed: loadingMore ? null : onLoadMore,
                      child: Text(loadingMore ? '加载中…' : '加载更多'),
                    ),
                  )
                : Column(
                    children: [
                      Text(
                        '加载更多失败：$moreError',
                        key: const ValueKey('dashboard-load-more-error'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: AppType.uiXs,
                          color: context.colors.destructive,
                        ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          TextButton(
                            onPressed: loadingMore ? null : onRetryMore,
                            child: Text('重试'),
                          ),
                          TextButton(
                            key: const ValueKey('dashboard-load-more-stop'),
                            onPressed: onStopMore,
                            child: Text('停止'),
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
      ],
    );
  }
}

class _MetricsView extends StatelessWidget {
  final DashboardSpec spec;
  final List<ArtifactDataItem> items;
  const _MetricsView({required this.spec, required this.items});

  @override
  Widget build(BuildContext context) {
    final tiles = buildMetricTiles(spec, items);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (label, value) in tiles)
          Container(
            key: ValueKey('metric-$label'),
            width: (MediaQuery.sizeOf(context).width - 24 - 8) / 2,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: context.colors.card,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: context.colors.borderFaint),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  translate: false,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: AppType.uiXs,
                      color: context.colors.foregroundSubtle),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  translate: false,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: AppType.uiLg, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _TableView extends StatefulWidget {
  final DashboardSpec spec;
  final List<ArtifactDataItem> items;
  const _TableView({required this.spec, required this.items});

  @override
  State<_TableView> createState() => _TableViewState();
}

class _TableViewState extends State<_TableView> {
  // thumbVisibility:true 的 Scrollbar 在移动端必须显式持控（断言：
  // 无 controller 时回落 PrimaryScrollController——横向滚动没有主控）。
  final _hScroll = ScrollController();

  @override
  void dispose() {
    _hScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rows = buildTableRows(widget.spec, widget.items);
    if (rows.isEmpty) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        color: context.colors.card,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: context.colors.borderFaint),
      ),
      // 视觉补跑必修（Visual A 复签终版）：5 列
      // 形态右缘硬切零提示。第一轮只加底部 Scrollbar——A 复签实锤
      // thumb 落在全表底部（34 行≈1630dp 折叠线外），正视区仍零提示；
      // 且内容收缩后卡片右侧留 85dp 空白带。终版=①minWidth 填满卡片
      // ②右缘渐隐随滚动位置显隐（未滚到最右时提示「右边还有列」）
      // ③间距收窄（columnSpacing 56→14、horizontalMargin 24→12）
      // +单元格 224dp 封顶省略（官方 ArtifactTable 对位；定高内滚+
      // 表头吸顶的完整对位归 backlog）。
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          children: [
            Scrollbar(
              controller: _hScroll,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _hScroll,
                scrollDirection: Axis.horizontal,
                child: ConstrainedBox(
                  constraints:
                      BoxConstraints(minWidth: constraints.maxWidth),
                  child: DataTable(
                    key: const ValueKey('dashboard-table'),
                    columnSpacing: 14,
                    horizontalMargin: 12,
                    headingTextStyle: TextStyle(
                        fontSize: AppType.uiXs,
                        fontWeight: FontWeight.w600,
                        color: context.colors.foregroundSubtle),
                    dataTextStyle: TextStyle(
                        fontSize: AppType.uiXs,
                        color: context.colors.foreground),
                    columns: [
                      for (final c in widget.spec.columns!)
                        DataColumn(
                            label: Text(c.displayLabel, translate: false)),
                    ],
                    rows: [
                      for (final row in rows)
                        DataRow(cells: [
                          for (final cell in row)
                            DataCell(ConstrainedBox(
                              constraints:
                                  const BoxConstraints(maxWidth: 224),
                              child: Text(cell,
                                  translate: false,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                            )),
                        ]),
                    ],
                  ),
                ),
              ),
            ),
            // 右缘渐隐：按视口定位、随横向滚动位置显隐（滚到头/无溢出
            // 时消失）——替代落底 Scrollbar thumb 成为正视区的提示。
            Positioned.fill(
              child: IgnorePointer(
                child: _TableRightFade(
                  hScroll: _hScroll,
                  fadeColor: context.colors.card,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 独立小组件：横向有剩余内容（extentAfter>0）时右缘渐隐。
/// 状态驱动=controller 监听 + 首帧 postFrame 校准 + 滚动维度通知
/// （AnimatedBuilder 会错过「position 挂载但维度未就绪」窗口的最后一次
/// 通知，纯 listenable 构建在首帧后不再刷新——实证：渐隐恒缺席）。
class _TableRightFade extends StatefulWidget {
  final ScrollController hScroll;
  final Color fadeColor;
  const _TableRightFade({required this.hScroll, required this.fadeColor});

  @override
  State<_TableRightFade> createState() => _TableRightFadeState();
}

class _TableRightFadeState extends State<_TableRightFade> {
  bool _overflow = false;

  @override
  void initState() {
    super.initState();
    widget.hScroll.addListener(_update);
    WidgetsBinding.instance.addPostFrameCallback((_) => _update());
  }

  @override
  void didUpdateWidget(covariant _TableRightFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hScroll != widget.hScroll) {
      oldWidget.hScroll.removeListener(_update);
      widget.hScroll.addListener(_update);
      _update();
    }
  }

  @override
  void dispose() {
    widget.hScroll.removeListener(_update);
    super.dispose();
  }

  void _update() {
    if (!widget.hScroll.hasClients) return;
    final pos = widget.hScroll.position;
    // 首帧 position 已挂客户端但内容维度未就绪（maxScrollExtent 内部
    // null 检查会炸）——hasContentDimensions 双守卫。
    if (!pos.hasContentDimensions) return;
    final overflow = pos.extentAfter > 0;
    if (overflow != _overflow && mounted) {
      setState(() => _overflow = overflow);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_overflow) return const SizedBox.shrink();
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        _update();
        return false;
      },
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          key: const ValueKey('dashboard-table-right-fade'),
          width: 20,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                widget.fadeColor.withValues(alpha: 0),
                widget.fadeColor,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChartView extends StatelessWidget {
  final DashboardSpec spec;
  final List<ArtifactDataItem> items;
  const _ChartView({required this.spec, required this.items});

  @override
  Widget build(BuildContext context) {
    // （高②）：只取「x 有值的条目」同步构建 x 与序列——
    // 旧实现 x 过滤 null 但序列按全量 items 建，任一条目缺 x 即整体
    // 错位。序列键=官方 y0..yN 序号（displayLabel 做键会在同标签时
    // 覆盖丢序列，apply.ts:178-190）。
    final pts = <({Object? x, List<double?> ys})>[];
    for (final it in items) {
      final x = readArtifactField(it.item, spec.x!.field);
      if (x == null) continue;
      pts.add((
        x: x,
        ys: [
          for (final y in spec.ys)
            switch (readArtifactField(it.item, y.field)) {
              num n => n.toDouble(),
              String s => double.tryParse(s),
              _ => null,
            },
        ],
      ));
    }
    // all-or-nothing 数值轴（官方 apply.ts:225-240）——任一 x 非
    // 有限数值则整轴退化为到达序号。
    final allNumeric = pts.every((p) => switch (p.x) {
          num n => n.isFinite,
          String s => (double.tryParse(s) ?? double.nan).isFinite &&
              double.tryParse(s) != null,
          _ => false,
        });
    final xNums = <double>[
      for (var i = 0; i < pts.length; i++)
        allNumeric
            ? switch (pts[i].x) {
                num n => n.toDouble(),
                String s => double.tryParse(s)!,
                _ => i.toDouble(),
              }
            : i.toDouble(),
    ];
    // 数值轴按 x 升序稳定排序（官方同款；乱序数据 dx 假设首尾
    // 即 min/max 会左右翻转）。
    if (allNumeric) {
      final order = List<int>.generate(xNums.length, (i) => i);
      order.sort((a, b) => xNums[a].compareTo(xNums[b]));
      final sortedPts = [for (final i in order) pts[i]];
      final sortedX = [for (final i in order) xNums[i]];
      for (var i = 0; i < pts.length; i++) {
        pts[i] = sortedPts[i];
        xNums[i] = sortedX[i];
      }
    }
    final seriesLabels = [
      for (var i = 0; i < spec.ys.length; i++) spec.ys[i].displayLabel,
    ];
    final palette = context.charts.series;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 180,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: context.colors.card,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(color: context.colors.borderFaint),
          ),
          child: CustomPaint(
            key: const ValueKey('dashboard-chart'),
            size: Size.infinite,
            painter: _DashboardChartPainter(
              xNums: xNums,
              // series 按点集重建（每条 y 一列）。
              series: [
                for (var yi = 0; yi < spec.ys.length; yi++)
                  [for (final p in pts) p.ys[yi]],
              ],
              colors: [
                for (var i = 0; i < spec.ys.length; i++)
                  palette[i % palette.length],
              ],
              chartType: allNumeric ? spec.chartType : 'bar',
              gridColor: context.colors.borderFaint,
              lineColor: context.colors.foregroundSubtlest,
              // 视觉补跑必修（Visual A）：官方
              // ArtifactChartView 有 XAxis/YAxis+悬浮 tooltip，手机无
              // hover——无刻度=真人只能读形状读不出任何数值。补=左缘
              // y 刻度（网格线对位）+首末 x 标签。
              unit: spec.ys
                  .map((y) => y.unit ?? '')
                  .firstWhere((u) => u.isNotEmpty, orElse: () => ''),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 12,
          children: [
            for (var i = 0; i < seriesLabels.length; i++)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: palette[i % palette.length],
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    seriesLabels[i],
                    translate: false,
                    style: TextStyle(
                        fontSize: AppType.uiXs,
                        color: context.colors.foregroundSubtle),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

/// 刻度标签（自上而下= maxY→minY 等分 4 档；顶格带单位）。
/// 独立纯函数供测试钉死（视觉补跑必修：无刻度=图表零信息量）。
@visibleForTesting
List<String> chartTickLabels(double minY, double maxY, String unit) {
  if (maxY == minY) maxY = minY + 1;
  return [
    for (var i = 0; i < 4; i++)
      '${fmtChartNum(minY + (maxY - minY) * (3 - i) / 3)}'
      '${i == 0 && unit.isNotEmpty ? unit : ''}',
  ];
}

/// 紧凑数值：千位以上 k 记法、非整数保留 1 位、其余取整。
@visibleForTesting
String fmtChartNum(double v) {
  final a = v.abs();
  if (a >= 1000) {
    final k = v / 1000;
    return '${k % 1 == 0 ? k.toInt() : double.parse(k.toStringAsFixed(1))}k';
  }
  if (v % 1 == 0) return '${v.toInt()}';
  return v.toStringAsFixed(1);
}

class _DashboardChartPainter extends CustomPainter {
  final List<double> xNums;
  final List<List<double?>> series;
  final List<Color> colors;
  final String chartType;
  final Color gridColor;
  final Color lineColor;

  /// y 刻度单位（spec.ys 首个非空 unit；只拼在顶格刻度上，避免每行重复）。
  final String unit;

  _DashboardChartPainter({
    required this.xNums,
    required this.series,
    required this.colors,
    required this.chartType,
    required this.gridColor,
    required this.lineColor,
    this.unit = '',
  });

  double _measureLabel(String text) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: 11, color: lineColor),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    return tp.width;
  }

  void _paintLabel(Canvas canvas, String text, double x, double y,
      {bool alignRight = false, double maxWidth = 0}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: 11, color: lineColor),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: maxWidth > 0 ? '…' : null,
    )..layout(maxWidth: maxWidth > 0 ? maxWidth : double.infinity);
    tp.paint(
        canvas, Offset(alignRight ? x - tp.width : x, y - tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (xNums.isEmpty || series.isEmpty) return;
    var maxY = 0.0;
    var minY = 0.0;
    for (final s in series) {
      for (final v in s) {
        if (v == null) continue;
        if (v > maxY) maxY = v;
        if (v < minY) minY = v;
      }
    }
    if (maxY == minY) maxY = minY + 1;
    final tickLabels = chartTickLabels(minY, maxY, unit);
    // 视觉补跑必修：左缘 y 刻度槽 + 底部 x 标签槽 14dp（原四边 8dp 无处
    // 落字）。A 复签观察①：槽宽按实测最宽标签自适应（30..56 封顶）——
    // 固定 30dp 在长数值/长单位下会向左溢出卡片；仍超宽按槽宽省略。
    final leftPad = (tickLabels
                .map(_measureLabel)
                .reduce((a, b) => a > b ? a : b) +
            6)
        .clamp(30.0, 56.0);
    const rightPad = 8.0;
    const topPad = 8.0;
    const bottomPad = 14.0;
    final w = size.width - leftPad - rightPad;
    final h = size.height - topPad - bottomPad;
    final minX = xNums.first;
    final maxX = xNums.last == minX ? minX + 1 : xNums.last;
    double dx(double x) => leftPad + (x - minX) / (maxX - minX) * w;
    double dy(double y) => topPad + h - (y - minY) / (maxY - minY) * h;

    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 0.5;
    for (var i = 0; i <= 3; i++) {
      final y = topPad + h * i / 3;
      canvas.drawLine(Offset(leftPad, y), Offset(leftPad + w, y), grid);
      _paintLabel(canvas, tickLabels[i], leftPad - 4, y,
          alignRight: true, maxWidth: leftPad - 2);
    }
    // 首末 x 标签（单点/两点间距过窄时只画首个，避免重叠）。
    _paintLabel(canvas, fmtChartNum(minX), leftPad, size.height - 5);
    if (xNums.length > 1 && maxX != minX) {
      _paintLabel(canvas, fmtChartNum(maxX), leftPad + w, size.height - 5,
          alignRight: true);
    }

    for (var si = 0; si < series.length; si++) {
      final s = series[si];
      final color = colors[si % colors.length];
      final stroke = Paint()
        ..color = color
        ..strokeWidth = 1.8
        ..style = PaintingStyle.stroke;
      final fill = Paint()
        ..color = color.withValues(alpha: 0.35)
        ..style = PaintingStyle.fill;
      if (chartType == 'bar') {
        final barW = (w / xNums.length).clamp(4.0, 24.0);
        for (var i = 0; i < s.length && i < xNums.length; i++) {
          final v = s[i];
          if (v == null) continue;
          final x = dx(xNums[i]);
          canvas.drawRect(
              Rect.fromLTRB(x - barW / 2, dy(v), x + barW / 2, topPad + h),
              fill);
        }
      } else {
        // null 缺测=断线（官方 connectNulls=false），分段绘制——
        // 每段独立成路径，段与段之间不桥接。
        for (final seg in splitChartLineSegments(s)) {
          if (chartType == 'scatter') {
            final dot = Paint()..color = color;
            for (final pt in seg) {
              if (pt.index >= xNums.length) continue;
              canvas.drawCircle(
                Offset(dx(xNums[pt.index]), dy(pt.value)),
                2.5,
                dot,
              );
            }
            continue;
          }
          final path = Path();
          for (var i = 0; i < seg.length; i++) {
            final pt = seg[i];
            if (pt.index >= xNums.length) continue;
            final p = Offset(dx(xNums[pt.index]), dy(pt.value));
            if (i == 0) {
              path.moveTo(p.dx, p.dy);
            } else {
              path.lineTo(p.dx, p.dy);
            }
          }
          canvas.drawPath(path, stroke);
        }
      }
    }
    if (minY < 0 && maxY > 0) {
      canvas.drawLine(Offset(leftPad, dy(0)), Offset(leftPad + w, dy(0)),
          Paint()
            ..color = lineColor
            ..strokeWidth = 0.8);
    }
  }

  @override
  bool shouldRepaint(covariant _DashboardChartPainter old) =>
      old.xNums != xNums || old.series != series || old.unit != unit;
}

class _BoardView extends StatelessWidget {
  final DashboardSpec spec;
  final List<ArtifactDataItem> items;
  const _BoardView({required this.spec, required this.items});

  @override
  Widget build(BuildContext context) {
    final boardKey = spec.boardKey!;
    final boardStatus = spec.boardStatus!;
    final cards =
        <String, ({String title, String status, List<String> detail})>{};
    final order = <String>[];
    for (final it in items) {
      final key = '${readArtifactField(it.item, boardKey) ?? ''}';
      if (key.isEmpty) continue;
      final status = '${readArtifactField(it.item, boardStatus) ?? ''}';
      final title = spec.cardTitle.isNotEmpty
          ? '${readArtifactField(it.item, spec.cardTitle) ?? key}'
          : key;
      final detail = [
        for (final d in spec.detail)
          '${d.displayLabel}: ${readArtifactField(it.item, d.field) ?? '—'}',
      ];
      if (!cards.containsKey(key)) order.add(key);
      cards[key] = (title: title, status: status, detail: detail);
    }
    // （·board 中三条，官方 apply.ts:358-375）：列=spec 列
    // 原序 + 未列入的 status 统一落末尾单一「其他」列（不再各造列）；
    // status 缺失/空的卡同样落「其他」不被丢弃。
    final specCols = [...spec.boardColumns];
    final knownStatuses = specCols.toSet();
    // 存在判据：status 为空 **或** 不在 spec 列 → 必须有「其他」列接住。
    // 旧实现只扫非空未知 status，status 缺失的卡无处可落直接消失。
    final needsOther = cards.values.any(
      (c) => c.status.isEmpty || !knownStatuses.contains(c.status),
    );
    final columns = [...specCols, if (needsOther) '其他'];
    return SizedBox(
      height: 240,
      child: ListView(
        key: const ValueKey('dashboard-board'),
        scrollDirection: Axis.horizontal,
        children: [
          for (final col in columns)
            Container(
              width: 200,
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: context.colors.card,
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(color: context.colors.borderFaint),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    col.isEmpty ? '其他' : col,
                    translate: false,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: AppType.uiXs,
                        fontWeight: FontWeight.w600,
                        color: context.colors.foregroundSubtle),
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: cards.isEmpty
                        ? const SizedBox.shrink()
                        : ListView(
                            children: [
                              for (final key in order)
                                if ((col == '其他' &&
                                        !specCols.contains(
                                            cards[key]!.status)) ||
                                    cards[key]!.status == col)
                                  Container(
                                    margin: const EdgeInsets.only(bottom: 6),
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: context.colors.background,
                                      borderRadius:
                                          BorderRadius.circular(AppRadius.sm),
                                      border: Border.all(
                                          color: context.colors.borderFaint),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          cards[key]!.title,
                                          translate: false,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontSize: AppType.uiXs,
                                              fontWeight: FontWeight.w500),
                                        ),
                                        for (final d in cards[key]!.detail)
                                          Text(
                                            d,
                                            translate: false,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                                fontSize: AppType.uiXs,
                                                color: context
                                                    .colors.foregroundSubtlest),
                                          ),
                                      ],
                                    ),
                                  ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

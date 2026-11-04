/// 用量页图表 painter 独立库（批次 1 A6 抽取，2026-10-19 外部审查）：
/// 从 usage_page 抽出以便单测直接构造 painter 断言 shouldRepaint。
///
/// A6 修复说明：三种图表的 shouldRepaint 原为长度比较（柱状）与引用
/// 比较（折线/环形）。长度比较在"数据刷新但天数不变"时漏重绘（图表
/// 停留旧数据，真 bug）；引用比较配合调用方每次新建 list 成了恒重绘
/// （浪费但正确）。统一改为值比较：数据等值不重绘，数据变化必重绘。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../core/l10n.dart';

/// 图表序列（值等值：name/color/values 逐项相等）。
class ChartSeries {
  final String name;
  final Color color;
  final List<double> values;
  const ChartSeries({
    required this.name,
    required this.color,
    required this.values,
  });

  @override
  bool operator ==(Object other) =>
      other is ChartSeries &&
      other.name == name &&
      other.color == color &&
      listEquals(other.values, values);

  @override
  int get hashCode => Object.hash(name, color, Object.hashAll(values));
}

/// 日期标签压缩：去年份（"2026-10-17"→"10-17"；小时粒度取 "MM-DD HH"）。
String shortChartDate(String s) {
  if (s.length >= 10 && s.startsWith(RegExp(r'\d{4}-'))) {
    final tail = s.substring(5);
    return tail.length > 11 ? tail.substring(0, 11) : tail;
  }
  return s.length > 11 ? s.substring(0, 11) : s;
}

/// "2026-10-18" → "10月18日"（M月d日、不补零；非日期原样返回）。
/// 供柱状图点选明细行用（快照 date 为纯日期串，无时区换算需求）。
String chartDayLabel(String date) {
  final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(date);
  if (m == null) return date;
  return '${int.parse(m.group(2)!)}月${int.parse(m.group(3)!)}日';
}

/// 柱状图点选命中换算（与 BarChartPainter 同款 slot=width/n 公式）：
/// dx → 柱下标，越界钳到首/末柱；n<=0 或宽<=0 → null。
int? barHitIndex(double dx, double width, int n) {
  if (n <= 0 || width <= 0) return null;
  final slot = width / n;
  return (dx / slot).floor().clamp(0, n - 1);
}

/// 柱状图单日明细：第一行日期+合计，第二行模型拆分；数字/日期随语言本地化。
String barDayDetailLine({
  required String date,
  required num total,
  required List<({String name, num tokens})> topModels,
  required String Function(num) formatter,
}) {
  final buf = StringBuffer(
    '${tr(chartDayLabel(date))} · ${tr('共')} ${tr(formatter(total))}',
  );
  if (topModels.isNotEmpty) {
    final sep = L10n.resolvedLocale == 'en-US' ? ', ' : '、';
    buf.write(
      '\n${topModels.map((m) => '${m.name} ${tr(formatter(m.tokens))}').join(sep)}',
    );
  }
  return buf.toString();
}

/// 柱状图取消选中时的明细行（区间合计口径）。
String barRangeTotalText(num total, String Function(num) formatter) =>
    '${tr('区间合计')} · ${tr('共')} ${tr(formatter(total))}';

// ── 2026-10-23 用户反馈批①：图表可点选（折线/饼图/热力图）─────────

/// 折线图点选命中换算（对抗审查 C2）：与 LineChartPainter 布点同式
/// （x = width * i / (n-1)，首末点贴边）——此前复用柱状 slot=width/n
/// 公式，中间点系统性半槽偏移。n<=1 时直接命中首点。
int? linePointHitIndex(double dx, double width, int n) {
  if (n <= 0 || width <= 0) return null;
  if (n == 1) return 0;
  final i = (dx / width * (n - 1)).round().clamp(0, n - 1);
  return i;
}

/// x 标签人话化："2026-10-18"→"10月18日"；小时粒度串（无日期前缀
/// 匹配）退 shortChartDate 截短。
/// N1 P3-10/N3 P3-4：日期+小时形态（today 档 'YYYY-MM-DD HH'）
/// 保留小时位——此前被 chartDayLabel 截成纯日期，24 个点全显同一天而
/// x 轴标签却有小时；官方 buildHourlyAxis 纯 'HH:00:00' 形态不匹配本
/// 分支、照走 shortChartDate。
String chartXLabel(String raw) {
  final hm = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2}) (\d{1,2})$').firstMatch(
    raw,
  );
  if (hm != null) {
    return '${tr(chartDayLabel('${hm.group(1)}-${hm.group(2)}-${hm.group(3)}'))} ${hm.group(4)}:00';
  }
  final l = tr(chartDayLabel(raw));
  return l == raw ? shortChartDate(raw) : l;
}

/// 折线图点选明细：第一行日期+合计，第二行模型拆分；数字/日期随语言本地化。
String linePointDetailLine({
  required String date,
  required int index,
  required List<ChartSeries> series,
  required String Function(num) formatter,
}) {
  var total = 0.0;
  final parts = <String>[];
  for (final s in series) {
    if (index >= s.values.length) continue;
    final v = s.values[index];
    total += v;
    if (v > 0) parts.add('${s.name} ${tr(formatter(v))}');
  }
  final buf = StringBuffer(
    '${tr(chartXLabel(date))} · ${tr('共')} ${tr(formatter(total))}',
  );
  if (parts.isNotEmpty) {
    buf.write('\n${parts.join(L10n.resolvedLocale == 'en-US' ? ', ' : '、')}');
  }
  return buf.toString();
}

/// 折线图区间合计（各序列全点求和）。
double lineRangeTotal(List<ChartSeries> series) => series.fold<double>(
  0,
  (sum, s) => sum + s.values.fold<double>(0, (a, v) => a + v),
);

/// 环形图描边宽（painter 与命中判定共用—— N3 P3-3）。
const double kDonutStroke = 18.0;

/// 环形图半径（ N3 P3-3：原 height/2-6 的外缘=height/2+3 超出
/// 画布半高 ~3px（选中片 +5.5px），Stack 默认裁掉外缘环带；改扣
/// stroke/2+3 让非选中外缘收进 3px、选中外缘恰好贴边）。
double donutRadius(Size size) => size.height / 2 - kDonutStroke / 2 - 3;

/// 环形图切片命中（2026-10-23 批①）：p 相对中心的角度落在某片弧段内
/// 且半径在环带（radius±stroke/2 外扩 8px 容差）内；中心空洞/环外→null。
/// 弧段铺排与 DonutPainter.paint 完全同款（-90° 起顺时针、按值比例）。
int? donutHitIndex(Offset p, Size size, List<ChartSeries> series) {
  // 尺寸守卫（18074 验收根因配套）：无界尺寸（滚动列 constraints.biggest
  // 高度 ∞）会让中心/半径无穷化、角度退化恒 0——所有点按都命中第一片。
  if (!size.isFinite || size.width <= 0 || size.height <= 0) return null;
  final total = series.fold<double>(
    0,
    (sum, s) => sum + (s.values.isNotEmpty ? s.values.first : 0),
  );
  if (total <= 0) return null;
  final c = Offset(size.width / 2, size.height / 2);
  final d = (p - c).distance;
  final radius = donutRadius(size);
  const stroke = kDonutStroke;
  if (d < radius - stroke / 2 - 8 || d > radius + stroke / 2 + 8) return null;
  var rel =
      (math.atan2(p.dy - c.dy, p.dx - c.dx) + math.pi / 2) % (2 * math.pi);
  if (rel < 0) rel += 2 * math.pi;
  var start = 0.0;
  for (var i = 0; i < series.length; i++) {
    final v = series[i].values.isNotEmpty ? series[i].values.first : 0;
    if (v <= 0) continue;
    final sweep = v / total * 2 * math.pi;
    if (rel >= start && rel < start + sweep) return i;
    start += sweep;
  }
  return null;
}

/// 热力图格子点选明细行：已退役（ N1 P3-2/N2-9：18074 结构化
/// 明细卡替代后全仓零调用，删除；此处不留桩——需要时查 git 历史）。

/// 模型饼图切片数据（官方范式 refs/ZCode/packages/ui/src/settings/
/// usage-stats/appUsageModelPieChartViewModel.ts:28-48：totalTokens>0
/// 过滤 → 降序 → 超过 6 片时前 5 + 合并"其他"；切片值=totalTokens 实际量，
/// 弧占比由 DonutPainter 按值比例计算——等价于官方"用过滤后总量重算占比"）。
class ModelPieData {
  final List<ChartSeries> slices;

  /// 过滤后模型 token 总量（占比重算基数）。
  final double totalTokens;
  const ModelPieData({required this.slices, required this.totalTokens});
}

const _maxPieSlices = 6;

/// 切片配色由调用方注入（palette 循环取用；合并片用 otherColor——
/// 建议中性灰，与任何模型色不撞色）。
ModelPieData buildModelPieSlices(
  List<Map<String, dynamic>> models, {
  required List<Color> palette,
  required Color otherColor,
}) {
  final positive = <({String name, double tokens})>[];
  for (final m in models) {
    final t = (m['totalTokens'] as num?)?.toDouble() ?? 0;
    if (t <= 0) continue;
    final id = '${m['modelId'] ?? ''}'.trim();
    positive.add((name: id.isEmpty ? '未知' : id, tokens: t));
  }
  positive.sort((a, b) => b.tokens.compareTo(a.tokens));
  final shouldMergeOther = positive.length > _maxPieSlices;
  final limit = shouldMergeOther ? _maxPieSlices - 1 : _maxPieSlices;
  final slices = <ChartSeries>[
    for (var i = 0; i < limit && i < positive.length; i++)
      ChartSeries(
        name: positive[i].name,
        color: palette[i % palette.length],
        values: [positive[i].tokens],
      ),
  ];
  var total = 0.0;
  for (final p in positive) {
    total += p.tokens;
  }
  if (shouldMergeOther) {
    var other = 0.0;
    for (var i = limit; i < positive.length; i++) {
      other += positive[i].tokens;
    }
    if (other > 0) {
      slices.add(ChartSeries(name: '其他', color: otherColor, values: [other]));
    }
  }
  return ModelPieData(slices: slices, totalTokens: total);
}

/// 折线图（多序列）：3 条横向网格线 + 序列折线 + 首末 x 标签。
class LineChartPainter extends CustomPainter {
  final List<ChartSeries> series;
  final List<String> xLabels;
  final String Function(num) valueFormatter;
  final TextStyle labelStyle;

  /// E22（2026-10-24 修复批搭车）：canvas 文字随系统字体缩放（华为大字
  /// 用户）；由 build 传 MediaQuery.textScalerOf。
  final TextScaler textScaler;

  /// 深色模式批1：画布颜色全部由 build 传参（painter 无 context）；
  /// 主题切换→build 重建 painter→shouldRepaint 比较颜色触发重绘。
  final Color gridColor;

  /// 点选高亮（批①）：竖向细线 + 各序列在该点的圆点标记；null=无点选。
  final int? selectedIndex;
  final Color? selectedColor;
  LineChartPainter({
    required this.series,
    required this.xLabels,
    required this.valueFormatter,
    required this.labelStyle,
    required this.textScaler,
    required this.gridColor,
    this.selectedIndex,
    this.selectedColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const labelSpaceH = 16.0;
    final chart = Rect.fromLTWH(0, 0, size.width, size.height - labelSpaceH);
    var maxV = 0.0;
    for (final s in series) {
      for (final v in s.values) {
        if (v > maxV) maxV = v;
      }
    }
    if (maxV <= 0) maxV = 1;
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 0.7;
    // 官方网格=仅横向虚线 3-3（recharts CartesianGrid vertical=false
    // strokeDasharray="3 3"，2026-10-26 对齐轮：实线→虚线）。
    for (var i = 0; i <= 3; i++) {
      final y = chart.top + chart.height * i / 3;
      _dashedHLine(canvas, chart.left, chart.right, y, grid);
    }
    final n = xLabels.length;
    for (final s in series) {
      if (s.values.isEmpty || n < 2) continue;
      final paint = Paint()
        ..color = s.color
        // 官方 strokeWidth=2（2026-10-26 对齐 1.8→2）。
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      // 官方 type="monotone"（recharts=d3 curveMonotoneX，Fritsch–
      // Carlson 单调三次插值——不过冲）。2026-10-26 对齐轮：直折线
      // →单调平滑曲线。
      final pts = <Offset>[
        for (var i = 0; i < s.values.length && i < n; i++)
          Offset(
            chart.left + chart.width * i / (n - 1),
            chart.bottom - chart.height * (s.values[i] / maxV),
          ),
      ];
      canvas.drawPath(_monotonePath(pts), paint);
    }
    // 批①：点选高亮——竖向细线 + 各序列圆点（填充序列色+描边选中色）。
    final sel = selectedIndex;
    if (sel != null && n >= 2 && sel < n) {
      final x = chart.left + chart.width * sel / (n - 1);
      final hairColor = selectedColor ?? gridColor;
      final hair = Paint()
        ..color = hairColor.withValues(alpha: 0.45)
        ..strokeWidth = 0.8;
      canvas.drawLine(Offset(x, chart.top), Offset(x, chart.bottom), hair);
      for (final s in series) {
        if (sel >= s.values.length) continue;
        final y = chart.bottom - chart.height * (s.values[sel] / maxV);
        // 官方 activeDot r=4（2026-10-26 对齐 3.2→4）。
        canvas.drawCircle(Offset(x, y), 4, Paint()..color = s.color);
        canvas.drawCircle(
          Offset(x, y),
          4,
          Paint()
            ..color = hairColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4,
        );
      }
    }
    _drawXLabels(canvas, chart, maxV);
  }

  /// 横向虚线（3-3 虚线段，px 单位——官方 recharts strokeDasharray 口径）。
  void _dashedHLine(Canvas canvas, double x0, double x1, double y, Paint p) {
    const dash = 3.0, gap = 3.0;
    var x = x0;
    while (x < x1) {
      canvas.drawLine(Offset(x, y), Offset((x + dash).clamp(x0, x1), y), p);
      x += dash + gap;
    }
  }

  /// d3 curveMonotoneX 同款（Fritsch–Carlson）：按点列造单调三次贝塞尔
  /// ——相邻区间斜率取 min/max 钳制，保证不过冲（官方 recharts
  /// type="monotone" 等价实现）。
  Path _monotonePath(List<Offset> pts) {
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    final n = pts.length;
    if (n == 1) return path;
    if (n == 2) {
      return path..lineTo(pts[1].dx, pts[1].dy);
    }
    // 标准两遍法（d3 curveMonotoneX / Fritsch–Carlson）：
    // ①区间斜率→②逐点切线（内部点同号取均值/异号取 0，端点单侧）→
    // ③成对钳制 |m|≤3|δ| 防过冲（一遍向前，互不覆盖）。
    final dx = List<double>.filled(n - 1, 0);
    final delta = List<double>.filled(n - 1, 0);
    for (var i = 0; i < n - 1; i++) {
      dx[i] = pts[i + 1].dx - pts[i].dx;
      delta[i] = (pts[i + 1].dy - pts[i].dy) / dx[i];
    }
    final m = List<double>.filled(n, 0.0);
    m[0] = delta[0];
    m[n - 1] = delta[n - 2];
    for (var i = 1; i < n - 1; i++) {
      m[i] = delta[i - 1] * delta[i] <= 0 ? 0 : (delta[i - 1] + delta[i]) / 2;
    }
    for (var i = 0; i < n - 1; i++) {
      if (delta[i] == 0) {
        m[i] = 0;
        m[i + 1] = 0;
        continue;
      }
      final a = m[i] / delta[i];
      final b = m[i + 1] / delta[i];
      final s = a * a + b * b;
      if (s > 9) {
        final t = 3 / math.sqrt(s);
        m[i] = t * a * delta[i];
        m[i + 1] = t * b * delta[i];
      }
    }
    for (var i = 0; i < n - 1; i++) {
      final h = dx[i];
      path.cubicTo(
        pts[i].dx + h / 3,
        pts[i].dy + m[i] * h / 3,
        pts[i + 1].dx - h / 3,
        pts[i + 1].dy - m[i + 1] * h / 3,
        pts[i + 1].dx,
        pts[i + 1].dy,
      );
    }
    return path;
  }

  void _drawXLabels(Canvas canvas, Rect chart, double maxV) {
    void label(String text, Offset anchor, bool leftAlign) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: labelStyle),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
      )..layout();
      final offset = leftAlign
          ? anchor
          : Offset(anchor.dx - tp.width, anchor.dy);
      tp.paint(canvas, offset);
    }

    if (xLabels.isEmpty) return;
    // 官方抽稀（shouldShowDailyChartAxisLabel，2026-10-26 对齐轮：原只画
    // 首尾）：total≤14 全显；>45 步长 7、否则 5；首/尾/整步位显示。
    bool show(int i) {
      final total = xLabels.length;
      if (total <= 14) return true;
      final step = total > 45 ? 7 : 5;
      return i == 0 || i == total - 1 || i % step == 0;
    }

    for (var i = 0; i < xLabels.length; i++) {
      if (!show(i)) continue;
      final x = chart.left + chart.width * i / (xLabels.length - 1);
      final t = shortChartDate(xLabels[i]);
      // 居中画（首尾向内收半宽防出界——首尾外贴边沿用旧锚定）。
      if (i == 0) {
        label(t, Offset(chart.left, chart.bottom + 3), true);
      } else if (i == xLabels.length - 1) {
        label(t, Offset(chart.right, chart.bottom + 3), false);
      } else {
        final tp = TextPainter(
          text: TextSpan(text: t, style: labelStyle),
          textDirection: TextDirection.ltr,
          textScaler: textScaler,
        )..layout();
        tp.paint(canvas, Offset(x - tp.width / 2, chart.bottom + 3));
      }
    }
    // 峰值标注在左上。
    label(
      tr(valueFormatter(maxV)),
      Offset(chart.left + 2, chart.top - 1),
      true,
    );
  }

  @override
  bool shouldRepaint(covariant LineChartPainter old) =>
      !listEquals(old.series, series) ||
      !listEquals(old.xLabels, xLabels) ||
      old.gridColor != gridColor ||
      // 波2 路A2 A-1：labelStyle 颜色随主题（foregroundSubtlest），
      // 漏比则深浅切换 x 轴标签/峰值标注残留旧色。与 Bar 完全同口径。
      old.labelStyle != labelStyle ||
      old.textScaler != textScaler ||
      old.selectedIndex != selectedIndex ||
      old.selectedColor != selectedColor;
}

/// 柱状图：每日 Token 总量。barColor 由调用方传（用量页配色同源）。
/// 点选高亮（selectedIndex 非 null）：选中柱用 selectedColor 强调，
/// 其余柱降透明；null=无点选（全部正常色）。
class BarChartPainter extends CustomPainter {
  final List<double> values;
  final List<String> xLabels;
  final String Function(num) valueFormatter;
  final TextStyle labelStyle;
  final Color barColor;
  final int? selectedIndex;
  final Color selectedColor;

  /// E22（2026-10-24 修复批搭车）：canvas 文字随系统字体缩放（与 Line 同）。
  final TextScaler textScaler;

  /// 深色模式批1：画布颜色全部由 build 传参（painter 无 context）。
  final Color gridColor;
  BarChartPainter({
    required this.values,
    required this.xLabels,
    required this.valueFormatter,
    required this.labelStyle,
    required this.barColor,
    this.selectedIndex,
    required this.selectedColor,
    required this.gridColor,
    required this.textScaler,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const labelSpaceH = 16.0;
    final chart = Rect.fromLTWH(0, 0, size.width, size.height - labelSpaceH);
    var maxV = 0.0;
    for (final v in values) {
      if (v > maxV) maxV = v;
    }
    if (maxV <= 0) maxV = 1;
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 0.7;
    for (var i = 0; i <= 2; i++) {
      final y = chart.top + chart.height * i / 2;
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), grid);
    }
    final n = values.length;
    if (n > 0) {
      final slot = chart.width / n;
      final barW = slot * 0.62;
      for (var i = 0; i < n; i++) {
        if (values[i] <= 0) continue;
        final h = chart.height * (values[i] / maxV);
        final r = Rect.fromLTWH(
          chart.left + slot * i + (slot - barW) / 2,
          chart.bottom - h,
          barW,
          h,
        );
        final paint = Paint()
          ..color = selectedIndex == null
              ? barColor
              : i == selectedIndex
              ? selectedColor
              : barColor.withValues(alpha: 0.3);
        canvas.drawRRect(
          RRect.fromRectAndRadius(r, const Radius.circular(1.5)),
          paint,
        );
      }
    }
    void label(String text, Offset anchor, bool leftAlign) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: labelStyle),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
      )..layout();
      final offset = leftAlign
          ? anchor
          : Offset(anchor.dx - tp.width, anchor.dy);
      tp.paint(canvas, offset);
    }

    if (xLabels.isNotEmpty) {
      label(
        shortChartDate(xLabels.first),
        Offset(chart.left, chart.bottom + 3),
        true,
      );
    }
    if (xLabels.length > 1) {
      label(
        shortChartDate(xLabels.last),
        Offset(chart.right, chart.bottom + 3),
        false,
      );
    }
    label(
      tr(valueFormatter(maxV)),
      Offset(chart.left + 2, chart.top - 1),
      true,
    );
  }

  @override
  bool shouldRepaint(covariant BarChartPainter old) =>
      !listEquals(old.values, values) ||
      !listEquals(old.xLabels, xLabels) ||
      old.selectedIndex != selectedIndex ||
      // 对抗审查路A A-1（2026-10-23）：漏比较颜色参数——主题深浅切换时
      // values/选中态不变则不重绘，浅色侧残留深色柱/网格。与 Line 同口径。
      old.barColor != barColor ||
      old.selectedColor != selectedColor ||
      old.gridColor != gridColor ||
      old.labelStyle != labelStyle ||
      old.textScaler != textScaler;
}

/// 环形图：模型 share 分布。
/// 点选高亮（批①）：选中片加粗，其余片降透明；null=全部正常。
class DonutPainter extends CustomPainter {
  final List<ChartSeries> series;
  final int? selectedIndex;
  DonutPainter({required this.series, this.selectedIndex});

  @override
  void paint(Canvas canvas, Size size) {
    final total = series.fold<double>(
      0,
      (sum, s) => sum + (s.values.isNotEmpty ? s.values.first : 0),
    );
    if (total <= 0) return;
    final c = Offset(size.width / 2, size.height / 2);
    final radius = size.height / 2 - 6;
    final stroke = 18.0;
    final rect = Rect.fromCircle(center: c, radius: radius);
    var start = -math.pi / 2;
    for (var i = 0; i < series.length; i++) {
      final s = series[i];
      final v = s.values.isNotEmpty ? s.values.first : 0;
      if (v <= 0) continue;
      final sweep = v / total * 2 * math.pi;
      final selected = selectedIndex != null && i == selectedIndex;
      final paint = Paint()
        ..color = selectedIndex == null || selected
            ? s.color
            : s.color.withValues(alpha: 0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? stroke + 5 : stroke
        ..strokeCap = StrokeCap.butt;
      canvas.drawArc(rect, start, sweep, false, paint);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant DonutPainter old) =>
      !listEquals(old.series, series) || old.selectedIndex != selectedIndex;
}

/// 按模型趋势序列构建（2026-10-26 拍板④B，官方 AppUsageDailyModelTrend
/// Chart.tsx:134 对位）：Top6 模型（按总量降序）多序列日折线，色板循环
/// （官方 6 色循环；我方 charts.series 5 色循环同义）。纯函数供单测。
({
  List<ChartSeries> series,
  List<String> dates,
  List<({String label, Color color, num total})> legend,
})
buildModelTrendSeries({
  required List<Map<String, dynamic>> models,
  required List<Map<String, dynamic>> dailyModelUsage,
  required List<Color> palette,
}) {
  final withTotals = <({String id, num total})>[];
  for (final m in models) {
    final t = (m['totalTokens'] as num?) ?? 0;
    if (t > 0) withTotals.add((id: '${m['modelId'] ?? '未知'}', total: t));
  }
  withTotals.sort((a, b) => b.total.compareTo(a.total));
  final top = withTotals.take(6).toList();
  if (top.isEmpty) return (series: const [], dates: const [], legend: const []);

  final dates = <String>[];
  final byDate = <String, Map<String, num>>{};
  for (final d in dailyModelUsage) {
    final date = '${d['date'] ?? ''}';
    if (date.isEmpty) continue;
    dates.add(date);
    final perModel = byDate.putIfAbsent(date, () => {});
    for (final m in (d['models'] as List?) ?? const []) {
      if (m is! Map) continue;
      final id = '${m['modelId'] ?? '未知'}';
      perModel[id] = (perModel[id] ?? 0) + ((m['totalTokens'] as num?) ?? 0);
    }
  }

  final series = <ChartSeries>[];
  final legend = <({String label, Color color, num total})>[];
  for (var i = 0; i < top.length; i++) {
    final m = top[i];
    final color = palette[i % palette.length];
    series.add(
      ChartSeries(
        name: m.id,
        color: color,
        values: [for (final d in dates) (byDate[d]?[m.id] ?? 0).toDouble()],
      ),
    );
    legend.add((label: m.id, color: color, total: m.total));
  }
  return (series: series, dates: dates, legend: legend);
}

/// 动效组件库（V3 动效包，2026-10-22 审美优化轮）。
///
/// 原则（写入 ui-references）：**动画只给「状态变化」和「等待反馈」
/// 两类场景，不给装饰**——与项目性能红线文化一致。全部组件尊重系统
/// 「移除动画」设置（MediaQuery.disableAnimations），关闭时退化为
/// 静态呈现。
///
/// 官方对位：refs/ZCode packages/ui/src/styles.css
/// - wf-lamp-running / wf-beat（:1660/:2130）：运行灯 1.6s 心跳
/// - animated-gradient-text（:856）：运行中文字扫光，4s 循环
library;

import 'package:flutter/material.dart' hide Text;
import '../core/localized_text.dart';

import '../core/theme.dart';

/// 运行态脉冲状态点（动效包#1）——官方 wf-lamp-running 参数复刻：
/// 1.6s 循环、12% 处鼓到 1.12 倍、常亮 3px 光晕（20% alpha）、扩散环
/// 从光晕边缘涨到灯外 8px 淡尽；系统关动画时只留静态光晕。
/// 仅用于「运行中」实例（性能红线：列表中非运行行零动画开销）。
///
/// 质感修订二轮（2026-10-22，调研 ui-animations 技能库 + M3 Expressive
/// 弹簧体系后落地）：①心跳上冲=easeOutBack 微过冲回落（弹簧感——
/// 有机「鼓一下」，非关键帧插值的机械升除）②下落=easeOutCubic 快收
/// ③扩散环改双层（内亮外淡）模拟柔边光晕、透明度二次曲线淡出
/// （线性淡出=突然消失感）④只动 transform/装饰层，GPU 合成友好。
class RunningPulseDot extends StatefulWidget {
  final Color color;
  final double size;

  const RunningPulseDot({super.key, required this.color, this.size = 8});

  @override
  State<RunningPulseDot> createState() => _RunningPulseDotState();
}

class _RunningPulseDotState extends State<RunningPulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced) {
      return Icon(Icons.sync, size: widget.size, color: widget.color);
    }
    // 细旋转图标（官方 loader 语义），取代扩散光晕/双层圆环——
    // 状态靠形状与颜色，不靠 glow 抢占注意力。
    return RotationTransition(
      turns: _c,
      child: Icon(Icons.sync, size: widget.size, color: widget.color),
    );
  }
}

/// 运行中文字扫光（动效包#6）——官方 .animated-gradient-text 复刻：
/// 渐变域=3 倍文本宽（background-size:300%）、暗带（前景色 22% alpha，
/// 两肩 34%/66%）软波扫过、前 2s 扫掠后 2s 静止、4s 无限循环；系统关
/// 动画时静态前景色。
/// 用于运行中工具的名称行与「正在思考」标题（官方同款语义：转圈
/// loader 长期占用渲染资源，运行态保留文案扫光）。
///
/// 质感修订（2026-10-22 真机反馈⑦"不明显"）：渐变域从 1 倍文本宽改为
/// 官方 3 倍——暗带宽度≈整窗，视觉是整段文字的软暗波次第掠过（原窄带
/// 只是局部闪烁，几乎不可见）。
class ShimmerText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final int? maxLines;

  /// 最小行数（2026-10-23 用户反馈：思考条流式摘要内容时长时短，
  /// 1↔2 行切换导致下方内容上蹿下跳）。Text 无 minLines 参数（那是
  /// TextField 的）——实现为定高占位：按「字号×显式行高×行数」计算
  /// 高度包 SizedBox（文字缩放感知），短句顶对齐第二行留空。
  final int? minLines;

  const ShimmerText({
    super.key,
    required this.text,
    required this.style,
    this.maxLines,
    this.minLines,
  });

  @override
  State<ShimmerText> createState() => _ShimmerTextState();
}

class _ShimmerTextState extends State<ShimmerText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final fg = widget.style.color ?? context.colors.foreground;
    if (reduced) {
      return _fixedLines(
        Text(
          widget.text,
          style: _fixedLinesStyle(),
          maxLines: widget.maxLines,
          overflow: widget.maxLines != null ? TextOverflow.ellipsis : null,
        ),
      );
    }
    return _fixedLines(
      AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
        // 扫掠相位 easeInOut（光加速掠过、临边减速——匀速相位=传送带
        // 感，调研结论）；暗带不对称两肩（.36/.60）：渐入慢、恢复快，
        // 视觉=带拖尾的光从文字上扫过。
        final t = _c.value;
        final s = Curves.easeInOut.transform((t / 0.5).clamp(0.0, 1.0));
        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) {
            final w = bounds.width;
            // 渐变域 [left, left+3w]；left 从 +w（窗口全 strong，带在
            // 窗左外）扫到 -3w（带出窗右外）。中点 left=-w 时窗口正对
            // 暗带中心（50% stop）。
            final left = w - s * 4 * w;
            return LinearGradient(
              colors: [
                fg,
                fg,
                fg.withValues(alpha: 0.22),
                fg,
                fg,
              ],
              stops: const [0, 0.36, 0.5, 0.60, 1],
            ).createShader(
              Rect.fromLTWH(left, 0, 3 * w, bounds.height),
            );
          },
          child: child,
        );
      },
        child: Text(
          widget.text,
          style: _fixedLinesStyle(),
          maxLines: widget.maxLines,
          overflow: widget.maxLines != null ? TextOverflow.ellipsis : null,
        ),
      ),
    );
  }

  /// 定高实现用：行高显式化（minLines 生效时才注入，默认 1.45——
  /// 未显式设置时的字体默认行高不定，定高计算必须与实际渲染一致）。
  TextStyle _fixedLinesStyle() => widget.minLines == null
      ? widget.style
      : widget.style.copyWith(height: widget.style.height ?? 1.45);

  /// minLines 定高占位：高度=文字缩放后(字号×行高×行数)，子内容顶对齐。
  Widget _fixedLines(Widget child) {
    final min = widget.minLines;
    if (min == null) return child;
    final size =
        widget.style.fontSize ?? DefaultTextStyle.of(context).style.fontSize ?? 14;
    final lineHeight = widget.style.height ?? 1.45;
    // 公式修正（对抗审查 B1）：Flutter 实际行高 = scale(字号)×行高
    // （先缩放字号再乘行高）；Android 14+ 非线性 FontScaler 下
    // scale(字号×行高) 会算矮 → 第二行底部被裁。
    final scaled = MediaQuery.textScalerOf(context).scale(size) * lineHeight;
    return SizedBox(
      height: scaled * min,
      // 垂直居中（2026-10-24 用户验收：完成态单行文字贴上沿不居中）——
      // 占位高度恒定、内容不足时居中；与 FixedLinesText 同步（两态
      // 一致防流式→完成切换跳动）。
      child: Align(alignment: Alignment.centerLeft, child: child),
    );
  }
}

/// 定高文本占位（对抗审查 A1 2026-10-24：思考条流式→完成边沿从
/// minLines 两行塌到单行=完成瞬间一次跳变；完成态沿用同款定高公式
/// 保持高度恒定）。与 ShimmerText._fixedLines 同公式：字号×行高
/// （默认 1.45）×行数，文字缩放感知，内容顶对齐。
class FixedLinesText extends StatelessWidget {
  final String text;
  final int lines;
  final TextStyle style;
  final int? maxLines;
  const FixedLinesText({
    super.key,
    required this.text,
    required this.lines,
    required this.style,
    this.maxLines,
  });

  @override
  Widget build(BuildContext context) {
    final size =
        style.fontSize ?? DefaultTextStyle.of(context).style.fontSize ?? 14;
    final lineHeight = style.height ?? 1.45;
    // 与 ShimmerText._fixedLines 同公式（含非线性 FontScaler 修正）：
    // 高度 = scale(字号) × 行高 × 行数。
    final scaled = MediaQuery.textScalerOf(context).scale(size) * lineHeight;
    return SizedBox(
      height: scaled * lines,
      // 垂直居中（用户验收 2026-10-24：完成态单行文字在两行定高内
      // 贴第一行不居中）——与 ShimmerText._fixedLines 同款。
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          text,
          style: style.copyWith(height: lineHeight),
          maxLines: maxLines,
          overflow: maxLines != null ? TextOverflow.ellipsis : null,
        ),
      ),
    );
  }
}

/// 新内容进入动效（动效包#2）：200ms 淡入+8px 上移，一次性播放。
/// 配合页面级「已见行」集合使用——只给新出现的行，滚动回看的旧行
/// 直接渲染（避免快速滚动时整屏闪烁）。
class EntryFadeSlide extends StatelessWidget {
  final Widget child;

  const EntryFadeSlide({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 1, end: 0),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      builder: (context, v, child) => Opacity(
        opacity: 1 - v,
        child: Transform.translate(
          offset: Offset(0, v * 8),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// 按压缩放反馈（动效包#3）：按下缩至 0.92、松开弹回（150ms）。
/// Listener 指针事件实现，不吞点击手势（发送键等高频按钮用）。
class PressScale extends StatefulWidget {
  final Widget child;

  const PressScale({super.key, required this.child});

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;
    return Listener(
      onPointerDown: (_) => setState(() => _down = true),
      onPointerUp: (_) => setState(() => _down = false),
      onPointerCancel: (_) => setState(() => _down = false),
      child: AnimatedScale(
        scale: _down ? 0.92 : 1.0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// 从指定方向滑入（动效包#4：审批横幅从输入栏方向=底部滑入 250ms）。
/// 一次性播放（TweenAnimationBuilder）。
class SlideIn extends StatelessWidget {
  final Widget child;
  final Offset from;

  const SlideIn({super.key, required this.child, this.from = const Offset(0, 0.15)});

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 1, end: 0),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      builder: (context, v, child) => Opacity(
        opacity: 1 - v,
        child: FractionalTranslation(
          translation: from * v,
          child: child,
        ),
      ),
      child: child,
    );
  }
}

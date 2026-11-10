import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';

import '../core/localized_text.dart';
import '../core/l10n.dart';
import '../core/theme.dart';
import '../state/send_queue_store.dart';
import 'brand_logo.dart';
import 'motion.dart';

class ReadOnlyBar extends StatelessWidget {
  const ReadOnlyBar();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: context.colors.card,
        borderRadius: BorderRadius.circular(AppRadius.glassChrome),
        border: Border.all(color: context.colors.border),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.lock_outline,
            size: 15,
            color: context.colors.foregroundSubtlest,
          ),
          const SizedBox(width: 6),
          Text(
            '子智能体工作记录 · 只读',
            style: TextStyle(
              fontSize: AppType.uiCaption,
              color: context.colors.foregroundSubtle,
            ),
          ),
        ],
      ),
    );
  }
}

/// 上下文占用进度环（2026-10-26 对齐桌面 context.tsx ContextIcon）：
/// viewBox24/r10/stroke4 等比——底环同色 25% 透明度+进度弧 70% 圆头、
/// 顶部起顺时针；颜色沿用连接状态语义（在线绿/重连琥珀/异常红——
/// 手机端把桌面的「灰底+机会绿」融合为状态色）。

class ContextUsageRing extends StatelessWidget {
  final Color color;
  final double progress;

  const ContextUsageRing({required this.color, required this.progress});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      key: const ValueKey('context-usage-ring'),
      size: const Size.square(14),
      painter: ContextUsageRingPainter(color: color, progress: progress),
    );
  }
}

class ContextUsageRingPainter extends CustomPainter {
  final Color color;
  final double progress;

  ContextUsageRingPainter({required this.color, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    // 桌面比例：r=10/24、stroke=4/24 → 按 14px 视径等比。
    final stroke = size.width * 4 / 24;
    final radius = (size.width - stroke) / 2;
    final center = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: center, radius: radius);
    final p = progress.clamp(0.0, 1.0);

    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = color.withValues(alpha: 0.25);
    canvas.drawCircle(center, radius, base);

    if (p > 0) {
      final arc = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: 0.7);
      canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * p, false, arc);
    }
  }

  @override
  bool shouldRepaint(ContextUsageRingPainter old) =>
      old.color != color || old.progress != progress;
}


class InputBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool running;

  /// 本地发送在途（A3）：发送键转圈+禁用——原实现可点但静默无反应。
  final bool sending;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final String selectionMain;

  /// 次级文字（档位；Paseo 参考两级分层）。null/空=不显示。
  final String? selectionSub;

  /// 当前模型品牌 logo 资产（null=回退纯文字）。
  final String? selectionBrand;
  final bool selectionPending;
  final VoidCallback? onSelectionTap;

  /// V2 审美优化：上下文用量仪表（进度条并入输入卡顶部内边，评审
  final VoidCallback? onAdd;

  /// 待发送附件 chips 行（阶段 3 第三段；空附件传 null 不占位）。
  final Widget? attachmentsBar;

  /// 语音输入入口（null=不可用）：发送键**长按**触发（2026-10-22 用户
  /// 拍板：语音键收起腾位给状态点——独立语音键退役）。
  final VoidCallback? onVoice;

  /// 连接状态点（输入栏常亮；V2 曾收进「+」面板导致常亮信号丢失，
  /// 2026-10-22 用户发现后拍板回输入栏原位——点按=用量详情卡开关）。
  final Color? statusColor;

  /// 上下文窗口占用（0..1，null=无数据）——状态圈升级为进度环
  /// （2026-10-26 对齐桌面 context.tsx：圈=上下文用量进度，颜色=连接态）。
  final double? statusProgress;
  final VoidCallback? onStatusTap;

  const InputBar({
    required this.controller,
    required this.focusNode,
    required this.running,
    required this.sending,
    required this.onSend,
    required this.onStop,
    this.selectionMain = '',
    this.selectionSub,
    this.selectionBrand,
    this.selectionPending = false,
    this.onSelectionTap,
    this.onAdd,
    this.attachmentsBar,
    this.onVoice,
    this.statusColor,
    this.statusProgress,
    this.onStatusTap,
  });

  @override
  Widget build(BuildContext context) {
    // 验收③（真机折叠态复发）：有效宽度（除以字体缩放）不足时进入紧凑
    // 态——状态点/语音键收窄，把空间让给合并药丸（两药合一后药丸区
    // 已净省一枚，标签「模型 · 档」仍留足宽度）。
    // 批3 观感审查 A（2026-10-23）：输入区底色深色下从 header 改
    // background——深色阴影不可见（黑35/50% 叠深底<1.2:1），输入卡
    // (#2B2B2B) 坐 header(#202020) 上台阶仅 1.15:1，浮起感塌陷只剩描边；
    // 坐 background(#161616) 得 1.28:1 与任务卡同款台阶。浅色不动
    // （header 白+阴影活，浮起感完整）。
    return ColoredBox(
      color: Theme.of(context).brightness == Brightness.dark
          ? context.colors.background
          : context.colors.header,
      child: SafeArea(
        top: false,
        child: Padding(
          // 视觉轮（2026-10-17 真机+视觉评审）：白卡浮层质感——纯白底+
          // 大圆角+柔和投影（对齐官方桌面浮层语言），外边距留呼吸感。
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
          child: Container(
            decoration: BoxDecoration(
              // Paseo 参考（2026-10-23 用户拍板）：输入卡底深色降一档
              // （专用 token 不连坐 popover/menu/toast）。
              // Paseo 观感二轮（2026-10-23 用户）：圆角 20→16（Paseo
              // borderRadius.2xl=16，refs/paseo theme.ts:616）、阴影降
              // xs 档（轻浮起，Paseo shadow.sm 同量级）。
              color: context.colors.inputSurface,
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: context.colors.border),
              boxShadow: context.shadows.xs,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (attachmentsBar != null)
                  Padding(
                    // Paseo 观感二轮：内边距收进（框内 12 档节奏）。
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                    child: attachmentsBar,
                  ),
                TextField(
                  key: const ValueKey('chat-input'),
                  controller: controller,
                  focusNode: focusNode,
                  // 桌面同款：运行中不锁输入（消息进队列/由服务端按 queue 语义
                  // 处理）——运行中禁用曾把"phase 卡在 running"放大成"窗口
                  // 卡死无法发送"（真机 2026-10-15 反馈）
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.newline,
                  style: const TextStyle(fontSize: AppType.mobileInputSafe),
                  decoration: InputDecoration(
                    hintText: running
                        ? tr('运行中，发送将排队…')
                        : sending
                        ? tr('发送中…')
                        : tr('发送消息'),
                    // Paseo 占位符用最浅 surface4 档——对齐降一档更轻。
                    hintStyle: TextStyle(
                      color: context.colors.foregroundSubtlest,
                    ),
                    isCollapsed: true,
                    // Paseo 观感二轮：内边距对齐 Paseo 手机档
                    // （paddingH 12、上下 8 节奏，input.tsx:2211-2223），
                    // 文本→工具行靠留白衔接（下 8+上 2≈Paseo gap 12）。
                    contentPadding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                    border: InputBorder.none,
                  ),
                ),
                // Paseo 观感二轮（2026-10-23 用户拍板）：删输入框与
                // 工具行之间的分隔线——Paseo 无任何 Divider/border-t，
                // 分隔全靠留白（input.tsx:2206 gap 12）。行高随控件
                // 收小再收一档。
                Padding(
                  // B5（2026-11-07 用户折中）：右内距 6→8——复核实测发送键
                  // 几乎贴边框（左 17/右 6 不对称）；不动左端（＋按钮独占）。
                  padding: const EdgeInsets.fromLTRB(6, 2, 8, 4),
                  child: Row(
                    children: [
                      // ③（2026-10-19 真机反馈）：工具栏过挤——加号/
                      // 绿点/语音收窄一档，把宽度让给选型药丸（看全
                      // 「模型 · 档」标签优先）。
                      // Paseo 观感二轮：控件收小一档 40→36、图标 22→20
                      // （Paseo 28 控件+20 图标；36 为 Android 手感折中，
                      // 用户拍板「UI 大小参考 Paseo 更精致」）。
                      SizedBox(
                        width: 36,
                        height: 36,
                        child: IconButton(
                          key: const ValueKey('add-trigger'),
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                          onPressed: onAdd,
                          icon: Icon(
                            Icons.add,
                            size: 20,
                            color: context.colors.foreground,
                          ),
                          tooltip: tr('添加（上下文/能力/技能）'),
                        ),
                      ),
                      // 2026-10-23 用户反馈三轮：绿圈+模型药丸+发送键
                      // 整组靠右贴齐（「＋」独占左端）。弹性空白全部落在
                      // ＋与右组之间——Spacer+Flexible 各分一半会把绿圈
                      // 甩到行中央（目检实锤），右组包成一个 min Row。
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // 批4 反馈③（2026-10-23 用户，对齐桌面输入
                              // 栏截图）：状态圈在模型药丸左侧（顺序=状态
                              // 圈→模型→发送），实心点改空心圈（视觉更轻，
                              // 桌面同款形态）。2026-10-22 用户拍板：语音
                              // 键退役（发送键长按说话），腾位放回连接状态
                              // 点；点按=用量详情卡。
                              if (statusColor != null)
                                SizedBox(
                                  width: 36,
                                  height: 36,
                                  child: IconButton(
                                    key: const ValueKey('status-dot'),
                                    padding: EdgeInsets.zero,
                                    iconSize: 13,
                                    tooltip: statusProgress == null
                                        ? tr('连接状态 · 点按看用量')
                                        : '${tr('连接状态 · 上下文 ')}'
                                              '${(statusProgress! * 100).round()}%'
                                              '${tr(' · 点按看用量')}',
                                    icon: ContextUsageRing(
                                      color: statusColor!,
                                      progress: statusProgress ?? 0,
                                    ),
                                    onPressed: onStatusTap,
                                  ),
                                ),
                              Flexible(
                                child: ToolbarPill(
                                  key: const ValueKey('model-switch'),
                                  label: selectionMain,
                                  subLabel: selectionSub,
                                  brandAsset: selectionBrand,
                                  chevron: true,
                                  pending: selectionPending,
                                  // Paseo 观感二轮（模型药丸不强求，
                                  // 2026-10-23 用户）：常驻大药丸→Paseo 式
                                  // 透明小触发器（model-sheet.tsx:264-293
                                  // 透明底 28 高）——logo 保留（上批拍板
                                  // 成果），两级文字保持「名亮档暗」。
                                  plain: true,
                                  minHeight: 28,
                                  onTap: onSelectionTap,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      // 桌面对齐（F7 真机反馈）：发送键常驻（运行中点击=排队，
                      // hint 才不是空头支票）。V2 单键切换（评审 2.2#4）：
                      // 运行中且无草稿→主键变红实心停止键（消除红灰并排）；
                      // 有草稿→仍为发送键（保留「发送即排队」语义）+小描边
                      // 停止键。视觉轮：黑色圆锚点（官方 bg-brand），42px 触达。
                      ListenableBuilder(
                        listenable: controller,
                        builder: (context, _) =>
                            running && controller.text.trim().isEmpty
                            ? SizedBox(
                                // Paseo 观感二轮：发送/停止 42→36、
                                // 图标 22→18（控件小一圈=精致感主来源）。
                                width: 36,
                                height: 36,
                                child: IconButton.filled(
                                  key: const ValueKey('stop-button'),
                                  // 批4 反馈①（2026-10-23 用户）：深色下
                                  // 红底黑标扎眼——改黑底白标+白 15% 描边
                                  // （与主按钮黑白反转同族的中性停止）；
                                  // 浅色保持官方系红底白标不动。
                                  style: IconButton.styleFrom(
                                    backgroundColor:
                                        Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? context.colors.background
                                        : context.colors.destructive,
                                    foregroundColor:
                                        Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? context.colors.brand
                                        : context.colors.onBrand,
                                    side:
                                        Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? BorderSide(
                                            color: context.colors.borderHover,
                                          )
                                        : null,
                                    shape: const CircleBorder(),
                                  ),
                                  onPressed: onStop,
                                  icon: const Icon(Icons.stop, size: 18),
                                ),
                              )
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (running) ...[
                                    SizedBox(
                                      // A7③（2026-10-24 修复批）：描边停止
                                      // 键统一 36×36 对齐发送键（修复前默认
                                      // 盒约 40，与右邻 36 并排错拍）。
                                      width: 36,
                                      height: 36,
                                      child: IconButton.outlined(
                                        key: const ValueKey('stop-button'),
                                        visualDensity: VisualDensity.compact,
                                        padding: EdgeInsets.zero,
                                        style: IconButton.styleFrom(
                                          foregroundColor:
                                              context.colors.destructive,
                                          side: BorderSide(
                                            color: context.colors.destructive
                                                .withValues(alpha: 0.55),
                                          ),
                                        ),
                                        onPressed: onStop,
                                        icon: const Icon(Icons.stop, size: 18),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                  ],
                                  SizedBox(
                                    width: 36,
                                    height: 36,
                                    // V3 动效包#3：按下 0.92 缩放回弹。
                                    child: PressScale(
                                      // 2026-10-22 用户拍板：长按发送键=
                                      // 语音输入（语音键退役腾位状态点）。
                                      // 长按不与点按冲突（无 onTap 竞技），
                                      // 触觉反馈提示已触发。
                                      child: GestureDetector(
                                        // D1-P1/D2-P2/D3-P1-1
                                        //（语音直发静默丢弃）：发送在途
                                        //（_sending=RPC/附件上传/held 等待
                                        // 可达分钟级）时长按拉起语音面板，
                                        // 听写后 onSend 撞 _sendText 的
                                        // _sending 早退=文本无痕丢失（不入
                                        // 草稿/队列/暂存）。长按与点按同闸
                                        //（对齐下方 onPressed 的麦克风门）。
                                        onLongPress:
                                            (onVoice == null || sending)
                                            ? null
                                            : () {
                                                HapticFeedback.mediumImpact();
                                                onVoice!();
                                              },
                                        child: IconButton.filled(
                                          key: const ValueKey('send-button'),
                                          style: IconButton.styleFrom(
                                            backgroundColor:
                                                context.colors.brand,
                                            foregroundColor:
                                                context.colors.onBrand,
                                            shape: const CircleBorder(),
                                            disabledBackgroundColor:
                                                context.colors.secondary,
                                            disabledForegroundColor: context
                                                .colors
                                                .foregroundSubtlest,
                                          ),
                                          // A3：发送在途时禁用+转圈；验收回填
                                          // （2026-10-22 可发现性）：空闲且无
                                          // 草稿时图标换麦克风、点按直达语音
                                          // （微信/Telegram 同款惯例；长按
                                          // 语音不变）——「发送键能语音」
                                          // 从此可见。
                                          onPressed:
                                              (sending ||
                                                  controller.text
                                                      .trim()
                                                      .isEmpty)
                                              ? ((onVoice != null && !sending)
                                                    ? onVoice
                                                    : null)
                                              // 优化批 #1：发送键触觉反馈
                                              // （点按即轻震，确认已触发）。
                                              // 18077 验收#13（M）：light
                                              // 档真机几乎无感——升 medium。
                                              : () {
                                                  HapticFeedback.mediumImpact();
                                                  onSend();
                                                },
                                          icon: sending
                                              ? const SizedBox(
                                                  width: 16,
                                                  height: 16,
                                                  child:
                                                      CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                      ),
                                                )
                                              : (controller.text
                                                        .trim()
                                                        .isEmpty &&
                                                    onVoice != null)
                                              ? const Icon(
                                                  Icons.mic_rounded,
                                                  size: 21,
                                                )
                                              : const Icon(
                                                  Icons.arrow_upward,
                                                  size: 21,
                                                ),
                                        ),
                                      ),
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
          ),
        ),
      ),
    );
  }
}

/// 工具栏药丸（合并选型常驻入口）：统一 32px 高（minHeight 约束）、
/// 10px 水平内距；
/// filled=浅灰底（白卡上对比清晰），outlined=描边（模式类安全语义）；
/// statusDot 并入模型药丸头部（独立小点在行内漂浮显凌乱——视觉轮定）。
/// 挂起态以强调色小点提示（随下次发送生效）。
/// （批次 B 勘误：原文"34px 高"与实际约束 32 脱节——以约束为准。）
/// 用量详情卡（桌面绿色圆圈悬停卡的手机等价物，用户 2026-10-17 提议）：
/// 上下文容量 + 用量构成（官方 BREAKDOWN_SOURCE_LABEL_ID zh 文案）+
/// 缓存命中率 + 剩余额度三卡（entitlement 快照，开卡时拉一次）。
/// 数据全部来自 snapshot.usage（零 RPC）+ 可选 entitlement。

class ToolbarPill extends StatelessWidget {
  final IconData? icon;
  final Color? iconColor;
  final String label;

  /// 品牌小 logo 资产路径（Paseo 参考 2026-10-23：模型药丸行首品牌标，
  /// 单色跟随文字色；null=无 logo 不占位）。
  final String? brandAsset;

  /// 次级文字（Paseo 参考：模型名亮+档位暗两级分层，降低文字密度感）。
  final String? subLabel;
  final bool chevron;
  final bool pending;
  final bool outlined;

  /// 主文字色（批⑦：完全访问药丸整颗变 warning 橙——官方
  /// text-warning 药丸视觉，null=默认前景色）。
  final Color? labelColor;

  /// Paseo 观感二轮（2026-10-23）：透明底小触发器形态（模型药丸用，
  /// 对齐 Paseo 手机端 28 高透明 pill，model-sheet.tsx:264-293）。
  final bool plain;

  /// 最小高（默认 32；plain 触发器传 28）。
  final double minHeight;
  final VoidCallback? onTap;

  const ToolbarPill({
    super.key,
    this.icon,
    this.iconColor,
    required this.label,
    this.brandAsset,
    this.subLabel,
    this.chevron = false,
    this.pending = false,
    this.outlined = false,
    this.labelColor,
    this.plain = false,
    this.minHeight = 32,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final border = outlined
        ? Border.all(color: context.colors.borderHover)
        : null;
    // plain：透明底无描边（Paseo 式触发器）；否则描边档透明/侧栏底。
    final bg = plain
        ? Colors.transparent
        : (outlined ? Colors.transparent : context.colors.sidebar);
    return Material(
      color: bg,
      shape: RoundedRectangleBorder(
        // 批次 B：胶囊语义化——999 会被钳到半高（minHeight 32 → 16），
        // 与原手写 17 的实际渲染等值，视觉零变化；不再依赖魔法数。
        borderRadius: BorderRadius.circular(AppRadius.pill),
        side: border?.top ?? BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        onTap: onTap,
        child: Container(
          constraints: BoxConstraints(minHeight: minHeight),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (brandAsset != null) ...[
                // 品牌色自动策略（2026-10-26 拍板①）：浅色原色/深色提亮。
                BrandLogo(asset: brandAsset!, size: 15),
                if (label.isNotEmpty) const SizedBox(width: 5),
              ],
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 16,
                  color: iconColor ?? context.colors.foreground,
                ),
                if (label.isNotEmpty) const SizedBox(width: 4),
              ],
              if (label.isNotEmpty)
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    // ③：chrome 药丸不随系统字体缩放（大字号机型下
                    // 「模型 · 档」被截断看不全——真机实锤），12px 恒定。
                    textScaler: TextScaler.noScaling,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: labelColor ?? context.colors.foreground,
                    ),
                  ),
                ),
              if (subLabel != null && subLabel!.isNotEmpty) ...[
                const SizedBox(width: 4),
                // Flexible（对抗审查 B2）：次级档位文字裸 Text 先量先占，
                // 档位名过长时会把 Flexible 的主模型名压到 0——同 label
                // 处理，双弹性收缩。
                Flexible(
                  child: Text(
                    subLabel!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textScaler: TextScaler.noScaling,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: context.colors.foregroundSubtle,
                    ),
                  ),
                ),
              ],
              if (pending) ...[
                const SizedBox(width: 5),
                Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: context.colors.interactionAskForeground,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
              if (chevron) ...[
                const SizedBox(width: 2),
                Icon(
                  Icons.keyboard_arrow_down,
                  size: 15,
                  color: context.colors.foregroundSubtle,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 「添加」弹层宫格项（zemote 交互范式参考，官方语义=插入触发符）。

class AddAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const AddAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(14),
    child: SizedBox(
      width: 86,
      child: Column(
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: context.colors.interactionAskSurface,
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            child: Icon(
              icon,
              color: context.colors.interactionAskForeground,
              size: 24,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: const TextStyle(fontSize: AppType.uiSm),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    ),
  );
}

/// 离线发送排队条（6.6②，从页面内联块逐字提取为受控组件）：
/// 断连期发送的消息在此排队，重连后自动按序发出；逐条可撤销。
/// 18077 验收#12（优化意见 L）：灰小字升级为一眼可见的卡片——
/// 容器底+边框+品牌色图标、字号 uiXs→uiCaption。
class OfflineSendQueueStrip extends StatelessWidget {
  final List<SendQueueEntry> entries;
  final bool expanded;
  final VoidCallback onToggle;
  final Future<void> Function(SendQueueEntry entry) onCancel;

  const OfflineSendQueueStrip({
    super.key,
    required this.entries,
    required this.expanded,
    required this.onToggle,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return             Padding(
              key: const ValueKey('send-queue-strip'),
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: Container(
                padding: const EdgeInsets.fromLTRB(10, 6, 4, 4),
                decoration: BoxDecoration(
                  color: context.colors.brandAccent.withValues(
                    alpha: AppAlpha.faint,
                  ),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  border: Border.all(
                    color: context.colors.brandAccent.withValues(
                      alpha: AppAlpha.mid,
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.schedule,
                          size: 16,
                          color: context.colors.brandAccent,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            tr('未连接，已排队待发送（') +
                                '${entries.length}' +
                                tr(' 条），恢复连接后自动发出'),
                            style: TextStyle(
                              fontSize: AppType.uiCaption,
                              fontWeight: FontWeight.w600,
                              color: context.colors.foreground,
                            ),
                          ),
                        ),
                        if (entries.length > 1)
                          TextButton(
                            key: const ValueKey('send-queue-toggle'),
                            onPressed: onToggle,
                            child: Text(expanded ? tr('收起') : tr('展开')),
                          ),
                      ],
                    ),
                  // 单条直接展示（无展开钮也可撤销）；多条默认收起、
                  // 展开逐条可见可撤销。
                  if (expanded || entries.length == 1)
                    for (final e in entries)
                      Padding(
                        padding: const EdgeInsets.only(left: 20, top: 2),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                e.text,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                translate: false,
                                style: TextStyle(
                                  fontSize: AppType.uiXs,
                                  color: context.colors.foregroundSubtle,
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 32,
                              height: 32,
                              child: IconButton(
                                key: ValueKey('send-queue-cancel-${e.id}'),
                                padding: EdgeInsets.zero,
                                iconSize: 16,
                                tooltip: tr('撤销这条排队消息'),
                                onPressed: () =>
                                    unawaited(onCancel(e)),
                                icon: const Icon(Icons.close),
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

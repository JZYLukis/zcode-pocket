// 状态托盘（status-tray-1109，用户拍板「可行，可执行」）：输入区上方
// 的状态条带家族（排队/后台工作/暂存/结果未知）合并治理——小屏上
// 多条横幅各占一行是密度事故源（视觉补跑+用户「屏幕承载太多」关切）。
// 规则：单源=直接渲染该源原始条带（现状路径零回归，既有测试/肌肉
// 记忆不变）；≥2 源=合并成一行摘要（段点+计数+chevron，40dp 触控下限）
// 点按展开=限高 240dp 内部滚动堆叠各源原始条带（动作入口原样保留）。
// 判断口诀（AGENTS 活事项 74）：临时状态就地收、同类信息合并收——
// 本组件是「合并收」的载体；简洁模式（已暂存形态）日后压成角标。
import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/theme.dart';

class StatusTraySection {
  final String id;
  final String label;
  final String detail;
  final Color? accent;
  final Widget Function() body;

  const StatusTraySection({
    required this.id,
    required this.label,
    required this.detail,
    required this.body,
    this.accent,
  });
}

class StatusTray extends StatelessWidget {
  final List<StatusTraySection> sections;
  final bool expanded;
  final VoidCallback onToggle;

  const StatusTray({
    super.key,
    required this.sections,
    required this.expanded,
    required this.onToggle,
  });

  /// 展开体高度上限（与 BackgroundWorksPanel.maxBodyHeight 同口径：
  /// 多源堆叠也只占约屏高 1/3，消息列表不被挤没）。
  static const double maxBodyHeight = 240;

  @override
  Widget build(BuildContext context) {
    if (sections.isEmpty) return const SizedBox.shrink();
    // 单源：现状直通——各条带自身的折叠/展开语义保持权威（零回归）。
    if (sections.length == 1) return sections.first.body();
    return Container(
      key: const ValueKey('status-tray'),
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: context.colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: context.colors.borderFaint),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            key: const ValueKey('status-tray-toggle'),
            onTap: onToggle,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 40),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 10,
                        runSpacing: 2,
                        children: [
                          for (final s in sections) _segment(context, s),
                        ],
                      ),
                    ),
                    Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: context.colors.foregroundSubtle,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (expanded)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: maxBodyHeight),
              child: SingleChildScrollView(
                key: const ValueKey('status-tray-body'),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < sections.length; i++)
                      Padding(
                        padding: EdgeInsets.only(top: i == 0 ? 4 : 8),
                        // Visual 审查（compactness 批）处置：段前同色点列
                        // ——统一左基准线（原各源自带边距参差 8dp）+延续
                        // 折叠行的颜色归属（展开体不再只靠读文字分组）。
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 5),
                              child: Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: sections[i].accent ??
                                      context.colors.foregroundSubtle,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(child: sections[i].body()),
                          ],
                        ),
                      ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _segment(BuildContext context, StatusTraySection s) {
    // Visual 审查处置（tray 七维 ②⑤）：段点=accent 类别色，段字统一
    // foreground——浅色 surface 底上彩字对比度 4.45:1 差 AA 一线，且
    // warning/running 同 token（浅 #B45309/深 #FF8A30）使「三色三义」
    // 不可实现。定档：点色=类别（蓝=排队待发/橙=需注意），字色=统一
    // 高对比；warning 与 running 的真分色是全局 token 议题（backlog
    // VR-11 对比度口径一并拍板）。
    final dotColor = s.accent ?? context.colors.foregroundSubtle;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          s.detail.isEmpty ? s.label : '${s.label} ${s.detail}',
          style: TextStyle(
            fontSize: AppType.uiXs,
            fontWeight: FontWeight.w600,
            color: context.colors.foreground,
          ),
        ),
      ],
    );
  }
}

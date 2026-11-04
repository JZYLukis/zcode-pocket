import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 以稳定条目为锚的双向懒列表。
///
/// 官方 ConversationTimeline 用稳定 turn key + virtualizer measurement 在
/// prepend commit 绘制前恢复阅读位置；Flutter 原生对应物是
/// `CustomScrollView.center`：较老条目位于 center 前的反向 sliver，新增历史
/// 只增长负向滚动区，center 与当前阅读内容不需要 postFrame 补偿。
class AnchoredChatList extends StatelessWidget {
  static const _centerKey = ValueKey('anchored-chat-center');

  final ScrollController controller;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final int centerIndex;
  final Widget? leading;
  final Widget? trailing;
  final EdgeInsets padding;
  final ScrollViewKeyboardDismissBehavior keyboardDismissBehavior;

  const AnchoredChatList({
    super.key,
    required this.controller,
    required this.itemCount,
    required this.itemBuilder,
    required this.centerIndex,
    this.leading,
    this.trailing,
    this.padding = EdgeInsets.zero,
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.manual,
  }) : assert(itemCount >= 0),
       assert(centerIndex >= 0),
       assert(itemCount == 0 || centerIndex < itemCount),
       // 开源审查 A2-P3-6：itemCount==0 时 afterCenter=-1 会把 trailing
       // 静默吞成底距 SizedBox——潜伏地雷（当前调用方用 isNotEmpty 守住，
       // 留断言防未来调用方踩入）。
       assert(itemCount > 0 || trailing == null, 'trailing requires itemCount>0');

  @override
  Widget build(BuildContext context) {
    final horizontal = EdgeInsets.only(
      left: padding.left,
      right: padding.right,
    );
    // 开源审查 A2-P3-6：itemCount==0 时 afterCenter=-1（构造断言已拦
    // trailing 非空形态）——clamp 到 0 保 childCount 数学恒正。
    final afterCenter = math.max(0, itemCount - centerIndex - 1);
    final leadingCount = centerIndex + (leading == null ? 0 : 1);
    final trailingCount = afterCenter + (trailing == null ? 0 : 1) + 1; // 末尾底距

    return CustomScrollView(
      controller: controller,
      center: _centerKey,
      physics: const ClampingScrollPhysics(),
      keyboardDismissBehavior: keyboardDismissBehavior,
      slivers: [
        SliverPadding(
          padding: horizontal,
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate((context, reverseIndex) {
              if (leading != null && reverseIndex == centerIndex) {
                return Padding(
                  padding: EdgeInsets.only(top: padding.top),
                  child: leading,
                );
              }
              final index = centerIndex - reverseIndex - 1;
              final child = itemBuilder(context, index);
              if (leading == null && index == 0) {
                return Padding(
                  padding: EdgeInsets.only(top: padding.top),
                  child: child,
                );
              }
              return child;
            }, childCount: leadingCount),
          ),
        ),
        SliverPadding(
          key: _centerKey,
          padding: horizontal,
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate((context, _) {
              final child = itemBuilder(context, centerIndex);
              if (centerIndex == 0 && leading == null) {
                return Padding(
                  padding: EdgeInsets.only(top: padding.top),
                  child: child,
                );
              }
              return child;
            }, childCount: itemCount == 0 ? 0 : 1),
          ),
        ),
        SliverPadding(
          padding: horizontal,
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              if (index < afterCenter) {
                return itemBuilder(context, centerIndex + index + 1);
              }
              if (trailing != null && index == afterCenter) {
                return trailing;
              }
              return SizedBox(height: padding.bottom);
            }, childCount: trailingCount),
          ),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'motion.dart';

/// 任务状态徽标视觉（批次4 状态色收敛单源，2026-10-19 审查）：
/// 归一化 phase →（前景色, 底色, 中文标签）。原先 task_center 的
/// _TaskCard._statusOf 与 _CrossTaskCard 各持一份近似 switch（词表与
/// 配色存在漂移：completedInterrupted 一侧"已停止"一侧"出错"）——收敛
/// 为一份，两处同源。pendingInteraction 的"待处理"优先分支留在调用方
/// （entry 级语义，非 phase 词表）。
/// 深色模式批1：色值改为显式传色板（调用方 context.colors；测试
/// AppThemeSpec.light.colors）——徽标单源跟随主题，勿缓存。
({Color color, Color surface, String label}) taskPhaseBadge(
    AppColors colors,
    String phase,
) {
  return switch (phase) {
    'running' || 'prewarming' => (
        color: colors.running,
        surface: colors.running.withValues(alpha: AppAlpha.light),
        label: '运行中',
      ),
    'completedSuccess' => (
        color: colors.success,
        surface: colors.success.withValues(alpha: AppAlpha.light),
        label: '完成',
      ),
    'completedInterrupted' => (
        color: colors.warning,
        surface: colors.warning.withValues(alpha: AppAlpha.light),
        label: '已停止',
      ),
    'error' || 'failed' => (
        color: colors.destructive,
        surface: colors.destructive.withValues(alpha: AppAlpha.light),
        label: '失败',
      ),
    'draft' => (
      color: colors.foregroundSubtle,
      surface: colors.surface,
      label: '草稿',
    ),
    // controller/tasks-index liveStatus 新增词：等待用户
    // 审批/输入——视觉与首页 pendingInteraction 分支同款"待处理"。
    'waiting' => (
      color: colors.interactionAskForeground,
      surface: colors.interactionAskSurface,
      label: '待处理',
    ),
    _ => (
        color: colors.idleTask,
        surface: colors.idleTaskSurface,
        label: '空闲',
      ),
  };
}

/// 状态小图标（2026-10-27 视觉优化）：运行中用细旋转图标而非扩散光晕；
/// 其余状态用可辨形状的小图标，不再一律实心圆点。
Widget taskPhaseIcon(String phase, Color color, {double size = 10}) {
  final icon = switch (phase) {
    'running' || 'prewarming' => null,
    'completedSuccess' => Icons.check,
    'completedInterrupted' => Icons.stop_circle_outlined,
    'error' || 'failed' => Icons.error_outline,
    'draft' => Icons.edit_outlined,
    'waiting' => Icons.front_hand_outlined,
    _ => Icons.schedule,
  };
  if (icon == null) return RunningPulseDot(color: color, size: size);
  return Icon(icon, size: size, color: color);
}

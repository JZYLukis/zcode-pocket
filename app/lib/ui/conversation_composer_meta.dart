import 'dart:async';

import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/l10n.dart';
import '../core/payload_guard.dart';
import '../core/theme.dart';
import '../core/usage_format.dart';
import '../state/app_state_scope.dart';
import '../transport/conversation.dart';
import 'conversation_composer.dart';

class ContextDetailsCard extends StatelessWidget {
  final ConversationState state;
  final Map<String, dynamic>? entitlement;
  final bool entitlementLoading;
  final Map<String, dynamic>? resetStatus;
  final Future<void> Function(String resetType)? onUseReset;
  final List<Map>? cachedBreakdown;

  /// 压缩上下文动作（compact-command-1：官方 contextUsage 压缩按钮
  /// 对位——空载荷 compact 命令）；null=不显示。
  final VoidCallback? onCompact;
  const ContextDetailsCard({
    required this.state,
    this.entitlement,
    this.entitlementLoading = false,
    this.resetStatus,
    this.onUseReset,
    this.cachedBreakdown,
    this.onCompact,
  });

  /// 来源圆点取色序（官方 7 类；与 _sourceLabels 键一致——确定性映射，
  /// 跨重启稳定；批3 修 hashCode 换色 bug 引入）。
  static const _sourceLabelsOrder = <String>[
    'messages',
    'system_prompt',
    'meta_user_context',
    'skills',
    'tool_prompt',
    'system_tool_schemas',
    'mcp_tool_schemas',
  ];

  static const _sourceLabels = <String, String>{
    'messages': '消息',
    'system_prompt': '系统提示词',
    'meta_user_context': '其他',
    'skills': '技能',
    'tool_prompt': '工具提示词',
    'system_tool_schemas': '系统工具',
    'mcp_tool_schemas': 'MCP 工具',
  };

  @override
  Widget build(BuildContext context) {
    final usage = state.usage;
    final cw = usage?['contextWindow'];
    // 数字守卫（ D1/D2/D3：usedTokens 缺失而 maxTokens>0 时
    // used! 崩 build；String 形态漂移同炸——统一走 payload_guard 兜底）。
    final used = numOf(cw is Map ? cw['usedTokens'] : null) ?? 0;
    final max = numOf(cw is Map ? cw['maxTokens'] : null) ?? 0;
    final ratio = max > 0 ? (used / max).clamp(0.0, 1.0) : 0.0;
    final warn = ratio > 0.85;
    final cache = cw is Map ? cw['cache'] : null;
    final hitRate = cache is Map
        ? cache['hitRate'] ?? cache['latestHitRate']
        : null;
    final breakdown = cw is Map ? cw['breakdown'] : null;
    final liveItems = breakdown is List && breakdown.isNotEmpty
        ? breakdown.whereType<Map>().toList()
        : const <Map>[];
    // conflation 缺发时回退上次数据（用户拍板「一直展示」）
    final stale = liveItems.isEmpty && (cachedBreakdown?.isNotEmpty ?? false);
    final items = stale ? cachedBreakdown! : liveItems;
    final totalChars = items.fold<int>(
      0,
      (sum, it) => sum + intOrZero(it['chars']),
    );

    final quota = entitlement?['quota'];
    final limits = quota is Map ? listOf(quota['limits']) : null;
    final mcpAggregate = () {
      final mcp = entitlement?['mcpQuota'];
      return mcp is Map ? mcp['aggregate'] : null;
    }();
    // 验收①：命名对齐桌面（5小时额度）；重置时间仅 5 小时档展示且
    // 裸时间不带「重置」前缀（桌面同款）；工具/MCP 的时间留用量页。
    final quotaCards =
        <
            ({
              String label,
              Map<String, dynamic>? limit,
              bool showReset,
              Color color,
            })
          >[
            (
              label: '5小时额度',
              limit: findQuotaLimit(
                limits,
                tokenKind: true,
                unit: 3,
                number: 5,
              ),
              showReset: true,
              color: context.charts.series[0],
            ),
            (
              label: '工具调用',
              limit: findQuotaLimit(limits, tokenKind: false),
              showReset: false,
              color: context.charts.series[1],
            ),
            (
              label: 'ZCode MCP',
              limit: mcpAggregate is Map
                  ? mcpAggregate.cast<String, dynamic>()
                  : null,
              showReset: false,
              color: context.charts.series[2],
            ),
          ]
          ..removeWhere((c) => c.limit == null);
    // 重置机会（官方 getCodingPlanResetStatus；FIVE_HOUR 与徽标展示对齐）
    final resetAvail =
        listOf(resetStatus?['availableFiveHourResets'])?.length ?? 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: context.colors.card,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: context.colors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 上下文容量
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '上下文容量',
                    style: TextStyle(
                      fontSize: AppType.uiSm,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  '${tr(formatTokens(used))}/${tr(formatTokens(max))}'
                  '${L10n.resolvedLocale == 'en-US' ? ' (' : '（'}'
                  '${(ratio * 100).toStringAsFixed(0)}%'
                  '${L10n.resolvedLocale == 'en-US' ? ')' : '）'}',
                  style: TextStyle(
                    fontSize: AppType.uiSm,
                    color: warn
                        ? context.colors.warning
                        : context.colors.foreground,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 5,
                backgroundColor: context.colors.sidebar,
                valueColor: AlwaysStoppedAnimation(
                  warn ? context.colors.warning : context.colors.linkBlue,
                ),
              ),
            ),
            // 压缩上下文动作（compact-command-1：官方 contextUsage 压缩
            // 按钮对位；进度反馈=时间线「正在压缩上下文」标记行）。
            if (onCompact != null) ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  key: const ValueKey('compact-context'),
                  onPressed: onCompact,
                  icon: const Icon(Icons.compress, size: 16),
                  label: Text(tr('压缩上下文')),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
            ],
            // 用量构成
            if (items.isNotEmpty && totalChars > 0) ...[
              const SizedBox(height: 12),
              Text(
                stale ? tr('上下文来源（上次）') : tr('上下文来源'),
                style: const TextStyle(
                  fontSize: AppType.uiSm,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              // 按官方 BREAKDOWN_SOURCE_ORDER 排序后按占比渲染
              for (final it
                  in [...items]..sort(
                    (a, b) => (numOf(b['chars']) ?? 0).compareTo(
                      numOf(a['chars']) ?? 0,
                    ),
                  ))
                Builder(
                  builder: (_) {
                    final source = '${it['source']}';
                    final chars = intOrZero(it['chars']);
                    final pct = (chars / totalChars * 100);
                    // 批3 附带上报修复：原 source.hashCode 取色违反
                    // token 契约（String hashCode 进程随机种子——重启后同
                    // 一来源换色，6.5-1 同失效类）。改按官方 7 类 label 固定
                    // 序号索引，跨重启稳定；未知来源回落 source 长度取模。
                    final known = _sourceLabelsOrder.indexOf(source);
                    final idx = known >= 0
                        ? known
                        : source.length % context.charts.sourceColors.length;
                    final color = context.charts.sourceColors[idx];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _sourceLabels[source] ?? source,
                              style: const TextStyle(fontSize: AppType.uiSm),
                            ),
                          ),
                          Text(
                            '${pct >= 10 ? pct.toStringAsFixed(0) : pct.toStringAsFixed(1)}%'
                            ' · ${formatTokens(chars)}',
                            style: TextStyle(
                              fontSize: AppType.uiSm,
                              color: context.colors.foregroundSubtle,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
            ],

            // 缓存命中率
            if (hitRate is num && hitRate > 0) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '缓存命中率',
                      style: TextStyle(fontSize: AppType.uiSm),
                    ),
                  ),
                  Text(
                    '${(hitRate > 1 ? hitRate : hitRate * 100).toStringAsFixed(1)}%',
                    style: TextStyle(
                      fontSize: AppType.uiSm,
                      color: context.colors.foreground,
                    ),
                  ),
                ],
              ),
            ],
            // 剩余额度（entitlement）
            if (quotaCards.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text(
                '剩余额度',
                style: TextStyle(
                  fontSize: AppType.uiSm,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              for (final c in quotaCards) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          c.label,
                          style: const TextStyle(fontSize: AppType.uiSm),
                        ),
                      ),
                      Text(
                        '${quotaRemainingPercent(c.limit).toStringAsFixed(0)}%'
                        '${c.showReset ? ' · ${formatResetTime(c.limit?['nextResetTime'])}' : ''}',
                        style: TextStyle(
                          fontSize: AppType.uiSm,
                          color: c.color,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: quotaRemainingPercent(c.limit) / 100,
                    minHeight: 3,
                    backgroundColor: context.colors.sidebar,
                    valueColor: AlwaysStoppedAnimation(c.color),
                  ),
                ),
              ],
              // 重置额度（桌面同款徽标语义：可用次数 + 核销按钮）
              if (resetAvail > 0 && onUseReset != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${tr('🎁 可重置额度')} ×$resetAvail',
                          style: TextStyle(
                            fontSize: AppType.uiSm,
                            color: context.colors.interactionAskForeground,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => onUseReset!('FIVE_HOUR'),
                        icon: const Icon(Icons.replay, size: 14),
                        label: Text(tr('重置5小时额度')),
                        style: TextButton.styleFrom(
                          foregroundColor:
                              context.colors.interactionAskForeground,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),
                ),
            ] else if (entitlementLoading)
              Padding(
                padding: EdgeInsets.only(top: 10),
                child: Text(
                  '正在获取额度…',
                  style: TextStyle(
                    fontSize: AppType.uiSm,
                    color: context.colors.foregroundSubtle,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class InfoRow extends StatelessWidget {
  final ConversationState state;
  final String? sessionId;
  final String modeLabel;

  /// 批⑦（2026-10-23）：权限档图标与配色——完全访问=warning 橙+
  /// 盾牌警示图标、自主=brandAccent 蓝（官方 text-warning /
  /// text-icon-blue 药丸视觉）。
  final IconData? modeIcon;
  final Color? modeIconColor;
  final Color? modeLabelColor;
  final bool modePending;

  /// 计划模式生效值：真则模式药丸右侧追加「计划」标记药丸（官方
  /// plan marker：灯泡+「计划」，V4ComposerModeControls.tsx:193-219）。
  final bool planEnabled;
  final VoidCallback? onModeTap;
  const InfoRow({
    required this.state,
    this.sessionId,
    required this.modeLabel,
    this.modeIcon,
    this.modeIconColor,
    this.modeLabelColor,
    this.modePending = false,
    this.planEnabled = false,
    this.onModeTap,
  });

  @override
  Widget build(BuildContext context) {
    final usage = state.usage;

    final cw = usage?['contextWindow'];

    // 数字守卫（ D1-P2/D2-06/D3-P2-1）：usedTokens 缺失而
    // maxTokens>0 时旧 used! 空断言崩整页 build；与同文件
    // ContextDetailsCard 对齐走 payload_guard（缺字段/畸形形态按 0 兜底）。
    final used = numOf(cw is Map ? cw['usedTokens'] : null) ?? 0;

    final max = numOf(cw is Map ? cw['maxTokens'] : null) ?? 0;

    final hasUsage = max > 0;

    final ratio = hasUsage ? (used / max).clamp(0.0, 1.0) : 0.0;

    final warn = ratio > 0.85;
    final modePill = ToolbarPill(
      key: const ValueKey('mode-switch'),
      icon: modeIcon ?? Icons.shield_outlined,
      iconColor: modeIconColor ?? context.colors.foreground,
      label: modeLabel.isEmpty ? '模式' : modeLabel,
      labelColor: modeLabelColor,
      pending: modePending,
      outlined: true,
      onTap: onModeTap,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),

      child: Row(
        children: [
          // 2026-10-22 用户反馈改回：用量仪表（进度条+数字）留在本行，

          // 与压缩入口、模式药丸同排（输入卡内嵌方案撤销）——进度条

          // 占满剩余宽度（验收② 2026-10-18 无右坠空白），空态常驻占位。
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.pill),

              child: LinearProgressIndicator(
                value: ratio,

                minHeight: 4,

                backgroundColor: context.colors.sidebar,

                valueColor: AlwaysStoppedAnimation(
                  warn ? context.colors.warning : context.colors.linkBlue,
                ),
              ),
            ),
          ),

          const SizedBox(width: 6),

          Text(
            hasUsage ? '${_fmtK(used.toInt())}/${_fmtK(max.toInt())}' : '0/1000k',

            style: TextStyle(
              fontSize: AppType.uiSm,

              color: warn
                  ? context.colors.warning
                  : context.colors.foregroundSubtlest,
            ),
          ),

          if (hasUsage && sessionId != null) ...[
            // 速赢#1（WR）：compact 入口（桌面 contextUsage 菜单同款语义）。

            if (sessionId != null)
              SizedBox(
                width: 26,
                height: 26,
                child: IconButton(
                  key: const ValueKey('compact-entry'),
                  padding: EdgeInsets.zero,
                  iconSize: 13,
                  icon: Icon(
                    Icons.compress,
                    color: context.colors.foregroundSubtlest,
                  ),
                  tooltip: tr('压缩上下文'),
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: const Text('压缩上下文？'),
                        content: const Text(
                          '将把当前对话历史压缩为摘要以释放上下文空间。'
                          '压缩后早期消息的原文不再可用。',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () =>
                                Navigator.pop(dialogContext, false),
                            child: const Text('取消'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(dialogContext, true),
                            child: const Text('压缩'),
                          ),
                        ],
                      ),
                    );
                    if (ok != true) return;
                    try {
                      await AppStateScope.of(context).compact(sessionId!);
                      messenger.showSnackBar(
                        const SnackBar(
                          content: Text('已发起上下文压缩'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    } catch (e) {
                      messenger.showSnackBar(
                        SnackBar(content: Text('压缩失败：$e')),
                      );
                    }
                  },
                ),
              ),
            const SizedBox(width: 6),
          ],
          if (L10n.resolvedLocale == 'en-US')
            Flexible(fit: FlexFit.loose, child: modePill)
          else
            modePill,

          // 计划模式标记药丸（批⑦：计划与权限并行——开启时模式药丸
          // 右侧出「计划」标记，点按回模式面板可关；对位官方 plan
          // marker 的手机端常显形态）。
          if (planEnabled) ...[
            const SizedBox(width: 6),

            ToolbarPill(
              key: const ValueKey('plan-marker'),
              icon: Icons.lightbulb_outline,
              iconColor: context.colors.foreground,
              label: '计划',
              outlined: true,
              onTap: onModeTap,
            ),
          ],
        ],
      ),
    );
  }

  static String _fmtK(int tokens) => tokens >= 1000
      ? '${(tokens / 1000).toStringAsFixed(tokens >= 100000 ? 0 : 1)}k'
      : '$tokens';
}

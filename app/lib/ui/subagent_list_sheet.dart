// 会话子代理列表（2026-10-26 拍板⑥，方案 A——官方
// SubagentSessionSidePane 的手机化）：会话顶栏入口 → 底部弹层分
// 「运行中 / 已结束」两段，已结束分页（endedCursor，官方默认 20/页）；
// 点条目经 childSessionId 下钻现有只读会话页（官方同款 drill-in）。
import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import '../core/localized_text.dart';

import '../core/theme.dart';
import '../state/app_state_scope.dart';
import 'conversation_session_opener.dart';

Future<void> showSubagentListSheet(
  BuildContext context, {
  required String sessionId,
  required ConversationSessionOpener openSession,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => SafeArea(
      child: _SubagentListSheet(sessionId: sessionId, openSession: openSession),
    ),
  );
}

class _SubagentListSheet extends StatefulWidget {
  final String sessionId;
  final ConversationSessionOpener openSession;
  const _SubagentListSheet({required this.sessionId, required this.openSession});

  @override
  State<_SubagentListSheet> createState() => _SubagentListSheetState();
}

class _SubagentListSheetState extends State<_SubagentListSheet> {
  List<Map<String, dynamic>>? _running;
  List<Map<String, dynamic>> _ended = [];
  int _endedTotal = 0;
  String? _nextCursor;
  String? _error;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
 // initState 内不得读 inherited（AppStateScope）——首帧后再取。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    try {
      final res = await AppStateScope.of(context)
          .sessionSubagents(widget.sessionId) ??
          (throw StateError('未连接电脑'));
      if (!mounted) return;
      setState(() {
        _running = [
          for (final r in (res['running'] as List?) ?? const [])
            if (r is Map) r.cast<String, dynamic>(),
        ];
        final ended = res['ended'];
        _ended = ended is Map
            ? [
                for (final e in (ended['items'] as List?) ?? const [])
                  if (e is Map) e.cast<String, dynamic>(),
              ]
            : [];
        _endedTotal = ended is Map ? (ended['total'] as num?)?.toInt() ?? 0 : 0;
        _nextCursor = ended is Map ? ended['nextCursor'] as String? : null;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _nextCursor == null) return;
    setState(() => _loadingMore = true);
    try {
      final res = await AppStateScope.of(context).sessionSubagents(
            widget.sessionId,
            endedCursor: _nextCursor,
          ) ??
          (throw StateError('未连接电脑'));
      if (!mounted) return;
      setState(() {
        final ended = res['ended'];
        if (ended is Map) {
          _ended = [
            ..._ended,
            for (final e in (ended['items'] as List?) ?? const [])
              if (e is Map) e.cast<String, dynamic>(),
          ];
          _nextCursor = ended['nextCursor'] as String?;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _open(Map<String, dynamic> item) {
    final child = '${item['childSessionId'] ?? ''}'.trim();
    if (child.isEmpty) return;
 // 2026-11-05 反馈①：下钻页标题优先用类型（官方 sidePaneTabPresentation
 // L127-128 同款——类型即子代理身份；无类型回退任务 title）。
    final type = '${item['subagentType'] ?? ''}'.trim();
    unawaited(
      widget.openSession(
        context,
        sessionId: child,
        title: type.isNotEmpty ? type : '${item['title'] ?? '子智能体'}',
        readOnly: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final running = _running;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.65,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              '子智能体',
              style: TextStyle(
                fontSize: AppType.uiBase,
                fontWeight: FontWeight.w600,
                color: context.colors.foreground,
              ),
            ),
          ),
          if (_error != null)
            SizedBox(
              height: 220,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.cloud_off_outlined,
                      size: 32,
                      color: context.colors.foregroundSubtlest,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '子智能体加载失败',
                      style: TextStyle(fontSize: AppType.uiCaption),
                    ),
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        '$_error',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: AppType.uiXs,
                          color: context.colors.foregroundSubtle,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      key: const ValueKey('subagents-retry'),
                      onPressed: () {
                        setState(() {
                          _error = null;
                          _running = null;
                        });
                        _load();
                      },
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('重试'),
                    ),
                  ],
                ),
              ),
            )
          else if (running == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (running.isEmpty && _ended.isEmpty)
            SizedBox(
              key: const ValueKey('subagents-empty'),
              height: 220,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.smart_toy_outlined,
                      size: 36,
                      color: context.colors.foregroundSubtlest,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '本会话还没有子智能体',
                      style: TextStyle(
                        fontSize: AppType.uiCaption,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: Text(
                        '主智能体创建子智能体后，可在这里查看运行状态和结果',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: AppType.uiXs,
                          color: context.colors.foregroundSubtle,
                          height: 1.5,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('知道了'),
                    ),
                  ],
                ),
              ),
            )
          else
            Expanded(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 12),
                children: [
                  if (running.isNotEmpty) ...[
                    _sectionLabel(context, '运行中'),
                    for (final r in running) _tile(context, r, running: true),
                  ],
                  if (_ended.isNotEmpty) ...[
                    _sectionLabel(context, '已结束 $_endedTotal'),
                    for (final e in _ended) _tile(context, e),
                  ],
                  if (_nextCursor != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextButton(
                        key: const ValueKey('subagents-load-more'),
                        onPressed: _loadingMore ? null : _loadMore,
                        child: Text(
                          _loadingMore
                              ? '加载中…'
                              : '加载更多（${_ended.length}/$_endedTotal）',
                          style:
                              const TextStyle(fontSize: AppType.uiCaption),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text(
          text,
          style: TextStyle(
            fontSize: AppType.uiXs,
            fontWeight: FontWeight.w600,
            color: context.colors.foregroundSubtlest,
          ),
        ),
      );

  Widget _tile(
    BuildContext context,
    Map<String, dynamic> item, {
    bool running = false,
  }) {
    final status = '${item['status'] ?? ''}';
    final failed = status == 'failed' || status == 'lost';
    final titleColor = failed
        ? context.colors.destructive
        : running
            ? context.colors.running
            : context.colors.foreground;
 // 2026-11-05 反馈①：类型徽标（协议 subagentType 字段本就随行返回，
 // 此前 UI 未消费）——标题旁小 chip 给出 general-purpose / Explore
 // 等类型身份。
    final type = '${item['subagentType'] ?? ''}'.trim();
    return ListTile(
      key: ValueKey('subagent-${item['childSessionId'] ?? ''}'),
      dense: true,
      leading: Icon(
        Icons.smart_toy_outlined,
        size: 18,
        color: failed ? context.colors.destructive : titleColor,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              '${item['title'] ?? '子智能体'}'
              '${failed ? ' · 失败' : status == 'cancelled' ? ' · 已取消' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: AppType.uiBase, color: titleColor),
            ),
          ),
          if (type.isNotEmpty) ...[
            const SizedBox(width: 6),
            Container(
              key: ValueKey('subagent-type-${item['childSessionId'] ?? ''}'),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: context.colors.foregroundSubtlest.withValues(
                  alpha: 0.12,
                ),
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: Text(
                type,
                translate: false,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppType.uiXs,
                  color: context.colors.foregroundSubtle,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: '${item['summary'] ?? ''}'.isEmpty
          ? null
          : Text(
              '${item['summary']}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppType.uiXs,
                color: context.colors.foregroundSubtle,
              ),
            ),
      trailing: const Icon(Icons.chevron_right, size: 16),
      onTap: () => _open(item),
    );
  }
}

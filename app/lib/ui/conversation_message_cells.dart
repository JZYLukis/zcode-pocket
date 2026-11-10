import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/l10n.dart';
import '../core/theme.dart';
import '../state/app_state.dart';
import '../state/app_state_scope.dart';
import 'app_widgets.dart';
import 'conversation_session_opener.dart';
import 'file_preview.dart';
import 'markdown_view.dart';
import 'turn_model.dart';

class SearchTargetFrame extends StatelessWidget {
  final int? rowId;
  final int? activeRowId;
  final GlobalKey? targetKey;
  final Widget child;

  const SearchTargetFrame({
    required this.rowId,
    required this.activeRowId,
    required this.targetKey,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final active = rowId != null && rowId == activeRowId && targetKey != null;
    return DecoratedBox(
      decoration: active
          ? BoxDecoration(
              // 视觉复核（2026-10-27）：纯 9% 底色在真机上不够醒目，
              // 对齐草稿工作区 chip 的「底色+描边」双信号模式。
              color: context.colors.accent.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(
                color: context.colors.accent.withValues(alpha: 0.35),
              ),
            )
          : const BoxDecoration(),
      child: Stack(
        children: [
          // 主体始终位于 index 0：增删高亮不再重置长提问等内部 State。
          child,
          Positioned(
            top: 0,
            left: 0,
            child: SizedBox(
              key: active ? targetKey : null,
              width: 0,
              height: 0,
            ),
          ),
        ],
      ),
    );
  }
}

/// 稳定行渲染缓存（优化批 #8）：流式期页面合帧后仍会整列 rebuild，未变化的
/// 历史正文（非末轮 markdown/用户气泡文本）逐次全文重解析仍是每帧大头。cacheKey
/// 深比较（元素 ==：字符串按内容、Map 按引用——row.upserted
/// 换新实例的协议不变量，见 _ToolCallTile A2 备注）未变时复用上次 child
/// 实例——Element.updateChild 的 identical 短路直接跳过整棵子树 rebuild。
/// InheritedWidget（主题/MediaQuery/L10n）变化不受影响——依赖注册在
/// 子树自身 element 上，仍会直接标记重建。只缓存文本型内容（
/// 工具行有状态动画，不进缓存）。

class CachedContent extends StatefulWidget {
  final List<Object?> cacheKey;

  /// 惰性构建（ B3-P3-1）：命中时不再热构建 child——AssistantText
  /// 的 child 含 parseVisualizeSegments 全文正则与整棵子树，缓存命中期
  /// 的每帧重建是纯浪费。
  final Widget Function() childBuilder;

  const CachedContent({required this.cacheKey, required this.childBuilder});

  @override
  State<CachedContent> createState() => CachedContentState();
}

class CachedContentState extends State<CachedContent> {
  Widget? _cached;

  @override
  void didUpdateWidget(covariant CachedContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.cacheKey, widget.cacheKey)) {
      _cached = widget.childBuilder();
    }
  }

  @override
  Widget build(BuildContext context) => _cached ??= widget.childBuilder();
}

/// 文件卡行首类型图标（18077 验收#16 优化意见 O）：路径过长无法区分
/// md/html/代码/图片——行首小图标给文件属性一眼可辨。

List<InlineSpan> buildSearchHighlightSpans(
  String source,
  String query, {
  required TextStyle base,
  required TextStyle hit,
}) {
  // B1-P1-1/B2-P2-4/B3-P1-1：toLowerCase 对 İ（U+0130）等
  // 扩长字符改变码元长度，折叠串下标切原串会错位/RangeError——改用
  // 长度稳定折叠（foldCaseStable），命中下标恒在原串坐标系。
  final needle = foldCaseStable(query.trim());
  if (needle.isEmpty) {
    return [TextSpan(text: source, style: base)];
  }
  final spans = <InlineSpan>[];
  final haystack = foldCaseStable(source);
  var from = 0;
  while (from <= haystack.length - needle.length) {
    final start = haystack.indexOf(needle, from);
    if (start < 0) break;
    if (start > from) {
      spans.add(TextSpan(text: source.substring(from, start), style: base));
    }
    spans.add(
      TextSpan(
        text: source.substring(start, start + needle.length),
        style: hit,
      ),
    );
    from = start + needle.length;
  }
  if (from < source.length) {
    spans.add(TextSpan(text: source.substring(from), style: base));
  }
  return spans;
}


class AssistantText extends StatelessWidget {
  final String text;
  final bool streaming;

  /// 上下呼吸边距（默认 6）；收起态外置正文紧贴轮尾文件卡时传小值
  /// （用户拍板 2026-10-24 五轮：正文→卡的间距堆栈里正文自身底边距
  /// 占 6dp，外部实例清零由外层 Padding 统一控制节奏）。
  final double verticalPadding;

  /// 18074 验收③：::visualize 指令卡片取本轮 fileChanges 用（所属轮
  /// turnHeader 行与 sessionId）；缺省=null 不解析指令（旧行为）。
  final String? sessionId;
  final Map<String, dynamic>? header;

  /// 搜索命中词级高亮（优化批 #25）：非空=搜索激活，正文从
  /// markdown 渲染切换为纯文本预览（markdown 源文本+命中词底色）；
  /// 关闭搜索或关键词为空即恢复 markdown 渲染。
  final String? searchQuery;

  const AssistantText({
    required this.text,
    required this.streaming,
    this.verticalPadding = 6,
    this.sessionId,
    this.header,
    this.searchQuery,
  });

  @override
  Widget build(BuildContext context) {
    // 官方：空正文不渲染占位（进度由工作条/思考条表达）。
    if (text.isEmpty) return const SizedBox.shrink();
    final codeHighlight = AppStateScope.of(context)
        .uiPrefs
        .codeHighlightEnabled;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: verticalPadding),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          // 640 对齐官方 max-w 量级；折叠屏展开态按屏宽 94% 收口，
          // 避免宽屏正文被 640 卡住右侧空一截（对抗审查 C#27）。
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.94 > 640
                ? 640
                : MediaQuery.sizeOf(context).width * 0.94,
          ),
          // 稳定行渲染缓存（优化批 #8）：文本/流式态/高亮开关/搜索词
          // 未变时复用上次子树，跳过 MarkdownBody 全文重解析（宽屏约
          // 束在缓存外，尺寸变化经约束传导仍会重排）。
          // B3-P3-1：键里的 header 由实例身份换成 rowId/
          // entityId 值——turnHeader 每次 upsert（文件变更/轮状态迁移）
          // 都换新实例，同轮全部 AssistantText 缓存被击穿=全文重解析，
          // 而 header 实际只被 VisualizeCard 读这两个值。
          // B1-P3-9/B2-7/B3-P3-2：亮度掺键——span 里的命中
          // 底色/前景色在祖先 build 烘焙，主题切换（浅↔深）时 cacheKey
          // 不含亮度会复用旧主题配色的子树。
          child: CachedContent(
            cacheKey: [
              text,
              streaming,
              codeHighlight,
              sessionId,
              header?['rowId'],
              header?['entityId'],
              searchQuery,
              Theme.of(context).brightness,
            ],
            // B3-P1-2：空关键词按无高亮处理——页面在搜索开启
            // 且输入为空时传 ''（非 null），缺非空守卫会让全部助手正文
            // 从 markdown 降级纯文本（与 UserBubble 的 isNotEmpty 守卫
            // 及上方注释契约对齐）。
            childBuilder: () => (searchQuery != null &&
                    searchQuery!.trim().isNotEmpty)
                // 搜索激活预览（优化批 #25）：markdown 源文本直出+
                // 命中词底色高亮（不改 MarkdownView 内部——关闭搜索
                // 即恢复原渲染）。
                ? Text.rich(
                    key: const ValueKey('search-highlight-preview'),
                    TextSpan(
                      children: buildSearchHighlightSpans(
                        text,
                        searchQuery!,
                        base: TextStyle(
                          fontSize: AppType.uiBase,
                          height: 1.6,
                          color: context.colors.foreground,
                        ),
                        hit: TextStyle(
                          fontSize: AppType.uiBase,
                          height: 1.6,
                          color: context.colors.foreground,
                          backgroundColor: context.colors.brandAccent
                              .withValues(alpha: AppAlpha.mid),
                        ),
                      ),
                    ),
                    translate: false,
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 18074 验收③：::visualize 指令位渲染成可点卡片（官方
                      // gen-ui 引用；桌面投影沙箱，手机=点卡经 fileChanges
                      // 取全文进渲染页）。无指令=单段直渲染（零开销路径）。
                      if (sessionId == null || header == null)
                        MarkdownView(
                          data: text,
                          streaming: streaming,
                          codeHighlightEnabled: codeHighlight,
                        )
                      else ...[
                        for (final seg in parseVisualizeSegments(text))
                          seg.path != null
                              ? VisualizeCard(
                                  path: seg.path!,
                                  sessionId: sessionId,
                                  header: header,
                                )
                              : MarkdownView(
                                  data: seg.text ?? '',
                                  streaming: streaming,
                                  codeHighlightEnabled: codeHighlight,
                                ),
                      ],
                      // 轮尾操作行（2026-10-23 桌面对齐批）：复制/赞/踩/分支
                      // 收敛到轮尾 TurnTailActions（桌面同款仅轮末渲染）——
                      // 段级不再单独放复制钮。
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// timelineMarker 的「─ 图标 文案 ─」标记行（官方 MarkerDividerRow 对
/// 位）。 B2-1（lane 语义）：顶层（轮边界 lane，经
/// TimelineMarkerItem）与段内（mid-turn compact，lane=assistantWork 落
/// 进 TurnWork.work 由 conversation_turn_view 渲染）两处共用同一渲染。
class TimelineMarkerDivider extends StatelessWidget {
  final String label;

  /// B11：运行中标记（压缩进行中/目标校验中）。
  final bool running;

  const TimelineMarkerDivider({
    super.key,
    required this.label,
    this.running = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          const Expanded(child: Divider(height: 1, thickness: 0.5)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.swap_horiz,
                  size: 12,
                  color: context.colors.foregroundSubtlest,
                ),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: AppType.uiXs,
                    color: context.colors.foregroundSubtlest,
                  ),
                ),
              ],
            ),
          ),
          const Expanded(child: Divider(height: 1, thickness: 0.5)),
        ],
      ),
    );
  }
}

/// 轮尾操作行（2026-10-23 用户反馈批，对齐桌面轮尾 action bar——
/// ConversationRowView.tsx:1580-1649：复制/点赞/点踩/分支 ghost 一排，
/// 仅完成态轮尾渲染）。反馈乐观更新（官方同款，失败回滚+提示）；
/// 分支=forkAssistant（ack 带 sessionId，直接打开子会话）。

class TurnTailActions extends StatefulWidget {
  final Map<String, dynamic> row;

  /// 轮尾复制内容（对抗审查 B1：官方=整轮全部 text 段 join("\n\n")；
  /// 缺省回落本行 text）。
  final String? copyText;

  /// 协议命令用；null=反馈/分支按钮禁用（复制不受影响）。
  final String? sessionId;

  /// 轮开始时刻（优化批 #27：行最右侧 subtle 时间标签）。null/行数据
  /// 缺时间戳（旧快照/测试夹具）不显示。
  final int? createdAtMs;
  final ConversationSessionOpener openSession;
  const TurnTailActions({
    required this.row,
    this.copyText,
    this.sessionId,
    this.createdAtMs,
    required this.openSession,
  });

  @override
  State<TurnTailActions> createState() => TurnTailActionsState();
}

class TurnTailActionsState extends State<TurnTailActions> {
  /// 乐观反馈覆盖值（null=跟随行数据 row.feedback）。
  String? _override;

  /// 权威行值同步锚（对抗审查 B4）：行数据推送更新 feedback 字段后
  /// override 不得永久遮蔽——官方 useEffect([feedback]) 同步本地态。
  String? _syncedRowFeedback;

  /// 分支在途防抖（对抗审查 B7）：连点=两条 forkAssistant=服务端两个
  /// 子会话+路由叠栈。
  bool _forking = false;

  String? get _rowFeedback {
    final f = widget.row['feedback'];
    return f == 'like' || f == 'dislike' ? '$f' : null;
  }

  @override
  void didUpdateWidget(covariant TurnTailActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 行数据更新（feedback 随行广播，rows.ts:178）：权威值到位即弃本地
    // 乐观覆盖，避免永久遮蔽。
    if (!identical(oldWidget.row, widget.row) &&
        _rowFeedback != _syncedRowFeedback) {
      _syncedRowFeedback = _rowFeedback;
      _override = null;
    }
  }

  void _snack(String t) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(t), duration: const Duration(seconds: 2)),
  );

  /// B3：conversationRowTargetSchema 的 entityId 必填
  /// （strict）——缺失时返回 null，调用方降级为纯本地操作（与 H1 的
  /// 行菜单口径一致；此前两处口径相反）。
  Map<String, dynamic>? get _target {
    final entityId = '${widget.row['entityId'] ?? ''}'.trim();
    if (entityId.isEmpty) return null;
    return {'rowId': widget.row['rowId'], 'entityId': entityId};
  }

  /// ack 状态判定（官方 SessionPane.tsx:4084-4094/3976-3978 同款）：
  /// sendCommand 对 rejected/stale 耗尽等只打日志正常返回——UI 必须自查
  /// status，否则被拒当成功（乐观 UI 永久停在错误态/假成功提示）。
  bool _ackOk(dynamic res) =>
      res is Map &&
      (res['status'] == 'accepted' || res['status'] == 'duplicate');

  Future<void> _sendFeedback(AppState app, String? next) async {
    final prev = _override ?? _rowFeedback;
    _syncedRowFeedback = _rowFeedback;
    setState(() => _override = next);
    final target = _target;
    if (target == null) {
      if (mounted) {
        setState(() => _override = prev);
        _snack(tr('该行缺少协议标识，反馈仅本地保留'));
      }
      return;
    }
    try {
      final res = await app.setAssistantFeedback(
        widget.sessionId!,
        target,
        next,
      );
      if (!_ackOk(res)) {
        // 服务端拒绝（含 stale 收敛失败）：回滚+提示，不静默。
        if (mounted) {
          setState(() => _override = prev);
          _snack(
            '反馈未生效（${res is Map ? res['reasonCode'] ?? res['status'] : 'rejected'}），已还原',
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _override = prev);
        _snack('反馈失败：$e');
      }
    }
  }

  Future<void> _fork(AppState app) async {
    if (_forking) return;
    _forking = true;
    final target = _target;
    if (target == null) {
      _forking = false;
      _snack(tr('该行缺少协议标识，无法创建分支'));
      return;
    }
    try {
      final res = await app.forkAssistant(widget.sessionId!, target);
      if (!mounted) return;
      if (!_ackOk(res)) {
        _snack(
          '分支未创建（${res is Map ? res['reasonCode'] ?? res['status'] : 'rejected'}）',
        );
        return;
      }
      // sessionId 嵌套在 ack.result 下（command.ts:392-401/450-463，官方
      // 消费 ack.result.sessionId——对抗审查 A1：此前读顶层恒为空，
      // 分支永远打不开子会话还提示成功）。
      final result = res is Map ? res['result'] : null;
      final sid = result is Map ? '${result['sessionId'] ?? ''}' : '';
      if (sid.isNotEmpty) {
        unawaited(
          widget.openSession(
            context,
            sessionId: sid,
            title: '分支会话',
            readOnly: false,
          ),
        );
      } else {
        _snack('已从此处创建分支');
      }
    } catch (e) {
      if (mounted) _snack('分支失败：$e');
    } finally {
      _forking = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // H1（审计纪律）：conversationRowTargetSchema 的 entityId 必填——
    // 旧行缺 entityId 时只保留复制，协议按钮禁用。
    final canCommand =
        widget.sessionId != null &&
        '${widget.row['entityId'] ?? ''}'.trim().isNotEmpty;
    final feedback = _override ?? _rowFeedback;
    Widget ghost(
      IconData icon,
      String tooltip,
      VoidCallback? onTap, {
      Color? color,
    }) => SizedBox(
      width: 28,
      height: 28,
      child: IconButton(
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        iconSize: 15,
        tooltip: tooltip,
        color: color ?? context.colors.foregroundSubtlest,
        onPressed: onTap,
        icon: Icon(icon),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 目检修正（2026-10-23）：复制钮外套 28 紧盒（IconButton 内部
        // 密度会外扩致首间隙偏大 9dp）——四钮等距。
        SizedBox(
          width: 28,
          height: 28,
          child: CopyIconButton(
            text: (widget.copyText?.trim().isNotEmpty ?? false)
                ? widget.copyText!
                : '${widget.row['text'] ?? ''}',
            tooltip: tr('复制这条回复'),
            compact: true,
            iconSize: 14,
          ),
        ),
        ghost(
          feedback == 'like' ? Icons.thumb_up : Icons.thumb_up_outlined,
          feedback == 'like' ? '取消点赞' : '点赞',
          canCommand
              ? () => _sendFeedback(
                  AppStateScope.of(context),
                  feedback == 'like' ? null : 'like',
                )
              : null,
          color: feedback == 'like' ? context.colors.brandAccent : null,
        ),
        ghost(
          feedback == 'dislike' ? Icons.thumb_down : Icons.thumb_down_outlined,
          feedback == 'dislike' ? '取消点踩' : '点踩',
          canCommand
              ? () => _sendFeedback(
                  AppStateScope.of(context),
                  feedback == 'dislike' ? null : 'dislike',
                )
              : null,
          color: feedback == 'dislike' ? context.colors.brandAccent : null,
        ),
        ghost(
          Icons.account_tree_outlined,
          '从这里分支',
          canCommand ? () => _fork(AppStateScope.of(context)) : null,
        ),
        // 优化批 #27：行最右侧 subtle 时间标签（今天 HH:mm/今年 M月d日/
        // 往年 yyyy/M/d）——回看长会话时"这轮是什么时候"不再需要猜。
        // createdAtMs 缺席（旧快照/夹具）不显示；纯日期数字，en 走 tr
        // 日期形态自动转「Oct 5」。
        if (turnTailTimestampLabel(widget.createdAtMs) case final clock?)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Text(
              clock,
              style: TextStyle(
                fontSize: AppType.uiXs,
                color: context.colors.foregroundSubtlest,
              ),
            ),
          ),
      ],
    );
  }
}


class UserBubble extends StatelessWidget {
  final String text;
  final List<Map<String, dynamic>> attachments;
  final VoidCallback? onLongPress;

  /// 点按第 index 个附件（页面侧持行上下文构造官方 target）。
  final void Function(int index)? onAttachment;
  final bool searchReveal;

  /// 18077 验收#11（Bug H）：搜索激活时提问同享词级高亮（此前仅
  /// assistant 路径接入，提问命中只有行级定位效果）。
  final String? searchQuery;

  const UserBubble({
    required this.text,
    this.attachments = const [],
    this.onLongPress,
    this.onAttachment,
    this.searchReveal = false,
    this.searchQuery,
  });

  /// #12：SelectionArea 会吃掉长按（选词），行操作菜单难触达——
  /// 把「编辑重发/更多」注入系统选词菜单，两条路径都通。
  Widget _selectableText(BuildContext context, String data) {
    final menu = onLongPress;
    // 搜索激活：源文本直出+命中词底色高亮（对齐 assistant 预览路径
    // 的 buildSearchHighlightSpans，见 AssistantText.searchQuery）。
    final q = searchQuery;
    final child = (q != null && q.trim().isNotEmpty)
        ? Text.rich(
            key: const ValueKey('user-search-highlight'),
            TextSpan(
              children: buildSearchHighlightSpans(
                data,
                q,
                base: const TextStyle(
                  fontSize: AppType.uiBase,
                  height: 1.5,
                ),
                hit: TextStyle(
                  fontSize: AppType.uiBase,
                  height: 1.5,
                  backgroundColor: context.colors.brandAccent
                      .withValues(alpha: AppAlpha.mid),
                ),
              ),
            ),
            translate: false,
          )
        : Text(
            data,
            translate: false,
            style: const TextStyle(fontSize: AppType.uiBase, height: 1.5),
          );
    if (menu == null) {
      return SelectionArea(child: child);
    }
    return SelectionArea(
      contextMenuBuilder: (context, selectableRegion) {
        final items = [...selectableRegion.contextMenuButtonItems];
        items.add(
          ContextMenuButtonItem(
            label: '编辑/更多',
            onPressed: () {
              ContextMenuController.removeAny();
              menu();
            },
          ),
        );
        return AdaptiveTextSelectionToolbar.buttonItems(
          buttonItems: items,
          anchors: selectableRegion.contextMenuAnchors,
        );
      },
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 附件 chips 在气泡外上方（官方 ConversationRowView 布局）。
              // 官方行字段为 fileName（camelCase，attachment-ref.ts）；
              // filename 兜底兼容旧投影/测试夹具。
              for (var i = 0; i < attachments.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: InkWell(
                    key: ValueKey('attachment-${attachments[i]['ref']}'),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    onTap: () => onAttachment?.call(i),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: context.colors.card,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        border: Border.all(color: context.colors.border),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.attach_file,
                            size: 13,
                            color: context.colors.foregroundSubtle,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              '${attachments[i]['fileName'] ?? attachments[i]['filename']}',
                              translate: false,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: AppType.uiXs,
                                color: context.colors.foregroundSubtle,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              // #10：纯附件消息（空文本）不渲染空壳气泡。
              if (text.trim().isNotEmpty)
                // V2 审美优化：左缘 3px 品牌蓝竖条——「我的话」成为
                // 长会话滚动的视觉锚点（评审 2.2#1）。竖条为独立元素
                // （视觉验收 S03 实锤：多色 Border + borderRadius 触发
                // Flutter paint 断言「borders with uniform colors」）。
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 3,
                        margin: const EdgeInsets.only(left: 56),
                        decoration: BoxDecoration(
                          color: context.colors.brandAccent,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            // R 轮审美（2026-10-17 用户反馈"自己发的信息
                            // 不明显"）：品牌色 6% 浅底保辨识（surface 与
                            // 背景几乎同色）。描边对抗审查收敛 2026-10-22：
                            // 38% 是加竖条锚点之前的历史浓度，官方仅
                            // border(10%)——竖条在，描边降 15% 不丢辨识。
                            // 批4 拍板 a（2026-10-23 用户）：深色气泡改亮
                            // 于卡片一档（secondary #363636）——业界 11/11
                            // 全员做法+真镜像语义（浅色气泡暗于背景，翻转
                            // 后应亮于）；亮底后描边同步降档（15%→10% 白，
                            // 官方 border 档）防抢眼。浅色不动（红线）。
                            color:
                                Theme.of(context).brightness == Brightness.dark
                                ? context.colors.secondary
                                : context.colors.brand.withValues(alpha: 0.06),
                            border: Border.all(
                              color:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? context.colors.border
                                  : context.colors.foreground.withValues(
                                      alpha: 0.15,
                                    ),
                            ),
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(AppRadius.bubble),
                              topRight: Radius.circular(
                                AppRadius.bubbleTail,
                              ), // 官方 rounded-tr-xs
                              bottomLeft: Radius.circular(AppRadius.bubble),
                              bottomRight: Radius.circular(AppRadius.bubble),
                            ),
                          ),
                          child: FoldableUserText(
                            text: text,
                            selectable: (data) => _selectableText(context, data),
                            searchReveal: searchReveal,
                            searchQuery: searchQuery,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 用户长消息折叠（对抗审查 1a-3，2026-10-22；官方
/// ConversationUserInputBody:7-25 120px+渐隐+悬浮展开钮的手机化）：
/// 阈值 180dp（官方 120px≈桌面 5 行；手机行高更小，约 11 行起折——
/// 照搬 120dp 会把正常两三句追问也折了）；展开钮 ≥44px 触控（官方
/// size-4 悬浮钮对触屏过小）；内容变化重置回收起（官方 :48-50）。

class FoldableUserText extends StatefulWidget {
  final String text;
  final Widget Function(String) selectable;
  final bool searchReveal;

  /// 18077 验收#11：搜索词变化时缓存必须失效（高亮重建）。
  final String? searchQuery;

  const FoldableUserText({
    super.key,
    required this.text,
    required this.selectable,
    this.searchReveal = false,
    this.searchQuery,
  });

  @override
  State<FoldableUserText> createState() => FoldableUserTextState();
}

class FoldableUserTextState extends State<FoldableUserText> {
  bool _expanded = false;
  String _lastText = '';

  @override
  void didUpdateWidget(covariant FoldableUserText oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 内容变化（编辑重发）重置回收起——官方同款语义。
    if (widget.text != _lastText) {
      _lastText = widget.text;
      _expanded = false;
    }
  }

  static const _maxCollapsed = 180.0;

  /// 溢出判定（保守估算，不做布局测量——气泡在 IntrinsicHeight 内，
  /// LayoutBuilder/TextPainter 前置测量会触发 intrinsic 断言）：
  /// 行数与单段长度双折算，≈超过 8-9 行（180dp/21px 行高）才折叠，
  /// 正常两三句追问不受影响。
  bool get _overflows {
    final t = widget.text;
    if (t.isEmpty) return false;
    final nl = String.fromCharCode(10);
    final lines = nl.allMatches(t).length + 1;
    final byLen = (t.length / 20).ceil(); // 14px 字号 ~280dp 宽约 20 字/行
    final est = lines >= byLen ? lines : byLen;
    return est * 21 > _maxCollapsed;
  }

  @override
  Widget build(BuildContext context) {
    final overflows = _overflows;
    final expanded = _expanded || widget.searchReveal || !overflows;
    // 稳定行渲染缓存（优化批 #8）：文本与展开态未变时复用上次
    // SelectionArea/Text 实例（流式期间整列 rebuild 的稳定行短路）。
    final content = CachedContent(
      // P3-7（D-8 批4）：键掺亮度——浅↔深切换后搜索高亮 span 颜色
      // 沿旧主题（助手正文同款，用户气泡此前漏网）。
      cacheKey: [
        widget.text,
        expanded,
        widget.searchQuery,
        Theme.of(context).brightness,
      ],
      childBuilder: () => widget.selectable(widget.text),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (expanded)
          content
        else
          // 收起态：渐隐遮罩+底部悬浮圆钮（官方悬浮圆钮对位，44px 触达）。
          Stack(
            alignment: Alignment.bottomCenter,
            children: [
              ShaderMask(
                // 底部渐隐遮罩（官方 mask 70%-100% 线性渐变对位）。
                blendMode: BlendMode.dstIn,
                shaderCallback: (rect) => LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  // dstIn 只消费 alpha，色值取任意不透明 token（单源纪律）。
                  colors: [context.colors.card, Colors.transparent],
                  stops: [0.65, 1.0],
                ).createShader(rect),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: _maxCollapsed),
                  child: SingleChildScrollView(
                    physics: const NeverScrollableScrollPhysics(),
                    child: content,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Tooltip(
                  message: '展开全部',
                  child: InkWell(
                    key: const ValueKey('fold-expand'),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    onTap: () => setState(() => _expanded = true),
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: context.colors.card,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                        border: Border.all(color: context.colors.border),
                      ),
                      child: Icon(
                        Icons.expand_more,
                        size: 20,
                        color: context.colors.foregroundSubtle,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        if (overflows && _expanded)
          // 展开态：通栏收起条（官方 ConversationUserInputBody 通栏按钮
          // 对位——验收反馈原文字按钮"突兀"）。
          GestureDetector(
            key: const ValueKey('fold-collapse'),
            onTap: () => setState(() => _expanded = false),
            child: Container(
              width: double.infinity,
              height: 38,
              margin: const EdgeInsets.only(top: 6),
              decoration: BoxDecoration(
                color: context.colors.surface,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.expand_less,
                    size: 16,
                    color: context.colors.foregroundSubtlest,
                  ),
                  SizedBox(width: 4),
                  Text(
                    '收起',
                    style: TextStyle(
                      fontSize: AppType.uiCaption,
                      color: context.colors.foregroundSubtlest,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// 轮尾文件变更卡（官方 ConversationFileSummaryPanel 对位，F5 重做）：
/// 折叠头「N 个文件已更改 +A/-D」（reverted 态带「已撤销」标签并禁用撤销）；
/// 展开拉取明细（fileChanges，锚点修复后）平铺文件行；点行进查看器审查；
/// 「撤销」走整轮 rewind 预检（safe/unsafe/ignored 三计数）→ apply。

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/theme.dart';
import '../transport/conversation.dart';
import 'turn_model.dart';

const int conversationSearchRowLimit = 1200;

enum ConversationSearchKind { user, assistant, tool }

class ConversationSearchMatch {
  final int rowId;
  final int? turnId;
  final String anchorKey;
  final ConversationSearchKind kind;
  final int occurrence;
  final String sourceText;
  final int start;
  final int end;

  const ConversationSearchMatch({
    required this.rowId,
    required this.turnId,
    required this.anchorKey,
    required this.kind,
    required this.occurrence,
    required this.sourceText,
    required this.start,
    required this.end,
  });

  String get identity => '$rowId:${kind.name}:$occurrence';

  String get snippet {
    final from = math.max(0, start - 42);
    final to = math.min(sourceText.length, end + 72);
    final body = sourceText
        .substring(from, to)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return '${from > 0 ? '…' : ''}$body${to < sourceText.length ? '…' : ''}';
  }
}

String? _toolSearchText(Map<String, dynamic> row) {
  final parts = <String>[];
  final name = '${row['toolName'] ?? row['name'] ?? ''}'.trim();
  if (name.isNotEmpty) parts.add(name);
  final input = toolInputArgs(row);
  if (input != null) {
    parts.add(jsonEncode(input));
  } else {
    final raw = '${row['inputText'] ?? ''}'.trim();
    if (raw.isNotEmpty) parts.add(raw);
  }
  final error = row['error'];
  if (error is Map && '${error['message'] ?? ''}'.trim().isNotEmpty) {
    parts.add('${error['message']}'.trim());
  } else {
    final status = '${row['status'] ?? ''}';
    final running = status == 'running' || status == 'inputStreaming';
    var added = false;
    if (running) {
      final preview = row['outputPreview'];
      if (preview is Map && '${preview['fullText'] ?? ''}'.trim().isNotEmpty) {
        parts.add('${preview['fullText']}'.trim());
        added = true;
      }
    }
    if (!added) {
      final output = row['output'];
      if (output is Map) {
        final text = '${output['text'] ?? ''}'.trim();
        if (text.isNotEmpty) {
          parts.add(text);
          added = true;
        } else {
          final display = output['display'];
          if (display is Map && display['kind'] == 'bash_output') {
            final bash = '${display['output'] ?? ''}'.trim();
            if (bash.isNotEmpty) parts.add(bash);
          }
        }
      }
    }
  }
  if (parts.isEmpty) return null;
  return parts.join('\n');
}

String? _searchTextOf(Map<String, dynamic> row) => switch ('${row['kind']}') {
  'userInput' || 'assistantText' => '${row['text'] ?? ''}',
  'toolCall' => _toolSearchText(row),
  _ => null,
};

ConversationSearchKind? _searchKindOf(Map<String, dynamic> row) =>
    switch ('${row['kind']}') {
      'userInput' => ConversationSearchKind.user,
      'assistantText' => ConversationSearchKind.assistant,
      'toolCall' => ConversationSearchKind.tool,
      _ => null,
    };

/// 主会话的提问/回复加上用户明确要求的工具内容；思考与内部标记不索引。
/// 匹配规则与官方一致：trim、大小写不敏感、字面子串、同一行内非重叠计数。
List<ConversationSearchMatch> buildConversationSearchMatches(
  List<ChatItem> items,
  String query,
) {
  // B2-P2-4/D2-08：长度稳定折叠——İ 等扩长字符会使折叠串
  // 下标漂移（snippet 切原串错位/极端越界），命中下标必须落在原串
  // 坐标系（与 buildSearchHighlightSpans 同源 foldCaseStable）。
  final needle = foldCaseStable(query.trim());
  if (needle.isEmpty) return const [];
  final matches = <ConversationSearchMatch>[];
  for (var index = 0; index < items.length; index++) {
    final item = items[index];
    final anchorKey = chatItemKey(item, index);
    final rows = switch (item) {
      UserItem(:final row) => [row],
      TurnBarItem(:final work) => work.work,
      _ => const <Map<String, dynamic>>[],
    };
    final turnId = item is TurnBarItem
        ? (item.work.header?['rowId'] as num?)?.toInt()
        : null;
    for (final row in rows) {
      final rowId = (row['rowId'] as num?)?.toInt();
      final kind = _searchKindOf(row);
      final source = _searchTextOf(row);
      if (rowId == null || rowId < 0 || kind == null || source == null) {
        continue;
      }
      final haystack = foldCaseStable(source);
      var occurrence = 0;
      var from = 0;
      while (from <= haystack.length - needle.length) {
        final start = haystack.indexOf(needle, from);
        if (start < 0) break;
        matches.add(
          ConversationSearchMatch(
            rowId: rowId,
            turnId: turnId,
            anchorKey: anchorKey,
            kind: kind,
            occurrence: occurrence,
            sourceText: source,
            start: start,
            end: start + needle.length,
          ),
        );
        occurrence++;
        from = start + needle.length;
      }
    }
  }
  return matches;
}

int reanchorConversationSearchMatch(
  List<ConversationSearchMatch> matches,
  String? previousIdentity,
  int fallbackIndex,
) {
  if (matches.isEmpty) return -1;
  if (previousIdentity != null) {
    final found = matches.indexWhere((m) => m.identity == previousIdentity);
    if (found >= 0) return found;
  }
  return fallbackIndex.clamp(0, matches.length - 1);
}

class ConversationSearchCloseResult {
  final ConversationSearchMatch? activeMatch;
  const ConversationSearchCloseResult(this.activeMatch);
}

/// 会话内搜索控制链。滚动与可见性定位由页面通过 onLocate/onAnchorMigrate
/// 完成；本类不 import 会话页，也不持有 ScrollController。
class ConversationSearchController {
  ConversationSearchController({
    required ConversationState? Function() stateProvider,
    required List<ChatItem> Function(ConversationState state) itemsProvider,
    required Future<bool> Function() loadOlder,
    required bool Function() isAlive,
    required void Function() onNotify,
    required Future<void> Function(ConversationSearchMatch match) onLocate,
    required void Function(String previousAnchor, String currentAnchor)
    onAnchorMigrate,
  }) : _stateProvider = stateProvider,
       _itemsProvider = itemsProvider,
       _loadOlder = loadOlder,
       _isAlive = isAlive,
       _onNotify = onNotify,
       _onLocate = onLocate,
       _onAnchorMigrate = onAnchorMigrate;

  final ConversationState? Function() _stateProvider;
  final List<ChatItem> Function(ConversationState state) _itemsProvider;
  final Future<bool> Function() _loadOlder;
  final bool Function() _isAlive;
  final void Function() _onNotify;
  final Future<void> Function(ConversationSearchMatch match) _onLocate;
  final void Function(String previousAnchor, String currentAnchor)
  _onAnchorMigrate;

  final controller = TextEditingController();
  final focusNode = FocusNode();
  bool isOpen = false;
  bool loading = false;
  bool truncated = false;
  bool stalled = false;
  String? error;
  List<ConversationSearchMatch> matches = const [];
  int activeIndex = -1;
  int navigationId = 0;
  String? locatedIdentity;
  bool _historyPumping = false;
  bool _disposed = false;

  String get query => controller.text;
  ConversationSearchMatch? get activeMatch =>
      activeIndex >= 0 && activeIndex < matches.length
      ? matches[activeIndex]
      : null;

  void open() {
    if (_disposed || _stateProvider() == null) return;
    isOpen = true;
    error = null;
    refresh(reset: true);
    _onNotify();
    final active = activeMatch;
    if (active != null) _locate(active);
    unawaited(pumpHistory());
  }

  ConversationSearchCloseResult close() {
    navigationId++;
    focusNode.unfocus();
    final result = ConversationSearchCloseResult(activeMatch);
    isOpen = false;
    loading = false;
    truncated = false;
    stalled = false;
    error = null;
    matches = const [];
    activeIndex = -1;
    locatedIdentity = null;
    controller.clear();
    _onNotify();
    return result;
  }

  void refresh({bool reset = false}) {
    final state = _stateProvider();
    if (state == null || _disposed) return;
    final previous = activeMatch?.identity;
    final previousAnchor = activeMatch?.anchorKey;
    matches = buildConversationSearchMatches(
      _itemsProvider(state),
      controller.text,
    );
    activeIndex = reset
        ? (matches.isEmpty ? -1 : 0)
        : reanchorConversationSearchMatch(
            matches,
            previous,
            activeIndex < 0 ? 0 : activeIndex,
          );
    truncated = state.rows.length >= conversationSearchRowLimit && state.canLoadOlder;
    final currentAnchor = activeMatch?.anchorKey;
    if (previousAnchor != null &&
        currentAnchor != null &&
        previousAnchor != currentAnchor) {
      _onAnchorMigrate(previousAnchor, currentAnchor);
    }
  }

  void change(String _) {
    navigationId++;
    locatedIdentity = null;
    error = null;
    stalled = false;
    refresh(reset: true);
    _onNotify();
    final active = activeMatch;
    if (active != null) _locate(active);
    unawaited(pumpHistory());
  }

  void step(int direction) {
    if (matches.isEmpty) return;
    final count = matches.length;
    activeIndex = direction > 0
        ? (activeIndex + 1) % count
        : (activeIndex <= 0 ? count - 1 : activeIndex - 1);
    _onNotify();
    final active = activeMatch;
    if (active != null) _locate(active);
  }

  void cancelNavigation() {
    navigationId++;
  }

  void retry() {
    error = null;
    unawaited(pumpHistory());
  }

  /// 定位实际开始（页面守卫通过后）才标记已定位——先标记会让
  /// pumpHistory 的补定位条件（locatedIdentity==null）永久失效
  ///（独立复核低 1：列表未挂载时首个命中不再自动滚入）。
  void markLocated(ConversationSearchMatch match) {
    locatedIdentity = match.identity;
  }

  void _locate(ConversationSearchMatch match) {
    unawaited(_onLocate(match));
  }

  Future<void> pumpHistory() async {
    if (_historyPumping || !isOpen || _disposed) return;
    final query = controller.text.trim();
    if (query.isEmpty) return;
    final initial = _stateProvider();
    if (initial == null ||
        !initial.canLoadOlder ||
        initial.rows.length >= conversationSearchRowLimit ||
        initial.phase == 'running' ||
        initial.phase == 'prewarming') {
      return;
    }
    _historyPumping = true;
    if (_isAlive()) {
      loading = true;
      error = null;
      _onNotify();
    }
    try {
      while (_isAlive() && isOpen && controller.text.trim() == query) {
        final state = _stateProvider();
        if (state == null ||
            !state.canLoadOlder ||
            state.rows.length >= conversationSearchRowLimit ||
            state.phase == 'running' ||
            state.phase == 'prewarming') {
          break;
        }
        final progressed = await _loadOlder();
        if (!_isAlive() || controller.text.trim() != query) break;
        refresh();
        if (!progressed) {
          if (_stateProvider()?.canLoadOlder == true) stalled = true;
          break;
        }
        final active = activeMatch;
        if (active != null && locatedIdentity == null) _locate(active);
      }
    } catch (caught) {
      if (_isAlive() && isOpen && controller.text.trim() == query) {
        error = '$caught';
      }
    } finally {
      _historyPumping = false;
      if (_isAlive()) {
        loading = false;
        refresh();
        _onNotify();
        if (isOpen && controller.text.trim() != query) {
          unawaited(pumpHistory());
        }
      }
    }
  }

  String? get partialNotice {
    if (!isOpen || loading || truncated || error != null) return null;
    final state = _stateProvider();
    if (state?.canLoadOlder != true) return null;
    if (state!.phase == 'running' || state.phase == 'prewarming') {
      return tr('当前仅搜索已加载内容，运行结束后自动补查更早消息');
    }
    if (stalled) return tr('更早历史暂时不可用，当前仅显示已加载范围');
    return null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    navigationId++;
    controller.dispose();
    focusNode.dispose();
  }
}

class ConversationSearchBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String query;
  final List<ConversationSearchMatch> matches;
  final int activeIndex;
  final bool loading;
  final bool truncated;
  final String? error;
  final String? partialNotice;
  final ValueChanged<String> onChanged;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onClose;
  final VoidCallback onRetry;

  const ConversationSearchBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.query,
    required this.matches,
    required this.activeIndex,
    required this.loading,
    required this.truncated,
    required this.error,
    this.partialNotice,
    required this.onChanged,
    required this.onPrevious,
    required this.onNext,
    required this.onClose,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final hasQuery = query.trim().isNotEmpty;
    final active = activeIndex >= 0 && activeIndex < matches.length
        ? matches[activeIndex]
        : null;
    final kindLabel = switch (active?.kind) {
      ConversationSearchKind.user => '提问',
      ConversationSearchKind.assistant => 'AI 回复',
      ConversationSearchKind.tool => '工具',
      null => '',
    };
    return Material(
      key: const ValueKey('conversation-search-bar'),
      color: context.colors.header,
      child: Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: context.colors.border)),
        ),
        padding: const EdgeInsets.fromLTRB(8, 4, 4, 5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('conversation-search-input'),
                    controller: controller,
                    focusNode: focusNode,
                    autofocus: true,
                    onChanged: onChanged,
                    onSubmitted: (_) => onNext(),
                    textInputAction: TextInputAction.search,
                    style: const TextStyle(fontSize: AppType.mobileInputSafe),
                    decoration: InputDecoration(
                      hintText: tr('搜索消息和工具'),
                      isDense: true,
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 12,
                      ),
                    ),
                  ),
                ),
                if (hasQuery)
                  Text(
                    activeIndex < 0
                        ? '0/${matches.length}'
                        : '${activeIndex + 1}/${matches.length}',
                    key: const ValueKey('conversation-search-count'),
                    style: TextStyle(
                      fontSize: AppType.uiCaption,
                      color: context.colors.foregroundSubtle,
                    ),
                  ),
                // 18077 审美门建议②：可见图形放大（arrow 图形稀疏视觉
                // 偏小——28/24 进 40dp 可见档；隐性触控面 48 不变）。
                IconButton(
                  key: const ValueKey('conversation-search-previous'),
                  onPressed: matches.isEmpty ? null : onPrevious,
                  icon: const Icon(Icons.keyboard_arrow_up, size: 28),
                  tooltip: tr('上一个匹配项'),
                ),
                IconButton(
                  key: const ValueKey('conversation-search-next'),
                  onPressed: matches.isEmpty ? null : onNext,
                  icon: const Icon(Icons.keyboard_arrow_down, size: 28),
                  tooltip: tr('下一个匹配项'),
                ),
                IconButton(
                  key: const ValueKey('conversation-search-close'),
                  onPressed: onClose,
                  icon: const Icon(Icons.close, size: 24),
                  tooltip: tr('关闭'),
                ),
              ],
            ),
            if (active != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      kindLabel,
                      style: TextStyle(
                        fontSize: AppType.uiXs,
                        fontWeight: FontWeight.w600,
                        // 18077 验收#11（I）：accent 深色档=近黑深藏青
                        // （0xFF001D3D）叠深色 header 上几乎不可见——
                        // 改品牌蓝（浅 #134CFF/深 #4099FF，两档可读）。
                        color: context.colors.brandAccent,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        active.snippet,
                        key: const ValueKey('conversation-search-snippet'),
                        translate: false,
                        maxLines: 2,
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
            if (loading ||
                truncated ||
                error != null ||
                partialNotice != null ||
                (hasQuery && matches.isEmpty))
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 2),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: error != null
                      ? TextButton.icon(
                          key: const ValueKey('conversation-search-retry'),
                          onPressed: onRetry,
                          icon: const Icon(Icons.refresh, size: 16),
                          label: const Text('历史加载失败，点按重试'),
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 48),
                            tapTargetSize: MaterialTapTargetSize.padded,
                          ),
                        )
                      : Text(
                          loading
                              ? '正在加载更早消息…'
                              : truncated
                              ? '已搜索最近 $conversationSearchRowLimit 行，更早内容未纳入'
                              : partialNotice ?? '没有匹配结果',
                          style: TextStyle(
                            fontSize: AppType.uiXs,
                            color: context.colors.foregroundSubtle,
                          ),
                        ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

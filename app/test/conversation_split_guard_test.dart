import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  test('turn_model 纯投影不依赖 Flutter Widget，页面不留已迁实现', () {
    final model = _read('lib/ui/turn_model.dart');
    final page = _read('lib/ui/conversation_page.dart');
    expect(model.contains("package:flutter/material.dart"), isFalse);
    expect(model.contains("package:flutter/widgets.dart"), isFalse);
    for (final symbol in [
      'sealed class WorkUnit',
      'class RowUnit',
      'class GroupUnit',
      'class SubagentPairUnit',
      'List<WorkUnit> buildWorkUnits(',
      'String? turnTailTimestampLabel(',
      'int? turnHeaderCreatedAt(',
    ]) {
      expect(model.contains(symbol), isTrue, reason: symbol);
    }
    expect(page.contains('sealed class WorkUnit'), isFalse);
    expect(page.contains('class RowUnit'), isFalse);
    expect(page.contains('List<WorkUnit> _buildWorkUnits('), isFalse);
    expect(page.contains('String? turnTailTimestampLabel('), isFalse);
    expect(page.contains('int? turnHeaderCreatedAt('), isFalse);
    expect(page.contains("import 'turn_model.dart'"), isTrue);
    expect(
      _read('lib/ui/conversation_turn_view.dart').contains('buildWorkUnits('),
      isTrue,
    );
  });

  test('会话页与纯投影不使用 part/part of', () {
    for (final path in [
      'lib/ui/conversation_page.dart',
      'lib/ui/turn_model.dart',
      'lib/ui/conversation_composer.dart',
      'lib/ui/conversation_composer_meta.dart',
      'lib/ui/conversation_queue_strip.dart',
      'lib/ui/conversation_message_cells.dart',
      'lib/ui/conversation_tool_tiles.dart',
      'lib/ui/conversation_file_summary_card.dart',
      'lib/ui/conversation_turn_view.dart',
      'lib/ui/conversation_view_store.dart',
      'lib/ui/conversation_session_opener.dart',
      'lib/ui/subagent_list_sheet.dart',
      'lib/state/send_queue_controller.dart',
    ]) {
      final source = _read(path);
      expect(RegExp(r'^\s*part\s+', multiLine: true).hasMatch(source), isFalse,
          reason: path);
    }
  });

  test('七个展示组件文件真实接入，新组件不反向依赖会话页', () {
    final page = _read('lib/ui/conversation_page.dart');
    final files = [
      'lib/ui/conversation_composer.dart',
      'lib/ui/conversation_composer_meta.dart',
      'lib/ui/conversation_queue_strip.dart',
      'lib/ui/conversation_message_cells.dart',
      'lib/ui/conversation_tool_tiles.dart',
      'lib/ui/conversation_file_summary_card.dart',
      'lib/ui/conversation_turn_view.dart',
    ];
    for (final path in files) {
      final source = _read(path);
      expect(source.contains('conversation_page.dart'), isFalse, reason: path);
      expect(source.contains('_ConversationPageState'), isFalse, reason: path);
      expect(source.trim().length, greaterThan(100), reason: path);
    }
    for (final old in [
      'class _InputBar',
      'class _ToolbarPill',
      'class _ContextDetailsCard',
      'class _QueueStrip',
      'class _SearchTargetFrame',
      'class _AssistantText',
      'class _TurnTailActions',
      'class _UserBubble',
      'class _ToolCallTile',
      'class _FileSummaryCard',
      'class _TurnBar',
      'class _ReasoningTile',
      'class _ToolGroupTile',
      'class _SubagentTile',
      'class _ReadOnlyBar',
      'class _ContextUsageRing',
      'class _AddAction',
      'class _InfoRow',
      'class _TodoTile',
      'class _ToolProgressLine',
      'class _PlanModeCard',
      'class _PlanModeDetailPage',
      'class _OutputViewport',
    ]) {
      expect(page.contains(old), isFalse, reason: old);
    }
    for (final symbol in [
      'InputBar(',
      'ContextDetailsCard(',
      'QueueStrip(',
      'UserBubble(',
      'FileSummaryCard(',
      'TurnBar(',
      'OfflineSendQueueStrip(',
    ]) {
      expect(page.contains(symbol), isTrue, reason: symbol);
    }
    expect(
      _read('lib/ui/conversation_turn_view.dart')
          .contains("import 'conversation_tool_tiles.dart'"),
      isTrue,
    );
    expect(
      _read('lib/ui/conversation_turn_view.dart').contains('ToolCallTile('),
      isTrue,
    );
  });

  test('搜索、离线队列与 ViewStore 是页面唯一控制状态源', () {
    final page = _read('lib/ui/conversation_page.dart');
    expect(page.contains('ConversationSearchController('), isTrue);
    expect(page.contains('OfflineSendQueueController('), isTrue);
    expect(page.contains('ConversationViewStore()'), isTrue);
    expect(page.contains('bool _searchOpen ='), isFalse);
    expect(page.contains('List<SendQueueEntry> _queueEntries ='), isFalse);
    expect(page.contains('final Map<int, bool> _liveCollapsedByRow ='), isFalse);
    expect(page.contains('final Map<int, DateTime> _reasoningFirstSeen ='),
        isFalse);
    expect(
      _read('lib/state/send_queue_controller.dart')
          .contains('conversation_page.dart'),
      isFalse,
    );
    expect(
      _read('lib/ui/subagent_list_sheet.dart')
          .contains('conversation_page.dart'),
      isFalse,
    );
  });
}

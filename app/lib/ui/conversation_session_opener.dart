import 'package:flutter/material.dart';

/// 跨页面打开会话的唯一注入端口；具体 Route、标题和 readOnly 语义由页面决定。
typedef ConversationSessionOpener =
    Future<void> Function(
      BuildContext context, {
      required String sessionId,
      required String title,
      required bool readOnly,
    });

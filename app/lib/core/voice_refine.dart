import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';


/// 语音口语整理（ 决策 5；2026-10-19 扩展为多提供商）：
/// 听写文本 → 用户自己的 API key 调所选平台的快速档模型 → 相对规范的
/// 指令。无 key/失败/超时一律退回原文，不影响主流程；整理步骤可整体
/// 关闭（uiPrefs.voiceRefineEnabled）。
///
/// 三家都是 OpenAI 兼容的 chat/completions 协议，差别只在域名与模型名。
/// 端点/模型核对来源（2026-10-19）：api-docs.deepseek.com、
/// platform.kimi.ai/docs/api/chat（国内域名 api.moonshot.cn，注意国内/
/// 国际平台的 key 不互通）。

class VoiceRefineProvider {
  final String id;
  final String label;
  final String endpoint;
  final String model;
  final String keyHint;
  final String note;
  const VoiceRefineProvider({
    required this.id,
    required this.label,
    required this.endpoint,
    required this.model,
    required this.keyHint,
    required this.note,
  });
}

const voiceRefineProviders = <VoiceRefineProvider>[
  VoiceRefineProvider(
    id: 'zhipu',
    label: '智谱',
    endpoint: 'https://open.bigmodel.cn/api/paas/v4/chat/completions',
    model: 'glm-4-flash', // 免费档
    keyHint: 'open.bigmodel.cn 的 API key',
    note: '免费档模型',
  ),
  VoiceRefineProvider(
    id: 'deepseek',
    label: 'DeepSeek',
    endpoint: 'https://api.deepseek.com/chat/completions',
    model: 'deepseek-chat', // 别名=当前标准版
    keyHint: 'platform.deepseek.com 的 API key',
    note: '按量计费（极便宜）',
  ),
  VoiceRefineProvider(
    id: 'kimi',
    label: 'Kimi',
    endpoint: 'https://api.moonshot.cn/v1/chat/completions',
    model: 'kimi-latest', // 别名=最新版
    keyHint: 'platform.moonshot.cn 的 API key（国内站）',
    note: '按量计费（极便宜）',
  ),
];

/// 提供商解析（未知/空 → 智谱默认，兼容只填过 key 的老配置）。
VoiceRefineProvider voiceRefineProviderOf(String? id) {
  for (final p in voiceRefineProviders) {
    if (p.id == id) return p;
  }
  return voiceRefineProviders.first;
}

void _log(String line) => debugPrint('[voice] $line');

/// 测试缝：覆盖请求端点（null=用提供商表）——假服务器红绿专用。
@visibleForTesting
String? debugRefineEndpointOverride;

/// 测试缝：覆盖 body 读取超时（null=用生产值 [_bodyReadTimeout]）。
@visibleForTesting
Duration? debugBodyReadTimeout;

/// body 读取超时（四路同报）：
/// connectionTimeout/postUrl/close 三级超时只覆盖连接与响应头，body
/// `.join()` 无界——弱网/劣化代理下服务端发完头后 body 停滞时，语音面板
/// refining 态 PopScope canPop=false（voice_input_sheet.dart）会把用户锁死
/// 在面板内只能杀 app。取 20s：需容纳 max_tokens=512 补全的正常传输，
/// 与响应头 12s 分档。
const _bodyReadTimeout = Duration(seconds: 20);

Future<String> refineDictation({
  required String? apiKey,
  required String raw,
  String? providerId,
}) async {
  final key = apiKey?.trim() ?? '';
  if (key.isEmpty || raw.trim().isEmpty) {
    _log('refine skipped: key/文本为空（key=${key.isEmpty ? "空" : "有"}, '
        'raw=${raw.trim().isEmpty ? "空" : "有"}）');
    return raw;
  }
  final provider = voiceRefineProviderOf(providerId);
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5);
  try {
    final req = await client
        .postUrl(Uri.parse(debugRefineEndpointOverride ?? provider.endpoint))
        .timeout(const Duration(seconds: 8));
    req.headers.set('Authorization', 'Bearer $key');
    req.headers.contentType = ContentType.json;
    req.write(
      jsonEncode({
        'model': provider.model,
        'temperature': 0.2,
        'max_tokens': 512,
        'messages': [
          {
            // 场景化系统提示词（2026-10-20 用户提议：明确告知模型这是
            // 口语语音转写、目标是改写成规范提示词，而非泛泛"整理"）。
            'role': 'system',
            'content': '你是手机端编程助手（ZCode）的语音输入整理器。'
                '用户输入是对着手机说话的口语转写：常带语气词、口语赘词、'
                '碎句和同音错别字。你的任务：把它改写成一条规范、清晰、'
                '可直接执行的中文指令——也就是给编程助手的提示词。规则：'
                '保留原意与全部细节（文件名、路径、数字、代码名、英文'
                '术语一律原样保留）；删去语气词与赘词，修正明显错别字；'
                '可补全省略的句子成分，但不得添加原意之外的任何内容；'
                '不解释、不加引号、不用 Markdown 修饰、不换行分段，'
                '直接输出改写后的这一条指令。',
          },
          {'role': 'user', 'content': raw},
        ],
      }),
    );
    final res = await req.close().timeout(const Duration(seconds: 12));
    final bodyTimeout = debugBodyReadTimeout ?? _bodyReadTimeout;
    if (res.statusCode != 200) {
      final body = await res
          .transform(utf8.decoder)
          .join()
          .timeout(bodyTimeout);
      _log('refine http ${res.statusCode} (${provider.model}): '
          '${body.length > 200 ? body.substring(0, 200) : body}');
      return raw;
    }
    final body = await res
        .transform(utf8.decoder)
        .join()
        .timeout(bodyTimeout);
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      final choices = decoded['choices'];
      if (choices is List && choices.isNotEmpty) {
        final msg = choices.first is Map ? choices.first['message'] : null;
        final content = msg is Map ? msg['content'] : null;
        if (content is String && content.trim().isNotEmpty) {
          _log('refine ok (${provider.model})');
          return content.trim();
        }
      }
    }
    _log('refine 响应无可解析内容');
    return raw;
  } catch (e) {
    _log('refine failed (${voiceRefineProviderOf(providerId).model}): $e');
    return raw; // 失败退回原文（决策 5 判定）
  } finally {
    client.close();
  }
}

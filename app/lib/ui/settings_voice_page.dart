import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';

import '../core/theme.dart';
import '../core/voice_refine.dart';
import '../state/app_state_scope.dart';

/// 语音输入子页（ADR 0028，2026-10-20）：口语自动整理开关 + 整理服务
/// 提供商选择 + API key 对话框——三项原样自 settings_page 一级页迁入
/// （文案/存储 key/控件行为不变）。子页骨架同 notify_ledger_page。
class SettingsVoicePage extends StatelessWidget {
  const SettingsVoicePage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        title: const Text('语音输入', style: TextStyle(fontSize: AppType.uiLg)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: context.colors.border),
        ),
      ),
      body: ListenableBuilder(
        listenable: app.uiPrefs,
        builder: (context, _) => ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            SwitchListTile(
              value: app.uiPrefs.voiceRefineEnabled,
              onChanged: (v) => app.uiPrefs.setVoiceRefineEnabled(v),
              title: const Text(
                '口语自动整理',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: Text(
                (app.uiPrefs.voiceApiKey ?? '').trim().isEmpty
                    ? '听写直接进输入框（填 API key 后可把口语整理成规范指令）'
                    : '听写后自动整理成规范指令，可一键回退原文',
                style: const TextStyle(fontSize: AppType.uiCaption),
              ),
            ),
            // 整理提供商（2026-10-19 多提供商：智谱/DeepSeek/Kimi——同一
            // 套 OpenAI 兼容协议，端点/模型见 voice_refine.dart）。
            ListTile(
              leading: const Icon(Icons.dns_outlined, size: 20),
              title: const Text(
                '整理服务提供商',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: Text(
                '${voiceRefineProviderOf(app.uiPrefs.voiceApiProvider).label}'
                '（${voiceRefineProviderOf(app.uiPrefs.voiceApiProvider).note}）',
                style: const TextStyle(fontSize: AppType.uiCaption),
              ),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () async {
                final picked = await showDialog<String>(
                  context: context,
                  builder: (dialogContext) => SimpleDialog(
                    title: const Text('整理服务提供商'),
                    children: [
                      for (final p in voiceRefineProviders)
                        RadioListTile<String>(
                          key: ValueKey('voice-provider-${p.id}'),
                          value: p.id,
                          groupValue: app.uiPrefs.voiceApiProvider,
                          title: Text('${p.label}（${p.model}）'),
                          subtitle: Text(
                            p.keyHint,
                            style: TextStyle(
                              fontSize: AppType.uiXs,
                              color: context.colors.foregroundSubtle,
                            ),
                          ),
                          onChanged: (v) => Navigator.pop(dialogContext, v),
                        ),
                    ],
                  ),
                );
                if (picked != null) {
                  final oldKey = (app.uiPrefs.voiceApiKey ?? '').trim();
                  await app.uiPrefs.setVoiceApiProvider(picked);
                  // 开源审查 M1 P3-9：key 是全局单键（ui.voiceApiKey）跨
                  // 提供商共用——切换后旧 key 会被提交给新端点（401→整理
                  // 静默回退原文，开关看起来像坏了）。提醒更新；不自动清
                  // 空防误触切换丢 key。
                  if (oldKey.isNotEmpty && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('已切换提供商——API key 不通用，请更新为新平台的 key'),
                        duration: Duration(seconds: 4),
                      ),
                    );
                  }
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.key_outlined, size: 20),
              title: Text(
                '${voiceRefineProviderOf(app.uiPrefs.voiceApiProvider).label} API key（整理用）',
                style: const TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: Text(
                (app.uiPrefs.voiceApiKey ?? '').trim().isEmpty
                    ? '未设置——整理步骤将跳过'
                    : '已设置（key 仅存本机）',
                style: const TextStyle(fontSize: AppType.uiCaption),
              ),
              trailing: const Icon(Icons.edit_outlined, size: 16),
              onTap: () async {
                final provider = voiceRefineProviderOf(
                  app.uiPrefs.voiceApiProvider,
                );
                final controller = TextEditingController(
                  text: app.uiPrefs.voiceApiKey ?? '',
                );
                final value = await showDialog<String>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    title: Text('${provider.label} API key'),
                    content: TextField(
                      key: const ValueKey('voice-api-key-input'),
                      controller: controller,
                      obscureText: true,
                      decoration: InputDecoration(hintText: provider.keyHint),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () =>
                            Navigator.pop(dialogContext, controller.text),
                        child: const Text('保存'),
                      ),
                    ],
                  ),
                );
                // 开源审查 M1 P3-3：延迟到退场动画后释放（pop 瞬间 dispose
                // 会在动画期编辑事件触发写断言）。
                Future.delayed(
                  const Duration(milliseconds: 400),
                  controller.dispose,
                );
                if (value != null) {
                  await app.uiPrefs.setVoiceApiKey(value);
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

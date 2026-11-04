import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/voice_refine.dart';

void main() {
  group('语音整理提供商表（2026-10-19 多提供商）', () {
    test('三家端点互不相同且协议路径正确', () {
      expect(voiceRefineProviders.length, 3);
      final endpoints = voiceRefineProviders.map((p) => p.endpoint).toSet();
      expect(endpoints.length, 3, reason: '端点不得重复');
      for (final p in voiceRefineProviders) {
        expect(p.endpoint, endsWith('/chat/completions'),
            reason: '${p.label} 端点必须是 OpenAI 兼容 chat/completions');
        expect(p.model, isNotEmpty);
        expect(p.keyHint, isNotEmpty);
      }
    });

    test('解析：已知 id 命中', () {
      expect(voiceRefineProviderOf('zhipu').model, 'glm-4-flash');
      expect(voiceRefineProviderOf('deepseek').endpoint,
          'https://api.deepseek.com/chat/completions');
      expect(voiceRefineProviderOf('kimi').model, 'kimi-latest');
    });

    test('解析：空/未知 id 回落智谱（兼容只填过 key 的老配置）', () {
      expect(voiceRefineProviderOf(null).id, 'zhipu');
      expect(voiceRefineProviderOf('').id, 'zhipu');
      expect(voiceRefineProviderOf('openai?').id, 'zhipu');
    });

    test('无 key/空文本不发起请求直接退回原文', () async {
      expect(await refineDictation(apiKey: null, raw: '帮我看下日志'), '帮我看下日志');
      expect(await refineDictation(apiKey: '  ', raw: '帮我看下日志'), '帮我看下日志');
      expect(await refineDictation(apiKey: 'sk-x', raw: '   '), '   ');
    });

    // 开源审查 D1-P2-3/D2-P2-03/D3-P2-2/P3-P2-4（四路同报）：连接/
    // 响应头三级超时只覆盖到 headers，body `.join()` 无界——弱网/劣化
    // 代理下服务端发完头后 body 停滞时，语音面板 refining 态 PopScope
    // canPop=false 锁死只能杀 app。修复=body 读取纳入超时。
    test('响应 body 停滞按超时失败退回原文（修复前=无界挂死）', () async {
      // 假服务器：响应头+半截 body 先上线，剩余 body 永不落、连接不关
      //（弱网/劣化代理的半挂形态——头到了 body 停滞）。
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        await request.drain<void>();
        request.response.statusCode = 200;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"choices":'); // 头随首写上线
        await request.response.flush();
      });
      debugRefineEndpointOverride =
          'http://127.0.0.1:${server.port}/chat/completions';
      debugBodyReadTimeout = const Duration(milliseconds: 300);
      addTearDown(() {
        debugRefineEndpointOverride = null;
        debugBodyReadTimeout = null;
      });
      final sw = Stopwatch()..start();
      final out = await refineDictation(apiKey: 'sk-x', raw: '帮我看下日志');
      expect(out, '帮我看下日志', reason: '超时必须退回原文（决策 5 判定）');
      expect(
        sw.elapsed.inSeconds,
        lessThan(5),
        reason: 'body 停滞不得无界等待——修复前 join() 永不完成',
      );
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}

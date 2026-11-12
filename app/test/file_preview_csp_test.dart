// 生成网页预览 CSP 外发面收紧：
// 资源域从任意 `https:` 收窄到官方 visualize 页同一份 CDN 白名单
// （官方 3.17.1 源码快照 visualize/SKILL.md），并补 base-uri/form-action/
// object-src 关死；img-src 不再给任意 https 域留 beacon 外带通道。
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/ui/file_preview.dart';

void main() {
  test('CSP 关死外发与 <base>/表单/插件通道', () {
    final injected = injectPreviewCsp(
      '<html><head><title>x</title></head><body>y</body></html>',
    );
    expect(injected, contains("connect-src 'none'"));
    expect(injected, contains("base-uri 'none'"),
        reason: '防 <base> 劫持相对 URL 把资源引向任意域');
    expect(injected, contains("form-action 'none'"),
        reason: '防表单外发');
    expect(injected, contains("object-src 'none'"),
        reason: '插件对象通道关死');
  });

  test('资源域=官方 visualize CDN 白名单，不再放行任意 https', () {
    final injected = injectPreviewCsp('<html><head></head><body></body></html>');
    for (final host in const [
      'https://cdnjs.cloudflare.com',
      'https://esm.sh',
      'https://cdn.jsdelivr.net',
      'https://unpkg.com',
      'https://fonts.googleapis.com',
      'https://fonts.gstatic.com',
      'https://fonts.bunny.net',
      'https://zcode.z.ai',
    ]) {
      expect(injected, contains(host), reason: '官方 visualize 资源域保留');
    }
    expect(injected, contains("img-src data: blob: https://cdnjs.cloudflare.com"),
        reason: 'img-src 仅保留 data/blob + 官方 CDN（不再任意 https 外带）');
    expect(injected.contains("img-src https:"), isFalse);
    expect(injected.contains("script-src 'unsafe-inline' https:;"), isFalse);
    expect(injected.contains("connect-src 'none'"), isTrue);
  });

  test('无 <head> 时骨架内注入同样带新指令', () {
    final injected = injectPreviewCsp('<h1>x</h1>');
    expect(injected, contains("object-src 'none'"));
    expect(injected.indexOf('Content-Security-Policy'),
        lessThan(injected.indexOf('<body>')));
  });
}

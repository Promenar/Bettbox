import 'package:bett_box/xboard/binding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('rewriteHost（F-DOMAIN-5 订阅 URL host 热替换）', () {
    final base = Uri.parse('https://new.panel.example.com:8443');

    test('host/port/scheme 变化时替换并保留路径查询', () {
      final old = Uri.parse('https://old.panel.example.com:7001/api/v1/client/subscribe?token=abc');
      final rewritten = rewriteHost(old, base);
      expect(
        rewritten.toString(),
        'https://new.panel.example.com:8443/api/v1/client/subscribe?token=abc',
      );
    });

    test('host 一致时原样返回', () {
      final same = Uri.parse('https://new.panel.example.com:8443/sub?token=abc');
      expect(rewriteHost(same, base), same);
    });

    test('无端口 base 继承原端口语义', () {
      final noPort = Uri.parse('https://plain.example.com');
      final old = Uri.parse('https://always.example.com:443/sub?token=abc');
      final rewritten = rewriteHost(old, noPort);
      expect(rewritten.host, 'plain.example.com');
    });
  });
}

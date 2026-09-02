import 'dart:convert';
import 'dart:typed_data';

import 'package:bett_box/xboard/bootstrap.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.responses);

  /// 每个请求依次返回的 (statusCode, jsonBody)；耗尽后抛错。
  final List<(int, Map<String, dynamic>)> responses;
  int _index = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_index >= responses.length) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'no more fake responses',
      );
    }
    final (status, body) = responses[_index++];
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('XboardBootstrapDoc.tryParse', () {
    test('合法文档解析', () {
      final doc = XboardBootstrapDoc.tryParse({
        'version': 1,
        'api_domains': ['https://a.example.com', 'https://b.example.com', 'https://a.example.com'],
        'bootstrap_sources': ['https://src.example.com/domains.json'],
        'min_app_version': 1000000,
        'announcement_url': 'https://ann.example.com',
      });
      expect(doc, isNotNull);
      expect(doc!.apiDomains, ['https://a.example.com', 'https://b.example.com'], reason: '去重保序');
      expect(doc.bootstrapSources, ['https://src.example.com/domains.json']);
      expect(doc.minAppVersion, 1000000);
    });

    test('空/非法 api_domains 判为不可用（返回 null）', () {
      expect(XboardBootstrapDoc.tryParse(null), isNull);
      expect(XboardBootstrapDoc.tryParse({'api_domains': []}), isNull);
      expect(XboardBootstrapDoc.tryParse({'api_domains': ['ftp://x']}), isNull);
      expect(XboardBootstrapDoc.tryParse({'api_domains': 'https://x'}), isNull);
    });

    test('混合非法项被忽略', () {
      final doc = XboardBootstrapDoc.tryParse({
        'api_domains': ['ftp://bad', 'https://ok.example.com', 123],
      });
      expect(doc, isNotNull);
      expect(doc!.apiDomains, ['https://ok.example.com']);
    });
  });

  group('XboardBootstrapClient.fetch', () {
    test('按序尝试：首个合法文档生效，非法源回退下一源', () async {
      final dio = Dio(BaseOptions(
        baseUrl: 'https://fake',
        validateStatus: (_) => true,
      ));
      dio.httpClientAdapter = _FakeAdapter([
        (200, {'api_domains': []}), // 第一个源 schema 非法
        (200, {'api_domains': ['https://b.example.com']}), // 第二个源合法
      ]);
      final client = XboardBootstrapClient(dio: dio);
      final doc = await client.fetch(['https://s1/domains.json', 'https://s2/domains.json']);
      expect(doc, isNotNull);
      expect(doc!.apiDomains, ['https://b.example.com']);
    });

    test('全部源失败返回 null', () async {
      final dio = Dio();
      dio.httpClientAdapter = _FakeAdapter([
        (500, {'error': 'boom'}),
        (200, {'api_domains': []}),
      ]);
      final client = XboardBootstrapClient(dio: dio);
      final errors = <String>[];
      final doc = await client.fetch(['https://s1', 'https://s2'], onError: (s, e) => errors.add(s));
      expect(doc, isNull);
      expect(errors.length, 2);
    });
  });

  test('builtinBootstrapSources 生成面板同源路径', () {
    expect(
      builtinBootstrapSources(['https://a.example.com:8443']),
      ['https://a.example.com:8443/bootstrap.json'],
    );
  });
}

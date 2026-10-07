import 'dart:io';

import 'package:bett_box/xboard/api_client.dart';
import 'package:bett_box/xboard/bootstrap.dart';
import 'package:bett_box/xboard/domain_manager.dart';
import 'package:bett_box/xboard/models.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';

/// 仅测试传输把合法 HTTPS 测试域名映射到回环服务；生产策略不放宽。
class _LoopbackClient implements HttpClient {
  _LoopbackClient(this.port);
  final int port;
  final HttpClient _client = HttpClient();

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) => _client.openUrl(
    method,
    url.replace(scheme: 'http', host: '127.0.0.1', port: port),
  );
  @override
  Duration? get connectionTimeout => _client.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => _client.connectionTimeout = value;
  @override
  void close({bool force = false}) => _client.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final status in [302, 303, 307, 308]) {
    test('实际 IO 传输拒绝 $status 重定向且不发送凭据到目的地', () async {
      var sinkHits = 0;
      final sink = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      sink.listen((request) {
        sinkHits++;
        request.response.write('unexpected');
        request.response.close();
      });
      final entry = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      entry.listen((request) {
        if (request.uri.path == '/safe.json') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            '{"api_domains":["https://safe.example.test"]}',
          );
        } else {
          request.response.statusCode = status;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            'http://127.0.0.1:${sink.port}/sink',
          );
        }
        request.response.close();
      });
      final dio = Dio()
        ..httpClientAdapter = IOHttpClientAdapter(
          createHttpClient: () => _LoopbackClient(entry.port),
        );
      try {
        final client = XboardApiClient(
          domainManager: XboardDomainManager(
            domains: ['https://entry.example.test'],
          ),
          dio: dio,
          authDataProvider: () => 'Bearer fixture-only',
        );
        await expectLater(
          client.get<dynamic>('/user/info'),
          throwsA(isA<XboardException>()),
        );
        final bootstrap = await XboardBootstrapClient(dio: dio).fetch([
          'https://entry.example.test/redirect.json',
          'https://entry.example.test/safe.json',
        ]);
        expect(bootstrap?.apiDomains, ['https://safe.example.test']);
        expect(sinkHits, 0);
      } finally {
        dio.close(force: true);
        await entry.close(force: true);
        await sink.close(force: true);
      }
    });
  }
}

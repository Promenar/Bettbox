import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bett_box/xboard/api_client.dart';
import 'package:bett_box/xboard/domain_manager.dart';
import 'package:bett_box/xboard/invite.dart';
import 'package:bett_box/xboard/models.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> snapshot({List<dynamic>? stat}) => {
  'codes': [
    {'code': 'available', 'status': false},
    {'code': 'used', 'status': true},
    {'code': 'available', 'status': 0},
    {'code': 'second', 'status': '0'},
  ],
  'stat': stat ?? [3, 12345, 120.5, 10, 4567],
};

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final ResponseBody Function(RequestOptions) handler;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => handler(options);
}

ResponseBody response(Object? data, {bool success = true}) =>
    ResponseBody.fromString(
      jsonEncode({
        'status': success ? 'success' : 'fail',
        'message': success ? '' : '邀请码已达上限',
        'data': data,
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

void main() {
  group('邀请统计', () {
    test('字段映射准确且过滤已用和重复邀请码', () {
      final result = XboardInviteSummary.fromJson(snapshot());
      expect(result.codes, ['available', 'second']);
      expect(result.registeredCount, 3);
      expect(result.totalCommission, 12345);
      expect(result.pendingCommission, 120.5);
      expect(result.availableCommission, 4567);
    });
    test('保留零值及数字字符串', () {
      final result = XboardInviteSummary.fromJson(
        snapshot(stat: ['0', '0', '0', 10, '0']),
      );
      expect(result.availableCommission, 0);
      expect(result.registeredCount, 0);
    });
    test('缺失或异常金额不能变成零收益', () {
      for (final stat in [
        [],
        [0, 0],
        [0, 'invalid', 0, 10, 0],
        [0, -1, 0, 10, 0],
        [0, 1.5, 0, 10, 0],
        [0, 0, double.nan, 10, 0],
      ]) {
        expect(
          () => XboardInviteSummary.fromJson(snapshot(stat: stat)),
          throwsFormatException,
        );
      }
      expect(() => XboardInviteSummary.fromJson(null), throwsFormatException);
    });
  });
  group('邀请链接', () {
    test('网站地址与 API 域名解耦，符合主题注册路由', () {
      expect(
        buildXboardInviteLink('https://www.example.com', 'abc')?.toString(),
        'https://www.example.com/#/register?code=abc',
      );
      expect(
        buildXboardInviteLink('https://www.example.com/panel/', 'abc')?.path,
        '/panel/',
      );
    });
    test('邀请码作为独立参数编码，不能注入额外查询字段', () {
      const code = 'a&email=other#中+%';
      final url = buildXboardInviteLink('https://www.example.com', code)!;
      final route = Uri.parse(url.fragment);
      expect(route.path, '/register');
      expect(route.queryParameters, {'code': code});
    });
    test('缺失、不安全或带身份参数的网站地址不生成二维码链接', () {
      for (final website in [
        null,
        '',
        'http://example.com',
        'javascript:alert(1)',
        'https://user:pass@example.com',
        'https://example.com?token=test',
        'https://example.com/#/login',
        '/relative',
      ]) {
        expect(buildXboardInviteLink(website, 'abc'), isNull);
      }
      expect(buildXboardInviteLink('https://example.com', '  '), isNull);
    });
  });
  group('邀请 HTTP 契约', () {
    late List<RequestOptions> requests;
    late XboardInviteRepository repository;
    late ResponseBody Function(RequestOptions) handler;
    setUp(() {
      requests = [];
      handler = (options) => switch (options.uri.path) {
        '/api/v1/user/invite/fetch' => response(snapshot()),
        '/api/v1/user/comm/config' => response({'currency': 'CNY'}),
        '/api/v1/guest/comm/config' => response({
          'app_url': 'https://web.example.com',
        }),
        '/api/v1/user/invite/save' => response(true),
        _ => throw StateError('意外请求'),
      };
      repository = XboardInviteRepository(
        XboardApiClient(
          domainManager: XboardDomainManager(
            domains: ['https://api.example.com'],
          ),
          authDataProvider: () => 'Bearer test-only',
          dio: Dio()
            ..httpClientAdapter = _Adapter((options) {
              requests.add(options);
              return handler(options);
            }),
        ),
      );
    });
    test('加载只有三次读取，无自动创建；分享链接不含鉴权信息', () async {
      final result = await repository.load();
      expect(requests.length, 3);
      expect(requests.every((r) => r.method == 'GET'), isTrue);
      expect(requests.any((r) => r.uri.path.endsWith('/save')), isFalse);
      expect(requests.first.headers['Authorization'], 'Bearer test-only');
      expect(result.currency, 'CNY');
      expect(result.linkFor('available')?.host, 'web.example.com');
      expect(result.linkFor('available').toString(), isNot(contains('Bearer')));
    });
    test('创建使用上游 GET，失败不重试', () async {
      handler = (_) => response(null, success: false);
      await expectLater(
        repository.createCode(),
        throwsA(isA<XboardException>()),
      );
      expect(requests.length, 1);
      expect(requests.single.method, 'GET');
      expect(requests.single.uri.path, '/api/v1/user/invite/save');
    });
    test('创建结果必须明确成功', () async {
      handler = (_) => response(false);
      await expectLater(repository.createCode(), throwsFormatException);
      expect(requests.length, 1);
    });
    test('公开网站读取失败时仍可读取收益和邀请码', () async {
      final original = handler;
      handler = (options) => options.uri.path.contains('/guest/')
          ? response(null, success: false)
          : original(options);
      final result = await repository.load();
      expect(result.summary.totalCommission, 12345);
      expect(result.linkFor('available'), isNull);
    });
    test('币种缺失时不冒用人民币', () async {
      final original = handler;
      handler = (options) => options.uri.path.endsWith('/user/comm/config')
          ? response({})
          : original(options);
      await expectLater(repository.load(), throwsFormatException);
    });
  });
}

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bett_box/xboard/api_client.dart';
import 'package:bett_box/xboard/domain_manager.dart';
import 'package:bett_box/xboard/models.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final ResponseBody Function(RequestOptions options) handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => handler(options);
}

ResponseBody _ok(String jsonFragment) => ResponseBody.fromString(
      '{"status":"success","message":"操作成功","data":$jsonFragment,"error":null}',
      200,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
    );

void main() {
  group('XboardApiClient', () {
    test('成功响应解析 data', () async {
      final client = XboardApiClient(
        domainManager: XboardDomainManager(),
        dio: Dio()..httpClientAdapter = _FakeAdapter(
          (options) => _ok('{"token":"t","auth_data":"Bearer x","is_admin":false}'),
        ),
      );
      final result = await client.post<Map<String, dynamic>>(
        '/passport/auth/login',
        body: {'email': 'a@b.c', 'password': 'x'},
        parse: (data) => Map<String, dynamic>.from(data as Map),
      );
      expect(result?['token'], 't');
      expect(client.domainManager.activeFailureCount, 0);
    });

    test('业务失败抛 business 异常且不触发域名轮换', () async {
      final manager = XboardDomainManager();
      final client = XboardApiClient(
        domainManager: manager,
        dio: Dio()..httpClientAdapter = _FakeAdapter(
          (options) => ResponseBody.fromString(
            '{"status":"fail","message":"邮箱验证码有误","data":null,"error":null}',
            200,
            headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
          ),
        ),
      );
      await expectLater(
        client.get<void>('/user/info'),
        throwsA(
          isA<XboardException>()
              .having((e) => e.type, 'type', XboardErrorType.business)
              .having((e) => e.message, 'message', '邮箱验证码有误'),
        ),
      );
      expect(manager.active, XboardDomainManager.defaultDomains.first);
    });

    test('无 status 变体按失败处理', () async {
      final client = XboardApiClient(
        domainManager: XboardDomainManager(),
        dio: Dio()..httpClientAdapter = _FakeAdapter(
          (options) => ResponseBody.fromString(
            '{"message":"套餐周期参数有误"}',
            200,
            headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
          ),
        ),
      );
      await expectLater(
        client.post<void>('/user/order/save', body: {}),
        throwsA(isA<XboardException>()),
      );
    });

    test('401/403 归类为 auth', () async {
      final client = XboardApiClient(
        domainManager: XboardDomainManager(),
        dio: Dio()..httpClientAdapter = _FakeAdapter(
          (options) => ResponseBody.fromString(
            '{"status":"fail","message":"token is error","data":null,"error":null}',
            403,
            headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
          ),
        ),
      );
      await expectLater(
        client.get<String>('/user/resetSecurity'),
        throwsA(
          isA<XboardException>().having((e) => e.isAuth, 'isAuth', isTrue),
        ),
      );
    });

    test('连接层失败计入域名池并在阈值后轮换', () async {
      final manager = XboardDomainManager(
        domains: ['https://a.example.com', 'https://b.example.com'],
      );
      final client = XboardApiClient(
        domainManager: manager,
        dio: Dio()..httpClientAdapter = _FakeAdapter(
          (options) => throw DioException.connectionError(
            requestOptions: options,
            reason: 'refused',
          ),
        ),
      );
      await expectLater(
        client.get<void>('/guest/comm/config'),
        throwsA(
          isA<XboardException>().having((e) => e.isConnection, 'isConnection', isTrue),
        ),
      );
      expect(manager.activeFailureCount, 1);
      await expectLater(
        client.get<void>('/guest/comm/config'),
        throwsA(isA<XboardException>()),
      );
      expect(manager.activeFailureCount, 0, reason: '阈值 2 已触发轮换到 b');
      expect(manager.active, 'https://b.example.com');
    });

    test('GET 请求携带 Authorization 头', () async {
      String? authHeader;
      final client = XboardApiClient(
        domainManager: XboardDomainManager(),
        authDataProvider: () => 'Bearer token123',
        dio: Dio()..httpClientAdapter = _FakeAdapter((options) {
          authHeader = options.headers['Authorization'] as String?;
          return _ok('true');
        }),
      );
      await client.get<void>('/user/checkLogin');
      expect(authHeader, 'Bearer token123');
    });
  });
}

import 'package:bett_box/xboard/error_map.dart';
import 'package:bett_box/xboard/models.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

Response<dynamic> _response(int? status) => Response<dynamic>(
      requestOptions: RequestOptions(path: '/s/test'),
      statusCode: status,
    );

void main() {
  group('isNoPlanError（无订阅 403 判定）', () {
    test('订阅内容下载 403（原始 DioException）判为无订阅', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/s/test'),
        response: _response(403),
        type: DioExceptionType.badResponse,
      );
      expect(isNoPlanError(error), isTrue);
    });

    test('面板业务拒绝判为无订阅', () {
      expect(
        isNoPlanError(XboardException(XboardErrorType.business, '无套餐')),
        isTrue,
      );
      expect(
        isNoPlanError(
          XboardException(XboardErrorType.auth, 'forbidden', statusCode: 403),
        ),
        isTrue,
      );
    });

    test('连接层/服务端异常不判为无订阅', () {
      expect(
        isNoPlanError(XboardException(XboardErrorType.connection, 'timeout')),
        isFalse,
      );
      expect(
        isNoPlanError(
          XboardException(XboardErrorType.server, 'oops', statusCode: 500),
        ),
        isFalse,
      );
      expect(
        isNoPlanError(
          DioException(
            requestOptions: RequestOptions(path: '/s/test'),
            type: DioExceptionType.connectionTimeout,
          ),
        ),
        isFalse,
      );
      expect(isNoPlanError(StateError('bug')), isFalse);
    });
  });
}

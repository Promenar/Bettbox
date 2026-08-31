/// Xboard API 客户端：BaseURL 域名注入 + Bearer 鉴权 + 包络解析 + 错误分类。
///
/// 与 lib/common/request.dart（通用订阅下载）刻意分离：本客户端服务商业化链路，
/// 不复用其 UA/代理逻辑；域名切换失败上报在 [reportFailure] 钩子。
library;

import 'package:dio/dio.dart';

import 'domain_manager.dart';
import 'models.dart';

class XboardApiClient {
  XboardApiClient({
    required this.domainManager,
    String? Function()? authDataProvider,
    void Function(XboardException error)? onError,
    Dio? dio,
  }) : _authDataProvider = authDataProvider,
       _onError = onError,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 8),
               receiveTimeout: const Duration(seconds: 15),
               validateStatus: (_) => true,
               headers: {'Accept': 'application/json'},
             ),
           );

  final XboardDomainManager domainManager;
  final String? Function()? _authDataProvider;
  final void Function(XboardException error)? _onError;
  final Dio _dio;

  Uri _uri(String path, [Map<String, dynamic>? query]) =>
      Uri.parse('${domainManager.active}/api/v1$path').replace(
        queryParameters: (query == null || query.isEmpty)
            ? null
            : query.map((k, v) => MapEntry(k, v?.toString() ?? '')),
      );

  Options _options() {
    final auth = _authDataProvider?.call();
    return Options(
      headers: {
        if (auth != null && auth.isNotEmpty) 'Authorization': auth,
      },
    );
  }

  /// GET + 包络解析；[parse] 为空时返回原始 data。
  Future<T?> get<T>(String path, {Map<String, dynamic>? query, T Function(dynamic data)? parse}) async {
    final envelope = await _run(() => _dio.getUri<dynamic>(_uri(path, query), options: _options()));
    return _unwrap<T>(envelope, parse);
  }

  /// POST（JSON body）+ 包络解析。
  Future<T?> post<T>(String path, {Map<String, dynamic>? body, T Function(dynamic data)? parse}) async {
    final envelope = await _run(
      () => _dio.postUri<dynamic>(
        _uri(path),
        data: body ?? const {},
        options: _options()..contentType = 'application/json',
      ),
    );
    return _unwrap<T>(envelope, parse);
  }

  XboardException _classify(Object error) {
    if (error is XboardException) return error;
    if (error is DioException) {
      final response = error.response;
      final status = response?.statusCode;
      if (error.type == DioExceptionType.connectionError ||
          error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.sendTimeout) {
        return XboardException(
          XboardErrorType.connection,
          error.message ?? 'connection failure',
          statusCode: status,
        );
      }
      if (status == 401 || status == 403) {
        return XboardException(
          XboardErrorType.auth,
          _messageOf(response?.data) ?? 'unauthorized',
          statusCode: status,
        );
      }
      return XboardException(
        status != null && status >= 500
            ? XboardErrorType.server
            : XboardErrorType.business,
        _messageOf(response?.data) ?? error.message ?? 'request failed',
        statusCode: status,
      );
    }
    return XboardException(XboardErrorType.business, error.toString());
  }

  String? _messageOf(dynamic body) {
    if (body is Map<String, dynamic>) {
      return XboardEnvelope.parse(body).message;
    }
    return null;
  }

  Future<XboardEnvelope> _run(Future<Response<dynamic>> Function() send) async {
    XboardEnvelope envelope;
    try {
      final response = await send();
      envelope = XboardEnvelope.parse(response.data);
    } catch (error) {
      final ex = _classify(error);
      if (ex.isConnection) domainManager.reportConnectionFailure();
      _onError?.call(ex);
      throw ex;
    }
    if (!envelope.success) {
      // 业务失败（含无 status 变体）：按 business 处理，不触发域名轮换。
      final ex = XboardException(XboardErrorType.business, envelope.message);
      _onError?.call(ex);
      throw ex;
    }
    domainManager.reportSuccess();
    return envelope;
  }

  T? _unwrap<T>(XboardEnvelope envelope, T Function(dynamic data)? parse) {
    if (T == XboardEnvelope) return envelope as T;
    final data = envelope.data;
    if (parse != null) return parse(data);
    if (data == null) return null;
    if (data is T) return data;
    throw XboardException(XboardErrorType.business, 'unexpected data type');
  }
}

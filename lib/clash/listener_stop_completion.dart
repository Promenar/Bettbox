import 'dart:convert';

/// 只接受同次检查式停止动作的明确成功回执。
Future<bool> confirmListenerStop({
  required String requestId,
  required Future<String> Function(String) invoke,
}) async {
  final response = await invoke(jsonEncode({
    'id': requestId,
    'method': 'stopListener',
    'data': null,
  }));
  try {
    final result = jsonDecode(response);
    return result is Map<String, dynamic> &&
        result['id'] == requestId &&
        result['method'] == 'stopListener' &&
        result['code'] is int && result['code'] == 0 &&
        result['data'] == true;
  } on FormatException {
    return false;
  }
}

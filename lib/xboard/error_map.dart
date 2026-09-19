/// 错误映射（F-SUB 无订阅态判定，纯 Dart，可单测）。
///
/// 无有效订阅时面板与订阅内容均以 403 表达（PRD §5.1）：
/// 订阅 YAML 下载（`request.getFileResponseForUrl` 直连 Dio）抛原始
/// `DioException`，面板 API 经 [XboardApiClient] 归一为 [XboardException]。
/// UI 层据此静默（无订阅界面已承接提示），不再透出原文。
library;

import 'package:dio/dio.dart';

import 'models.dart';

/// 是否为"无有效订阅"业务态（区别于网络/服务端异常）。
bool isNoPlanError(Object error) {
  if (error is DioException) return error.response?.statusCode == 403;
  if (error is XboardException) {
    return error.isBusiness || error.statusCode == 403;
  }
  return false;
}

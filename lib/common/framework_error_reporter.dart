import 'package:flutter/foundation.dart';

/// 仅报告固定失败标记，不读取可能包含账户资料的错误内容。
class FrameworkErrorReporter {
  FrameworkErrorReporter({required this.report});

  final void Function(String) report;

  void install() {
    FlutterError.onError = (details) {
      try {
        report('[界面] framework failed');
      } catch (_) {
        // 诊断故障不得递归触发框架错误。
      }
    };
  }
}

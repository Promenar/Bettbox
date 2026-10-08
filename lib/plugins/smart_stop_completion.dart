import 'package:bett_box/common/common.dart';

/// 原生回执与同一Dart会话均成立时才提交显示状态；等待期间换代不清理新会话。
Future<void> completeSmartStop({
  required Future<bool?> Function() stop,
  required Future<bool> Function() isSuspended,
  required Object? Function() currentSession,
  required void Function() commit,
}) async {
  final session = currentSession();
  if (await stop() != true ||
      !await isSuspended() ||
      !identical(currentSession(), session)) {
    throw StateError(appLocalizations.connectionStateUnconfirmed);
  }
  commit();
}

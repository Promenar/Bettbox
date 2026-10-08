import 'package:bett_box/common/network_matcher.dart';

enum SmartAutoStopDecision { none, stop, resume }

/// 根据设置、地址和当前状态决定动作，不自行修改会话。
SmartAutoStopDecision decideSmartAutoStop({
  required bool enabled,
  required String networks,
  required List<String> addresses,
  required bool suspended,
  required bool running,
}) {
  if (!enabled || networks.trim().isEmpty) {
    return suspended
        ? SmartAutoStopDecision.resume
        : SmartAutoStopDecision.none;
  }
  if (addresses.isEmpty) {
    return SmartAutoStopDecision.none;
  }
  final matches = addresses.any((ip) => NetworkMatcher.matchAny(ip, networks));
  if (matches && !suspended && running) return SmartAutoStopDecision.stop;
  if (!matches && suspended) return SmartAutoStopDecision.resume;
  return SmartAutoStopDecision.none;
}

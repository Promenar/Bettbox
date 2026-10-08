import 'package:bett_box/manager/smart_auto_stop_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  SmartAutoStopDecision decide({
    bool enabled = true,
    String networks = '10.0.2.16',
    List<String> addresses = const ['10.0.2.16'],
    bool suspended = false,
    bool running = true,
  }) => decideSmartAutoStop(
    enabled: enabled,
    networks: networks,
    addresses: addresses,
    suspended: suspended,
    running: running,
  );

  test('清空规则恢复已智能停止会话，无需可用地址', () {
    expect(
      decide(networks: '', addresses: [], suspended: true, running: false),
      SmartAutoStopDecision.resume,
    );
  });
  test('仅空白规则恢复已智能停止会话', () {
    expect(
      decide(networks: '  ', addresses: [], suspended: true, running: false),
      SmartAutoStopDecision.resume,
    );
  });
  test('关闭功能恢复已智能停止会话，无需可用地址', () {
    expect(
      decide(enabled: false, addresses: [], suspended: true, running: false),
      SmartAutoStopDecision.resume,
    );
  });
  test('无规则不会启动普通停止会话', () {
    expect(decide(networks: '', running: false), SmartAutoStopDecision.none);
  });
  test('关闭功能不会启动普通停止会话', () {
    expect(decide(enabled: false, running: false), SmartAutoStopDecision.none);
  });
  test('非空规则但无地址保留挂起状态', () {
    expect(
      decide(addresses: [], suspended: true, running: false),
      SmartAutoStopDecision.none,
    );
  });
  test('匹配地址停止运行会话', () {
    expect(decide(), SmartAutoStopDecision.stop);
  });
  test('已挂起且地址匹配不重复停止', () {
    expect(decide(suspended: true, running: false), SmartAutoStopDecision.none);
  });
  test('普通停止且地址匹配不执行动作', () {
    expect(decide(running: false), SmartAutoStopDecision.none);
  });
  test('离开匹配网络恢复挂起会话', () {
    expect(
      decide(addresses: ['192.168.1.2'], suspended: true, running: false),
      SmartAutoStopDecision.resume,
    );
  });
  test('任一地址匹配 CIDR 则停止', () {
    expect(
      decide(networks: '10.0.2.0/24', addresses: ['192.168.1.2', '10.0.2.16']),
      SmartAutoStopDecision.stop,
    );
  });
}

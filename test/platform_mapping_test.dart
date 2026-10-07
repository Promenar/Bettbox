import 'package:bett_box/enum/enum.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS 与各平台独立映射，桌面能力不扩展到移动平台', () {
    final expected = {
      'windows': SupportPlatform.Windows,
      'macos': SupportPlatform.MacOS,
      'linux': SupportPlatform.Linux,
      'android': SupportPlatform.Android,
      'ios': SupportPlatform.IOS,
    };
    for (final entry in expected.entries) {
      expect(SupportPlatform.forOperatingSystem(entry.key), entry.value);
    }
    expect(desktopPlatforms, isNot(contains(SupportPlatform.IOS)));
    expect(desktopPlatforms, isNot(contains(SupportPlatform.Android)));
    expect(() => SupportPlatform.forOperatingSystem('unknown'), throwsUnsupportedError);
  });
}

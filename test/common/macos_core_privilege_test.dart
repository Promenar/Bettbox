import 'dart:io';

import 'package:bett_box/common/system.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('macOS原生授权入口拒绝旧内核文件提权且无需初始化应用或通道', () async {
    // 不初始化路径插件、UI或原生通道，确保固定拒绝发生在外部调用之前。
    expect(await system.authorizeCore(), AuthorizeCode.error);
  }, skip: !Platform.isMacOS);
}

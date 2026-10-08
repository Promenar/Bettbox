import 'dart:ffi';
import 'dart:io';

import 'package:bett_box/clash/lib.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final libraryPath = Platform.environment['BETTBOX_TEST_CORE_LIBRARY'];
  test('后台实际Go FFI停止回执由生产Handler确认', () async {
    final file = File(libraryPath!);
    expect(file.resolveSymbolicLinksSync(),
        File('.test/listener-stop-ffi/libclash.dylib').absolute.path);
    final handler = ClashLibHandler.withLibrary(DynamicLibrary.open(file.path));
    expect(await handler.stopListener(), isTrue);
    expect(await handler.stopListener(), isTrue);
  }, skip: libraryPath == null,
     timeout: const Timeout(Duration(seconds: 20)));
}

import 'dart:ffi';
import 'dart:io';

import 'package:bett_box/clash/lib.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final libraryPath = Platform.environment['BETTBOX_TEST_CORE_LIBRARY'];
  test(
    '后台实际Go FFI停止回执由生产Handler确认',
    () async {
      final file = File(libraryPath!);
      expect(
        file.resolveSymbolicLinksSync(),
        File('.test/listener-stop-ffi/libclash.dylib').absolute.path,
      );
      final handler = ClashLibHandler.withLibrary(
        DynamicLibrary.open(file.path),
      );
      expect(await handler.startListener(), isTrue);
      expect(await handler.stopListener(), isTrue);
      expect(await handler.stopListener(), isTrue);
      int? firstEpoch;
      expect(
        await handler.verifyRuntimeIdentity(
          invokeNative: (epoch) async {
            expect(epoch, greaterThan(1));
            expect(epoch, lessThanOrEqualTo(9007199254740991));
            firstEpoch = epoch;
            return true;
          },
        ),
        isTrue,
      );
      expect(
        await handler.verifyRuntimeIdentity(
          invokeNative: (epoch) async {
            expect(epoch, firstEpoch);
            return false;
          },
        ),
        isFalse,
      );
    },
    skip: libraryPath == null,
    timeout: const Timeout(Duration(seconds: 20)),
  );
}

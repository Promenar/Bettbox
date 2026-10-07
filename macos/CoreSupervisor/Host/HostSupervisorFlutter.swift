import FlutterMacOS

final class HostSupervisorFlutterBridge {
    private let authority = makeHostSupervisorAuthority()
    private let channel: FlutterMethodChannel
    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "bettbox/core_supervisor", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else {
                result(FlutterError(code: "unavailable", message: "原生宿主已释放", details: nil)); return
            }
            self.authority.call(call.method, arguments: call.arguments) { response in
                switch response {
                case .success(let value): result(value)
                case .failure(let error): result(FlutterError(code: error.code, message: "身份链请求未完成", details: nil))
                }
            }
        }
    }
    deinit { channel.setMethodCallHandler(nil) }
}

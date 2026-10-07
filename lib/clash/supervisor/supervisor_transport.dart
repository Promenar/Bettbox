import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

abstract interface class SupervisorTransport {
  int get pid;
  Stream<List<int>> get output;
  Stream<List<int>> get diagnostics;
  Future<int> get exitCode;
  Future<void> write(Uint8List frame);
  Future<void> closeInput();
}

abstract interface class SupervisorTransportFactory {
  Future<SupervisorTransport> spawn(String nativePath, int generation);
}

typedef SupervisorProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      required Map<String, String> environment,
      required bool includeParentEnvironment,
      required bool runInShell,
      required ProcessStartMode mode,
    });

class ProcessSupervisorTransportFactory implements SupervisorTransportFactory {
  ProcessSupervisorTransportFactory({SupervisorProcessStarter? starter})
    : _starter = starter ?? Process.start;
  final SupervisorProcessStarter _starter;
  @override
  Future<SupervisorTransport> spawn(String nativePath, int generation) async {
    final process = await _starter(
      nativePath,
      ['--owned-supervisor-v1', '--generation', '$generation'],
      environment: const {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'},
      includeParentEnvironment: false,
      runInShell: false,
      mode: ProcessStartMode.normal,
    );
    return ProcessSupervisorTransport(process);
  }
}

// 宿主只持有helper；Core回收由helper负责，无kill或另一个reaper。
class ProcessSupervisorTransport implements SupervisorTransport {
  ProcessSupervisorTransport(this.process) : _exitCode = process.exitCode;
  final Process process;
  final Future<int> _exitCode;
  @override
  int get pid => process.pid;
  @override
  Stream<List<int>> get output => process.stdout;
  @override
  Stream<List<int>> get diagnostics => process.stderr;
  @override
  Future<int> get exitCode => _exitCode;
  @override
  Future<void> write(Uint8List frame) async {
    process.stdin.add(frame);
    await process.stdin.flush();
  }

  @override
  Future<void> closeInput() => process.stdin.close();
}

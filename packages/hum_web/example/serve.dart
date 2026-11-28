import 'dart:io';

import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_static/shelf_static.dart';

/// Compiles and serves a `hum_web` Wasm demo locally.
///
/// Usage:
/// - `dart run packages/hum_web/example/serve.dart` (default sine demo, port 8080)
/// - `dart run packages/hum_web/example/serve.dart mic_fx` (mic_fx demo, port 8080)
/// - `dart run packages/hum_web/example/serve.dart mic_fx 9000` (custom port)
/// - `dart run packages/hum_web/example/serve.dart 9000` (default demo, custom port)
Future<void> main(List<String> args) async {
  final rootExampleDir = File.fromUri(Platform.script).parent;
  String? demoName;
  int port = 8080;

  if (args.isNotEmpty) {
    final parsedPort = int.tryParse(args[0]);
    if (parsedPort != null) {
      port = parsedPort;
    } else {
      demoName = args[0];
      if (args.length > 1) {
        port = int.tryParse(args[1]) ?? 8080;
      }
    }
  }

  final targetDir = demoName == null
      ? rootExampleDir
      : Directory('${rootExampleDir.path}${Platform.pathSeparator}$demoName');

  final mainDartFile = File(
    '${targetDir.path}${Platform.pathSeparator}main.dart',
  );
  if (!targetDir.existsSync() || !mainDartFile.existsSync()) {
    final available = rootExampleDir
        .listSync()
        .whereType<Directory>()
        .where(
          (d) =>
              File('${d.path}${Platform.pathSeparator}main.dart').existsSync(),
        )
        .map((d) => d.uri.pathSegments.where((s) => s.isNotEmpty).last)
        .toList();
    stderr.writeln('Demo "$demoName" not found in ${rootExampleDir.path}.');
    if (available.isNotEmpty) {
      stderr.writeln(
        'Available demos: default (no arg), ${available.join(', ')}',
      );
    }
    exitCode = 64;
    return;
  }

  final buildDir = Directory('${targetDir.path}${Platform.pathSeparator}build')
    ..createSync(recursive: true);

  final label = demoName ?? 'default';
  stdout.writeln('Compiling $label demo to Wasm...');
  final compileResult = await Process.run(
    Platform.resolvedExecutable,
    [
      'compile',
      'wasm',
      '-o',
      '${buildDir.path}${Platform.pathSeparator}main.wasm',
      mainDartFile.path,
    ],
  );

  if (compileResult.exitCode != 0) {
    stderr.writeln(
      'dart compile wasm failed (exit ${compileResult.exitCode}):',
    );
    stderr.write(compileResult.stdout);
    stderr.write(compileResult.stderr);
    exitCode = compileResult.exitCode;
    return;
  }

  final handler = createStaticHandler(
    targetDir.path,
    defaultDocument: 'index.html',
  );
  final server = await shelf_io.serve(
    handler,
    InternetAddress.loopbackIPv4,
    port,
  );
  stdout.writeln('Serving hum_web ($label) at http://localhost:$port');
  stdout.writeln('Press Ctrl+C to stop.');

  await ProcessSignal.sigint.watch().first;
  stdout.writeln('\nStopping server...');
  await server.close(force: true);
}

import 'dart:io';

import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_static/shelf_static.dart';

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.tryParse(args.first) ?? 8080 : 8080;
  final exampleDir = File.fromUri(Platform.script).parent;
  final buildDir = Directory('${exampleDir.path}${Platform.pathSeparator}build')
    ..createSync(recursive: true);

  stdout.writeln('Compiling example/main.dart to Wasm...');
  final compileResult = await Process.run(
    Platform.resolvedExecutable,
    [
      'compile',
      'wasm',
      '-o',
      '${buildDir.path}${Platform.pathSeparator}main.wasm',
      '${exampleDir.path}${Platform.pathSeparator}main.dart',
    ],
  );

  if (compileResult.exitCode != 0) {
    stderr.writeln('dart compile wasm failed (exit ${compileResult.exitCode}):');
    stderr.write(compileResult.stdout);
    stderr.write(compileResult.stderr);
    exitCode = compileResult.exitCode;
    return;
  }

  final handler = createStaticHandler(
    exampleDir.path,
    defaultDocument: 'index.html',
  );
  final server = await shelf_io.serve(
    handler,
    InternetAddress.loopbackIPv4,
    port,
  );
  stdout.writeln('Serving hum_web demo at http://localhost:$port');
  stdout.writeln('Press Ctrl+C to stop.');

  await ProcessSignal.sigint.watch().first;
  stdout.writeln('\nStopping server...');
  await server.close(force: true);
}

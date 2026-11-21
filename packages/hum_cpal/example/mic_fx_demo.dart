import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:hum/hum.dart';
import 'package:hum/io.dart';
import 'package:hum_cpal/hum_cpal.dart';

/// Live microphone -> Delay -> Freeverb -> speakers demo using `hum_cpal`.
///
/// Use headphones to avoid acoustic feedback!
Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption(
      'input',
      abbr: 'i',
      valueHelp: 'deviceId',
      help: 'Target cpal input device ID (defaults to system default input).',
    )
    ..addOption(
      'output',
      abbr: 'o',
      valueHelp: 'deviceId',
      help: 'Target cpal output device ID (defaults to system default output).',
    )
    ..addFlag(
      'devices',
      abbr: 'l',
      negatable: false,
      help: 'List available cpal audio devices and exit.',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Show usage information.',
    );

  final ArgResults parsed;
  try {
    parsed = parser.parse(args);
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n');
    stderr.writeln(parser.usage);
    exitCode = 64;
    return;
  }

  if (parsed.flag('help')) {
    print(
      'Usage: dart run packages/hum_cpal/example/mic_fx_demo.dart [options]\n\n'
      '${parser.usage}',
    );
    return;
  }

  final snapshot = CpalHostSnapshot.probe();
  print('Host: ${snapshot.hostName} (${snapshot.devices.length} devices)');

  if (parsed.flag('devices')) {
    _printDevices(snapshot);
    return;
  }

  final requestedInId = parsed.option('input');
  final requestedOutId = parsed.option('output');

  final inDevice = requestedInId != null
      ? _findDeviceById(snapshot, requestedInId)
      : snapshot.defaultInputDevice;
  final outDevice = requestedOutId != null
      ? _findDeviceById(snapshot, requestedOutId)
      : snapshot.defaultOutputDevice;

  if (inDevice == null || inDevice.defaultInput == null) {
    stderr.writeln('No usable cpal input device found.\n');
    _printDevices(snapshot, sink: stderr);
    exitCode = 1;
    return;
  }
  if (outDevice == null || outDevice.defaultOutput == null) {
    stderr.writeln('No usable cpal output device found.\n');
    _printDevices(snapshot, sink: stderr);
    exitCode = 1;
    return;
  }

  final inCfg = inDevice.defaultInput!;
  final outCfg = outDevice.defaultOutput!;

  print('Input device:  ${inDevice.name} ($inCfg)');
  print('Output device: ${outDevice.name} ($outCfg)');

  if (inCfg.sampleRate != outCfg.sampleRate) {
    stderr.writeln(
      'Input sample rate (${inCfg.sampleRate}Hz) does not match output sample '
      'rate (${outCfg.sampleRate}Hz). Select devices with matching sample rates '
      'via --input / --output (use --devices to list).',
    );
    exitCode = 1;
    return;
  }
  if (outCfg.sampleFormat != CpalSampleFormat.f32) {
    stderr.writeln(
      'CpalAudioOutput requires f32; found ${outCfg.sampleFormat.name}.',
    );
    exitCode = 1;
    return;
  }

  const vectorSize = 64;
  final context = ProcessContext(
    sampleRate: outCfg.sampleRate,
    vectorSize: vectorSize,
  );

  // Route channel 0 of the input device through Delay -> Freeverb -> Master.
  final mic = In.mono();
  final delay = Delay.mono(
    input: mic.outlet,
    time: const .value(0.28),
    feedback: const .value(0.35),
    mix: const .value(0.4),
    damp: const .value(0.25),
    maxDelay: 2.0,
  );
  final reverb = Freeverb.mono(
    input: delay.outlet,
    roomSize: const .value(0.72),
    damp: const .value(0.4),
    mix: const .value(0.35),
  );
  final master = Mult.stereo(
    leftInput: reverb.left,
    rightInput: reverb.right,
    value: const .value(0.8),
  );

  final outChannels = outCfg.channels == 1
      ? [master.outlets[0]]
      : [
          master.outlets[0],
          master.outlets[1],
          for (int c = 2; c < outCfg.channels; c++) master.outlets[0],
        ];
  final out = Out(channels: outChannels);

  final host = await IsolateAudioHost.spawn(context: context);
  final errorSub = host.playbackErrors.listen((e) {
    stderr.writeln('Audio stream error: ${e.error}');
  });

  try {
    final diagnostics = host.setGraph(root: out);
    if (diagnostics.isNotEmpty) {
      stderr.writeln('Graph validation failed: $diagnostics');
      exitCode = 1;
      return;
    }

    final input = CpalAudioInput(
      numChannels: inCfg.channels,
      vectorSize: vectorSize,
      deviceId: requestedInId,
      bufferFrames: 2048,
    );
    final output = CpalAudioOutput(
      numChannels: outCfg.channels,
      vectorSize: vectorSize,
      deviceId: requestedOutId,
      bufferFrames: 2048,
    );

    print('Live mic FX @ ${outCfg.sampleRate}Hz (use headphones!).');
    print('Press Ctrl+C to stop.');
    await host.startPlayback(output: output, input: input);

    final stopCompleter = Completer<void>();
    final sigSub = ProcessSignal.sigint.watch().listen((_) {
      if (!stopCompleter.isCompleted) {
        stopCompleter.complete();
      }
    });
    try {
      await stopCompleter.future;
    } finally {
      await sigSub.cancel();
    }

    print('\nStopping...');
    await host.stopPlayback();
    print('Done.');
  } finally {
    await errorSub.cancel();
    await host.dispose();
  }
}

CpalDeviceInfo? _findDeviceById(CpalHostSnapshot snapshot, String id) {
  for (final device in snapshot.devices) {
    if (device.id == id) return device;
  }
  return null;
}

void _printDevices(CpalHostSnapshot snapshot, {IOSink? sink}) {
  final out = sink ?? stdout;
  for (final device in snapshot.devices) {
    final flags = [
      if (device.isDefaultOutput) 'default-out',
      if (device.isDefaultInput) 'default-in',
    ];
    final tag = flags.isEmpty ? '' : ' [${flags.join(', ')}]';
    out.writeln('- ${device.name}$tag (id: ${device.id})');

    if (device.defaultOutput case final defaultOut?) {
      out.writeln('    default out: $defaultOut');
    }
    if (device.defaultInput case final defaultIn?) {
      out.writeln('    default in:  $defaultIn');
    }
  }
}

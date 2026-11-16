import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:hum/hum.dart';
import 'package:hum/io.dart';
import 'package:hum_cpal/hum_cpal.dart';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption(
      'device',
      abbr: 'd',
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
      'Usage: dart run packages/hum_cpal/example/main.dart [options]\n\n'
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

  final requestedId = parsed.option('device');
  final device = requestedId != null
      ? _findDeviceById(snapshot, requestedId)
      : snapshot.defaultOutputDevice;

  if (device == null) {
    if (requestedId != null) {
      stderr.writeln('Audio output device "$requestedId" was not found.\n');
      _printDevices(snapshot, sink: stderr);
      exitCode = 1;
    } else {
      print('No default cpal output device available.');
    }
    return;
  }

  final config = device.defaultOutput;
  if (config == null) {
    stderr.writeln(
      'Device "${device.name}" (${device.id}) has no default output config.',
    );
    exitCode = 1;
    return;
  }

  print('Output device: ${device.name} ($config)');
  if (config.sampleFormat != CpalSampleFormat.f32) {
    print(
      'CpalAudioOutput requires f32 parity; '
      'found ${config.sampleFormat.name}.',
    );
    return;
  }

  const vectorSize = 64;
  final context = ProcessContext(
    sampleRate: config.sampleRate,
    vectorSize: vectorSize,
  );

  const tempo = Tempo(120);
  final clock = Clock(
    frequency: .value(1 / tempo.eighth),
    pulseWidth: const .value(0.5),
  );
  final notes = Note.parse('A3').scale(.locrian).take(8).map((e) => e.name);
  final seq = StepSequencer.notes(
    clock: clock.trigger,
    notes: notes,
  );
  final osc = SawtoothOscillator(frequency: .signal(seq.outlet));
  final env = Adsr(
    gate: clock.gate,
    attack: const .value(0.01),
    decay: const .value(0.18),
    sustain: const .value(0.25),
    release: const .value(0.06),
    curve: .exponential,
  );
  final filter = SvfFilter(
    input: osc.outlet,
    cutoff: const .value(1400.0),
    resonance: const .value(1.5),
  );
  final amp = Mult.mono(
    input: filter.lowpass,
    value: .signal(env.outlet),
  );
  final master = Mult.mono(
    input: amp.outlet,
    value: const .value(0.2),
  );
  final chorus = Chorus.toStereo(
    input: master.outlet,
    rate: const .value(0.8),
  );

  final outChannels = config.channels == 1
      ? [master.outlet]
      : [
          chorus.outlets[0],
          chorus.outlets[1],
          for (int c = 2; c < config.channels; c++) master.outlet,
        ];

  final out = Out(channels: outChannels);

  final host = await IsolateAudioHost.spawn(context: context);
  final errorSub = host.playbackErrors.listen((e) {
    print('Playback error: ${e.error}');
  });

  try {
    final diagnostics = host.setGraph(root: out);
    if (diagnostics.isNotEmpty) {
      print('Graph validation failed: $diagnostics');
      return;
    }

    final output = CpalAudioOutput(
      numChannels: config.channels,
      vectorSize: vectorSize,
      deviceId: requestedId,
      bufferFrames: 2048,
    );

    print('Playing for 3 seconds...');
    await host.startPlayback(output);
    await Future<void>.delayed(const Duration(seconds: 3));
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

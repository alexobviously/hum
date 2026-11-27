import 'dart:io' show Platform;

import 'package:hum/hum.dart';
import 'package:hum/io.dart';
import 'package:hum_codecs/native.dart';

// The point of this demo is that it loads a few audio files in various formats.
// Builds a randomised drum pattern.

Future<void> main() async {
  final sr = 44100, vs = 64, tempo = Tempo(140);
  final context = ProcessContext(sampleRate: sr, vectorSize: vs);
  final host = await IsolateAudioHost.spawn(context: context);
  final stopwatch = Stopwatch()..start();

  final samples = _loadSamples(host);
  print(
    'loaded ${samples.length} samples in ${stopwatch.elapsedMilliseconds} ms',
  );
  stopwatch.reset();

  final kicks = _randomiser(
    1 / tempo.quarter,
    [samples['kick1']!, samples['kick2']!],
    0.9,
  ).outlet;

  final snares = _randomiser(
    1 / tempo.dottedEighth,
    [
      samples['snare1']!,
      samples['snare2']!,
      samples['snare3']!,
      samples['snare4']!,
    ],
    0.5,
  ).outlet;

  final hats = _randomiser(
    1 / tempo.sixteenth,
    [samples['hat1']!, samples['hat2']!, samples['hat3']!],
    0.3,
  ).outlet.mult(0.5).outlet;

  final drums = Sum(inputs: [kicks, snares, hats]);
  final reverb = Freeverb.mono(
    input: drums.outlet,
    roomSize: .value(0.7),
    mix: .value(0.4),
  );
  final comp = Compressor.stereo(
    reverb.left,
    reverb.right,
    threshold: const .value(-30),
    ratio: const .value(3),
    makeupGain: const .value(6.0),
  );
  final out = Out.stereo(left: comp.left, right: comp.right);

  host.setGraph(root: out);

  final outPath = Platform.script.resolve('demo.wav').toFilePath();

  await host.exportWav(
    path: outPath,
    duration: Duration(seconds: (tempo.bar * 16).floor()),
  );
  print('exported to $outPath in ${stopwatch.elapsedMilliseconds} ms');

  await host.dispose();
}

Map<String, BufferHandle> _loadSamples(AudioHost host) {
  final paths = <String>[
    //
    'kick1.ogg', 'kick2.aiff',
    'snare1.mp3', 'snare2.m4a', 'snare3.wav', 'snare4.wav',
    'hat1.flac', 'hat2.flac', 'hat3.flac',
  ].map(_samplePath);

  final handles = <String, BufferHandle>{};

  for (final path in paths) {
    final buf = loadAudioSync(path);
    final handle = host.loadBuffer(buf);
    final fileName = path.split('/').last.split('.').first;
    handles[fileName] = handle;
  }

  return handles;
}

String _samplePath(String name) =>
    Platform.script.resolve('samples/$name').toFilePath();

Sum _randomiser(
  double frequency,
  List<BufferHandle> samples,
  double probability,
) {
  final clock = Clock(
    frequency: .value(frequency),
    pulseWidth: const .value(0.5),
  );

  final chance = Chance(
    input: clock.trigger,
    probability: .value(probability),
  );

  final branch = Branch.uniform(
    input: chance.a,
    count: samples.length,
  );

  final voices = [
    for (int i = 0; i < samples.length; i++)
      SamplePlayer(buffer: samples[i], trigger: branch[i]).outlet,
  ];

  return Sum(inputs: voices);
}

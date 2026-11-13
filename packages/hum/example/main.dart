import 'package:hum/hum.dart';

// Go and look at example/demos/ for more!

void main() async {
  print('=== hum DSP Synth Demo ===');
  const sampleRate = 44100;
  const vectorSize = 64;
  final context = ProcessContext(
    sampleRate: sampleRate,
    vectorSize: vectorSize,
  );

  // 1. Oscillators & Modulation
  final saw = SawtoothOscillator(frequency: const .value(110.0));
  final lfo = SineOscillator(frequency: const .value(0.5))
      .mapRange(200.0, 2000.0);

  // 2. Filter: cutoff modulated by LFO
  final filter = SvfFilter(
    input: saw.outlet,
    cutoff: ControlParam.signal(lfo.outlet),
    resonance: const .value(2.0),
  );

  // 3. Effects: Analog saturation + stereo chorus + delay
  final sat = Saturator.tube(filter.lowpass, drive: const .value(1.5));
  final chorus = Chorus.toStereo(input: sat.outlet, rate: const .value(0.8));
  final delayL = Delay.mono(
    input: chorus.outlets[0],
    time: const .value(0.25),
    feedback: const .value(0.4),
  );
  final delayR = Delay.mono(
    input: chorus.outlets[1],
    time: const .value(0.375),
    feedback: const .value(0.4),
  );

  final wav = WavSink.file(
    channels: [delayL.outlet, delayR.outlet],
    path: 'tmp/example_synth.wav',
  );

  final host = SyncAudioHost(context: context);
  final diagnostics = host.setGraph(root: wav);

  if (diagnostics.isNotEmpty) {
    print('Validation failed: $diagnostics');
    return;
  }

  print('Render schedule compiled successfully:');
  print('  Total nodes: ${host.currentSnapshot.nodes.length}');
  print('  Output channels: ${host.numChannels}');

  // Render 3 seconds of audio
  const seconds = 3;
  const totalBlocks = (seconds * sampleRate) ~/ vectorSize;
  print('Rendering $seconds seconds of audio ($totalBlocks blocks)...');

  for (int i = 0; i < totalBlocks; i++) {
    host.process();
  }

  host.processorOf<WavSinkProcessor>(wav)?.close();
  print('Demo successfully written to tmp/example_synth.wav!');
}

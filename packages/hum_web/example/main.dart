import 'dart:async';
import 'dart:js_interop';

import 'package:hum/hum.dart';
import 'package:hum_web/hum_web.dart';
import 'package:web/web.dart' as web;

// You probably want to run `serve.dart` and visit the page in a web browser.

void main() {
  final toggleBtn =
      web.document.getElementById('toggle')! as web.HTMLButtonElement;
  final freqSlider =
      web.document.getElementById('freq')! as web.HTMLInputElement;
  final statusEl = web.document.getElementById('status')!;

  AudioHost? host;
  SineOscillator? osc;
  bool playing = false;

  Future<void> toggle() async {
    if (playing) {
      playing = false;
      toggleBtn.textContent = 'Start Audio';
      statusEl.textContent = 'Stopped';
      await host?.stopPlayback();
      await host?.dispose();
      host = null;
      osc = null;
      return;
    }

    final audioCtx = web.AudioContext();
    final sampleRate = audioCtx.sampleRate.round();
    const vectorSize = 128;

    final context = ProcessContext(
      sampleRate: sampleRate,
      vectorSize: vectorSize,
    );

    final startFreq = double.tryParse(freqSlider.value) ?? 220.0;
    final sine = SineOscillator(frequency: .value(startFreq));
    final gain = Mult.mono(input: sine.outlet, value: const .value(0.25));
    final out = Out.stereo(left: gain.outlet, right: gain.outlet);

    final syncHost = AudioHost.sync(context: context);
    final diagnostics = syncHost.setGraph(root: out);
    if (diagnostics.isNotEmpty) {
      statusEl.textContent = 'Graph error: $diagnostics';
      await audioCtx.close().toDart;
      return;
    }

    final output = WebAudioOutput(
      numChannels: 2,
      vectorSize: vectorSize,
      bufferFrames: 2048,
      audioContext: audioCtx,
    );

    await syncHost.startPlayback(output);
    host = syncHost;
    osc = sine;
    playing = true;
    toggleBtn.textContent = 'Stop Audio';
    statusEl.textContent =
        'Playing @ $sampleRate Hz (SIMD.isSupported=${SIMD.isSupported})';
  }

  toggleBtn.addEventListener(
    'click',
    (web.Event _) {
      unawaited(toggle());
    }.toJS,
  );

  freqSlider.addEventListener(
    'input',
    (web.Event _) {
      final activeHost = host;
      final activeOsc = osc;

      if (activeHost != null && activeOsc != null) {
        final hz = double.tryParse(freqSlider.value) ?? 220.0;
        activeHost.update(activeOsc, (frequency: hz));
      }
    }.toJS,
  );
}

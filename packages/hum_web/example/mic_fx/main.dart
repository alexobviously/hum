import 'dart:async';
import 'dart:js_interop';

import 'package:hum/hum.dart';
import 'package:hum_web/hum_web.dart';
import 'package:web/web.dart' as web;

void main() {
  final toggleBtn =
      web.document.getElementById('toggle')! as web.HTMLButtonElement;
  final delayTimeSlider =
      web.document.getElementById('delayTime')! as web.HTMLInputElement;
  final feedbackSlider =
      web.document.getElementById('feedback')! as web.HTMLInputElement;
  final reverbMixSlider =
      web.document.getElementById('reverbMix')! as web.HTMLInputElement;
  final roomSizeSlider =
      web.document.getElementById('roomSize')! as web.HTMLInputElement;
  final gainSlider =
      web.document.getElementById('gain')! as web.HTMLInputElement;
  final statusEl = web.document.getElementById('status')!;

  AudioHost? host;
  web.AudioContext? activeCtx;
  Delay? delayNode;
  Freeverb? reverbNode;
  Mult? gainNode;
  bool playing = false;

  double readSlider(web.HTMLInputElement el, double fallback) =>
      double.tryParse(el.value) ?? fallback;

  void pushDelayParams() {
    final h = host;
    final d = delayNode;
    if (h == null || d == null) return;
    h.update(d, (
      time: readSlider(delayTimeSlider, 0.28),
      feedback: readSlider(feedbackSlider, 0.35),
      mix: 0.4,
      damp: 0.25,
      maxDelay: 2.0,
      interpTime: 0.06,
    ));
  }

  void pushReverbParams() {
    final h = host;
    final r = reverbNode;
    if (h == null || r == null) return;
    h.update(r, (
      roomSize: readSlider(roomSizeSlider, 0.72),
      damp: 0.4,
      width: 1.0,
      mix: readSlider(reverbMixSlider, 0.35),
      interpTime: 0.03,
    ));
  }

  void pushGainParams() {
    final h = host;
    final g = gainNode;
    if (h == null || g == null) return;
    h.update(g, (value: readSlider(gainSlider, 0.8), interpTime: 0.02));
  }

  Future<void> toggle() async {
    if (playing) {
      playing = false;
      toggleBtn.textContent = 'Start Mic FX';
      statusEl.textContent = 'Stopped';
      await host?.stopPlayback();
      await host?.dispose();
      if (activeCtx != null) {
        await activeCtx!.close().toDart;
      }
      host = null;
      activeCtx = null;
      delayNode = null;
      reverbNode = null;
      gainNode = null;
      return;
    }

    // Create AudioContext synchronously inside the click handler (Safari).
    final audioCtx = web.AudioContext();
    final sampleRate = audioCtx.sampleRate.round();
    const vectorSize = 128;

    final context = ProcessContext(
      sampleRate: sampleRate,
      vectorSize: vectorSize,
    );

    final mic = In.mono();
    final delay = Delay.mono(
      input: mic.outlet,
      time: .value(readSlider(delayTimeSlider, 0.28)),
      feedback: .value(readSlider(feedbackSlider, 0.35)),
      mix: const .value(0.4),
      damp: const .value(0.25),
      maxDelay: 2.0,
    );
    final reverb = Freeverb.mono(
      input: delay.outlet,
      roomSize: .value(readSlider(roomSizeSlider, 0.72)),
      damp: const .value(0.4),
      mix: .value(readSlider(reverbMixSlider, 0.35)),
    );
    final master = Mult.stereo(
      leftInput: reverb.left,
      rightInput: reverb.right,
      value: .value(readSlider(gainSlider, 0.8)),
    );

    final syncHost = AudioHost.sync(context: context);
    final diagnostics = syncHost.setGraph(root: master.out);
    if (diagnostics.isNotEmpty) {
      statusEl.textContent = 'Graph error: $diagnostics';
      await audioCtx.close().toDart;
      return;
    }

    // Share one AudioContext for clock-locked full-duplex capture + playback.
    final input = WebAudioInput(
      numChannels: 1,
      vectorSize: vectorSize,
      bufferFrames: 2048,
      audioContext: audioCtx,
    );
    final output = WebAudioOutput(
      numChannels: 2,
      vectorSize: vectorSize,
      bufferFrames: 2048,
      audioContext: audioCtx,
    );

    statusEl.textContent = 'Requesting microphone access...';
    try {
      await syncHost.startPlayback(output: output, input: input);
    } catch (e) {
      statusEl.textContent = 'Failed to start: $e';
      await syncHost.dispose();
      await audioCtx.close().toDart;
      return;
    }

    host = syncHost;
    activeCtx = audioCtx;
    delayNode = delay;
    reverbNode = reverb;
    gainNode = master;
    playing = true;
    toggleBtn.textContent = 'Stop Mic FX';
    statusEl.textContent = 'Live duplex @ $sampleRate Hz (use headphones!)';
  }

  toggleBtn.addEventListener(
    'click',
    (web.Event _) {
      unawaited(toggle());
    }.toJS,
  );

  delayTimeSlider.addEventListener(
    'input',
    ((web.Event _) => pushDelayParams()).toJS,
  );
  feedbackSlider.addEventListener(
    'input',
    ((web.Event _) => pushDelayParams()).toJS,
  );
  reverbMixSlider.addEventListener(
    'input',
    ((web.Event _) => pushReverbParams()).toJS,
  );
  roomSizeSlider.addEventListener(
    'input',
    ((web.Event _) => pushReverbParams()).toJS,
  );
  gainSlider.addEventListener(
    'input',
    ((web.Event _) => pushGainParams()).toJS,
  );
}

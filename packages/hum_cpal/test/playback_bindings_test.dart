import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:hum_cpal/hum_cpal.dart';
import 'package:hum_cpal/src/cpal_bindings.dart';
import 'package:test/test.dart';

void main() {
  group('playback FFI bindings', () {
    test('handle null pointers safely without crashing', () {
      expect(humCpalPlaybackAvailableWrite(nullptr), equals(0));
      expect(humCpalPlaybackWrite(nullptr, nullptr, 64), equals(0));
      expect(humCpalPlaybackIsStopped(nullptr), isTrue);
      expect(humCpalPlaybackTakeError(nullptr), equals(nullptr));
      expect(humCpalPlaybackUnderruns(nullptr), equals(0));
      humCpalPlaybackClose(nullptr);
    });

    test('reports creation errors through outError and frees string', () {
      final outError = calloc<Pointer<Utf8>>();
      final missingDevice = 'nonexistent-cpal-device'.toNativeUtf8();
      try {
        final invalidHandle = humCpalPlaybackCreate(
          nullptr,
          0,
          2,
          1024,
          0,
          outError,
        );
        expect(invalidHandle, equals(nullptr));
        expect(outError.value, isNot(equals(nullptr)));
        expect(outError.value.toDartString(), isNotEmpty);
        humCpalFreeString(outError.value);

        final missingHandle = humCpalPlaybackCreate(
          missingDevice,
          48000,
          2,
          1024,
          0,
          outError,
        );
        expect(missingHandle, equals(nullptr));
        expect(outError.value, isNot(equals(nullptr)));
        expect(
          outError.value.toDartString(),
          contains('nonexistent-cpal-device'),
        );
        humCpalFreeString(outError.value);
      } finally {
        calloc.free(missingDevice);
        calloc.free(outError);
      }
    });

    test('opens, writes frames to, and closes default f32 output stream', () {
      final snapshot = CpalHostSnapshot.probe();
      final defaultOut = snapshot.devices.cast<CpalDeviceInfo?>().firstWhere(
        (d) =>
            d != null &&
            d.isDefaultOutput &&
            d.defaultOutput?.sampleFormat == CpalSampleFormat.f32,
        orElse: () => null,
      );
      if (defaultOut == null) {
        return;
      }

      final cfg = defaultOut.defaultOutput!;
      final outError = calloc<Pointer<Utf8>>();
      const framesToWrite = 512;
      final samples = calloc<Float>(framesToWrite * cfg.channels);
      Pointer<HumPlaybackHandle> handle = nullptr;
      try {
        handle = humCpalPlaybackCreate(
          nullptr,
          cfg.sampleRate,
          cfg.channels,
          2048,
          0,
          outError,
        );
        if (outError.value != nullptr) {
          final err = outError.value.toDartString();
          humCpalFreeString(outError.value);
          fail('Unexpected cpal playback creation error: $err');
        }
        expect(handle, isNot(equals(nullptr)));
        expect(humCpalPlaybackIsStopped(handle), isFalse);
        expect(humCpalPlaybackTakeError(handle), equals(nullptr));

        final beforeWrite = humCpalPlaybackAvailableWrite(handle);
        expect(beforeWrite, greaterThanOrEqualTo(framesToWrite));

        final written = humCpalPlaybackWrite(handle, samples, framesToWrite);
        expect(written, equals(framesToWrite));
        expect(
          humCpalPlaybackAvailableWrite(handle),
          lessThanOrEqualTo(beforeWrite),
        );
        expect(humCpalPlaybackUnderruns(handle), greaterThanOrEqualTo(0));
      } finally {
        humCpalPlaybackClose(handle);
        calloc.free(samples);
        calloc.free(outError);
      }
    });
  });
}

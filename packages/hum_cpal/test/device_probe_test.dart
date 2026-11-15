import 'package:hum_cpal/hum_cpal.dart';
import 'package:hum_cpal/src/cpal_bindings.dart';
import 'package:test/test.dart';

void main() {
  group('hum_cpal native bindings', () {
    test('hello-world symbol works', () {
      expect(humCpalAdd(69, 420), 489);
    });

    test('probes live cpal host and devices', () {
      final snapshot = CpalHostSnapshot.probe();

      expect(snapshot.hostName, isNotEmpty);
      for (final device in snapshot.devices) {
        expect(device.id, isNotEmpty);
        expect(device.name, isNotEmpty);

        for (final cfg in [...device.outputConfigs, ...device.inputConfigs]) {
          expect(cfg.channels, greaterThan(0));
          expect(cfg.minSampleRate, greaterThan(0));
          expect(cfg.maxSampleRate, greaterThanOrEqualTo(cfg.minSampleRate));
          if (cfg.bufferSize case final range?) {
            expect(range.max, greaterThanOrEqualTo(range.min));
          }
        }
      }
    });
  });

  group('CpalHostSnapshot JSON decoding', () {
    test('decodes all fields, null optionals, and unknown sample formats', () {
      final snapshot = CpalHostSnapshot.fromJson({
        'hostName': 'CoreAudio',
        'devices': [
          {
            'id': 'dev-1',
            'name': 'Built-in Output',
            'isDefaultOutput': true,
            'isDefaultInput': false,
            'defaultOutput': {
              'sampleRate': 48000,
              'channels': 2,
              'sampleFormat': 'f32',
              'bufferSize': {'min': 14, 'max': 4096},
            },
            'defaultInput': null,
            'outputConfigs': [
              {
                'channels': 2,
                'minSampleRate': 44100,
                'maxSampleRate': 96000,
                'sampleFormat': 'i24',
                'bufferSize': null,
              },
            ],
            'inputConfigs': <Object?>[],
          },
        ],
      });

      expect(snapshot.hostName, 'CoreAudio');
      expect(snapshot.devices, hasLength(1));
      expect(snapshot.defaultOutputDevice?.name, 'Built-in Output');
      expect(snapshot.defaultInputDevice, isNull);

      final dev = snapshot.devices.single;
      expect(dev.defaultOutput?.sampleRate, 48000);
      expect(dev.defaultOutput?.sampleFormat, CpalSampleFormat.f32);
      expect(dev.defaultOutput?.bufferSize?.min, 14);
      expect(dev.outputConfigs.single.sampleFormat, CpalSampleFormat.other);
      expect(dev.outputConfigs.single.bufferSize, isNull);
    });
  });
}

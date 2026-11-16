import 'package:hum_cpal/hum_cpal.dart';

void main() {
  final snapshot = CpalHostSnapshot.probe();
  print('Host: ${snapshot.hostName} (${snapshot.devices.length} devices)');
  for (final device in snapshot.devices) {
    final flags = [
      if (device.isDefaultOutput) 'default-out',
      if (device.isDefaultInput) 'default-in',
    ];
    final tag = flags.isEmpty ? '' : ' [${flags.join(', ')}]';
    print('- ${device.name}$tag (id: ${device.id})');
    if (device.defaultOutput case final out?) {
      print('    default out: $out');
    }
    if (device.defaultInput case final input?) {
      print('    default in:  $input');
    }
  }
}

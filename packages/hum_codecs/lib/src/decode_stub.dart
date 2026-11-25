import 'dart:typed_data';

import 'package:hum/hum.dart';

/// Decodes an encoded audio byte buffer into a planar 32-bit float [AudioBuffer].
Future<AudioBuffer> decodeAudio(Uint8List bytes, {String? hint}) =>
    throw UnsupportedError(
      'hum_codecs is not supported on this platform.',
    );

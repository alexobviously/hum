// Copyright (c) 2026, the hum authors. All rights reserved.
// Please see the AUTHORS file for details. Use of this source code is governed
// by a BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

const _miniaudioVersion = '0.11.26';
const _miniaudioUrl =
    'https://raw.githubusercontent.com/mackron/miniaudio/$_miniaudioVersion/miniaudio.h';
const _miniaudioSha256 =
    '6b376c7fbb1352ba1e0e432ab66069b335ea9405e45cb6c30b97ef0f3c9c3e0e';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }

    final headerDir = await _ensureMiniaudioHeader(input.outputDirectoryShared);
    final targetOS = input.config.code.targetOS;

    final cbuilder = CBuilder.library(
      name: 'hum_miniaudio',
      assetName: 'src/bindings.dart',
      sources: const ['src/hum_miniaudio.c'],
      includes: ['src', headerDir.path],
      defines: {
        if (targetOS == OS.macOS ||
            targetOS == OS.iOS ||
            targetOS == OS.android)
          'MA_NO_RUNTIME_LINKING': null,
        if (targetOS == OS.windows) 'HUM_MINIAUDIO_EXPORTS': null,
      },
      frameworks: [
        if (targetOS == OS.macOS || targetOS == OS.iOS) ...[
          'CoreFoundation',
          'CoreAudio',
          'AudioToolbox',
        ],
      ],
      libraries: [
        if (targetOS == OS.macOS || targetOS == OS.iOS) ...['pthread', 'm'],
        if (targetOS == OS.linux) ...['dl', 'pthread', 'm'],
        if (targetOS == OS.android) ...['dl', 'm', 'OpenSLES'],
      ],
      flags: [if (targetOS != OS.windows) '-fvisibility=hidden'],
    );

    await cbuilder.run(input: input, output: output);
  });
}

Future<Directory> _ensureMiniaudioHeader(Uri sharedOutputDir) async {
  final headerDir = Directory.fromUri(
    sharedOutputDir.resolve('miniaudio_$_miniaudioVersion/'),
  );
  await headerDir.create(recursive: true);

  final headerFile = File.fromUri(headerDir.uri.resolve('miniaudio.h'));
  if (await headerFile.exists()) {
    final existingDigest = sha256.convert(await headerFile.readAsBytes());
    if (existingDigest.toString() == _miniaudioSha256) {
      return headerDir;
    }
  }

  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(_miniaudioUrl));
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Failed to download miniaudio $_miniaudioVersion '
        '(HTTP ${response.statusCode})',
        uri: Uri.parse(_miniaudioUrl),
      );
    }

    final bytes = await response.fold<List<int>>(
      <int>[],
      (acc, chunk) => acc..addAll(chunk),
    );
    final actualDigest = sha256.convert(bytes).toString();
    if (actualDigest != _miniaudioSha256) {
      throw StateError(
        'SHA-256 mismatch for miniaudio.h: '
        'expected $_miniaudioSha256, got $actualDigest',
      );
    }

    final tempFile = File('${headerFile.path}.tmp.$pid');
    await tempFile.writeAsBytes(bytes, flush: true);
    await tempFile.rename(headerFile.path);
  } finally {
    client.close(force: true);
  }

  return headerDir;
}


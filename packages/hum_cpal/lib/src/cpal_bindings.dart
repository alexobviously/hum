@DefaultAsset('package:hum_cpal/src/cpal_bindings.dart')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Adds two signed 32-bit integers via the native Rust `hum_cpal_add` symbol.
@Native<Int32 Function(Int32, Int32)>(symbol: 'hum_cpal_add')
external int humCpalAdd(int a, int b);

/// Probes the default cpal host and returns a UTF-8 JSON string pointer.
///
/// Callers must free non-null pointers with [humCpalFreeString].
@Native<Pointer<Utf8> Function()>(symbol: 'hum_cpal_probe_devices_json')
external Pointer<Utf8> humCpalProbeDevicesJson();

/// Frees a Rust-allocated UTF-8 string returned by native `hum_cpal` calls.
@Native<Void Function(Pointer<Utf8>)>(symbol: 'hum_cpal_free_string')
external void humCpalFreeString(Pointer<Utf8> ptr);

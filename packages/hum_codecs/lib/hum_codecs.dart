export 'src/decode_stub.dart'
    if (dart.library.ffi) 'src/decode_native.dart'
    if (dart.library.js_interop) 'src/decode_web.dart'
    show decodeAudio;

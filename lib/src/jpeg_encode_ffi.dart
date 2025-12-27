import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:jpeg_encode_ffi/src/jpeg_encode_ffi_bindings_generated.dart';

/// Encodes the image [image] to a file at [path] in JPEG format.
///
/// [pixels] Image byte array
/// [comp] Number of image channels
/// [path] Save path
Future<void> encodeJpegImageToFile(
  ui.Image image,
  String output, {
  int quality = 95,
}) async {
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (bytes == null) {
    throw Exception('Could not converts image to byte array.');
  }
  final pixels = bytes.buffer.asUint8List();
  await encodeJpegToFile(
    pixels,
    image.width,
    image.height,
    4,
    output,
    quality: quality,
  );
}

/// Encodes the image [pixels] to a file at [path] in JPEG format
///
/// [pixels] Image byte array
/// [width] Image width
/// [height] Image height
/// [comp] Number of image channels (only 1, 3, 4 are supported)
/// [path] Save path
Future<void> encodeJpegToFile(
  Uint8List pixels,
  int width,
  int height,
  int comp,
  String path, {
  int quality = 95,
}) async {
  assert(pixels.isNotEmpty, 'pixels is empty');
  assert(width > 0 || height > 0, 'invalid width or height');
  assert(
    comp == 1 || comp == 3 || comp == 4,
    'component input 2 is not supported',
  );

  final helperIsolateSendPort = await _helperIsolateSendPort;
  final id = _nextRequestId++;
  final request = _EncodeRequest(
    id,
    pixels,
    width,
    height,
    quality,
    comp,
    path,
  );

  final completer = Completer<int>();
  _requests[id] = completer;
  helperIsolateSendPort.send(request);

  final result = await completer.future;
  if (result == 0) throw Exception('Native encode jpeg fail');
}

/// Encodes the image [image] to JPEG format and returns the bytes.
///
/// This is a convenience wrapper around [encodeJpegToBytes] that extracts
/// raw RGBA pixel data from a [ui.Image].
///
/// [quality] JPEG quality (1-100, default 95)
/// [subsampling] Chroma subsampling mode:
///   - [JpegSubsampling.auto_] (default): Uses 4:2:0 if quality <= 90, else 4:4:4
///   - [JpegSubsampling.yuv444]: Force 4:4:4 (no subsampling, higher quality, larger files)
///   - [JpegSubsampling.yuv420]: Force 4:2:0 (subsampling, smaller files)
///
/// Returns `Uint8List` containing the JPEG-encoded image data.
Future<Uint8List> encodeJpegImageToBytes(
  ui.Image image, {
  int quality = 95,
  JpegSubsampling subsampling = JpegSubsampling.auto_,
}) async {
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (bytes == null) {
    throw Exception('Could not convert image to byte array.');
  }
  return encodeJpegToBytes(
    bytes.buffer.asUint8List(),
    image.width,
    image.height,
    4, // RGBA
    quality: quality,
    subsampling: subsampling,
  );
}

/// Encodes raw pixel data to JPEG format and returns the bytes.
///
/// [pixels] Raw pixel data (RGBA, RGB, or grayscale)
/// [width] Image width in pixels
/// [height] Image height in pixels
/// [comp] Number of channels (1=grayscale, 3=RGB, 4=RGBA)
/// [quality] JPEG quality (1-100, default 95)
/// [subsampling] Chroma subsampling mode:
///   - [JpegSubsampling.auto_] (default): Uses 4:2:0 if quality <= 90, else 4:4:4
///   - [JpegSubsampling.yuv444]: Force 4:4:4 (no subsampling, higher quality, larger files)
///   - [JpegSubsampling.yuv420]: Force 4:2:0 (subsampling, smaller files)
///
/// Returns `Uint8List` containing the JPEG-encoded image data.
Future<Uint8List> encodeJpegToBytes(
  Uint8List pixels,
  int width,
  int height,
  int comp, {
  int quality = 95,
  JpegSubsampling subsampling = JpegSubsampling.auto_,
}) async {
  assert(pixels.isNotEmpty, 'pixels is empty');
  assert(width > 0 && height > 0, 'invalid width or height');
  assert(
    comp == 1 || comp == 3 || comp == 4,
    'component must be 1, 3, or 4',
  );

  // Convert enum to int for FFI
  final subsampleMode = switch (subsampling) {
    JpegSubsampling.auto_ => -1,
    JpegSubsampling.yuv444 => 0,
    JpegSubsampling.yuv420 => 1,
  };

  final helperIsolateSendPort = await _helperIsolateSendPort;
  final id = _nextRequestId++;
  final request = _EncodeToMemRequest(
    id,
    pixels,
    width,
    height,
    quality,
    comp,
    subsampleMode,
  );

  final completer = Completer<Uint8List?>();
  _memRequests[id] = completer;
  helperIsolateSendPort.send(request);

  final result = await completer.future;
  if (result == null) {
    throw Exception('Native JPEG encoding to memory failed');
  }
  return result;
}

const String _libName = 'jpeg_encode_ffi';

/// The dynamic library in which the symbols for [JpegEncodeFfiBindings] can be found.
final ffi.DynamicLibrary _dylib = () {
  if (Platform.isMacOS || Platform.isIOS) {
    return ffi.DynamicLibrary.open('$_libName.framework/$_libName');
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return ffi.DynamicLibrary.open('lib$_libName.so');
  }
  if (Platform.isWindows) {
    return ffi.DynamicLibrary.open('$_libName.dll');
  }
  throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
}();

/// The bindings to the native functions in [_dylib].
final _bindings = JpegEncodeFfiBindings(_dylib);

mixin _Freeable {
  void free();
}

/// Encodes the request.
class _EncodeRequest with _Freeable {
  _EncodeRequest(
    this.id,
    this.pixels,
    this.width,
    this.height,
    this.quality,
    this.component,
    this.outputPath, {
    // ignore: unused_element_parameter
    this.allocator = calloc,
  });

  final int id;
  final Uint8List pixels;
  final int width;
  final int height;
  final int quality;
  final int component;
  final String outputPath;
  final ffi.Allocator allocator;

  ffi.Pointer<ffi.Uint8>? _pixelsPtr;

  ffi.Pointer<ffi.Uint8> get pixelsPtr {
    if (_pixelsPtr == null) {
      var ptr = allocator<ffi.Uint8>(pixels.length);
      ptr.asTypedList(pixels.length).setAll(0, pixels);
      _pixelsPtr = ptr;
    }
    return _pixelsPtr!;
  }

  ffi.Pointer<ffi.Char>? _pathPtr;

  ffi.Pointer<ffi.Char> get pathPtr {
    _pathPtr ??= outputPath.toNativeUtf8(allocator: allocator).cast();
    return _pathPtr!;
  }

  @override
  void free() {
    if (_pixelsPtr != null) {
      allocator.free(_pixelsPtr!);
      _pixelsPtr = null;
    }
    if (_pathPtr != null) {
      allocator.free(_pathPtr!);
      _pathPtr = null;
    }
  }
}

/// Encodes the response
class _EncodeResponse {
  final int id;
  final int result;

  const _EncodeResponse(this.id, this.result);
}

/// Chroma subsampling mode for JPEG encoding
enum JpegSubsampling {
  /// Automatically determine based on quality (4:2:0 if quality <= 90, else 4:4:4)
  auto_,
  /// Force 4:4:4 - no chroma subsampling (higher quality, larger files)
  yuv444,
  /// Force 4:2:0 - chroma subsampling (smaller files)
  yuv420,
}

/// Request for encoding to memory (returns bytes)
class _EncodeToMemRequest with _Freeable {
  _EncodeToMemRequest(
    this.id,
    this.pixels,
    this.width,
    this.height,
    this.quality,
    this.component,
    this.subsampleMode,
  );

  final int id;
  final Uint8List pixels;
  final int width;
  final int height;
  final int quality;
  final int component;
  final int subsampleMode; // -1 = auto, 0 = 4:4:4, 1 = 4:2:0

  ffi.Pointer<ffi.Uint8>? _pixelsPtr;

  ffi.Pointer<ffi.Uint8> get pixelsPtr {
    if (_pixelsPtr == null) {
      var ptr = malloc<ffi.Uint8>(pixels.length);
      ptr.asTypedList(pixels.length).setAll(0, pixels);
      _pixelsPtr = ptr;
    }
    return _pixelsPtr!;
  }

  @override
  void free() {
    if (_pixelsPtr != null) {
      malloc.free(_pixelsPtr!);
      _pixelsPtr = null;
    }
  }
}

/// Response containing encoded JPEG bytes
class _EncodeToMemResponse {
  final int id;
  final Uint8List? bytes;
  final bool success;

  const _EncodeToMemResponse(this.id, this.bytes, this.success);
}

/// Counter to identify [_EncodeRequest]s and [_EncodeResponse]s.
int _nextRequestId = 0;

/// Mapping from [_EncodeRequest] `id`s to the completers corresponding to the correct future of the pending request.
final _requests = <int, Completer<int>>{};

/// Mapping for memory encode requests
final _memRequests = <int, Completer<Uint8List?>>{};

/// The SendPort belonging to the helper isolate.
Future<SendPort> _helperIsolateSendPort = () async {
  // The helper isolate is going to send us back a SendPort, which we want to
  // wait for.
  final completer = Completer<SendPort>();

  // Receive port on the main isolate to receive messages from the helper.
  // We receive two types of messages:
  // 1. A port to send messages on.
  // 2. Responses to requests we sent.
  final receivePort = ReceivePort()
    ..listen((dynamic data) {
      if (data is SendPort) {
        // The helper isolate sent us the port on which we can sent it requests.
        completer.complete(data);
        return;
      }
      if (data is _EncodeResponse) {
        // The helper isolate sent us a response to a request we sent.
        final completer = _requests[data.id]!;
        _requests.remove(data.id);
        completer.complete(data.result);
        return;
      }
      if (data is _EncodeToMemResponse) {
        final completer = _memRequests[data.id]!;
        _memRequests.remove(data.id);
        completer.complete(data.bytes);
        return;
      }
      throw UnsupportedError('Unsupported message type: ${data.runtimeType}');
    });

  // Start the helper isolate.
  await Isolate.spawn((SendPort sendPort) async {
    final helperReceivePort = ReceivePort()
      ..listen((dynamic data) {
        // On the helper isolate listen to requests and respond to them.
        if (data is _EncodeRequest) {
          try {
            final result = _bindings.jo_write_jpg(
              data.pathPtr,
              data.pixelsPtr.cast(),
              data.width,
              data.height,
              data.component,
              data.quality,
            );
            final response = _EncodeResponse(data.id, result);
            sendPort.send(response);
            return;
          } finally {
            data.free();
          }
        }
        if (data is _EncodeToMemRequest) {
          try {
            final result = _bindings.jo_encode_jpg_to_mem(
              data.pixelsPtr.cast(),
              data.width,
              data.height,
              data.component,
              data.quality,
              data.subsampleMode,
            );
            
            Uint8List? bytes;
            if (result.data != ffi.nullptr && result.size > 0) {
              // Copy the data to Dart-managed memory
              bytes = Uint8List.fromList(
                result.data.cast<ffi.Uint8>().asTypedList(result.size),
              );
              // Free the native buffer
              _bindings.jo_free_buffer(result.data);
            }
            
            final response = _EncodeToMemResponse(data.id, bytes, bytes != null);
            sendPort.send(response);
            return;
          } finally {
            data.free();
          }
        }
        throw UnsupportedError(
          'Unsupported message type: ${data.runtimeType}',
        );
      });

    // Send the port to the main isolate on which we can receive requests.
    sendPort.send(helperReceivePort.sendPort);
  }, receivePort.sendPort);

  // Wait until the helper isolate has sent us back the SendPort on which we
  // can start sending requests.
  return completer.future;
}();

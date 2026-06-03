/// Silent full-desktop screen capture on Windows via Win32 GDI.
///
/// Why not `screen_capturer`: on Windows it shells out to
/// `SnippingTool.exe`, which is visible to anyone watching the
/// screen-share. This file does the capture in-process with no UI
/// chrome by walking the BitBlt -> GetDIBits -> PNG-encode path.
///
/// Combined with the runner's `SetWindowDisplayAffinity(WDA_EXCLUDE-
/// FROMCAPTURE)`, on Windows 10 v2004+ our own window is also
/// excluded from the captured image automatically — so the user can
/// keep our overlay open while solving.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;
import 'package:win32/win32.dart';

class SilentCaptureResult {
  /// PNG-encoded bytes ready to upload.
  final Uint8List bytes;
  final String filename;
  final int width;
  final int height;
  SilentCaptureResult({
    required this.bytes,
    required this.filename,
    required this.width,
    required this.height,
  });
}

class SilentCaptureError implements Exception {
  final String message;
  SilentCaptureError(this.message);
  @override
  String toString() => message;
}

class SilentCapture {
  /// Returns true if this platform supports silent capture without UI.
  static bool get isSupported => Platform.isWindows;

  /// Capture the entire virtual desktop (all monitors combined) as PNG.
  ///
  /// Runs the GDI dance on a background isolate-free path; the actual
  /// FFI calls are blocking but very fast (typically < 50ms for a 4K
  /// display). PNG encoding adds another 50-200ms.
  static Future<SilentCaptureResult> captureFullScreen() async {
    if (!Platform.isWindows) {
      throw SilentCaptureError(
        'Silent capture is only implemented on Windows in this build.',
      );
    }

    // Capture geometry — full virtual screen so multi-monitor setups
    // grab everything in one shot.
    final left = GetSystemMetrics(SM_XVIRTUALSCREEN);
    final top = GetSystemMetrics(SM_YVIRTUALSCREEN);
    final width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    final height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    if (width <= 0 || height <= 0) {
      throw SilentCaptureError(
        'Could not read screen dimensions ($width x $height).',
      );
    }

    final hdcScreen = GetDC(NULL);
    if (hdcScreen == 0) {
      throw SilentCaptureError('GetDC(NULL) failed — cannot read desktop DC.');
    }

    int hdcMem = 0;
    int hBitmap = 0;
    int oldBitmap = 0;
    Pointer<BITMAPINFO>? bmiPtr;
    Pointer<Uint8>? pixelsPtr;

    try {
      hdcMem = CreateCompatibleDC(hdcScreen);
      if (hdcMem == 0) {
        throw SilentCaptureError('CreateCompatibleDC failed.');
      }
      hBitmap = CreateCompatibleBitmap(hdcScreen, width, height);
      if (hBitmap == 0) {
        throw SilentCaptureError('CreateCompatibleBitmap failed.');
      }
      oldBitmap = SelectObject(hdcMem, hBitmap);

      // Copy the desktop. CAPTUREBLT ensures layered windows render
      // properly into the captured bitmap; without it, top-most or
      // alpha-blended UI may come out as black artifacts.
      final ok = BitBlt(
        hdcMem,
        0,
        0,
        width,
        height,
        hdcScreen,
        left,
        top,
        SRCCOPY | CAPTUREBLT,
      );
      if (ok == 0) {
        throw SilentCaptureError('BitBlt failed.');
      }

      // Pull the pixels out as a top-down BGRA buffer.
      bmiPtr = calloc<BITMAPINFO>();
      bmiPtr.ref.bmiHeader.biSize = sizeOf<BITMAPINFOHEADER>();
      bmiPtr.ref.bmiHeader.biWidth = width;
      bmiPtr.ref.bmiHeader.biHeight = -height; // negative -> top-down rows
      bmiPtr.ref.bmiHeader.biPlanes = 1;
      bmiPtr.ref.bmiHeader.biBitCount = 32;
      bmiPtr.ref.bmiHeader.biCompression = BI_RGB;

      final pixelByteCount = width * height * 4;
      pixelsPtr = calloc<Uint8>(pixelByteCount);

      final rowsCopied = GetDIBits(
        hdcMem,
        hBitmap,
        0,
        height,
        pixelsPtr,
        bmiPtr,
        DIB_RGB_COLORS,
      );
      if (rowsCopied == 0) {
        throw SilentCaptureError('GetDIBits returned 0 rows.');
      }

      // BGRA -> RGBA in-place, into a Dart-owned buffer.
      final dartBytes = Uint8List(pixelByteCount);
      final src = pixelsPtr.asTypedList(pixelByteCount);
      for (var i = 0; i < pixelByteCount; i += 4) {
        dartBytes[i] = src[i + 2];     // R
        dartBytes[i + 1] = src[i + 1]; // G
        dartBytes[i + 2] = src[i];     // B
        dartBytes[i + 3] = 0xFF;       // A — discard the alpha GDI gives us;
                                        // it's usually zero for desktop captures
                                        // and would make the PNG fully transparent.
      }

      // Encode to PNG. Run on a background helper to avoid stalling
      // the UI for large screens.
      final pngBytes = await _encodePng(
        width: width,
        height: height,
        rgba: dartBytes,
      );

      final ts = DateTime.now().millisecondsSinceEpoch;
      return SilentCaptureResult(
        bytes: pngBytes,
        filename: 'solve-$ts.png',
        width: width,
        height: height,
      );
    } finally {
      if (oldBitmap != 0) SelectObject(hdcMem, oldBitmap);
      if (hBitmap != 0) DeleteObject(hBitmap);
      if (hdcMem != 0) DeleteDC(hdcMem);
      ReleaseDC(NULL, hdcScreen);
      if (bmiPtr != null) calloc.free(bmiPtr);
      if (pixelsPtr != null) calloc.free(pixelsPtr);
    }
  }
}

Future<Uint8List> _encodePng({
  required int width,
  required int height,
  required Uint8List rgba,
}) async {
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    order: img.ChannelOrder.rgba,
    numChannels: 4,
  );
  // level 3 is the libpng-default "fast" preset — fine for OCR; we
  // don't need maximum compression for an in-process upload.
  final png = img.encodePng(image, level: 3);
  return Uint8List.fromList(png);
}

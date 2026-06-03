/// Screenshot acquisition for the Solve screen.
///
/// Windows desktop: in-process Win32 GDI capture via [SilentCapture] —
///   completely silent, no SnippingTool, no UI chrome shown to anyone
///   sharing the screen.
/// macOS / Linux desktop: not yet wired (silent_capture is Windows-only).
///   We surface a clear error so the user knows to fall back to the
///   image picker.
/// Mobile / Web: image picker, since silent screen capture isn't
///   permitted on those platforms anyway.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image_picker/image_picker.dart';

import 'silent_capture.dart';

class ScreenCaptureResult {
  final Uint8List bytes;
  final String filename;
  ScreenCaptureResult(this.bytes, this.filename);
}

class ScreenCaptureService {
  final ImagePicker _picker = ImagePicker();

  /// Grab a screenshot using the best path for the current platform.
  /// Returns null if the user cancels the picker; throws on a real failure.
  Future<ScreenCaptureResult?> capture() async {
    if (!kIsWeb && Platform.isWindows) {
      final shot = await SilentCapture.captureFullScreen();
      return ScreenCaptureResult(shot.bytes, shot.filename);
    }
    // Other desktops: fall through to the image picker for now. Users on
    // macOS/Linux can press their OS hotkey to take a screenshot and
    // then pick it through the file dialog.
    return _pickFile();
  }

  Future<ScreenCaptureResult?> _pickFile() async {
    final picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return null;
    final bytes = await picked.readAsBytes();
    return ScreenCaptureResult(bytes, picked.name);
  }
}

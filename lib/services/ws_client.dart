/// WebSocket client for the live-listen pipeline.
///
/// Wraps `web_socket_channel` so the Live Listen screen consumes a
/// simple `Stream<LiveEvent>` and gets `sendPcm(...)` / `sendText(...)`
/// methods without touching the raw channel.
///
/// Protocol mirrors `backend/app/api/routes_ws.py`:
///   - Binary frames carry int16 PCM at cfg.audio.sample_rate.
///   - Text frames carry JSON: {type, ...}.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

class LiveEvent {
  final String type;
  final Map<String, dynamic> data;
  LiveEvent(this.type, this.data);

  factory LiveEvent.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String? ?? 'unknown';
    final data = Map<String, dynamic>.from(json)..remove('type');
    return LiveEvent(type, data);
  }
}

class WsClient {
  final String baseUrl;
  final String wsPath;
  final String? resumeId;
  final String? sessionId;

  WebSocketChannel? _channel;
  StreamController<LiveEvent>? _events;

  WsClient({
    required this.baseUrl,
    this.wsPath = '/ws/live',
    this.resumeId,
    this.sessionId,
  });

  Stream<LiveEvent> connect() {
    final ws = _toWsScheme(baseUrl);
    final qs = <String, String>{};
    if (resumeId != null) qs['resume_id'] = resumeId!;
    if (sessionId != null) qs['session_id'] = sessionId!;
    final qsStr = qs.isEmpty
        ? ''
        : '?${qs.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&')}';

    // IOWebSocketChannel is the dart:io (desktop) implementation. It surfaces
    // connection failures reliably via `.ready` and supports a connect
    // timeout, unlike the generic `WebSocketChannel.connect` which can hang
    // on a dead/refused port on Windows. This app is desktop-only.
    _channel = IOWebSocketChannel.connect(
      Uri.parse('$ws$wsPath$qsStr'),
      connectTimeout: const Duration(seconds: 8),
    );
    _events = StreamController<LiveEvent>.broadcast();

    _channel!.stream.listen(
      (msg) {
        if (msg is String) {
          try {
            final decoded = jsonDecode(msg) as Map<String, dynamic>;
            _events!.add(LiveEvent.fromJson(decoded));
          } catch (_) {/* ignore malformed frame */}
        }
      },
      onError: (e) => _events!.add(LiveEvent('error', {'detail': '$e'})),
      onDone: () {
        _events!.add(LiveEvent('closed', {}));
        _events!.close();
      },
    );

    return _events!.stream;
  }

  /// Completes once the underlying socket has actually connected, or throws
  /// if the connection fails (e.g. the backend isn't running). Call this
  /// after [connect] to detect failures — `WebSocketChannel.connect` is lazy
  /// and won't surface a refused/closed port synchronously.
  Future<void> get ready async {
    final ch = _channel;
    if (ch == null) {
      throw StateError('connect() must be called before awaiting ready');
    }
    await ch.ready;
  }

  /// The resolved WebSocket URL (for diagnostics / error messages).
  String get url {
    final ws = _toWsScheme(baseUrl);
    return '$ws$wsPath';
  }

  /// Send a JSON control frame (text / flush / stop / ping).
  void sendText(Map<String, dynamic> payload) {
    _channel?.sink.add(jsonEncode(payload));
  }

  /// Send a binary frame of int16 little-endian PCM samples.
  void sendPcm(Uint8List bytes) {
    _channel?.sink.add(bytes);
  }

  /// Ask the backend to capture audio itself (system loopback / mic) and run
  /// it through the live pipeline. Used for "Interviewer (system audio)" mode,
  /// where the other party's voice comes out of the speakers and the Flutter
  /// `record` package can't capture it.
  void startCapture({String source = 'system_loopback'}) {
    sendText({'type': 'start_capture', 'source': source});
  }

  /// Stop a server-side capture started with [startCapture].
  void stopCapture() {
    sendText({'type': 'stop_capture'});
  }

  Future<void> close() async {
    await _channel?.sink.close();
    await _events?.close();
  }

  static String _toWsScheme(String httpUrl) {
    var u = httpUrl;
    if (u.startsWith('https://')) {
      u = u.replaceFirst('https://', 'wss://');
    } else if (u.startsWith('http://')) {
      u = u.replaceFirst('http://', 'ws://');
    }
    // Force IPv4 loopback. On Windows, `localhost` frequently resolves to
    // IPv6 `::1` first, but uvicorn binds to IPv4 `127.0.0.1` (config
    // server.host), so a `localhost` WebSocket gets connection-refused.
    // Matching the bind address avoids that silent failure.
    u = u.replaceFirst('//localhost:', '//127.0.0.1:');
    u = u.replaceFirst('//localhost/', '//127.0.0.1/');
    return u;
  }
}

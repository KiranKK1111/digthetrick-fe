// Smoke test: the app boots and renders the loading screen.
// Real screens depend on a running backend, so we don't drive further
// interactions here. Add screen-level tests with mock HTTP/WebSocket
// clients when the surface stabilises.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:digthetrick_ai_thin_slice/main.dart';

void main() {
  testWidgets('App boots and shows the loading state', (tester) async {
    await tester.pumpWidget(const DigTheTrickAIApp());
    expect(find.byType(MaterialApp), findsOneWidget);
    // Bootstrap shows a CircularProgressIndicator until /api/settings resolves.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}

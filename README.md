# DigTheTrick AI — Thin-Slice UI

A minimal but **fully working** Flutter chat UI: streaming markdown rendering,
syntax-highlighted code blocks with copy buttons, conversation continuity, and
a live connection-status indicator.

It talks to the thin-slice backend in `../backend`. Start the backend first.

## Prerequisites

1. **Flutter SDK 3.3+** — https://docs.flutter.dev/get-started/install
2. The **backend running** on `http://127.0.0.1:8000` (see `../backend/README.md`)

## Setup

The **web platform folder is already included**, so there is no scaffolding
step for the web build. Just fetch dependencies:

```bash
cd flutter_app
flutter pub get
```

> Adding other platforms later: this package ships only the `web/` platform
> folder. To also target desktop or mobile, run `flutter create .` from this
> directory once — it generates the missing platform folders (`windows/`,
> `macos/`, `linux/`, etc.) around the existing `lib/`, `web/`, and
> `pubspec.yaml` without overwriting them.

## Run

The web build needs no desktop toolchain:

```bash
flutter run -d chrome
```

For a desktop window instead, scaffold the platform first (see the note
above), then:

```bash
flutter config --enable-windows-desktop   # once
flutter run -d windows
```

The app opens, shows "backend ok · ollama ok · llama3.2" in the header if the
backend is reachable, and you can start asking questions.

## Configuration

The backend URL is set in `lib/services/api_service.dart`:

```dart
ApiService({this.baseUrl = 'http://127.0.0.1:8000'});
```

Change the default if your backend runs elsewhere. When running the **web**
build, `127.0.0.1` works because the browser and backend share the machine.

> Note: if you run the web app and the browser blocks the request with a CORS
> error, confirm the backend's `DIGTHETRICK_CORS_ORIGINS` includes your origin. It
> defaults to `*`, which is fine for local development.

## What it does

- **Streaming chat** — assistant replies render token-by-token with a live
  cursor, via the backend's SSE endpoint.
- **Markdown rendering** — headings, lists, bold, inline code, blockquotes.
- **Code blocks** — fenced code renders syntax-highlighted, with a copy button
  and the language label.
- **Intent chips** — each assistant message shows which intent the backend's
  Sense→Plan step picked (behavioral / coding / concept / general).
- **Conversation continuity** — follow-up messages continue the same
  conversation; the backend persists everything.
- **New conversation** — the `+` button in the header starts fresh.
- **Connection status** — the header shows whether the backend and Ollama are
  reachable, checked on startup.
- **Error handling** — backend or Ollama failures show a red banner instead of
  crashing.

## Project layout

```
flutter_app/
├── lib/
│   ├── main.dart                    app entry point + theme
│   ├── models/
│   │   └── models.dart              Message, ConversationSummary, StreamEvent
│   ├── services/
│   │   └── api_service.dart         backend client + SSE stream parser
│   ├── widgets/
│   │   ├── code_block.dart          highlighted code block + copy button
│   │   └── message_bubble.dart      one chat bubble (markdown for assistant)
│   └── screens/
│       └── chat_screen.dart         the main screen + streaming logic
├── web/                             web platform folder (included)
│   ├── index.html
│   ├── manifest.json
│   ├── favicon.png
│   └── icons/                       PWA icons (placeholder art — replace freely)
├── pubspec.yaml
├── analysis_options.yaml
├── .metadata
├── .gitignore
└── README.md
```

> The icons in `web/icons/` and `web/favicon.png` are simple generated
> placeholders so nothing 404s. Replace them with your own art any time —
> they are not referenced by the Dart code, only by the browser.

## Where to go next

This UI is intentionally one screen. Natural extensions, matching the
architecture document:

1. **A conversation sidebar** — `GET /api/conversations` is already there;
   add a drawer that lists them and loads one on tap via
   `getConversationMessages`.
2. **The clarification popup** — when the backend gains an ambiguity score,
   surface a clarifying-question UI before streaming the answer.
3. **Settings** — expose the backend URL and model in a settings screen
   instead of a hardcoded default.
4. **Response-shape rendering** — when the backend starts returning structured
   shapes, render them with shape-specific widgets instead of plain markdown.

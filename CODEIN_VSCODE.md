# CodeIn → embedded DigTheTrick IDE (VS Code / code-server)

CodeIn no longer ships a Dart reimplementation of the VS Code workbench. It now
embeds the **DigTheTrick fork of VS Code** — served locally by
`digthetrick-server` (an [openvscode-server] build of `../vscode-main`) — inside
a Flutter webview (`flutter_inappwebview`).

Because the server is built from the **same source** as the desktop fork, it
inherits everything that was done there:
- DigTheTrick branding (`product.json`)
- the **DigTheTrick Dark** default theme (pink `#FFB6C1`)
- the removed Accounts/login UI
- the **`digthetrick-chat`** extension — the GUI replica of the digthetrick CLI

The Flutter side (`lib/screens/codein_screen.dart`) **spawns and owns** the
server: when you open the CodeIn tab it launches `digthetrick-server` on
`127.0.0.1:9888`, waits until it answers, then loads
`http://127.0.0.1:9888/?folder=<workspace>` in the webview. It kills the process
when the tab/app closes. If the server binary isn't found, CodeIn shows a
"build the IDE first" message instead of a blank page.

---

## 1. Build the server (once)

From the fork checkout:

```powershell
cd D:\SDM_GENAI\DigTheTrickAI\vscode-main
npm install                                   # if not already done
npm run gulp vscode-reh-web-win32-x64-min     # web/remote-extension-host build
```

This produces a `vscode-reh-web-win32-x64/` folder (a sibling of `vscode-main`)
containing a server launcher (`bin\code-server-oss.cmd` / `server.cmd` depending
on the build). That launcher is the openvscode-server entry point.

> Alternative: use the upstream **openvscode-server** packaging if you prefer a
> prebuilt server, then drop the fork's `extensions/theme-digthetrick` and
> `extensions/digthetrick-chat` into its `extensions/` and set the product
> branding. The gulp build above is the cleaner path since it bakes them in.

## 2. Make it discoverable as `digthetrick-server`

`codein_screen.dart` looks for the launcher (first match wins):

1. `--dart-define=DIGTHETRICK_SERVER=<full path to launcher>` (explicit override)
2. `<flutter-app-exe-dir>\digthetrick-server\digthetrick-server.cmd` (packaged)
3. `D:\SDM_GENAI\DigTheTrickAI\vscode-main\.build\reh-web\digthetrick-server.cmd`
4. `D:\SDM_GENAI\DigTheTrickAI\digthetrick-server\digthetrick-server.cmd`

Easiest dev setup — copy the build to a stable folder and name the launcher
`digthetrick-server.cmd`:

```powershell
# example: stage the build where CodeIn looks for it
New-Item -ItemType Directory -Force D:\SDM_GENAI\DigTheTrickAI\digthetrick-server
Copy-Item -Recurse D:\SDM_GENAI\DigTheTrickAI\vscode-reh-web-win32-x64\* `
  D:\SDM_GENAI\DigTheTrickAI\digthetrick-server\
# create digthetrick-server.cmd that calls the real server launcher, e.g.:
#   @echo off
#   "%~dp0bin\code-server-oss.cmd" %*
```

…or just skip staging and point CodeIn straight at the build:

```powershell
flutter run -d windows ^
  --dart-define=DIGTHETRICK_SERVER=D:\SDM_GENAI\DigTheTrickAI\vscode-reh-web-win32-x64\bin\code-server-oss.cmd
```

## 3. Server flags CodeIn uses

CodeIn launches the server with:

```
--host 127.0.0.1 --port 9888 --without-connection-token --accept-server-license-terms
```

`--without-connection-token` is intentional: this is a local, single-user,
loopback-only embed, so no auth token is needed. (If you'd rather use a token,
add it to `_spawnServer` in `codein_screen.dart` and append `&tkn=<token>` to the
URL.)

## 4. Workspace

CodeIn opens `D:\SDM_GENAI\DigTheTrickAI` by default. Override with:

```powershell
flutter run -d windows --dart-define=DIGTHETRICK_WORKSPACE=D:\path\to\project
```

---

## Run it

```powershell
cd D:\SDM_GENAI\DigTheTrickAI\digthetrick_fe
flutter pub get
flutter run -d windows
# click the CodeIn tab → "Starting DigTheTrick IDE…" → the editor loads
```

If you see "DigTheTrick IDE server not found", you haven't built/staged the
server yet (step 1–2), or the launcher path doesn't match the candidates above —
use the `DIGTHETRICK_SERVER` dart-define to point at it explicitly.

---

## Notes

- **WebView2 runtime** ships with Windows 11; `flutter_inappwebview` uses it on
  Windows. No extra install on Win11.
- The server process is owned by the Flutter app — it starts on first CodeIn open
  and is killed on dispose/app exit. Opening CodeIn again reuses a server that's
  already up (it checks the port first).
- This file documents the one prerequisite the agent couldn't do for you: the
  multi-GB `npm run gulp` server build. Everything Flutter-side is already wired.

[openvscode-server]: https://github.com/gitpod-io/openvscode-server

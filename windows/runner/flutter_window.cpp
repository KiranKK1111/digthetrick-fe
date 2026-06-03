#include "flutter_window.h"

#include <optional>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <shobjidl.h>     // ITaskbarList3 / CLSID_TaskbarList — the
                          // canonical way to remove a window from the
                          // taskbar without a ShowWindow(HIDE)/SHOW
                          // cycle (which crashes the engine on some
                          // Win11 builds). The same DeleteTab call
                          // also makes the window disappear from
                          // Task Manager's "Apps" group.

#include "flutter/generated_plugin_registrant.h"


// Stealth constants the Windows SDK may or may not define depending
// on the toolchain.
#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif
#ifndef WDA_NONE
#define WDA_NONE 0x00000000
#endif


// Apply the taskbar / Alt-Tab hide via WS_EX_TOOLWINDOW + ITaskbarList3.
//
// Two steps, both on the same HWND, no ShowWindow cycle:
//   1. SetWindowLongPtrW(GWL_EXSTYLE, +WS_EX_TOOLWINDOW -WS_EX_APPWINDOW)
//      — removes the window from Alt-Tab. (When un-hiding we swap
//      the bits back the other way.)
//   2. ITaskbarList3::DeleteTab / AddTab — removes/restores the
//      taskbar entry directly, and the Task Manager "Apps" group
//      follows because it reads from the same shell window-list.
//
// Returns true on success.
static bool ApplyTaskbarHide(HWND hwnd, bool hidden) {
  // 1. Style swap.
  LONG_PTR current = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
  LONG_PTR next = hidden
      ? (current | WS_EX_TOOLWINDOW) & ~WS_EX_APPWINDOW
      : (current | WS_EX_APPWINDOW) & ~WS_EX_TOOLWINDOW;
  if (next != current) {
    SetWindowLongPtrW(hwnd, GWL_EXSTYLE, next);
  }

  // 2. Taskbar registration via ITaskbarList3.
  bool ok = false;
  ITaskbarList3* tbl = nullptr;
  HRESULT hr = CoCreateInstance(
      CLSID_TaskbarList, nullptr, CLSCTX_INPROC_SERVER,
      IID_PPV_ARGS(&tbl));
  if (SUCCEEDED(hr) && tbl) {
    tbl->HrInit();
    if (hidden) {
      ok = SUCCEEDED(tbl->DeleteTab(hwnd));
    } else {
      ok = SUCCEEDED(tbl->AddTab(hwnd));
    }
    tbl->Release();
  }
  return ok;
}


// Apply overlay mode — always-on-top + 50% alpha.
//
// When stealth is ON the window is removed from the taskbar AND
// Alt-Tab, which means an `Alt-Tab → another app` flow leaves no
// way back to DigTheTrick. The fix is to pin the window topmost
// so it stays visible above whatever the user switches to. Pair
// with 50% alpha so they can still see / interact with the app
// underneath.
//
// SetLayeredWindowAttributes(LWA_ALPHA) requires WS_EX_LAYERED on
// the window; we toggle it here as part of the same swap. Flutter
// renders fine through a layered window on Windows 10/11 — the
// DXGI swapchain composes through DWM correctly.
static void ApplyOverlay(HWND hwnd, bool overlay) {
  // 1. Always-on-top. HWND_NOTOPMOST drops it back to normal Z-order.
  SetWindowPos(
      hwnd, overlay ? HWND_TOPMOST : HWND_NOTOPMOST,
      0, 0, 0, 0,
      SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);

  // 2. Layered + alpha. ~50% on, fully opaque off.
  LONG_PTR ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
  if (overlay) {
    if (!(ex & WS_EX_LAYERED)) {
      SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex | WS_EX_LAYERED);
    }
    // 191 / 255 ≈ 75% opaque (≈ 25% see-through). Reads as a clear
    // overlay while still letting you see the app underneath.
    SetLayeredWindowAttributes(hwnd, 0, /*alpha=*/191, LWA_ALPHA);
  } else {
    // Restore opacity first, then peel WS_EX_LAYERED — peeling
    // before the alpha reset can briefly render the window at the
    // old alpha against the unlayered surface.
    SetLayeredWindowAttributes(hwnd, 0, /*alpha=*/255, LWA_ALPHA);
    if (ex & WS_EX_LAYERED) {
      SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex & ~WS_EX_LAYERED);
    }
  }
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Stealth method channel — Dart calls
  //   `MethodChannel("digthetrick/stealth").invokeMethod("setEnabled", true|false)`
  // and we apply it directly to OUR window handle (the one Win32Window
  // owns via GetHandle()). No FFI guesswork about which HWND to use.
  //
  // Returns a map: {"capture": bool, "taskbar": bool} reporting what
  // actually took effect.
  auto messenger = flutter_controller_->engine()->messenger();
  stealth_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "digthetrick/stealth",
          &flutter::StandardMethodCodec::GetInstance());
  stealth_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "setEnabled") {
          result->NotImplemented();
          return;
        }
        const auto* enabled = std::get_if<bool>(call.arguments());
        if (!enabled) {
          result->Error("ARG", "expected bool argument");
          return;
        }
        const HWND hwnd = GetHandle();
        bool capture_ok = false;
        bool taskbar_ok = false;
        if (hwnd) {
          // Capture exclusion — proven-stable on Win10 v2004+.
          capture_ok = SetWindowDisplayAffinity(
              hwnd, *enabled ? WDA_EXCLUDEFROMCAPTURE : WDA_NONE) != 0;
          // Taskbar + Alt-Tab + Task Manager "Apps" group.
          // ApplyTaskbarHide combines a style swap (no ShowWindow
          // cycle) with ITaskbarList3::DeleteTab — the canonical
          // way to remove a window from the taskbar at runtime.
          taskbar_ok = ApplyTaskbarHide(hwnd, *enabled);
          // Overlay — always-on-top + 50% alpha when ON so an
          // Alt-Tab away doesn't bury the window (the user can't
          // get it back via the taskbar when stealth's on).
          ApplyOverlay(hwnd, *enabled);
        }
        flutter::EncodableMap reply{
            {flutter::EncodableValue("capture"),
             flutter::EncodableValue(capture_ok)},
            {flutter::EncodableValue("taskbar"),
             flutter::EncodableValue(taskbar_ok)},
        };
        result->Success(flutter::EncodableValue(reply));
      });

  // Native window channel — maximize/restore that works even though
  // we strip WS_MAXIMIZEBOX (to disable the Windows 11 Snap Layouts
  // flyout). window_manager.maximize() posts WM_SYSCOMMAND/SC_MAXIMIZE,
  // which DefWindowProc ignores without the maximize box. ShowWindow
  // bypasses that, and the WM_SIZE it generates still drives
  // window_manager's work-area NCCALCSIZE clamp + its maximize/
  // unmaximize events. isMaximized uses IsZoomed (== SW_MAXIMIZE).
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "digthetrick/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        const HWND hwnd = GetHandle();
        if (!hwnd) {
          result->Error("NO_HWND", "window handle unavailable");
          return;
        }
        const std::string& m = call.method_name();
        if (m == "maximize") {
          ShowWindow(hwnd, SW_MAXIMIZE);
          result->Success();
        } else if (m == "unmaximize") {
          ShowWindow(hwnd, SW_RESTORE);
          result->Success();
        } else if (m == "isMaximized") {
          result->Success(
              flutter::EncodableValue(IsZoomed(hwnd) != 0));
        } else {
          result->NotImplemented();
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Clamp the maximized size to the monitor *work area* (excludes the
  // taskbar). We must do this BEFORE window_manager's delegate runs:
  //
  //   * We strip WS_MAXIMIZEBOX (to kill the Win11 Snap Layouts flyout),
  //     and a borderless/custom-frame window without it gets maximized to
  //     the full monitor rect by default — so the bottom slides under the
  //     taskbar.
  //   * window_manager's own NCCALCSIZE adjustment only corrects the
  //     left/top offset, not a bottom/right taskbar, so it can't fix this.
  //
  // Setting ptMaxSize/ptMaxPosition here pins the maximized frame to
  // rcWork exactly. window_manager still runs afterwards and only sets the
  // min/max *track* sizes, so the two don't conflict.
  if (message == WM_GETMINMAXINFO) {
    HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi = {};
    mi.cbSize = sizeof(mi);
    if (GetMonitorInfo(monitor, &mi)) {
      auto* mmi = reinterpret_cast<MINMAXINFO*>(lparam);
      // ptMaxPosition is relative to the monitor's top-left.
      mmi->ptMaxPosition.x = mi.rcWork.left - mi.rcMonitor.left;
      mmi->ptMaxPosition.y = mi.rcWork.top - mi.rcMonitor.top;
      mmi->ptMaxSize.x = mi.rcWork.right - mi.rcWork.left;
      mmi->ptMaxSize.y = mi.rcWork.bottom - mi.rcWork.top;
      // Fall through so window_manager can still set track sizes.
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

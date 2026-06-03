#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Stealth toggle channel. Dart side calls
  // `digthetrick/stealth#setEnabled(bool)` and we apply
  // SetWindowDisplayAffinity + tool-window-style swap directly
  // to OUR HWND. No FFI / FindWindow guesswork.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      stealth_channel_;

  // Native maximize channel. Dart calls
  // `digthetrick/window#maximize|unmaximize|isMaximized`. We strip
  // WS_MAXIMIZEBOX (in main.dart, to kill the Win11 Snap Layouts
  // flyout), which makes window_manager's SC_MAXIMIZE a no-op — so
  // we maximize via ShowWindow(SW_MAXIMIZE) here instead, which
  // ignores the missing maximize box. The resulting WM_SIZE still
  // lets window_manager constrain the frame to the monitor work
  // area (no taskbar overlap) and emit its maximize/unmaximize
  // events, so the Dart WindowListener state sync is unaffected.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_

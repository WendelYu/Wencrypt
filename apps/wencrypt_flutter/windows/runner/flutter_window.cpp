#include "flutter_window.h"

#include <cstring>
#include <optional>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "../../../../platform_probes/windows/device_probe.h"

#include "flutter/generated_plugin_registrant.h"

namespace {
bool CopyPng(HWND owner, const std::vector<uint8_t>& png) {
  if (png.empty()) {
    return false;
  }
  const UINT format = RegisterClipboardFormatW(L"PNG");
  if (format == 0) {
    return false;
  }
  HGLOBAL buffer = GlobalAlloc(GMEM_MOVEABLE, png.size());
  if (!buffer) {
    return false;
  }
  void* destination = GlobalLock(buffer);
  if (!destination) {
    GlobalFree(buffer);
    return false;
  }
  std::memcpy(destination, png.data(), png.size());
  GlobalUnlock(buffer);
  if (!OpenClipboard(owner)) {
    GlobalFree(buffer);
    return false;
  }
  const bool copied = EmptyClipboard() && SetClipboardData(format, buffer);
  CloseClipboard();
  if (!copied) {
    GlobalFree(buffer);
  }
  return copied;
}
}  // namespace

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
  flutter::MethodChannel<flutter::EncodableValue> device_channel(
      flutter_controller_->engine()->messenger(), "org.wencrypt.p0/device",
      &flutter::StandardMethodCodec::GetInstance());
  device_channel.SetMethodCallHandler([](const auto& call, auto result) {
    result->Success(WindowsDeviceProbe(call.method_name()));
  });
  flutter::MethodChannel<flutter::EncodableValue> image_channel(
      flutter_controller_->engine()->messenger(), "org.wencrypt.entry-image",
      &flutter::StandardMethodCodec::GetInstance());
  image_channel.SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() != "copyPng") {
      result->NotImplemented();
      return;
    }
    const auto* bytes = call.arguments()
        ? std::get_if<std::vector<uint8_t>>(call.arguments())
        : nullptr;
    result->Success(flutter::EncodableValue(bytes && CopyPng(GetHandle(), *bytes)));
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

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

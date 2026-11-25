#include "flutter_window.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <thread>
#include <utility>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "app_updater.h"
#include "image_clipboard.h"
#include "screenshot_ocr.h"

namespace {
constexpr UINT kWmOcrComplete = WM_APP + 101;
}  // namespace

struct OcrDispatchState {
  std::mutex mutex;
  HWND hwnd = nullptr;
  bool alive = true;
  std::vector<std::function<void()>> callbacks;
};

namespace {
void DispatchOcrCallback(const std::shared_ptr<OcrDispatchState>& state,
                         std::function<void()> callback) {
  if (!state) return;
  std::lock_guard<std::mutex> lock(state->mutex);
  if (!state->alive || !state->hwnd) return;
  HWND target_hwnd = state->hwnd;
  state->callbacks.push_back(std::move(callback));
  PostMessageW(target_hwnd, kWmOcrComplete, 0, 0);
}

flutter::EncodableMap BuildWindowsOcrPayload(const WindowsOcrResult& ocr) {
  flutter::EncodableList blocks;
  blocks.reserve(ocr.blocks.size());
  for (const auto& block : ocr.blocks) {
    flutter::EncodableMap item;
    item[flutter::EncodableValue("text")] =
        flutter::EncodableValue(block.text);
    item[flutter::EncodableValue("x")] = flutter::EncodableValue(block.x);
    item[flutter::EncodableValue("y")] = flutter::EncodableValue(block.y);
    item[flutter::EncodableValue("w")] = flutter::EncodableValue(block.w);
    item[flutter::EncodableValue("h")] = flutter::EncodableValue(block.h);
    blocks.push_back(flutter::EncodableValue(std::move(item)));
  }
  flutter::EncodableMap payload;
  payload[flutter::EncodableValue("text")] = flutter::EncodableValue(ocr.text);
  payload[flutter::EncodableValue("blocks")] =
      flutter::EncodableValue(std::move(blocks));
  return payload;
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
  ocr_state_ = std::make_shared<OcrDispatchState>();
  ocr_state_->hwnd = GetHandle();

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
    const auto copied = bytes ? CopyPngToClipboard(GetHandle(), *bytes)
                              : ImageClipboardResult::kFailed;
    if (copied == ImageClipboardResult::kBusy) {
      result->Error("clipboard_busy");
    } else {
      result->Success(flutter::EncodableValue(
          copied == ImageClipboardResult::kCopied));
    }
  });

  flutter::MethodChannel<flutter::EncodableValue> ocr_channel(
      flutter_controller_->engine()->messenger(), "org.wencrypt.ocr",
      &flutter::StandardMethodCodec::GetInstance());
  ocr_channel.SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "readClipboardImage") {
      RawClipboardImage raw;
      const auto status = GrabClipboardImageRaw(GetHandle(), &raw);
      if (status == ReadClipboardImageResult::kBusy) {
        result->Error("clipboard_busy");
      } else if (status != ReadClipboardImageResult::kFound) {
        result->Success(flutter::EncodableValue());
      } else if (!raw.is_dib) {
        result->Success(flutter::EncodableValue(std::move(raw.bytes)));
      } else {
        auto shared_result =
            std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
                result.release());
        auto state = ocr_state_;
        std::thread([raw = std::move(raw),
                     shared_result = std::move(shared_result),
                     state = std::move(state)]() mutable {
          std::vector<uint8_t> png = EncodeRawClipboardImageAsPng(raw);
          std::fill(raw.bytes.begin(), raw.bytes.end(), uint8_t{0});
          DispatchOcrCallback(state, [png = std::move(png),
                                      shared_result =
                                          std::move(shared_result)]() mutable {
            if (png.empty()) {
              shared_result->Success(flutter::EncodableValue());
            } else {
              shared_result->Success(flutter::EncodableValue(std::move(png)));
            }
          });
        }).detach();
      }
      return;
    }

    if (call.method_name() == "readAndRecognizeClipboardImage") {
      RawClipboardImage raw;
      const auto status = GrabClipboardImageRaw(GetHandle(), &raw);
      if (status == ReadClipboardImageResult::kBusy) {
        result->Error("clipboard_busy");
        return;
      }
      if (status != ReadClipboardImageResult::kFound) {
        flutter::EncodableMap empty_payload;
        empty_payload[flutter::EncodableValue("hasImage")] =
            flutter::EncodableValue(false);
        result->Success(flutter::EncodableValue(std::move(empty_payload)));
        return;
      }
      auto shared_result =
          std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
              result.release());
      auto state = ocr_state_;
      std::thread([raw = std::move(raw),
                   shared_result = std::move(shared_result),
                   state = std::move(state)]() mutable {
        std::vector<uint8_t> ocr_input =
            raw.is_dib ? WrapDibAsBmp(raw.bytes.data(), raw.bytes.size())
                       : raw.bytes;
        WindowsOcrResult ocr = RecognizeImageWindows(ocr_input);
        std::vector<uint8_t> preview;
        if (ocr.ok) {
          preview = EncodeImagePreviewBytes(ocr_input, 1600);
          if (preview.empty()) {
            preview = EncodeRawClipboardImageAsPng(raw);
          }
        }
        std::fill(ocr_input.begin(), ocr_input.end(), uint8_t{0});
        std::fill(raw.bytes.begin(), raw.bytes.end(), uint8_t{0});
        DispatchOcrCallback(
            state,
            [ocr = std::move(ocr), preview = std::move(preview),
             shared_result = std::move(shared_result)]() mutable {
              if (!ocr.ok) {
                shared_result->Error(
                    ocr.error_code.empty() ? "ocr_failed" : ocr.error_code);
                return;
              }
              if (preview.empty()) {
                shared_result->Error("invalid_image");
                return;
              }
              flutter::EncodableMap payload = BuildWindowsOcrPayload(ocr);
              payload[flutter::EncodableValue("hasImage")] =
                  flutter::EncodableValue(true);
              payload[flutter::EncodableValue("image")] =
                  flutter::EncodableValue(std::move(preview));
              shared_result->Success(
                  flutter::EncodableValue(std::move(payload)));
            });
      }).detach();
      return;
    }

    if (call.method_name() == "recognizeImage") {
      const auto* bytes = call.arguments()
          ? std::get_if<std::vector<uint8_t>>(call.arguments())
          : nullptr;
      if (!bytes || bytes->empty() || bytes->size() > 16 * 1024 * 1024) {
        result->Error("invalid_image");
        return;
      }
      std::vector<uint8_t> bytes_copy(*bytes);
      auto shared_result =
          std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
              result.release());
      auto state = ocr_state_;
      std::thread([bytes_copy = std::move(bytes_copy),
                   shared_result = std::move(shared_result),
                   state = std::move(state)]() mutable {
        WindowsOcrResult ocr = RecognizeImageWindows(bytes_copy);
        std::fill(bytes_copy.begin(), bytes_copy.end(), uint8_t{0});
        DispatchOcrCallback(state, [ocr = std::move(ocr),
                                    shared_result =
                                        std::move(shared_result)]() mutable {
          if (!ocr.ok) {
            shared_result->Error(
                ocr.error_code.empty() ? "ocr_failed" : ocr.error_code);
            return;
          }
          shared_result->Success(
              flutter::EncodableValue(BuildWindowsOcrPayload(ocr)));
        });
      }).detach();
      return;
    }

    result->NotImplemented();
  });

  flutter::MethodChannel<flutter::EncodableValue> updater_channel(
      flutter_controller_->engine()->messenger(), "org.wencrypt.updater",
      &flutter::StandardMethodCodec::GetInstance());
  updater_channel.SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "getAppInfo") {
      WindowsAppInfo info = GetWindowsAppInfo();
      flutter::EncodableMap payload;
      payload[flutter::EncodableValue("version")] =
          flutter::EncodableValue(info.version);
      payload[flutter::EncodableValue("buildNumber")] =
          flutter::EncodableValue(info.build_number);
      payload[flutter::EncodableValue("installPath")] =
          flutter::EncodableValue(info.install_path);
      payload[flutter::EncodableValue("canAutoInstall")] =
          flutter::EncodableValue(info.can_auto_install);
      payload[flutter::EncodableValue("isSandboxed")] =
          flutter::EncodableValue(false);
      payload[flutter::EncodableValue("platform")] =
          flutter::EncodableValue("windows");
      result->Success(flutter::EncodableValue(std::move(payload)));
      return;
    }

    if (call.method_name() == "openUrl") {
      const auto* url = call.arguments()
          ? std::get_if<std::string>(call.arguments())
          : nullptr;
      result->Success(flutter::EncodableValue(
          url != nullptr && OpenWindowsUrl(*url)));
      return;
    }

    if (call.method_name() == "openDirectory") {
      const auto* path = call.arguments()
          ? std::get_if<std::string>(call.arguments())
          : nullptr;
      result->Success(flutter::EncodableValue(
          path != nullptr && OpenWindowsDirectory(*path)));
      return;
    }

    if (call.method_name() == "installAndRestart") {
      const auto* args = call.arguments()
          ? std::get_if<flutter::EncodableMap>(call.arguments())
          : nullptr;
      std::string archive_path;
      std::string expected_sha256;
      if (args != nullptr) {
        auto it_path = args->find(flutter::EncodableValue("archivePath"));
        if (it_path != args->end()) {
          if (const auto* s = std::get_if<std::string>(&it_path->second)) {
            archive_path = *s;
          }
        }
        auto it_sha = args->find(flutter::EncodableValue("sha256"));
        if (it_sha != args->end()) {
          if (const auto* s = std::get_if<std::string>(&it_sha->second)) {
            expected_sha256 = *s;
          }
        }
      }
      if (archive_path.empty() || expected_sha256.empty()) {
        result->Error("invalid_args");
        return;
      }

      auto shared_result =
          std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
              result.release());
      auto state = ocr_state_;
      HWND target_hwnd = GetHandle();
      std::thread([archive_path = std::move(archive_path),
                   expected_sha256 = std::move(expected_sha256),
                   shared_result = std::move(shared_result),
                   state = std::move(state),
                   target_hwnd]() mutable {
        WindowsInstallResult install = InstallWindowsUpdateAndRestart(
            archive_path, expected_sha256, target_hwnd);
        if (!state) return;
        std::lock_guard<std::mutex> lock(state->mutex);
        if (!state->alive || !state->hwnd) return;
        HWND post_hwnd = state->hwnd;
        state->callbacks.push_back(
            [install = std::move(install),
             shared_result = std::move(shared_result),
             post_hwnd]() mutable {
              if (!install.ok) {
                shared_result->Error(
                    install.error_code.empty() ? "install_failed"
                                               : install.error_code);
                return;
              }
              shared_result->Success(flutter::EncodableValue(true));
              PostMessageW(post_hwnd, WM_CLOSE, 0, 0);
            });
        PostMessageW(post_hwnd, kWmOcrComplete, 0, 0);
      }).detach();
      return;
    }

    result->NotImplemented();
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
  if (ocr_state_) {
    std::lock_guard<std::mutex> lock(ocr_state_->mutex);
    ocr_state_->alive = false;
    ocr_state_->hwnd = nullptr;
    ocr_state_->callbacks.clear();
  }
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
    case kWmOcrComplete:
      if (ocr_state_) {
        std::vector<std::function<void()>> callbacks;
        {
          std::lock_guard<std::mutex> lock(ocr_state_->mutex);
          if (ocr_state_->alive) {
            callbacks.swap(ocr_state_->callbacks);
          }
        }
        for (auto& callback : callbacks) {
          callback();
        }
      }
      return 0;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

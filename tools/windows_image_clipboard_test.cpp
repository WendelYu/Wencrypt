#include <windows.h>
#include <objbase.h>

#include <array>
#include <cstdio>
#include <cstring>

#include "../apps/wencrypt_flutter/windows/runner/image_clipboard.h"

namespace {
// 2x2 RGBA PNG, red/green on the first row and blue/white on the second.
const std::vector<uint8_t> kPng = {
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00,
    0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02,
    0x00, 0x00, 0x00, 0x02, 0x08, 0x06, 0x00, 0x00, 0x00, 0x72,
    0xb6, 0x0d, 0x24, 0x00, 0x00, 0x00, 0x12, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xf0, 0x1f, 0x0c,
    0x81, 0x34, 0x18, 0x00, 0x00, 0x49, 0xc8, 0x09, 0xf7, 0xf9,
    0xab, 0xb6, 0x0d, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e,
    0x44, 0xae, 0x42, 0x60, 0x82,
};

bool CheckDib() {
  const auto handle = GetClipboardData(CF_DIB);
  const auto* bytes = static_cast<const uint8_t*>(GlobalLock(handle));
  if (!bytes) return false;
  BITMAPINFOHEADER header{};
  const std::array<uint8_t, 16> pixels = {
      255, 0, 0, 255, 255, 255, 0, 0, 0, 0, 255, 0, 255, 0, 0, 0,
  };
  const bool enough = GlobalSize(handle) >= sizeof(header) + pixels.size();
  if (enough) std::memcpy(&header, bytes, sizeof(header));
  const bool valid =
      enough && header.biSize == sizeof(header) && header.biWidth == 2 &&
      header.biHeight == 2 && header.biPlanes == 1 && header.biBitCount == 24 &&
      header.biCompression == BI_RGB &&
      std::memcmp(bytes + sizeof(header), pixels.data(), pixels.size()) == 0;
  GlobalUnlock(handle);
  return valid;
}

bool CheckPng() {
  const auto handle = GetClipboardData(RegisterClipboardFormatW(L"PNG"));
  const auto* bytes = static_cast<const uint8_t*>(GlobalLock(handle));
  if (!bytes) return false;
  const bool valid = GlobalSize(handle) >= kPng.size() &&
                     std::memcmp(bytes, kPng.data(), kPng.size()) == 0;
  GlobalUnlock(handle);
  return valid;
}
}  // namespace

int main() {
  if (FAILED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) return 1;
  const auto owner = CreateWindowW(L"STATIC", L"Wencrypt clipboard test", 0, 0,
                                   0, 0, 0, HWND_MESSAGE, nullptr,
                                   GetModuleHandleW(nullptr), nullptr);
  bool copied = false;
  if (owner) {
    for (int attempt = 0; attempt < 20; ++attempt) {
      const auto result = CopyPngToClipboard(owner, kPng);
      copied = result == ImageClipboardResult::kCopied;
      if (result != ImageClipboardResult::kBusy) break;
      Sleep(50);
    }
  }
  const bool rejected = CopyPngToClipboard(owner, {1, 2, 3}) ==
                        ImageClipboardResult::kFailed;
  bool formats_valid = false;
  if (copied && OpenClipboard(owner)) {
    formats_valid = CheckDib() && CheckPng();
    CloseClipboard();
  }
  if (owner) DestroyWindow(owner);
  CoUninitialize();
  if (!copied || !rejected || !formats_valid) {
    std::fprintf(stderr, "Clipboard copy=%d invalid_png_rejected=%d formats=%d\n",
                 copied, rejected, formats_valid);
    return 1;
  }
  std::puts("Windows clipboard passed: DIB pixels and original PNG verified");
  return 0;
}

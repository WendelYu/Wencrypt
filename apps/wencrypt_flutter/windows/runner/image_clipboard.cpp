#include "image_clipboard.h"

#include <wincodec.h>
#include <wrl/client.h>

#include <cstring>

namespace {
using Microsoft::WRL::ComPtr;

class ClipboardBuffer {
 public:
  explicit ClipboardBuffer(const std::vector<uint8_t>& bytes) {
    if (bytes.empty()) return;
    handle_ = GlobalAlloc(GMEM_MOVEABLE, bytes.size());
    if (!handle_) return;
    void* target = GlobalLock(handle_);
    if (!target) {
      GlobalFree(handle_);
      handle_ = nullptr;
      return;
    }
    std::memcpy(target, bytes.data(), bytes.size());
    GlobalUnlock(handle_);
  }

  ClipboardBuffer(const ClipboardBuffer&) = delete;
  ClipboardBuffer& operator=(const ClipboardBuffer&) = delete;

  ~ClipboardBuffer() {
    if (handle_) GlobalFree(handle_);
  }

  bool valid() const { return handle_ != nullptr; }

  bool Publish(UINT format) {
    if (!handle_ || !format || !SetClipboardData(format, handle_)) return false;
    handle_ = nullptr;  // Windows owns the memory after SetClipboardData.
    return true;
  }

 private:
  HGLOBAL handle_ = nullptr;
};

std::vector<uint8_t> DecodeDib(const std::vector<uint8_t>& png) {
  if (png.empty() || png.size() > 16 * 1024 * 1024) return {};

  ComPtr<IWICImagingFactory> factory;
  ComPtr<IWICStream> stream;
  ComPtr<IWICBitmapDecoder> decoder;
  ComPtr<IWICBitmapFrameDecode> frame;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                              CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(factory.GetAddressOf()))) ||
      FAILED(factory->CreateStream(stream.GetAddressOf())) ||
      // WIC takes a non-const pointer even though decoding only reads it.
      FAILED(stream->InitializeFromMemory(const_cast<BYTE*>(png.data()),
                                          static_cast<DWORD>(png.size()))) ||
      FAILED(factory->CreateDecoderFromStream(stream.Get(), nullptr,
                                              WICDecodeMetadataCacheOnDemand,
                                              decoder.GetAddressOf())) ||
      FAILED(decoder->GetFrame(0, frame.GetAddressOf()))) {
    return {};
  }

  UINT width = 0;
  UINT height = 0;
  if (FAILED(frame->GetSize(&width, &height)) || !width || !height ||
      width > 4096 || height > 4096 || width * height > 8 * 1024 * 1024) {
    return {};
  }

  ComPtr<IWICFormatConverter> converter;
  if (FAILED(factory->CreateFormatConverter(converter.GetAddressOf())) ||
      FAILED(converter->Initialize(frame.Get(), GUID_WICPixelFormat24bppBGR,
                                   WICBitmapDitherTypeNone, nullptr, 0,
                                   WICBitmapPaletteTypeCustom))) {
    return {};
  }

  const UINT stride = (width * 3 + 3) & ~3u;
  const UINT size = stride * height;
  std::vector<uint8_t> pixels(size);
  if (FAILED(converter->CopyPixels(nullptr, stride, size, pixels.data()))) {
    return {};
  }

  BITMAPINFOHEADER header{};
  header.biSize = static_cast<DWORD>(sizeof(header));
  header.biWidth = static_cast<LONG>(width);
  header.biHeight = static_cast<LONG>(height);
  header.biPlanes = 1;
  header.biBitCount = 24;
  header.biCompression = BI_RGB;
  header.biSizeImage = size;
  std::vector<uint8_t> dib(sizeof(header) + size);
  std::memcpy(dib.data(), &header, sizeof(header));
  // WIC returns top-down rows. A Windows DIB with positive height is bottom-up.
  for (UINT row = 0; row < height; ++row) {
    std::memcpy(dib.data() + sizeof(header) + row * stride,
                pixels.data() + (height - 1 - row) * stride, width * 3);
  }
  return dib;
}
}  // namespace

ImageClipboardResult CopyPngToClipboard(HWND owner,
                                        const std::vector<uint8_t>& png) {
  ClipboardBuffer bitmap(DecodeDib(png));
  if (!bitmap.valid()) return ImageClipboardResult::kFailed;
  ClipboardBuffer original(png);
  const UINT png_format = RegisterClipboardFormatW(L"PNG");
  if (!OpenClipboard(owner)) return ImageClipboardResult::kBusy;
  const bool copied = EmptyClipboard() && bitmap.Publish(CF_DIB);
  if (copied) original.Publish(png_format);
  CloseClipboard();
  return copied ? ImageClipboardResult::kCopied : ImageClipboardResult::kFailed;
}

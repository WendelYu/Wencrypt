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
class ClipboardGuard {
 public:
  explicit ClipboardGuard(HWND owner) : open_(OpenClipboard(owner) != FALSE) {}
  ClipboardGuard(const ClipboardGuard&) = delete;
  ClipboardGuard& operator=(const ClipboardGuard&) = delete;
  ~ClipboardGuard() {
    if (open_) CloseClipboard();
  }
  bool is_open() const { return open_; }

 private:
  bool open_ = false;
};

class GlobalLockGuard {
 public:
  explicit GlobalLockGuard(HANDLE handle)
      : handle_(handle), data_(handle ? GlobalLock(handle) : nullptr) {}
  GlobalLockGuard(const GlobalLockGuard&) = delete;
  GlobalLockGuard& operator=(const GlobalLockGuard&) = delete;
  ~GlobalLockGuard() {
    if (data_) GlobalUnlock(handle_);
  }
  const void* data() const { return data_; }
  size_t size() const { return handle_ ? GlobalSize(handle_) : 0; }

 private:
  HANDLE handle_ = nullptr;
  void* data_ = nullptr;
};

bool HasPngSignature(const uint8_t* data, size_t size) {
  static constexpr uint8_t kSig[8] = {0x89, 0x50, 0x4E, 0x47,
                                      0x0D, 0x0A, 0x1A, 0x0A};
  return size >= sizeof(kSig) && std::memcmp(data, kSig, sizeof(kSig)) == 0;
}

size_t ExactPngLength(const uint8_t* data, size_t size) {
  if (!HasPngSignature(data, size)) return 0;
  size_t pos = 8;
  while (pos + 12 <= size) {
    const uint32_t len = (static_cast<uint32_t>(data[pos]) << 24) |
                         (static_cast<uint32_t>(data[pos + 1]) << 16) |
                         (static_cast<uint32_t>(data[pos + 2]) << 8) |
                         static_cast<uint32_t>(data[pos + 3]);
    if (len > size - pos - 12) return size;
    const bool is_iend = data[pos + 4] == 'I' && data[pos + 5] == 'E' &&
                         data[pos + 6] == 'N' && data[pos + 7] == 'D';
    pos += 12 + static_cast<size_t>(len);
    if (is_iend) return pos;
  }
  return size;
}

std::vector<uint8_t> EncodeDibAsPng(const uint8_t* dib, size_t dib_size) {
  constexpr size_t kMaxBytes = 16 * 1024 * 1024;
  if (!dib || dib_size < sizeof(BITMAPINFOHEADER) || dib_size > kMaxBytes * 4) {
    return {};
  }

  BITMAPINFOHEADER header{};
  std::memcpy(&header, dib, sizeof(header));
  if (header.biSize < sizeof(BITMAPINFOHEADER) || header.biSize > dib_size) {
    return {};
  }

  size_t palette_entries = 0;
  if (header.biClrUsed != 0) {
    palette_entries = header.biClrUsed;
  } else if (header.biBitCount <= 8) {
    palette_entries = size_t{1} << header.biBitCount;
  }
  if (palette_entries > 256) return {};

  size_t extra_masks = 0;
  if (header.biSize == sizeof(BITMAPINFOHEADER)) {
    if (header.biCompression == BI_BITFIELDS) {
      extra_masks = 12;
    } else if (header.biCompression == 6 /* BI_ALPHABITFIELDS */) {
      extra_masks = 16;
    }
  }

  const size_t pixel_offset = sizeof(BITMAPFILEHEADER) +
                              static_cast<size_t>(header.biSize) + extra_masks +
                              palette_entries * sizeof(RGBQUAD);
  const size_t total_size = sizeof(BITMAPFILEHEADER) + dib_size;
  if (pixel_offset > total_size || total_size > 0xFFFFFFFFu) return {};

  std::vector<uint8_t> bmp(total_size);
  BITMAPFILEHEADER file_header{};
  file_header.bfType = 0x4D42;  // 'BM'
  file_header.bfSize = static_cast<DWORD>(total_size);
  file_header.bfOffBits = static_cast<DWORD>(pixel_offset);
  std::memcpy(bmp.data(), &file_header, sizeof(file_header));
  std::memcpy(bmp.data() + sizeof(file_header), dib, dib_size);

  ComPtr<IWICImagingFactory> factory;
  ComPtr<IWICStream> input_stream;
  ComPtr<IWICBitmapDecoder> decoder;
  ComPtr<IWICBitmapFrameDecode> frame;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                              CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(factory.GetAddressOf()))) ||
      FAILED(factory->CreateStream(input_stream.GetAddressOf())) ||
      FAILED(input_stream->InitializeFromMemory(bmp.data(),
                                                static_cast<DWORD>(bmp.size()))) ||
      FAILED(factory->CreateDecoderFromStream(input_stream.Get(), nullptr,
                                              WICDecodeMetadataCacheOnDemand,
                                              decoder.GetAddressOf())) ||
      FAILED(decoder->GetFrame(0, frame.GetAddressOf()))) {
    return {};
  }

  UINT width = 0;
  UINT height = 0;
  if (FAILED(frame->GetSize(&width, &height)) || !width || !height ||
      width > 8192 || height > 8192 ||
      static_cast<uint64_t>(width) * height > 32ULL * 1024 * 1024) {
    return {};
  }

  ComPtr<IWICFormatConverter> converter;
  if (FAILED(factory->CreateFormatConverter(converter.GetAddressOf())) ||
      FAILED(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppBGRA,
                                   WICBitmapDitherTypeNone, nullptr, 0,
                                   WICBitmapPaletteTypeCustom))) {
    return {};
  }

  ComPtr<IStream> output_stream;
  ComPtr<IWICBitmapEncoder> encoder;
  ComPtr<IWICBitmapFrameEncode> out_frame;
  if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, output_stream.GetAddressOf())) ||
      FAILED(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr,
                                    encoder.GetAddressOf())) ||
      FAILED(encoder->Initialize(output_stream.Get(), WICBitmapEncoderNoCache)) ||
      FAILED(encoder->CreateNewFrame(out_frame.GetAddressOf(), nullptr)) ||
      FAILED(out_frame->Initialize(nullptr)) ||
      FAILED(out_frame->SetSize(width, height)) ||
      [&]() {
        WICPixelFormatGUID pixel_format = GUID_WICPixelFormat32bppBGRA;
        return FAILED(out_frame->SetPixelFormat(&pixel_format));
      }() ||
      FAILED(out_frame->WriteSource(converter.Get(), nullptr)) ||
      FAILED(out_frame->Commit()) ||
      FAILED(encoder->Commit())) {
    return {};
  }

  STATSTG stat{};
  HGLOBAL hglobal = nullptr;
  if (FAILED(output_stream->Stat(&stat, STATFLAG_NONAME)) ||
      stat.cbSize.QuadPart == 0 || stat.cbSize.QuadPart > kMaxBytes ||
      FAILED(GetHGlobalFromStream(output_stream.Get(), &hglobal))) {
    return {};
  }

  GlobalLockGuard out_lock(hglobal);
  if (!out_lock.data() || out_lock.size() < stat.cbSize.QuadPart) return {};
  const size_t png_size = static_cast<size_t>(stat.cbSize.QuadPart);
  const auto* png_bytes = static_cast<const uint8_t*>(out_lock.data());
  return std::vector<uint8_t>(png_bytes, png_bytes + png_size);
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

ReadClipboardImageResult ReadClipboardPng(HWND owner,
                                          std::vector<uint8_t>* out_png) {
  if (!out_png) return ReadClipboardImageResult::kFailed;
  out_png->clear();

  constexpr size_t kMaxBytes = 16 * 1024 * 1024;
  const UINT png_format = RegisterClipboardFormatW(L"PNG");

  std::vector<uint8_t> dib_copy;
  {
    ClipboardGuard clipboard(owner);
    if (!clipboard.is_open()) return ReadClipboardImageResult::kBusy;

    if (png_format != 0 && IsClipboardFormatAvailable(png_format)) {
      HANDLE handle = GetClipboardData(png_format);
      GlobalLockGuard lock(handle);
      const size_t size = lock.size();
      const auto* bytes = static_cast<const uint8_t*>(lock.data());
      if (bytes && size > 0 && size <= kMaxBytes &&
          HasPngSignature(bytes, size)) {
        const size_t exact_len = ExactPngLength(bytes, size);
        out_png->assign(bytes, bytes + exact_len);
        return ReadClipboardImageResult::kFound;
      }
    }

    UINT dib_format = 0;
    if (IsClipboardFormatAvailable(CF_DIBV5)) {
      dib_format = CF_DIBV5;
    } else if (IsClipboardFormatAvailable(CF_DIB)) {
      dib_format = CF_DIB;
    }
    if (dib_format == 0) {
      return ReadClipboardImageResult::kEmpty;
    }

    HANDLE handle = GetClipboardData(dib_format);
    GlobalLockGuard lock(handle);
    const size_t size = lock.size();
    const auto* bytes = static_cast<const uint8_t*>(lock.data());
    if (!bytes || size < sizeof(BITMAPINFOHEADER) || size > kMaxBytes * 4) {
      return ReadClipboardImageResult::kFailed;
    }
    dib_copy.assign(bytes, bytes + size);
  }

  std::vector<uint8_t> encoded =
      EncodeDibAsPng(dib_copy.data(), dib_copy.size());
  if (encoded.empty()) return ReadClipboardImageResult::kFailed;
  *out_png = std::move(encoded);
  return ReadClipboardImageResult::kFound;
}

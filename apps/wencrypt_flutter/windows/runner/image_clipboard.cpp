#include "image_clipboard.h"

#include <objbase.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <cstring>

namespace {
using Microsoft::WRL::ComPtr;

constexpr size_t kMaxTransferBytes = 16 * 1024 * 1024;
constexpr size_t kMaxRawClipboardBytes = 64 * 1024 * 1024;

class ScopedComInit {
 public:
  ScopedComInit() : hr_(CoInitializeEx(nullptr, COINIT_MULTITHREADED)) {}
  ScopedComInit(const ScopedComInit&) = delete;
  ScopedComInit& operator=(const ScopedComInit&) = delete;
  ~ScopedComInit() {
    if (SUCCEEDED(hr_)) CoUninitialize();
  }
  bool ok() const { return SUCCEEDED(hr_) || hr_ == RPC_E_CHANGED_MODE; }

 private:
  HRESULT hr_ = E_FAIL;
};

struct ZeroVectorOnExit {
  std::vector<uint8_t>& buf;
  ~ZeroVectorOnExit() { std::fill(buf.begin(), buf.end(), uint8_t{0}); }
};

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

std::vector<uint8_t> EncodeWicBitmapSource(IWICImagingFactory* factory,
                                           IWICBitmapSource* source, UINT width,
                                           UINT height,
                                           REFGUID container_format,
                                           REFGUID target_pixel_format,
                                           size_t max_output_bytes) {
  if (!factory || !source || width == 0 || height == 0) return {};

  ComPtr<IWICFormatConverter> converter;
  if (FAILED(factory->CreateFormatConverter(converter.GetAddressOf())) ||
      FAILED(converter->Initialize(source, target_pixel_format,
                                   WICBitmapDitherTypeNone, nullptr, 0.0,
                                   WICBitmapPaletteTypeCustom))) {
    return {};
  }

  ComPtr<IStream> output_stream;
  ComPtr<IWICBitmapEncoder> encoder;
  ComPtr<IWICBitmapFrameEncode> out_frame;
  WICPixelFormatGUID pixel_format = target_pixel_format;
  if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, output_stream.GetAddressOf())) ||
      FAILED(factory->CreateEncoder(container_format, nullptr,
                                    encoder.GetAddressOf())) ||
      FAILED(encoder->Initialize(output_stream.Get(), WICBitmapEncoderNoCache)) ||
      FAILED(encoder->CreateNewFrame(out_frame.GetAddressOf(), nullptr)) ||
      FAILED(out_frame->Initialize(nullptr)) ||
      FAILED(out_frame->SetSize(width, height)) ||
      FAILED(out_frame->SetPixelFormat(&pixel_format)) ||
      FAILED(out_frame->WriteSource(converter.Get(), nullptr)) ||
      FAILED(out_frame->Commit()) ||
      FAILED(encoder->Commit())) {
    return {};
  }

  STATSTG stat{};
  HGLOBAL hglobal = nullptr;
  if (FAILED(output_stream->Stat(&stat, STATFLAG_NONAME)) ||
      stat.cbSize.QuadPart == 0 ||
      stat.cbSize.QuadPart > static_cast<ULONGLONG>(max_output_bytes) ||
      FAILED(GetHGlobalFromStream(output_stream.Get(), &hglobal))) {
    return {};
  }

  GlobalLockGuard out_lock(hglobal);
  if (!out_lock.data() ||
      static_cast<uint64_t>(out_lock.size()) < stat.cbSize.QuadPart) {
    return {};
  }
  const size_t encoded_size = static_cast<size_t>(stat.cbSize.QuadPart);
  const auto* encoded_bytes = static_cast<const uint8_t*>(out_lock.data());
  return std::vector<uint8_t>(encoded_bytes, encoded_bytes + encoded_size);
}

std::vector<uint8_t> EncodeDibAsPng(const uint8_t* dib, size_t dib_size) {
  std::vector<uint8_t> bmp = WrapDibAsBmp(dib, dib_size);
  if (bmp.empty()) return {};
  ZeroVectorOnExit zero_bmp{bmp};

  ComPtr<IWICImagingFactory> factory;
  ComPtr<IWICStream> input_stream;
  ComPtr<IWICBitmapDecoder> decoder;
  ComPtr<IWICBitmapFrameDecode> frame;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                              CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(factory.GetAddressOf()))) ||
      FAILED(factory->CreateStream(input_stream.GetAddressOf())) ||
      FAILED(input_stream->InitializeFromMemory(
          bmp.data(), static_cast<DWORD>(bmp.size()))) ||
      FAILED(factory->CreateDecoderFromStream(input_stream.Get(), nullptr,
                                              WICDecodeMetadataCacheOnDemand,
                                              decoder.GetAddressOf())) ||
      FAILED(decoder->GetFrame(0, frame.GetAddressOf()))) {
    return {};
  }

  UINT width = 0;
  UINT height = 0;
  if (FAILED(frame->GetSize(&width, &height)) || !width || !height ||
      width > 16384 || height > 16384 ||
      static_cast<uint64_t>(width) * height > 64ULL * 1024 * 1024) {
    return {};
  }

  return EncodeWicBitmapSource(factory.Get(), frame.Get(), width, height,
                               GUID_ContainerFormatPng,
                               GUID_WICPixelFormat32bppBGRA, kMaxTransferBytes);
}
}  // namespace

std::vector<uint8_t> WrapDibAsBmp(const uint8_t* dib, size_t dib_size) {
  if (!dib || dib_size < sizeof(BITMAPINFOHEADER) ||
      dib_size > kMaxRawClipboardBytes) {
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
  return bmp;
}

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

ReadClipboardImageResult GrabClipboardImageRaw(HWND owner,
                                               RawClipboardImage* out_raw) {
  if (!out_raw) return ReadClipboardImageResult::kFailed;
  out_raw->bytes.clear();
  out_raw->is_dib = false;

  const UINT png_format = RegisterClipboardFormatW(L"PNG");
  ClipboardGuard clipboard(owner);
  if (!clipboard.is_open()) return ReadClipboardImageResult::kBusy;

  if (png_format != 0 && IsClipboardFormatAvailable(png_format)) {
    HANDLE handle = GetClipboardData(png_format);
    GlobalLockGuard lock(handle);
    const size_t size = lock.size();
    const auto* bytes = static_cast<const uint8_t*>(lock.data());
    if (bytes && size > 0 && size <= kMaxTransferBytes &&
        HasPngSignature(bytes, size)) {
      const size_t exact_len = ExactPngLength(bytes, size);
      out_raw->bytes.assign(bytes, bytes + exact_len);
      out_raw->is_dib = false;
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
  if (!bytes || size < sizeof(BITMAPINFOHEADER) ||
      size > kMaxRawClipboardBytes) {
    return ReadClipboardImageResult::kFailed;
  }
  out_raw->bytes.assign(bytes, bytes + size);
  out_raw->is_dib = true;
  return ReadClipboardImageResult::kFound;
}

std::vector<uint8_t> EncodeRawClipboardImageAsPng(const RawClipboardImage& raw) {
  if (raw.bytes.empty()) return {};
  if (!raw.is_dib) {
    return raw.bytes.size() <= kMaxTransferBytes ? raw.bytes
                                                 : std::vector<uint8_t>{};
  }
  ScopedComInit com;
  if (!com.ok()) return {};
  return EncodeDibAsPng(raw.bytes.data(), raw.bytes.size());
}

std::vector<uint8_t> EncodeImagePreviewBytes(
    const std::vector<uint8_t>& image_bytes, UINT max_dimension) {
  if (image_bytes.empty() || image_bytes.size() > kMaxRawClipboardBytes) {
    return {};
  }
  ScopedComInit com;
  if (!com.ok()) return {};

  ComPtr<IWICImagingFactory> factory;
  ComPtr<IWICStream> input_stream;
  ComPtr<IWICBitmapDecoder> decoder;
  ComPtr<IWICBitmapFrameDecode> frame;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                              CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(factory.GetAddressOf()))) ||
      FAILED(factory->CreateStream(input_stream.GetAddressOf())) ||
      FAILED(input_stream->InitializeFromMemory(
          const_cast<BYTE*>(image_bytes.data()),
          static_cast<DWORD>(image_bytes.size()))) ||
      FAILED(factory->CreateDecoderFromStream(input_stream.Get(), nullptr,
                                              WICDecodeMetadataCacheOnDemand,
                                              decoder.GetAddressOf())) ||
      FAILED(decoder->GetFrame(0, frame.GetAddressOf()))) {
    return {};
  }

  UINT width = 0;
  UINT height = 0;
  if (FAILED(frame->GetSize(&width, &height)) || !width || !height ||
      width > 16384 || height > 16384 ||
      static_cast<uint64_t>(width) * height > 64ULL * 1024 * 1024) {
    return {};
  }

  ComPtr<IWICBitmapSource> source = frame;
  UINT dst_w = width;
  UINT dst_h = height;
  if (max_dimension > 0 && (width > max_dimension || height > max_dimension)) {
    const double scale = static_cast<double>(max_dimension) /
                         static_cast<double>((std::max)(width, height));
    dst_w = (std::max)(
        UINT{1}, static_cast<UINT>(static_cast<double>(width) * scale + 0.5));
    dst_h = (std::max)(
        UINT{1}, static_cast<UINT>(static_cast<double>(height) * scale + 0.5));
    ComPtr<IWICBitmapScaler> scaler;
    if (SUCCEEDED(factory->CreateBitmapScaler(scaler.GetAddressOf())) &&
        SUCCEEDED(scaler->Initialize(frame.Get(), dst_w, dst_h,
                                     WICBitmapInterpolationModeFant))) {
      source = scaler;
    } else {
      dst_w = width;
      dst_h = height;
    }
  }

  std::vector<uint8_t> preview = EncodeWicBitmapSource(
      factory.Get(), source.Get(), dst_w, dst_h, GUID_ContainerFormatJpeg,
      GUID_WICPixelFormat24bppBGR, kMaxTransferBytes);
  if (!preview.empty()) return preview;

  return EncodeWicBitmapSource(factory.Get(), source.Get(), dst_w, dst_h,
                               GUID_ContainerFormatPng,
                               GUID_WICPixelFormat32bppBGRA, kMaxTransferBytes);
}

ReadClipboardImageResult ReadClipboardPng(HWND owner,
                                          std::vector<uint8_t>* out_png) {
  if (!out_png) return ReadClipboardImageResult::kFailed;
  out_png->clear();

  RawClipboardImage raw;
  const ReadClipboardImageResult status = GrabClipboardImageRaw(owner, &raw);
  if (status != ReadClipboardImageResult::kFound) return status;
  ZeroVectorOnExit zero_raw{raw.bytes};

  std::vector<uint8_t> encoded = EncodeRawClipboardImageAsPng(raw);
  if (encoded.empty()) return ReadClipboardImageResult::kFailed;
  *out_png = std::move(encoded);
  return ReadClipboardImageResult::kFound;
}

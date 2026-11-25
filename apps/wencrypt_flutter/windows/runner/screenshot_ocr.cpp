#include "screenshot_ocr.h"

#include <windows.h>
#include <roapi.h>
#include <shcore.h>
#include <shlwapi.h>
#include <winstring.h>
#include <windows.foundation.h>
#include <windows.foundation.collections.h>
#include <windows.globalization.h>
#include <windows.graphics.imaging.h>
#include <windows.media.ocr.h>
#include <windows.storage.streams.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <memory>
#include <mutex>
#include <new>

namespace {
using Microsoft::WRL::ComPtr;
namespace ABI_Found = ABI::Windows::Foundation;
namespace ABI_Coll = ABI::Windows::Foundation::Collections;
namespace ABI_Glob = ABI::Windows::Globalization;
namespace ABI_Img = ABI::Windows::Graphics::Imaging;
namespace ABI_Ocr = ABI::Windows::Media::Ocr;
namespace ABI_Strm = ABI::Windows::Storage::Streams;

constexpr size_t kMaxImageBytes = 16 * 1024 * 1024;
constexpr UINT32 kMaxImageDim = 8192;
constexpr uint64_t kMaxImagePixels = 32ULL * 1024 * 1024;

class ScopedRoInit {
 public:
  ScopedRoInit() : hr_(RoInitialize(RO_INIT_MULTITHREADED)) {}
  ScopedRoInit(const ScopedRoInit&) = delete;
  ScopedRoInit& operator=(const ScopedRoInit&) = delete;
  ~ScopedRoInit() {
    if (SUCCEEDED(hr_)) RoUninitialize();
  }
  HRESULT result() const { return hr_; }

 private:
  HRESULT hr_;
};

class ScopedHString {
 public:
  ScopedHString() = default;
  ScopedHString(const ScopedHString&) = delete;
  ScopedHString& operator=(const ScopedHString&) = delete;
  ~ScopedHString() { Reset(); }

  void Reset() {
    if (value_) {
      WindowsDeleteString(value_);
      value_ = nullptr;
    }
  }

  HSTRING* Put() {
    Reset();
    return &value_;
  }

  HSTRING Get() const { return value_; }

 private:
  HSTRING value_ = nullptr;
};

class StaticHStringRef {
 public:
  template <size_t N>
  explicit StaticHStringRef(const wchar_t (&text)[N]) {
    hr_ = WindowsCreateStringReference(text, static_cast<UINT32>(N - 1),
                                       &header_, &value_);
  }
  StaticHStringRef(const StaticHStringRef&) = delete;
  StaticHStringRef& operator=(const StaticHStringRef&) = delete;

  HRESULT result() const { return hr_; }
  HSTRING get() const { return value_; }

 private:
  HSTRING_HEADER header_{};
  HSTRING value_ = nullptr;
  HRESULT hr_ = E_FAIL;
};

std::string HStringToUtf8(HSTRING value) {
  if (!value) return {};
  UINT32 utf16_len = 0;
  const wchar_t* wide = WindowsGetStringRawBuffer(value, &utf16_len);
  if (!wide || utf16_len == 0) return {};
  const int utf8_len = WideCharToMultiByte(
      CP_UTF8, 0, wide, static_cast<int>(utf16_len), nullptr, 0, nullptr,
      nullptr);
  if (utf8_len <= 0) return {};
  std::string out(static_cast<size_t>(utf8_len), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide, static_cast<int>(utf16_len),
                      out.data(), utf8_len, nullptr, nullptr);
  return out;
}

std::string TrimAsciiSpaces(const std::string& input) {
  size_t start = 0;
  while (start < input.size() &&
         (input[start] == ' ' || input[start] == '\t' ||
          input[start] == '\r' || input[start] == '\n')) {
    ++start;
  }
  size_t end = input.size();
  while (end > start &&
         (input[end - 1] == ' ' || input[end - 1] == '\t' ||
          input[end - 1] == '\r' || input[end - 1] == '\n')) {
    --end;
  }
  return input.substr(start, end - start);
}

bool StartsWithCaseInsensitive(const std::string& text, const char* prefix) {
  const size_t prefix_len = std::strlen(prefix);
  if (text.size() < prefix_len) return false;
  for (size_t i = 0; i < prefix_len; ++i) {
    char a = text[i];
    char b = prefix[i];
    if (a >= 'A' && a <= 'Z') a = static_cast<char>(a - 'A' + 'a');
    if (b >= 'A' && b <= 'Z') b = static_cast<char>(b - 'A' + 'a');
    if (a != b) return false;
  }
  return true;
}

struct SyncEventState {
  std::mutex mutex;
  HANDLE event = nullptr;
  bool closed = false;

  void Signal() {
    std::lock_guard<std::mutex> lock(mutex);
    if (!closed && event) SetEvent(event);
  }

  void Close() {
    std::lock_guard<std::mutex> lock(mutex);
    closed = true;
    if (event) {
      CloseHandle(event);
      event = nullptr;
    }
  }
};

template <typename LogicalT>
class AsyncWaitHandler final
    : public ABI_Found::IAsyncOperationCompletedHandler<LogicalT>,
      public IAgileObject {
 public:
  explicit AsyncWaitHandler(std::shared_ptr<SyncEventState> state)
      : state_(std::move(state)) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override {
    if (!ppv) return E_POINTER;
    if (riid == IID_IUnknown ||
        riid == __uuidof(ABI_Found::IAsyncOperationCompletedHandler<LogicalT>)) {
      *ppv = static_cast<ABI_Found::IAsyncOperationCompletedHandler<LogicalT>*>(
          this);
      AddRef();
      return S_OK;
    }
    if (riid == __uuidof(IAgileObject)) {
      *ppv = static_cast<IAgileObject*>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }

  ULONG STDMETHODCALLTYPE AddRef() override {
    return static_cast<ULONG>(
        ref_count_.fetch_add(1, std::memory_order_relaxed) + 1);
  }

  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG next = static_cast<ULONG>(
        ref_count_.fetch_sub(1, std::memory_order_acq_rel) - 1);
    if (next == 0) delete this;
    return next;
  }

  HRESULT STDMETHODCALLTYPE Invoke(
      ABI_Found::IAsyncOperation<LogicalT>* /*async_info*/,
      ABI_Found::AsyncStatus /*status*/) override {
    if (state_) state_->Signal();
    return S_OK;
  }

 private:
  ~AsyncWaitHandler() = default;
  std::atomic<LONG> ref_count_{1};
  std::shared_ptr<SyncEventState> state_;
};

template <typename LogicalT, typename AbiT>
HRESULT WaitForAsyncOperation(ABI_Found::IAsyncOperation<LogicalT>* op,
                              AbiT** out_result) {
  if (!op || !out_result) return E_POINTER;
  *out_result = nullptr;

  ComPtr<ABI_Found::IAsyncInfo> async_info;
  HRESULT hr = op->QueryInterface(IID_PPV_ARGS(async_info.GetAddressOf()));
  if (FAILED(hr)) return hr;

  ABI_Found::AsyncStatus status = ABI_Found::AsyncStatus::Started;
  hr = async_info->get_Status(&status);
  if (FAILED(hr)) return hr;

  if (status == ABI_Found::AsyncStatus::Started) {
    HANDLE raw_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!raw_event) return HRESULT_FROM_WIN32(GetLastError());

    auto event_state = std::make_shared<SyncEventState>();
    event_state->event = raw_event;

    ComPtr<ABI_Found::IAsyncOperationCompletedHandler<LogicalT>> handler;
    handler.Attach(new (std::nothrow) AsyncWaitHandler<LogicalT>(event_state));
    if (!handler) {
      event_state->Close();
      return E_OUTOFMEMORY;
    }

    hr = op->put_Completed(handler.Get());
    if (FAILED(hr)) {
      event_state->Close();
      return hr;
    }

    const DWORD wait_status = WaitForSingleObject(raw_event, 15000);
    event_state->Close();
    if (wait_status != WAIT_OBJECT_0) {
      async_info->Cancel();
      return HRESULT_FROM_WIN32(ERROR_TIMEOUT);
    }
  }

  ABI_Found::AsyncStatus final_status = ABI_Found::AsyncStatus::Error;
  hr = async_info->get_Status(&final_status);
  if (FAILED(hr)) return hr;
  if (final_status != ABI_Found::AsyncStatus::Completed) {
    HRESULT err = E_FAIL;
    if (SUCCEEDED(async_info->get_ErrorCode(&err)) && FAILED(err)) {
      return err;
    }
    return E_FAIL;
  }
  return op->GetResults(out_result);
}

HRESULT CreateOcrEngine(ABI_Ocr::IOcrEngineStatics* statics,
                        ABI_Ocr::IOcrEngine** out_engine) {
  if (!statics || !out_engine) return E_POINTER;
  *out_engine = nullptr;

  HRESULT hr = statics->TryCreateFromUserProfileLanguages(out_engine);
  if (SUCCEEDED(hr) && *out_engine) return S_OK;

  ComPtr<ABI_Coll::IVectorView<ABI_Glob::Language*>> languages;
  hr = statics->get_AvailableRecognizerLanguages(languages.GetAddressOf());
  if (FAILED(hr) || !languages) return hr;

  unsigned int count = 0;
  hr = languages->get_Size(&count);
  if (FAILED(hr) || count == 0) return HRESULT_FROM_WIN32(ERROR_NOT_FOUND);

  ComPtr<ABI_Glob::ILanguage> zh_lang;
  ComPtr<ABI_Glob::ILanguage> en_lang;
  ComPtr<ABI_Glob::ILanguage> first_lang;

  for (unsigned int i = 0; i < count; ++i) {
    ComPtr<ABI_Glob::ILanguage> lang;
    if (FAILED(languages->GetAt(i, lang.GetAddressOf())) || !lang) continue;
    if (!first_lang) first_lang = lang;
    ScopedHString tag_hstr;
    if (SUCCEEDED(lang->get_LanguageTag(tag_hstr.Put()))) {
      const std::string tag = HStringToUtf8(tag_hstr.Get());
      if (!zh_lang && StartsWithCaseInsensitive(tag, "zh")) {
        zh_lang = lang;
      } else if (!en_lang && StartsWithCaseInsensitive(tag, "en")) {
        en_lang = lang;
      }
    }
  }

  ABI_Glob::ILanguage* chosen = zh_lang
      ? zh_lang.Get()
      : (en_lang ? en_lang.Get() : first_lang.Get());
  if (!chosen) return HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
  return statics->TryCreateFromLanguage(chosen, out_engine);
}
}  // namespace

WindowsOcrResult RecognizeImageWindows(const std::vector<uint8_t>& bytes) {
  WindowsOcrResult result;
  if (bytes.empty() || bytes.size() > kMaxImageBytes) {
    result.error_code = "invalid_image";
    return result;
  }

  ScopedRoInit ro_init;
  if (FAILED(ro_init.result()) && ro_init.result() != RPC_E_CHANGED_MODE) {
    result.error_code = "ocr_unavailable";
    return result;
  }

  ComPtr<IStream> mem_stream;
  mem_stream.Attach(
      SHCreateMemStream(bytes.data(), static_cast<UINT>(bytes.size())));
  if (!mem_stream) {
    result.error_code = "invalid_image";
    return result;
  }

  ComPtr<ABI_Strm::IRandomAccessStream> random_stream;
  HRESULT hr = CreateRandomAccessStreamOverStream(
      mem_stream.Get(), BSOS_DEFAULT,
      IID_PPV_ARGS(random_stream.GetAddressOf()));
  if (FAILED(hr) || !random_stream) {
    result.error_code = "invalid_image";
    return result;
  }

  StaticHStringRef decoder_class(
      RuntimeClass_Windows_Graphics_Imaging_BitmapDecoder);
  if (FAILED(decoder_class.result())) {
    result.error_code = "ocr_failed";
    return result;
  }

  ComPtr<ABI_Img::IBitmapDecoderStatics> decoder_statics;
  hr = RoGetActivationFactory(decoder_class.get(),
                              IID_PPV_ARGS(decoder_statics.GetAddressOf()));
  if (FAILED(hr) || !decoder_statics) {
    result.error_code = "ocr_unavailable";
    return result;
  }

  ComPtr<ABI_Found::IAsyncOperation<ABI_Img::BitmapDecoder*>> decoder_op;
  hr = decoder_statics->CreateAsync(random_stream.Get(),
                                    decoder_op.GetAddressOf());
  if (FAILED(hr) || !decoder_op) {
    result.error_code = "invalid_image";
    return result;
  }

  ComPtr<ABI_Img::IBitmapDecoder> decoder;
  hr = WaitForAsyncOperation<ABI_Img::BitmapDecoder*, ABI_Img::IBitmapDecoder>(
      decoder_op.Get(), decoder.GetAddressOf());
  if (FAILED(hr) || !decoder) {
    result.error_code = "invalid_image";
    return result;
  }

  ComPtr<ABI_Img::IBitmapFrame> frame;
  hr = decoder.As(&frame);
  if (FAILED(hr) || !frame) {
    result.error_code = "invalid_image";
    return result;
  }

  UINT32 pixel_width = 0;
  UINT32 pixel_height = 0;
  if (FAILED(frame->get_PixelWidth(&pixel_width)) ||
      FAILED(frame->get_PixelHeight(&pixel_height)) || pixel_width == 0 ||
      pixel_height == 0 || pixel_width > kMaxImageDim ||
      pixel_height > kMaxImageDim ||
      static_cast<uint64_t>(pixel_width) * pixel_height > kMaxImagePixels) {
    result.error_code = "invalid_image";
    return result;
  }

  ComPtr<ABI_Img::IBitmapFrameWithSoftwareBitmap> frame_with_bitmap;
  hr = decoder.As(&frame_with_bitmap);
  if (FAILED(hr) || !frame_with_bitmap) {
    result.error_code = "invalid_image";
    return result;
  }

  ComPtr<ABI_Found::IAsyncOperation<ABI_Img::SoftwareBitmap*>> bitmap_op;
  hr = frame_with_bitmap->GetSoftwareBitmapConvertedAsync(
      ABI_Img::BitmapPixelFormat_Bgra8,
      ABI_Img::BitmapAlphaMode_Premultiplied, bitmap_op.GetAddressOf());
  if (FAILED(hr) || !bitmap_op) {
    result.error_code = "invalid_image";
    return result;
  }

  ComPtr<ABI_Img::ISoftwareBitmap> software_bitmap;
  hr = WaitForAsyncOperation<ABI_Img::SoftwareBitmap*,
                             ABI_Img::ISoftwareBitmap>(
      bitmap_op.Get(), software_bitmap.GetAddressOf());
  if (FAILED(hr) || !software_bitmap) {
    result.error_code = "invalid_image";
    return result;
  }

  ComPtr<ABI_Found::IClosable> closable_bitmap;
  software_bitmap.As(&closable_bitmap);

  StaticHStringRef ocr_class(RuntimeClass_Windows_Media_Ocr_OcrEngine);
  if (FAILED(ocr_class.result())) {
    if (closable_bitmap) closable_bitmap->Close();
    result.error_code = "ocr_unavailable";
    return result;
  }

  ComPtr<ABI_Ocr::IOcrEngineStatics> ocr_statics;
  hr = RoGetActivationFactory(ocr_class.get(),
                              IID_PPV_ARGS(ocr_statics.GetAddressOf()));
  if (FAILED(hr) || !ocr_statics) {
    if (closable_bitmap) closable_bitmap->Close();
    result.error_code = "ocr_unavailable";
    return result;
  }

  ComPtr<ABI_Ocr::IOcrEngine> ocr_engine;
  hr = CreateOcrEngine(ocr_statics.Get(), ocr_engine.GetAddressOf());
  if (FAILED(hr) || !ocr_engine) {
    if (closable_bitmap) closable_bitmap->Close();
    result.error_code = "ocr_unavailable";
    return result;
  }

  ComPtr<ABI_Found::IAsyncOperation<ABI_Ocr::OcrResult*>> ocr_op;
  hr = ocr_engine->RecognizeAsync(software_bitmap.Get(),
                                  ocr_op.GetAddressOf());
  if (FAILED(hr) || !ocr_op) {
    if (closable_bitmap) closable_bitmap->Close();
    result.error_code = "ocr_failed";
    return result;
  }

  ComPtr<ABI_Ocr::IOcrResult> ocr_result;
  hr = WaitForAsyncOperation<ABI_Ocr::OcrResult*, ABI_Ocr::IOcrResult>(
      ocr_op.Get(), ocr_result.GetAddressOf());
  if (closable_bitmap) closable_bitmap->Close();
  if (FAILED(hr) || !ocr_result) {
    result.error_code = "ocr_failed";
    return result;
  }

  ComPtr<ABI_Coll::IVectorView<ABI_Ocr::OcrLine*>> lines;
  hr = ocr_result->get_Lines(lines.GetAddressOf());
  if (FAILED(hr) || !lines) {
    result.error_code = "ocr_failed";
    return result;
  }

  unsigned int line_count = 0;
  hr = lines->get_Size(&line_count);
  if (FAILED(hr)) {
    result.error_code = "ocr_failed";
    return result;
  }

  const double img_w = static_cast<double>(pixel_width);
  const double img_h = static_cast<double>(pixel_height);

  for (unsigned int i = 0; i < line_count; ++i) {
    ComPtr<ABI_Ocr::IOcrLine> line;
    if (FAILED(lines->GetAt(i, line.GetAddressOf())) || !line) continue;

    ScopedHString line_text_hstr;
    if (FAILED(line->get_Text(line_text_hstr.Put()))) continue;
    const std::string line_text = TrimAsciiSpaces(
        HStringToUtf8(line_text_hstr.Get()));
    if (line_text.empty()) continue;

    double min_x = 1.0;
    double min_y = 1.0;
    double max_x = 0.0;
    double max_y = 0.0;
    bool has_rect = false;

    ComPtr<ABI_Coll::IVectorView<ABI_Ocr::OcrWord*>> words;
    unsigned int word_count = 0;
    if (SUCCEEDED(line->get_Words(words.GetAddressOf())) && words &&
        SUCCEEDED(words->get_Size(&word_count))) {
      for (unsigned int w = 0; w < word_count; ++w) {
        ComPtr<ABI_Ocr::IOcrWord> word;
        if (FAILED(words->GetAt(w, word.GetAddressOf())) || !word) continue;
        ABI_Found::Rect rect{};
        if (FAILED(word->get_BoundingRect(&rect))) continue;
        const double wx = (std::min)((std::max)(rect.X / img_w, 0.0), 1.0);
        const double wy = (std::min)((std::max)(rect.Y / img_h, 0.0), 1.0);
        const double wx2 =
            (std::min)((std::max)((rect.X + rect.Width) / img_w, 0.0), 1.0);
        const double wy2 =
            (std::min)((std::max)((rect.Y + rect.Height) / img_h, 0.0), 1.0);
        if (!has_rect) {
          min_x = wx;
          min_y = wy;
          max_x = wx2;
          max_y = wy2;
          has_rect = true;
        } else {
          min_x = (std::min)(min_x, wx);
          min_y = (std::min)(min_y, wy);
          max_x = (std::max)(max_x, wx2);
          max_y = (std::max)(max_y, wy2);
        }
      }
    }

    WindowsOcrBlock block;
    block.text = line_text;
    if (has_rect) {
      block.x = min_x;
      block.y = min_y;
      block.w = (std::max)(0.0, max_x - min_x);
      block.h = (std::max)(0.0, max_y - min_y);
    }
    result.blocks.push_back(std::move(block));
  }

  std::sort(result.blocks.begin(), result.blocks.end(),
            [](const WindowsOcrBlock& a, const WindowsOcrBlock& b) {
              if (a.y != b.y) return a.y < b.y;
              return a.x < b.x;
            });

  for (size_t i = 0; i < result.blocks.size(); ++i) {
    if (i > 0) result.text.push_back('\n');
    result.text.append(result.blocks[i].text);
  }

  result.ok = true;
  return result;
}

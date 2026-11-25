#pragma once

#include <windows.h>

#include <cstdint>
#include <vector>

enum class ImageClipboardResult { kCopied, kBusy, kFailed };

enum class ReadClipboardImageResult { kFound, kEmpty, kBusy, kFailed };

struct RawClipboardImage {
  std::vector<uint8_t> bytes;
  bool is_dib = false;
};

ImageClipboardResult CopyPngToClipboard(HWND owner,
                                        const std::vector<uint8_t>& png);

ReadClipboardImageResult ReadClipboardPng(HWND owner,
                                          std::vector<uint8_t>* out_png);

ReadClipboardImageResult GrabClipboardImageRaw(HWND owner,
                                               RawClipboardImage* out_raw);

std::vector<uint8_t> WrapDibAsBmp(const uint8_t* dib, size_t dib_size);

std::vector<uint8_t> EncodeRawClipboardImageAsPng(const RawClipboardImage& raw);

std::vector<uint8_t> EncodeImagePreviewBytes(
    const std::vector<uint8_t>& image_bytes, UINT max_dimension);

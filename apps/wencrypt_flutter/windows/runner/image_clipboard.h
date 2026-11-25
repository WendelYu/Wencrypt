#pragma once

#include <windows.h>

#include <cstdint>
#include <vector>

enum class ImageClipboardResult { kCopied, kBusy, kFailed };

enum class ReadClipboardImageResult { kFound, kEmpty, kBusy, kFailed };

ImageClipboardResult CopyPngToClipboard(HWND owner,
                                        const std::vector<uint8_t>& png);

ReadClipboardImageResult ReadClipboardPng(HWND owner,
                                          std::vector<uint8_t>* out_png);

#pragma once

#include <windows.h>

#include <cstdint>
#include <vector>

enum class ImageClipboardResult { kCopied, kBusy, kFailed };

ImageClipboardResult CopyPngToClipboard(HWND owner,
                                        const std::vector<uint8_t>& png);

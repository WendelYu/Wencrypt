#pragma once

#include <cstdint>
#include <string>
#include <vector>

struct WindowsOcrBlock {
  std::string text;
  double x = 0.0;
  double y = 0.0;
  double w = 0.0;
  double h = 0.0;
};

struct WindowsOcrResult {
  bool ok = false;
  std::string error_code;
  std::string text;
  std::vector<WindowsOcrBlock> blocks;
};

WindowsOcrResult RecognizeImageWindows(const std::vector<uint8_t>& bytes);

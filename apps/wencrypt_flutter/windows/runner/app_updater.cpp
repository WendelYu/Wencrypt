#include "app_updater.h"

#include <shellapi.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <string>
#include <system_error>
#include <vector>

namespace {

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) return L"";
  int required = MultiByteToWideChar(
      CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
  if (required <= 0) return L"";
  std::wstring out(static_cast<size_t>(required), L'\0');
  int written = MultiByteToWideChar(
      CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), &out[0], required);
  if (written <= 0) return L"";
  return out;
}

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) return "";
  int required = WideCharToMultiByte(
      CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()), nullptr, 0,
      nullptr, nullptr);
  if (required <= 0) return "";
  std::string out(static_cast<size_t>(required), '\0');
  int written = WideCharToMultiByte(
      CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()), &out[0], required,
      nullptr, nullptr);
  if (written <= 0) return "";
  return out;
}

std::wstring GetCurrentExePath() {
  std::wstring buffer(MAX_PATH, L'\0');
  for (;;) {
    DWORD len = GetModuleFileNameW(
        nullptr, &buffer[0], static_cast<DWORD>(buffer.size()));
    if (len == 0) return L"";
    if (len < buffer.size() - 1) {
      buffer.resize(len);
      return buffer;
    }
    buffer.resize(buffer.size() * 2);
  }
}

bool IsDirectoryWritable(const std::filesystem::path& dir) {
  std::error_code ec;
  if (!std::filesystem::is_directory(dir, ec) || ec) return false;
  std::wstring probe_name =
      L".wencrypt-write-probe-" + std::to_wstring(GetCurrentProcessId()) +
      L"-" + std::to_wstring(GetTickCount64());
  std::filesystem::path probe = dir / probe_name;
  HANDLE handle = CreateFileW(
      probe.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
      FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE, nullptr);
  if (handle == INVALID_HANDLE_VALUE) {
    return false;
  }
  CloseHandle(handle);
  return true;
}

struct Sha256State {
  uint32_t state[8] = {
      0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU,
      0x510e527fU, 0x9b05688cU, 0x1f83d9abU, 0x5be0cd19U,
  };
  uint64_t total_bytes = 0;
  uint8_t buffer[64] = {};
  size_t buffer_len = 0;

  static inline uint32_t Rotr(uint32_t v, uint32_t n) {
    return (v >> n) | (v << (32 - n));
  }

  void Transform(const uint8_t block[64]) {
    static constexpr uint32_t kK[64] = {
        0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U, 0x3956c25bU,
        0x59f111f1U, 0x923f82a4U, 0xab1c5ed5U, 0xd807aa98U, 0x12835b01U,
        0x243185beU, 0x550c7dc3U, 0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U,
        0xc19bf174U, 0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU,
        0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU, 0x983e5152U,
        0xa831c66dU, 0xb00327c8U, 0xbf597fc7U, 0xc6e00bf3U, 0xd5a79147U,
        0x06ca6351U, 0x14292967U, 0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU,
        0x53380d13U, 0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U,
        0xa2bfe8a1U, 0xa81a664bU, 0xc24b8b70U, 0xc76c51a3U, 0xd192e819U,
        0xd6990624U, 0xf40e3585U, 0x106aa070U, 0x19a4c116U, 0x1e376c08U,
        0x2748774cU, 0x34b0bcb5U, 0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU,
        0x682e6ff3U, 0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U,
        0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U,
    };

    uint32_t w[64] = {};
    for (int i = 0; i < 16; ++i) {
      int j = i * 4;
      w[i] = (static_cast<uint32_t>(block[j]) << 24) |
             (static_cast<uint32_t>(block[j + 1]) << 16) |
             (static_cast<uint32_t>(block[j + 2]) << 8) |
             static_cast<uint32_t>(block[j + 3]);
    }
    for (int i = 16; i < 64; ++i) {
      uint32_t s0 = Rotr(w[i - 15], 7) ^ Rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      uint32_t s1 = Rotr(w[i - 2], 17) ^ Rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }

    uint32_t a = state[0], b = state[1], c = state[2], d = state[3];
    uint32_t e = state[4], f = state[5], g = state[6], h = state[7];
    for (int i = 0; i < 64; ++i) {
      uint32_t s1 = Rotr(e, 6) ^ Rotr(e, 11) ^ Rotr(e, 25);
      uint32_t ch = (e & f) ^ ((~e) & g);
      uint32_t temp1 = h + s1 + ch + kK[i] + w[i];
      uint32_t s0 = Rotr(a, 2) ^ Rotr(a, 13) ^ Rotr(a, 22);
      uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
      uint32_t temp2 = s0 + maj;

      h = g;
      g = f;
      f = e;
      e = d + temp1;
      d = c;
      c = b;
      b = a;
      a = temp1 + temp2;
    }

    state[0] += a;
    state[1] += b;
    state[2] += c;
    state[3] += d;
    state[4] += e;
    state[5] += f;
    state[6] += g;
    state[7] += h;
  }

  void Update(const uint8_t* data, size_t len) {
    total_bytes += len;
    size_t offset = 0;
    if (buffer_len > 0) {
      size_t needed = 64 - buffer_len;
      size_t take = std::min(needed, len);
      std::memcpy(buffer + buffer_len, data, take);
      buffer_len += take;
      offset += take;
      if (buffer_len == 64) {
        Transform(buffer);
        buffer_len = 0;
      }
    }
    while (offset + 64 <= len) {
      Transform(data + offset);
      offset += 64;
    }
    if (offset < len) {
      buffer_len = len - offset;
      std::memcpy(buffer, data + offset, buffer_len);
    }
  }

  std::string FinalHex() {
    uint64_t total_bits = total_bytes * 8;
    uint8_t pad_one = 0x80U;
    Update(&pad_one, 1);
    uint8_t zero = 0;
    while (buffer_len != 56) {
      Update(&zero, 1);
    }
    uint8_t len_be[8] = {};
    for (int i = 0; i < 8; ++i) {
      len_be[i] = static_cast<uint8_t>((total_bits >> ((7 - i) * 8)) & 0xffU);
    }
    Update(len_be, 8);

    static constexpr char kHex[] = "0123456789abcdef";
    std::string out;
    out.reserve(64);
    for (uint32_t word : state) {
      for (int shift = 28; shift >= 0; shift -= 4) {
        out.push_back(kHex[(word >> shift) & 0x0fU]);
      }
    }
    return out;
  }
};

bool ComputeFileSha256(const std::wstring& path, std::string* hex_out) {
  HANDLE file = CreateFileW(
      path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;

  Sha256State sha;
  std::array<uint8_t, 64 * 1024> buf{};
  DWORD read_bytes = 0;
  BOOL ok = FALSE;
  for (;;) {
    ok = ReadFile(file, buf.data(), static_cast<DWORD>(buf.size()),
                  &read_bytes, nullptr);
    if (!ok) {
      CloseHandle(file);
      return false;
    }
    if (read_bytes == 0) break;
    sha.Update(buf.data(), read_bytes);
  }
  CloseHandle(file);
  *hex_out = sha.FinalHex();
  return true;
}

std::string NormalizeHex(const std::string& raw) {
  std::string out;
  out.reserve(raw.size());
  for (unsigned char ch : raw) {
    if (!std::isspace(ch)) {
      out.push_back(static_cast<char>(std::tolower(ch)));
    }
  }
  return out;
}

bool WriteUtf8File(const std::filesystem::path& path, const std::string& body) {
  HANDLE file = CreateFileW(
      path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
      FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  BOOL ok = WriteFile(file, body.data(), static_cast<DWORD>(body.size()),
                      &written, nullptr);
  CloseHandle(file);
  return ok == TRUE && written == body.size();
}

std::wstring QuoteArg(const std::wstring& arg) {
  std::wstring out = L"\"";
  for (wchar_t ch : arg) {
    if (ch == L'"') out.push_back(L'\\');
    out.push_back(ch);
  }
  out.push_back(L'"');
  return out;
}

bool ExpandZipWithPowerShell(const std::wstring& zip_path,
                             const std::wstring& stage_dir) {
  SetEnvironmentVariableW(L"WENCRYPT_ZIP_PATH", zip_path.c_str());
  SetEnvironmentVariableW(L"WENCRYPT_STAGE_DIR", stage_dir.c_str());

  std::wstring cmd =
      L"powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass "
      L"-Command \"Expand-Archive -LiteralPath $env:WENCRYPT_ZIP_PATH "
      L"-DestinationPath $env:WENCRYPT_STAGE_DIR -Force\"";

  STARTUPINFOW si{};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi{};
  BOOL launched = CreateProcessW(
      nullptr, &cmd[0], nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr,
      nullptr, &si, &pi);

  SetEnvironmentVariableW(L"WENCRYPT_ZIP_PATH", nullptr);
  SetEnvironmentVariableW(L"WENCRYPT_STAGE_DIR", nullptr);

  if (!launched) return false;
  DWORD wait_result = WaitForSingleObject(pi.hProcess, 60000);
  DWORD exit_code = 1;
  if (wait_result == WAIT_OBJECT_0) {
    GetExitCodeProcess(pi.hProcess, &exit_code);
  } else {
    TerminateProcess(pi.hProcess, 1);
  }
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  return wait_result == WAIT_OBJECT_0 && exit_code == 0;
}

std::wstring FindPayloadExecutableName(const std::filesystem::path& dir) {
  std::error_code ec;
  for (const wchar_t* candidate : {L"Wencrypt.exe", L"wencrypt.exe"}) {
    ec.clear();
    if (std::filesystem::is_regular_file(dir / candidate, ec) && !ec) {
      return candidate;
    }
  }
  return {};
}

std::filesystem::path LocatePayloadRoot(
    const std::filesystem::path& stage_dir) {
  if (!FindPayloadExecutableName(stage_dir).empty()) {
    return stage_dir;
  }
  std::error_code ec;
  std::vector<std::filesystem::path> subdirs;
  for (const auto& entry :
       std::filesystem::directory_iterator(stage_dir, ec)) {
    if (ec) break;
    std::error_code item_ec;
    if (entry.is_directory(item_ec) && !item_ec) {
      subdirs.push_back(entry.path());
    }
  }
  if (subdirs.size() == 1 && !FindPayloadExecutableName(subdirs[0]).empty()) {
    return subdirs[0];
  }
  return {};
}

bool ValidatePayloadRoot(const std::filesystem::path& root) {
  if (root.empty() || FindPayloadExecutableName(root).empty()) return false;
  std::error_code ec;
  for (const wchar_t* required : {L"wencrypt_core.dll", L"flutter_windows.dll"}) {
    ec.clear();
    if (!std::filesystem::is_regular_file(root / required, ec) || ec) {
      return false;
    }
  }
  return true;
}

}  // namespace

WindowsAppInfo GetWindowsAppInfo() {
  WindowsAppInfo info;
#ifdef FLUTTER_VERSION
  info.version = FLUTTER_VERSION;
#else
  info.version = "0.3.11";
#endif
#ifdef FLUTTER_VERSION_BUILD
  info.build_number = std::to_string(FLUTTER_VERSION_BUILD);
#else
  info.build_number = "1";
#endif

  std::wstring exe_path = GetCurrentExePath();
  if (!exe_path.empty()) {
    std::filesystem::path install_dir =
        std::filesystem::path(exe_path).parent_path();
    info.install_path = WideToUtf8(install_dir.wstring());
    info.can_auto_install = IsDirectoryWritable(install_dir);
  }
  return info;
}

bool OpenWindowsUrl(const std::string& url) {
  if (url.rfind("https://", 0) != 0) return false;
  std::wstring wide_url = Utf8ToWide(url);
  if (wide_url.empty()) return false;
  HINSTANCE result = ShellExecuteW(
      nullptr, L"open", wide_url.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
  return reinterpret_cast<intptr_t>(result) > 32;
}

bool OpenWindowsDirectory(const std::string& path) {
  std::wstring wide_path = Utf8ToWide(path);
  if (wide_path.empty()) return false;
  DWORD attrs = GetFileAttributesW(wide_path.c_str());
  if (attrs == INVALID_FILE_ATTRIBUTES ||
      (attrs & FILE_ATTRIBUTE_DIRECTORY) == 0) {
    return false;
  }
  HINSTANCE result = ShellExecuteW(
      nullptr, L"open", wide_path.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
  return reinterpret_cast<intptr_t>(result) > 32;
}

WindowsInstallResult InstallWindowsUpdateAndRestart(
    const std::string& archive_path,
    const std::string& expected_sha256,
    HWND /*hwnd*/) {
  std::wstring exe_path = GetCurrentExePath();
  if (exe_path.empty()) {
    return {false, "install_failed"};
  }
  std::filesystem::path install_dir =
      std::filesystem::path(exe_path).parent_path();
  if (!IsDirectoryWritable(install_dir)) {
    return {false, "install_location_readonly"};
  }

  std::wstring wide_archive = Utf8ToWide(archive_path);
  std::string expected_norm = NormalizeHex(expected_sha256);
  std::string actual_hex;
  if (wide_archive.empty() || expected_norm.size() != 64 ||
      !ComputeFileSha256(wide_archive, &actual_hex) ||
      actual_hex != expected_norm) {
    if (!wide_archive.empty()) DeleteFileW(wide_archive.c_str());
    return {false, "checksum_mismatch"};
  }

  wchar_t temp_root[MAX_PATH] = {};
  DWORD temp_len = GetTempPathW(MAX_PATH, temp_root);
  if (temp_len == 0 || temp_len >= MAX_PATH) {
    DeleteFileW(wide_archive.c_str());
    return {false, "install_failed"};
  }

  std::filesystem::path work_dir =
      std::filesystem::path(temp_root) /
      (L"wencrypt-updater-" + std::to_wstring(GetCurrentProcessId()) + L"-" +
       std::to_wstring(GetTickCount64()));
  std::filesystem::path stage_dir = work_dir / L"extracted";
  std::error_code ec;
  if (!std::filesystem::create_directories(stage_dir, ec) || ec) {
    DeleteFileW(wide_archive.c_str());
    return {false, "install_failed"};
  }

  if (!ExpandZipWithPowerShell(wide_archive, stage_dir.wstring())) {
    std::filesystem::remove_all(work_dir, ec);
    DeleteFileW(wide_archive.c_str());
    return {false, "invalid_archive"};
  }
  DeleteFileW(wide_archive.c_str());

  std::filesystem::path payload_root = LocatePayloadRoot(stage_dir);
  if (!ValidatePayloadRoot(payload_root)) {
    std::filesystem::remove_all(work_dir, ec);
    return {false, "bundle_validation_failed"};
  }
  const std::wstring payload_exe_name = FindPayloadExecutableName(payload_root);
  if (payload_exe_name.empty()) {
    std::filesystem::remove_all(work_dir, ec);
    return {false, "bundle_validation_failed"};
  }
  const std::filesystem::path target_exe_path = install_dir / payload_exe_name;

  std::filesystem::path script_path = work_dir / L"apply-update.ps1";
  const std::string script_body =
      "param(\n"
      "  [int]$TargetPid,\n"
      "  [string]$SourceDir,\n"
      "  [string]$InstallDir,\n"
      "  [string]$OldExePath,\n"
      "  [string]$TargetExePath,\n"
      "  [string]$WorkDir\n"
      ")\n"
      "$deadline = (Get-Date).AddSeconds(20)\n"
      "while ((Get-Date) -lt $deadline) {\n"
      "  if (-not (Get-Process -Id $TargetPid -ErrorAction SilentlyContinue)) { break }\n"
      "  Start-Sleep -Milliseconds 250\n"
      "}\n"
      "if (Get-Process -Id $TargetPid -ErrorAction SilentlyContinue) {\n"
      "  Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue\n"
      "  exit 1\n"
      "}\n"
      "if (($OldExePath -cne $TargetExePath) -and (Test-Path -LiteralPath $OldExePath)) {\n"
      "  Remove-Item -LiteralPath $OldExePath -Force -ErrorAction SilentlyContinue\n"
      "}\n"
      "Copy-Item -Path (Join-Path $SourceDir '*') -Destination $InstallDir -Recurse -Force\n"
      "Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue\n"
      "Start-Process -FilePath $TargetExePath\n";

  if (!WriteUtf8File(script_path, script_body)) {
    std::filesystem::remove_all(work_dir, ec);
    return {false, "install_failed"};
  }

  std::wstring cmd =
      L"powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " +
      QuoteArg(script_path.wstring()) + L" " +
      std::to_wstring(GetCurrentProcessId()) + L" " +
      QuoteArg(payload_root.wstring()) + L" " +
      QuoteArg(install_dir.wstring()) + L" " +
      QuoteArg(exe_path) + L" " +
      QuoteArg(target_exe_path.wstring()) + L" " +
      QuoteArg(work_dir.wstring());

  STARTUPINFOW si{};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi{};
  BOOL launched = CreateProcessW(
      nullptr, &cmd[0], nullptr, nullptr, FALSE,
      CREATE_NEW_PROCESS_GROUP | DETACHED_PROCESS | CREATE_NO_WINDOW,
      nullptr, nullptr, &si, &pi);
  if (!launched) {
    std::filesystem::remove_all(work_dir, ec);
    return {false, "install_failed"};
  }
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  return {true, ""};
}

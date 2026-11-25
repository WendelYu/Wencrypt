#ifndef RUNNER_APP_UPDATER_H_
#define RUNNER_APP_UPDATER_H_

#include <windows.h>

#include <string>

struct WindowsAppInfo {
  std::string version;
  std::string build_number;
  std::string install_path;
  bool can_auto_install = false;
};

struct WindowsInstallResult {
  bool ok = false;
  std::string error_code;
};

WindowsAppInfo GetWindowsAppInfo();
bool OpenWindowsUrl(const std::string& url);
bool OpenWindowsDirectory(const std::string& path);
WindowsInstallResult InstallWindowsUpdateAndRestart(
    const std::string& archive_path,
    const std::string& expected_sha256,
    HWND hwnd);

#endif  // RUNNER_APP_UPDATER_H_

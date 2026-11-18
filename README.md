# Wencrypt

Wencrypt 是一款离线优先的个人密码管理器，支持 macOS、Windows 和 Android。密码库加密保存在本机，可通过你自己的坚果云 WebDAV 在设备间同步。

## 下载与安装

从 [GitHub Releases](https://github.com/WendelYu/Wencrypt/releases/latest) 下载对应安装包。每次发布附带 `SHA256SUMS.txt`，可用于核对下载完整性。

- **macOS（Apple 芯片）**使用 `wencrypt-macos-arm64.dmg`。将 Wencrypt 拖到「应用程序」后打开。当前版本尚未经过 Apple 公证。遇到「已损坏」或无法打开时，请查看 DMG 内的「首次打开帮助.html」。[Apple 官方首次打开说明](https://support.apple.com/zh-cn/102445)
- **Windows（x64）**使用 `wencrypt-windows-x64.zip`。完整解压后运行 `wencrypt.exe`。
- **Android（ARM64）**使用 `wencrypt-android-arm64-debug.apk`。APK 使用开发签名。如果系统提示签名不匹配，请先确认可恢复的加密备份或已同步的云端副本，再处理旧版安装。

## 首次使用与跨设备同步

1. **第一台设备**选择「创建新库」，设置主密码。在「坚果云设置」绑定一个主同步目录，完成首次同步。
2. **其他设备**选择「加入已有库 → 从坚果云加入」，填写同一个坚果云账号和同步目录、该设备的 WebDAV 应用密码，以及原库主密码。也可从加密备份恢复。
3. **已有密码库升级到 0.3.0**时，先升级所有参与同步的设备，再在资料最完整的原设备用原目录完成一轮同步。新版以密文包分批同步，保留旧文件、历史和回收站状态，移除了原来的 598 条修订限制。

[使用与升级说明](docs/08-alpha-guide.md) · [同步协议](docs/04-sync-protocol.md)

## 功能与状态

- 本地新增、搜索和分组，支持置顶、撤回删除及查看历史版本。
- 导入浏览器 CSV，相同凭据会合并，已有账号的标题和置顶状态会保留。
- 坚果云同步支持分批传输与后续轮次续传。并发修改保留各版本，供用户解决冲突。
- 本机密码库使用 Argon2id 和 AES-256-GCM。支持独立加密备份，macOS 和 Android 支持本机指纹解锁。
- 0.3.0 已通过模拟 WebDAV 的三库大批量同步测试。真实坚果云与三端实机验收仍在进行，项目尚未完成独立安全审计。

## 开发文档

- [架构](docs/02-architecture.md)与[加密格式](docs/03-crypto-format.md)
- [坚果云配置与 GitHub 自动发布](docs/07-jianguoyun-and-github.md)
- [构建脚本](tools/package_p0.py)与[实测记录](reports/p0-status.md)

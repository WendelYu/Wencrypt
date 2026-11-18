## 下载

- **macOS（Apple 芯片）**：`wencrypt-macos-arm64.dmg`
- **Windows（x64）**：`wencrypt-windows-x64.zip`，解压后运行 `wencrypt.exe`
- **Android（ARM64）**：`wencrypt-android-arm64-debug.apk`，使用开发签名。若旧版签名不同，先导出并验证加密备份，再考虑卸载旧版。
- **SHA-256**：`SHA256SUMS.txt`

## 多设备首次使用与升级

请先把同一个库的各端都升级到此版本。现有设备保留本机密码库及坚果云配置，请先在资料最完整的原设备完成一轮同步。新设备在欢迎页选择「加入已有库」，用原主密码加入同一个坚果云目录，或从加密备份恢复。首次同步使用密文包分批处理历史记录。

## macOS 安装与首次打开

**当前 Wencrypt macOS 版本尚未经过 Apple 公证。**

1. 打开官方 Release 下载的 DMG，把 Wencrypt 拖到「应用程序」，然后从「应用程序」尝试打开。DMG 里的「首次打开帮助.html」提供直达系统设置的链接。
2. 如果提示无法验证开发者或无法检查 App，关闭提示后前往「系统设置 → 隐私与安全性」。滚动到「安全性」，点「仍要打开」并按提示确认。
3. 如果提示「已损坏」或仍然无法打开，重新下载 Apple 芯片版 DMG。可在终端运行 `shasum -a 256 ~/Downloads/wencrypt-macos-arm64.dmg`，并与 `SHA256SUMS.txt` 中该文件的摘要比对。重新安装后仍提示损坏、校验不符，或系统明确警告 App 会损坏电脑时，请停止打开，并在本仓库提交问题，附上 macOS 版本和完整提示。

[Apple 官方首次打开说明](https://support.apple.com/zh-cn/102445)

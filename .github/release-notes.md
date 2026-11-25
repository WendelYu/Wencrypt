## 下载

- **macOS（Apple 芯片）**：`Wencrypt-@TAG@-macos-arm64.dmg`
- **Windows（x64）**：`Wencrypt-@TAG@-windows-x64.zip`，解压后运行 `Wencrypt.exe`
- **Android（ARM64）**：`Wencrypt-@TAG@-android-arm64.apk`。已安装同一固定证书签名的版本时可直接覆盖安装。使用开发签名的旧版需要先导出并验证可恢复的加密备份，再卸载迁移。
- **SHA-256**：`SHA256SUMS.txt`

## 多设备首次使用与升级

请先把同一个库的各端都升级到此版本。现有设备保留本机密码库及坚果云配置，请先在资料最完整的原设备完成一轮同步。新设备在欢迎页选择「加入已有库」，用原主密码加入同一个坚果云目录，或从加密备份恢复。首次同步使用密文包分批处理历史记录。

## macOS 安装与首次打开

**当前 Wencrypt macOS 版本尚未经过 Apple 公证。**

1. 打开官方 Release 下载的 DMG，把 Wencrypt 拖到「应用程序」，然后从「应用程序」尝试打开。DMG 里的「首次打开帮助.html」提供直达系统设置的链接。
2. 如果提示无法验证开发者或无法检查 App，关闭提示后前往「系统设置 → 隐私与安全性」。滚动到「安全性」，点「仍要打开」并按提示确认。
3. 如果仍提示「已损坏」或无法打开，请重新下载本仓库的 Apple 芯片版 DMG，并核对 `SHA256SUMS.txt`。可运行 `shasum -a 256 "$HOME/Downloads/Wencrypt-@TAG@-macos-arm64.dmg"` 查看摘要。

确认摘要一致、应用已拖入「应用程序」，且系统未提示恶意软件时，可在终端执行下面的命令清除该应用的下载隔离标记，然后重新打开 Wencrypt。

```sh
xattr -dr com.apple.quarantine "/Applications/Wencrypt.app"
```

校验不符、系统提示 App 会损坏电脑，或执行后仍无法打开时，请停止尝试并提交问题，附上 macOS 版本和完整提示。

[Apple 官方首次打开说明](https://support.apple.com/zh-cn/102445)

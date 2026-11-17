# P0 验证操作手册

> 2026-11-17 更新：首期后端已改为坚果云 WebDAV。此前 OneDrive 首期说明由 [后端变更与构建说明](07-jianguoyun-and-github.md) 覆盖；OneDrive 验证暂停。
所有探针只使用公开测试数据，不录入真实密码。当前验证状态以 reports/p0-status.md 为准。

## OneDrive 应用注册（用户操作）

1. 打开 [Microsoft Entra 管理中心](https://entra.microsoft.com/)，进入“应用注册”→“新注册”。若当前账号无权创建应用，需要可创建注册的 Entra 租户；不要为方便改用他人的 Client ID。
2. 名称 Wencrypt P0。支持账户类型选择包含“个人 Microsoft 账户”的选项；仅个人账号也可。探针使用 consumers authority，不支持企业账号。
3. “身份验证”→添加平台→“移动和桌面应用”，添加重定向 URI `http://localhost/callback`。探针在 localhost 随机端口接收，Microsoft 对桌面 loopback 的端口匹配规则允许动态端口。不能填 SPA 或 Web confidential client。
4. “API 权限”移除自动添加的 User.Read，添加 Microsoft Graph **委托权限 Files.ReadWrite.AppFolder**。不添加 Files.ReadWrite、Files.ReadWrite.All 或应用权限。探针还请求 offline_access 用于内存中的刷新测试。
5. 不创建 Client Secret。复制“应用程序(客户端) ID”；它是公开标识，可告诉开发助手。
6. 本地运行 `python3 tools/onedrive_probe.py --client-id <Client-ID>`。系统浏览器会进入 Microsoft 登录与授权，由用户自行完成。
7. 工具仅在 AppFolder 内创建 `wencrypt-p0-<随机值>` 文件夹，上传五个公开测试密文并重复上传/下载/分页验证，之后保持测试文件以供人工检查；不删除用户文件。
8. 完成后 Token 只在进程内释放，进程退出；这不是 Microsoft 会话注销/服务端撤销。可在账号应用授权页面手动撤销应用权限，验证下次运行重新授权。删除测试文件夹由用户在 OneDrive 中操作。

不要发送密码、Token、Client Secret、完整浏览器回调地址或 HTTP 调试转储。工具仅输出去敏结果；失败时故意不打印服务端正文。Python 原型不保证内存可靠清零，不用于产品认证缓存。

注册参考：[官方原生应用 OAuth/PKCE](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow)、[原生应用重定向限制](https://learn.microsoft.com/en-us/entra/identity-platform/reply-url)、[AppFolder](https://learn.microsoft.com/graph/onedrive-sharepoint-appfolder)。若权限页面/接口不支持预期行为，记录失败，不扩大权限。

## macOS 开发环境（用户操作）

通过 App Store 安装完整 Xcode，首次启动并安装所需组件/接受许可。只有 Command Line Tools 无法构建 Flutter macOS Runner。安装后可使用 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 为单次构建选择环境，无需修改全局选择。

## 实机验收记录

每次填写设备型号、OS、安装包版本/源码版本、日期和结果。分别执行：

1. 运行 Rust build-info 和 Argon2 基准，核对 bootstrap=135 字节及 UTF-8 向量通过。
2. 设备探针创建公开随机测试密钥/数据，包裹并持久化，认证解包裹并比较原始数据，不展示数据本身。
3. 取消认证应失败；锁屏/重启后重新认证；后台回来不能复用旧认证上下文。
4. 在用户愿意时变更生物识别录入，旧保护是否按策略失效；不要求为普通开发随意删除系统生物信息。
5. 记录是否硬件支持与认证是否和密钥使用绑定，不以弹窗出现即判定安全。
6. OneDrive 在桌面网络和 Android 移动网络重复测试；断网期间本地测试仍可运行，恢复后再次读取已上传测试文件。

Android 需要启用开发者选项/USB 调试并在手机上确认本机授权；Windows 需要 Flutter、Rust MSVC、Visual Studio Desktop development with C++。这些机器不可由当前 Mac 的测试替代。

## macOS Touch ID 的本地开发签名

公开 Actions 包使用临时签名。在本机，应用能探测到 Touch ID 和 Secure Enclave，但用 Data Protection Keychain 保存测试密钥时返回 `-34018`。Keychain 默认访问组由签名里的应用标识决定。

1. 从 App Store 安装完整 Xcode，首次启动完成初始化。在 Xcode → Settings → Accounts 登录 Apple 账号并选择可用于本机开发的团队。
2. 打开 `apps/wencrypt_flutter/macos/Runner.xcworkspace`。选中 Runner target，进入 Signing & Capabilities，启用 Automatically manage signing，选择团队，保留 bundle ID `org.wencrypt.wencrypt`。使用 Xcode 生成 macOS 开发证书和适用于这台 Mac 的开发描述文件。先尝试已有团队或 Personal Team，能否获取匹配的描述文件以 Xcode 的结果为准。
3. 运行 `security find-identity -v -p codesigning`，找出描述文件包含的 Apple Development 签名身份。用已校验的 CI 测试包、描述文件和签名身份制作新副本。

   ```sh
   python3 tools/sign_macos_keychain_probe.py .tools/ci-macos-5231869/wencrypt.app \
     --profile /path/to/development.provisionprofile \
     --identity CERTIFICATE_SHA1 \
     --output .tools/macos-touch-id/Wencrypt-Development.app
   ```

4. 运行新副本并点击「生成测试密钥」，期待 `wrapped_test_marker`。退出后重新打开，点击「认证并解包测试数据」，先取消确认失败，再重试并按指纹，期待 `authenticated_unwrap_passed`。

脚本保留应用沙箱并使用描述文件授权的应用标识和团队标识。Wencrypt 只访问自身的默认 Keychain 组。描述文件和私钥留在本机。如果 Xcode 报 bundle ID 或描述文件冲突，记录报错并核对团队、设备和签名范围再继续。

[Apple Keychain 实现](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains) · [Apple 描述文件说明](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)

## Mac 无开发者会员的 Secure Enclave v2 路线

当前 macOS 探针使用 CryptoKit SecureEnclave P-256 ECDH、HKDF-SHA256 和 AES-256-GCM。硬件私钥设置 `privateKeyUsage + biometryCurrentSet`，每次解包使用新的 LAContext，不复用认证，也不回退系统密码或软件私钥。只存储本机硬件封装块、公钥、随机 salt 和测试数据密文。该格式独立于云端 WENC v1，不上传网盘。

Flutter 的三个按钮仍为生成、认证解包、清除测试密钥。数据默认存入应用 Application Support 的 `org.wencrypt/device-probe-v2.json`。旧 v1 Keychain 探针不会迁移或自动删除。v2 清除按钮只清除 v2 文件，不能视为旧文件备份的密码学撤销。

本机没有完整 Xcode 时可用 Command Line Tools 验证与 Flutter 共用的原生源文件：

```sh
swiftc platform_probes/macos/DeviceProbe.swift platform_probes/macos/main.swift -o /tmp/wencrypt-device-probe
WENCRYPT_PROBE_FILE="$PWD/.tools/macos-touch-id/persistent-v2.json" /tmp/wencrypt-device-probe createProbe
WENCRYPT_PROBE_FILE="$PWD/.tools/macos-touch-id/persistent-v2.json" /tmp/wencrypt-device-probe unlockProbe
```

每次命令是独立进程。第一轮按指纹，应为 `authenticated_unwrap_passed`；第二轮取消，必须 `not_passed` 且 `unlocked=false`。`unlockProbeNonInteractive` 必须拒绝解包。损坏文件、缺文件及超长文件测试可通过 `WENCRYPT_MACOS_PROBE=/tmp/wencrypt-device-probe python3 -m unittest discover -s tools -p test_macos_probe.py` 运行。

这仍是公开测试数据探针，`strictUnlockEnabled=false`。尚未接入真实 DEK、锁屏生命周期和主密码重绑定。独立进程验证不能替代 Flutter 沙箱包退出重开验证；完整 Flutter 包可通过 GitHub Actions 构建，不需要本机安装 Xcode。应用发行签名与公证另行处理。

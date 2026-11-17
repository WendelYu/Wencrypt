# P0 验证状态

- WEN-001 已生成三端 Flutter runner，Rust 动态库通过两个 C ABI 函数提供格式版本和公开数据解锁测试。P0 选择直接 Dart FFI，避免为这两个无参数函数引入生成器和跨端构建插件。正式 API 桥接另议。三端包由同一打包脚本生成，Windows 与 Android 实机安装仍待完成，本机缺完整 Xcode。
- WEN-002 用户在真实坚果云账号完成建目录、重复上传、密文下载和列举。仍需断网重连、Android 网络测试、目录完整性和撤销凭据测试。免费预算策略及 Rust 账本原型已补充，正式网络接入待 WEN-013。
- WEN-003 Android、macOS、Windows 原生探针已接入 Flutter。macOS Swift 文件已通过类型检查，本机检测到 Secure Enclave 和 Touch ID，但命令行探针创建密钥返回 -34018（Keychain entitlement 缺失）。需在带适当签名和 Keychain entitlement 的应用中验证。Windows 的 TPM 往返探针尚未验证 Hello 认证绑定。所有平台正式快速解锁仍关闭。
- WEN-004 Rust 与独立 Python 生成的公开数据向量交叉验证通过。CBOR 结构和版本图用例已在仓库。本机完成 Rust release 基准，Android 需运行 P0 应用的解锁计时。

GitHub Actions 产物文件名为 wencrypt-windows-x64.zip、wencrypt-macos-arm64.zip 和 wencrypt-android-arm64-debug.apk。macOS 包应用了临时签名，正式公证独立处理。远端验证以 Actions 实际运行结果为准。

## 实机复测 2026-11-17

- macOS 26.6.2 Apple Silicon 本机运行 CI 产物 `5231869`。下载摘要与 GitHub 一致，严格签名校验通过。旧版结果区触发 Flutter macOS 无障碍文本编辑的 `startEditing` 异常。改成只读文本后，应用界面显示 WENC v1 验证通过，Argon2id 解锁 90 ms，并顺利切换设备探针结果。
- 同一 macOS 应用报告 Touch ID 和 Secure Enclave 可用。生成测试密钥失败于 `secure_key_creation`，系统错误 `-34018`。本机无有效开发签名身份，需配置合适的 Apple 签名和 Keychain entitlement 后再验证持久密钥与认证解包。
- Windows 实机由用户反馈 TPM 可用，`authenticationBound = false`。随后报告 WENC v1 通过，Argon2id 解锁 131 ms。Hello 与解包操作的绑定仍待验证。

- macOS Touch ID 补充实验：CryptoKit Secure Enclave 测试密钥带 `privateKeyUsage` 和 `biometryCurrentSet`。用硬件封装数据重载同一密钥后，禁止认证交互时密钥协商返回 LocalAuthentication -1004，用户按指纹后密钥协商成功并匹配对端。这个实验独立于应用的 Data Protection Keychain 持久化。Keychain 测试包的开发签名仍待描述文件和证书，签名操作已整理进 P0 手册。

## Secure Enclave v2 / Android 补充

- Android 用户截图确认 WENC v1 解锁179ms、硬件保护创建和认证解包成功、清除成功。取消、锁屏、重新录入和跨进程矩阵尚未验证。
- macOS 改用 CryptoKit 硬件封装块持久化，绕开旧永久 Keychain 条目创建路径。Swift编译通过，独立进程禁止交互时返回 LocalAuthentication -1004，unlocked=false。
- 缺文件、无效JSON、缺字段、超长文件和重复清除测试通过。正向指纹和用户取消实测正在进行。正式快速解锁保持关闭。

- macOS v2 正向实测通过：创建进程退出后，另起进程读取磁盘硬件封装块，用户 Touch ID 认证后返回 authenticated_unwrap_passed、authenticationBound=true、hardwareBacked=true、unlocked=true。此证据属于原生独立进程，Flutter 沙箱包重开尚待验证。取消认证测试已发起。
- macOS v2 取消实测通过：在正向成功之后再起新进程，用户点击取消，返回 LocalAuthentication -2、not_passed、unlocked=false，退出码1。没有复用上一轮认证成功状态。原生独立进程退出重开和取消路径均已验证；正式DEK集成、Flutter沙箱应用重开、锁屏/重启/生物特征变更测试仍待完成。

## Alpha 0.1 首轮构建

提交62cfd30的GitHub Actions三端已产生产物。Rust离线/重启/冲突/备份测试、Flutter锁定页与预算测试通过。随后新增锁定epoch校验，防止排队解锁在锁定后重新建立会话；回归测试通过，最终包需对应后续提交。真实坚果云Alpha同步和三端真实库操作仍需实机验证。

## Alpha 最终产物

- 提交 `dbb994233955f266329031e0713b9ff66bb58de1`，Actions https://github.com/WendelYu/Wencrypt/actions/runs/44093230639 的核心检查和三端包全部通过。
- 三个artifact归档下载后SHA-256均匹配GitHub元数据。最终Mac包严格codesign验证通过。
- Mac首轮Alpha应用实测创建、保存、编辑、退出重开主密码解锁成功。中文真实输入法、最终包完整安全矩阵未计为通过。
- 交付目录 `build/alpha-dbb9942/`（忽略，不提交二进制），包含三端包、Mac解压应用和SHA256SUMS.txt。
- 本机实测创建了仅含公开fixture的Alpha库，主密码 `Wencrypt Alpha public test 2026!`。这不是用户真实主密码，也不能用于真实密码库。
- 当前仍是测试数据Alpha；正式生物识别DEK集成、自动同步、跨设备网盘验收及独立安全评审未完成，详见 docs/08-alpha-guide.md。

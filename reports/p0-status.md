# P0 验证状态

- WEN-001 已生成三端 Flutter runner，Rust 动态库通过两个 C ABI 函数提供格式版本和公开数据解锁测试。P0 选择直接 Dart FFI，避免为这两个无参数函数引入生成器和跨端构建插件。正式 API 桥接另议。三端包由同一打包脚本生成，Windows 与 Android 实机安装仍待完成，本机缺完整 Xcode。
- WEN-002 用户在真实坚果云账号完成建目录、重复上传、密文下载和列举。仍需断网重连、Android 网络测试、目录完整性和撤销凭据测试。免费预算策略及 Rust 账本原型已补充，正式网络接入待 WEN-013。
- WEN-003 Android、macOS、Windows 原生探针已接入 Flutter。macOS Swift 文件已通过类型检查，先前沙箱外检测确认硬件与生物识别能力存在，安全密钥创建首次失败。Windows TPM 往返不证明 Hello 约束绑定。所有平台正式快速解锁仍关闭。待签名环境和实机验证。
- WEN-004 Rust 与独立 Python 生成的公开数据向量交叉验证通过。CBOR 结构和版本图用例已在仓库。本机完成 Rust release 基准，Android 需运行 P0 应用的解锁计时。

GitHub Actions 产物文件名为 wencrypt-windows-x64.zip、wencrypt-macos-arm64.zip 和 wencrypt-android-arm64-debug.apk。macOS 包应用了临时签名，正式公证独立处理。远端验证以 Actions 实际运行结果为准。

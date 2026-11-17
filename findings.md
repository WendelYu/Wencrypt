# 研究记录

2026-11-17：项目目录为空，无现有代码和项目内 AGENTS.md。此前调研确认 KDBX 生态可替代，但用户已选择自研。

## 官方资料核对

- Graph AppFolder 支持专属目录和最小权限；通用上传 API 权限表与 AppFolder 专题文档展示不完全一致，因此只使用 AppFolder 的真实上传/列举/下载必须作为 P0 验证项，不静默升级权限。
- Graph 普通 PUT content 文档未列出 If-Match，上传会话文档才明确说明条件请求。不能把所有 Graph 上传都描述成有 CAS 保证。
- 同步采用不可变密文对象集合，避免依赖单个共享可变文件及全局锁。
- 坚果云官方存在 WebDAV 请求频率限制，通用 WebDAV 也需要单独测试认证、列举、写入和错误行为。
- Flutter 官方支持目标三端；flutter_rust_bridge 提供 Rust 桥接，但原生安全能力仍需平台代码与实机验证。

来源（2026-11-17 查阅）：
- https://learn.microsoft.com/graph/onedrive-sharepoint-appfolder
- https://learn.microsoft.com/en-us/graph/api/driveitem-put-content?view=graph-rest-1.0
- https://learn.microsoft.com/en-us/graph/api/driveitem-createuploadsession?view=graph-rest-1.0
- https://help.jianguoyun.com/?p=2064
- https://docs.flutter.dev/reference/supported-platforms
- https://cjycode.com/flutter_rust_bridge/
- https://www.rfc-editor.org/rfc/rfc9106.html

## 后续发现

- Android BiometricPrompt 区分强/弱认证，CryptoObject 将认证与密钥使用相连；弱人脸不能默认为硬件密钥解锁条件。
- Windows UserConsentVerifier 提供认证结果，不足以单独证明 DPAPI 解密受硬件认证绑定；将强绑定能力设为 P0 风险门槛。
- OAuth 使用 public client + Authorization Code / PKCE，不嵌入 client_secret。

来源：
- https://developer.android.com/identity/sign-in/biometric-auth
- https://developer.android.com/privacy-and-security/keystore
- https://learn.microsoft.com/en-us/uwp/api/windows.security.credentials.ui.userconsentverifier
- https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow

## 设计推论（不是来源直接结论）

- 首期优先 Graph 的原因是目标服务明确和权限范围，而不是推断其在用户网络一定更快或比 WebDAV 更安全。
- 不可变内容寻址修订避免正常并发时多端覆盖共享文件；没有共享 manifest 或 GC，因此代价是历史增长和首次发现成本。
- MVP 保留同条目并发版本，字段级自动合并延期，避免因误判共同基线产生静默密码覆盖。

坚果云MKCOL排查：认证根属性请求成功，43字符随机顶层目录创建失败。https://docs.agentero.app/backend/sync/ 记录顶层sandbox name is too long限制；坚果云官方 https://help.jianguoyun.com/?p=1904 仅说明通用255字符路径限制，并未给出顶层sandbox特例。因此缩短目录名是有依据的兼容修复，尚非实测确诊。

用户提供 Android 截图：WENC v1 179ms，hardwareBacked=true，authenticated_unwrap_passed，reset成功。正式strictUnlockEnabled仍false。
Apple CryptoKit 官方 Storing CryptoKit Keys in the Keychain 文档确认 dataRepresentation 为仅原Secure Enclave可恢复的加密块，不是明文私钥。新实现采用本地私有文件存储硬件块和AEAD密文，不依赖永久Keychain条目的签名权限。

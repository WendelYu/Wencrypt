# 架构与后端选型 v0.1

> 2026-11-17 更新：首期后端已改为坚果云 WebDAV。此前 OneDrive 首期说明由 [后端变更与构建说明](07-jianguoyun-and-github.md) 覆盖；OneDrive 验证暂停。
## 1. 选型结论

OneDrive 本身也是网盘。本次比较的实际选项是“个人 OneDrive 的 Graph API”和“支持 WebDAV 的网盘/NAS”。选择 OneDrive Graph 作为首期后端，WebDAV 为下一阶段适配器。

理由：当前目标已包含个人 OneDrive；AppFolder 能约束授权范围；统一提供方减少不同 WebDAV 服务的兼容性测试。三端直接调用相同 API，也避免桌面文件同步与 Android API 混用造成不同同步时序。[微软 AppFolder](https://learn.microsoft.com/graph/onedrive-sharepoint-appfolder)

WebDAV 的优势是提供方可替换、自建 NAS 和无需 Microsoft 应用注册；代价是认证、目录列举、错误码、限流和原子行为需逐个服务验证。WebDAV 是协议，不意味着所有网盘都支持；MVP 不能声称兼容所有网盘。[WebDAV 标准](https://www.rfc-editor.org/info/rfc4918/)；例如坚果云官方说明存在访问频率限制：[官方说明](https://help.jianguoyun.com/?p=2064)。

E2EE 安全性由本地加密决定，OneDrive 不天然比正确配置的 WebDAV 更保密。可用性由真实网络决定，尤其不能推定国内运营商网络访问 Microsoft 的稳定程度。自建 NAS 仍需要 HTTPS、外网访问与备份维护。

### 首期选型的开工门槛

使用实际个人账号，在用户常用桌面网络及 Android 移动网络测试登录、AppFolder 建目录、列举分页、上传、下载、断网恢复和 Token 更新。只授权 Files.ReadWrite.AppFolder 加必要登录/刷新范围，不因某接口失败改成全盘权限。

官方 AppFolder 专题与部分通用上传接口权限表展示存在差异，必须验证真实 API 组合；普通 PUT 文档未明确列出 If-Match，不能依赖未证实的条件写行为。[普通上传](https://learn.microsoft.com/en-us/graph/api/driveitem-put-content?view=graph-rest-1.0)；[上传会话](https://learn.microsoft.com/en-us/graph/api/driveitem-createuploadsession?view=graph-rest-1.0)。

若 AppFolder 所需能力或真实网络不可用，改为指定的一个 WebDAV 提供方先落地，沿用同一密文与合并协议，不同时开发两个首期后端。默认决策为 OneDrive，此门槛是工程验证而非要求用户先选服务。

## 2. 技术栈

- 界面：Flutter 稳定版 + Dart，三端共享响应式 UI；状态管理使用 Riverpod。
- 核心：Rust stable workspace，负责加密、序列化、条目/历史模型、版本图、搜索、持久化和同步状态机。
- 桥接：flutter_rust_bridge v2；只暴露会话句柄与必要业务方法，KEK/DEK 不返回 Dart。[Flutter 平台说明](https://docs.flutter.dev/reference/supported-platforms)；[桥接项目](https://cjycode.com/flutter_rust_bridge/)。
- 密码学依赖候选：RustCrypto argon2、aes-gcm、hkdf、sha2；系统随机源使用 getrandom；zeroize 管理可清零缓冲区。版本、特性与安全公告在 P0 锁定并提交 lockfile，不在设计阶段编造精确版本。
- 序列化：加密负载使用严格 CBOR；文件头固定二进制格式。禁止不受控多态反序列化。
- 本地：Rust rusqlite/SQLite 存储密文对象、outbox 和同步状态；无明文 SQL 表、FTS 或明文 WAL。搜索索引只在 Rust 内存。
- 网络：Rust reqwest + rustls + Tokio，Graph REST 适配器；认证使用原生 OAuth 流程/成熟库桥接，public client + 系统浏览器 + Authorization Code / PKCE。应用内不存 client_secret。[OAuth 官方文档](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow)
- Windows 原生层：C++/WinRT，锁屏/休眠通知、快捷键、剪贴板、Windows Hello 与 CNG/TPM 验证原型。
- macOS 原生层：Swift，Keychain/LocalAuthentication、锁屏/休眠事件、剪贴板与窗口控制。
- Android 原生层：Kotlin，BiometricPrompt/CryptoObject + Keystore、FLAG_SECURE、生命周期及 WorkManager；AutofillService 后续实现。
- 测试：Rust 单元/性质测试/故障注入/fuzz；Flutter widget 和 integration_test；三端原生桥接实机验收。

Flutter 减少三套 UI 工作量，Rust 让三端加密和同步逻辑保持一致。代价是 FFI 与原生桥接复杂度；不把 Rust 或跨平台框架本身等同于安全保证。核心不依赖 Flutter，便于独立测试与未来替换 UI。

## 3. 模块边界

建议目录：apps/wencrypt_flutter、crates/wencrypt-core、crates/wencrypt-storage、crates/wencrypt-sync、crates/wencrypt-ffi、test-vectors、docs。这里只定义结构，尚不创建应用脚手架。

调用链：Flutter → FFI 会话 API → Rust 核心 → 密文存储/同步适配器。原生层通过受限接口提供认证、设备密钥和系统事件。

锁定 API 必须取消进行中的敏感请求并递增会话代次；所有回调检查代次，防止锁定后旧请求重新显示密码。Rust 控制业务授权，不能只用一个 Flutter 布尔值判断是否解锁。

显示或编辑密码时不可避免会在 Dart/原生界面内存产生明文副本；最小化生命周期、不记日志、不缓存、不自动崩溃上传。不能承诺 GC 字符串被立即可靠擦除。主密码输入在传入 Rust 后尽快清空控件；密钥不经界面层往返。

## 4. 设备保护等级

系统存储保护、硬件支持与每次使用的认证绑定分别检测和报告。

- Android 优先认证绑定的硬件 Keystore 密钥，StrongBox 可用则评估启用，TEE 可接受；不支持所需组合则关闭严格快速解锁。
- macOS 采用设备本地 Keychain 项和生物识别访问控制，不启用 iCloud 同步；不能仅凭使用 Keychain 就标注 Secure Enclave。
- Windows 不采用“UserConsentVerifier 返回成功 → 无条件 DPAPI 解密”来声称硬件绑定。P0 必须证明 Windows Hello/TPM 与实际解包裹操作的联系、跨重启策略和 API 支持。失败时缩减为主密码 Alpha，不降低声明。
- 原生包裹内容绑定 vault_id、bootstrap 哈希和设备身份；换库/密钥失效不得复用旧缓存。

设备解锁材料与同步 Token 分开存储：Token 可后台访问密文；获取 DEK 必须满足解锁策略。

## 5. 本地可靠性

每次保存先在内存生成不可变密文对象，然后在同一个 SQLite 事务中写对象和 outbox；持久提交成功才显示“已保存”。崩溃后重试原始字节，不重新生成版本。

SQLite 开启适当的强持久化模式；单库单写者，多个窗口或后台进程通过同一存储协调。WAL 和临时表只允许存密文及最少同步元数据。磁盘满则保存失败且保留编辑内容，不能出现成功提示。

远端数据先放隔离缓存。完成大小、哈希、AEAD、结构和版本图验证后才进入可信对象集合；认证失败不清空本地库。

## 6. 开发与发布

需要 Windows 原生构建环境、macOS/Xcode 和 Android SDK/NDK；当前 Mac 工作区不能替代 Windows 实机验收。依赖锁定、许可证清单、秘密扫描、三端构建验证是发布流程组成部分。

公开发布前配置 Windows 签名、macOS 签名/公证、Android 稳定签名与更新密钥备份。MVP 手动安装更新；自更新延期，未来必须验证签名和防降级。

明确不建设 Wencrypt 云服务、不上传遥测、日志中的网址/账户/Token/明文一律禁止。允许用户主动导出经过脱敏的诊断信息。

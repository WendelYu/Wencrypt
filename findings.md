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

当前坚果云Alpha失败用户仅看到“操作未完成”，尚无阶段信息。现实现首次GET只允1KiB错误响应，且MKCOL成功/PUT失败后再次MKCOL会遇405而无法恢复；PROPFIND未检查DAV命名空间和propstat状态。需修正并以真实阶段诊断确认根因，不能把推断当实测结果。

2026-11-18：用户截图确认 Chrome 内部 URL 未能由 macOS 打开，坚果云的引导文件 GET 实际返回 409。409 的具体服务端原因未知，兼容路径在认证成功后通过建目录结果或目录内容判断能否初始化。Mac 用 AppKit 启动应用并让用户在浏览器地址栏打开设置。

2026-11-18：微软明确支持受支持浏览器迁移，桌面 Edge 官方密码导出为用户确认的 CSV。微软支持的扩展 API 列表未提供批量读取 Edge 已保存密码的授权接口。Windows 应用绑定加密和 macOS 钥匙串保护限制直接读取。Apple 的凭据交换由支持的来源 App 发起，查到的 Edge 桌面文档只确认 CSV 路径。见 https://support.microsoft.com/en-us/edge/export-passwords-in-microsoft-edge 和 https://learn.microsoft.com/en-us/microsoft-edge/extensions/developer-guide/api-support 。

2026-11-18：macOS 目前只能用原生桥接启动浏览器，内部地址由用户粘贴；现有 CI 产生三端 Actions 产物。Apple 将未经验证提示与「已损坏」区分处理，前者可经系统设置针对单个 App 确认，后者应先检查包完整性。来源 https://support.apple.com/zh-cn/102445 。

2026-11-18：本版通过系统桌面服务尝试直达浏览器设置，Chrome 和 Edge 在必要时可经系统授权创建设置标签页。首次建库会生成随机库 ID 和数据密钥，其他端要从同一份加密备份加入并使用相同的坚果云主同步目录。当前同步检查本地与远端的修订并集，达到 598 项即停止。

2026-11-18：坚果云单次 WebDAV 枚举最多 750 项，免费账户每 30 分钟 600 次请求。全量平铺枚举存在截断风险，逐对象传输也难在应用配额内高效完成。新版采用固定分桶的不可变密文包，读取原目录但不删除旧文件。参考 https://help.jianguoyun.com/?p=2064 。

2026-11-18：搜索框原先每次输入都重建筛选列表，分组框每次输入都重建编辑对话框，未区别中文组合文本。坚果云的「仅同步本次」会跳过加密保存，目录设置也会显示已保存密码的输入框。回收站目前只公开恢复操作，清除需要维持不可变修订的同步兼容性。

2026-11-18：同步进度之前只写界面状态，失败诊断只保留最后一次。新版按目录与尝试本地加密留存，记录每个已提交批次，锁定或退出后的未完成尝试仍可见。Apple 侧栏与工具栏用于稳定导航，Linear 强调主内容的视觉优先级，Raycast 的可搜索命令与键盘选择有助于减少操作步骤。

2026-11-18：浏览器导入每次重新创建监听器，过去仅从默认目录开始。新版持久保存手动添加的目录，沙盒 macOS 应用通过系统安全作用域书签恢复访问。主密码更新沿用库标识和数据密钥，云端条件写依赖坚果云对强 ETag 和 If-Match 的支持，模拟 WebDAV 已验证这一路径及竞争失败处理。

2026-11-19：WebDAV 凭据由当前库的数据密钥加密。已解锁时可同步检测密码更新，并认证保存新版密钥封装供锁屏使用；从未检测到更新的锁定设备需要先解锁，才能访问云端。

2026-11-19：用户实测本机密码已改但坚果云 GET 响应未提供可用的强 ETag，旧版在 update_bootstrap 停止。0.3.5 使用同步目录内 MKCOL 独占更新，通过复读核对已知旧字节，有强 ETag 时仍使用条件写入。

2026-11-19：0.3.5 首次加入提交前关闭表单，后台切换触发通用锁定并弹出路由，底层安装错误会回退为「操作未完成」。本机脱敏诊断只记录到较早的改密失败，无法确定用户本次加入失败的具体阶段。0.3.6 保持首次加入表单，并在完成云端读取和本机验证后才安装并进入库。

2026-11-19：Windows 测试截图显示错误发生在本机保存。SQLite 临时库提交后以只读句柄调用 Rust sync_all，Windows 使用的 FlushFileBuffers 要求 GENERIC_WRITE。改用可写临时文件句柄，沿用原先不覆盖本机已有库的安装步骤，Windows CI 新增原生建库与加入测试。参考 https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-flushfilebuffers 。

2026-11-19：Android 11 隔离模拟器用调试应用身份执行 build 14 的 Rust 库，确认建库返回 install_permission_denied，SELinux 审计确认拒绝 app_data_file 硬链接。修改为 renameat2 的 RENAME_NOREPLACE 原子安装，应用私有目录的独立探针已验证写入及 EEXIST 保留原文件。Android 10 AOSP 共用允许列表包含 renameat2 syscall，Bionic 封装从 API 30 才导出，因此保留内核调用方式，最低 SDK 仍为 29。

2026-11-20：Windows 路径来自 path_provider_windows 的 RoamingAppData 和 exe 资源中的 CompanyName 与 ProductName，实际常规位置为 `%APPDATA%\org.wencrypt\wencrypt\wencrypt-alpha.db`。图片旧实现只写自定义 PNG，Win32 可通过 CF_DIB/CF_DIBV5 合成其他位图格式。Windows 字体调整优先使用 Microsoft YaHei UI，相关字体及剪贴板格式参见 https://learn.microsoft.com/windows/apps/design/signature-experiences/typography 与 https://learn.microsoft.com/windows/win32/dataxchg/clipboard-formats 。

2026-11-20：三端文字导出使用现有复制入口，Android 通过原生通道设置系统剪贴板，macOS 和 Windows 使用 Flutter 的桌面剪贴板。默认只包含有值的账号名称、用户名及网址，勾选后才加入密码。图片继续采用桌面剪贴板和 Android 相册。

2026-11-20：现有同步已验证库身份，按哈希并集传输不可变密文包，真正的流量开销包括空闲时仍按 15 分钟列举目录。坚果云公开文档列出访问限制，但未确认其支持 RFC 6578 的集合变更令牌。继续沿用精确目录检查，增加只检查元数据的提醒模式与空闲退避，避免依赖根目录 ETag 或单个可变标记。

2026-11-20：通过 apksigner 实际比较正式 v0.3.5 和 v0.3.6 的 Android 证书，两份 APK 都通过各自的签名验证，但证书不同。已安装的 0.3.5 需要验证备份或云端可恢复后，才能卸载并安装 0.3.6。

2026-11-20：WENBACK1-alpha 导出加密引导和对象修订，不包含本机 WebDAV 设置和指纹授权。Android 固定签名使用相同 applicationId 和递增构建号。公开证书指纹作为 Actions 变量，PKCS#12 及密码保存在 Secrets，发布任务签名后先验证证书再上传。

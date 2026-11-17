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

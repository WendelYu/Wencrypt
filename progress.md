# 工作进度

2026-11-17：读取规划技能，检查空项目目录，开始方案设计。尚未编写应用代码或做真实设备验证。

已创建 README 和五份设计文档：需求、架构、加密格式、同步协议、22 项 MVP 任务。确定 OneDrive Graph 首期、Flutter/Rust、不可变修订 DAG；明确 Windows 强绑定未验证和主密码迁移限制。下一步检查文档一致性和链接。

完成：检查所有本地 Markdown 链接和代码围栏；22 个任务编号连续且唯一；用结构长度计算验证公共头部75字节、bootstrap头部87字节、完整bootstrap135字节。复核并修正自动备份与手动导出认证区别、主密码恢复范围，补充隔离缓存限额和小文件同步成本。此次验证仅为设计文档检查，未执行应用、密码学实现或真实网络/设备测试。

## P0 实施

- Rust workspace、WENC framing/AEAD/KDF 原型、DAG 小模型和命令行基准已运行；6 个单元测试和1个 Python 独立参考向量集通过。
- 本机 release Argon2id 64MiB/t3/p1：创建134ms、解锁112ms（一次样本，不代表Android）。
- OAuth/Graph PKCE 探针和6项测试通过；真实账号尚未登录，用户没有 Client ID，已提供注册手册。
- 用户可提供当前 Mac、Android、Windows 实机；完整 Xcode 尚未安装。
- macOS Secure Enclave/生物识别原型通过 Swift typecheck（存在待清理警告）；Android CryptoObject 和 Windows TPM 区别验证原型已编写，尚未实机验证。
- Flutter 官方下载清单及中国镜像404，改用官方 stable Git 仓库成功，SDK版本3.50.0 / Dart3.14.0；首次初始化仍在获取标签/构建工具。

用户改为坚果云首期并要求GitHub自动打包。新增WebDAV安全探针、5项测试（总11项通过）、后端约束覆盖文档和三端Actions开发产物工作流；真实账号和远程CI未验证。此前设备密钥创建重试因自动审批服务用量限制未执行，不能绕过；该限制不是安全判定。

坚果云实测返回HTTP400（旧输出缺阶段，根因尚未确认）。修正MKCOL空请求显式Content-Length:0，移除空请求不必要Content-Type；增加Depth:0根属性认证预检及脱敏stage/method/http_status诊断。新增3项回归测试，总14项通过。需要用户重新运行，不将兼容性修正当作已验证根因。

用户再次验证：authenticate_root通过，create_directory/MKCOL返回400 text/xml。怀疑原43字符顶层名称触发坚果云sandbox名称限制（Agentero项目官方适配文档记录此限制，非坚果云具体长度保证）。缩短为20字符随机名称，碰撞时仍失败不覆盖；新增限8KiB的XML错误白名单分类，不输出服务端原文。16项测试通过，远端修复待重试确认。前次Content-Length假设未解决此次实测错误。

用户确认真实坚果云基础 WebDAV 探针通过。已接入三端设备探针与 Rust P0 FFI，并让打包脚本将 Rust 动态库放入三个产物。核对免费版月额度和请求频率，补充预算策略及 Rust 账本原型。用户提供了空 GitHub 仓库，初始化了本地 Git。本机 GitHub CLI 凭据失效，等待重新登录。

Mac v2 实现已编译。沙箱内 SecureEnclave.isAvailable=false，需授权沙箱外硬件测试。首次创建遇到 Foundation atomic 与 withoutOverwriting 不兼容，改为排他创建，保留损坏文件拒绝解包和显式重置策略。

2026-11-17 Secure Enclave v2：替换旧Keychain永久条目创建，使用本地硬件块+ECDH/HKDF/AES-GCM。修正rawRepresentation的64字节公钥长度检查。创建成功，新进程禁止交互返回LA -1004且locked。两项自动测试覆盖缺失/损坏/超长数据与幂等重置通过；已请求用户按指纹，进程等待认证。Flutter源码引用同一DeviceProbe，无需改桥接。

用户确认已按指纹，独立重开进程返回0，authenticated_unwrap_passed / authenticationBound=true / unlocked=true。已再次发起认证并要求用户点击取消，待读取结果。
用户点击取消后读取结果：LocalAuthentication -2，退出码1，not_passed，unlocked=false。两轮独立进程实测完成，没有认证结果复用。待Flutter沙箱包验收和正式密码库接入。

三端 Alpha：Rust SQLite/WENC 会话、CBOR修订、事务保存、历史、因果冲突、备份/恢复和密文导入实现。重启/错误密码/明文扫描、双端离线冲突与合并测试通过。Flutter主流程与手动坚果云同步已接入。单机预算100MiB上传/300MiB下载、80请求/30分钟，最多三台安装可低于已知免费额度；其他软件流量仍需用户账户侧监控。远端目录上限598修订，未实现后台同步和正式生物识别DEK绑定。

62cfd30已推送，Actions 44040800579产出Windows/macOS/Android三端Alpha。新增会话epoch拒绝过期解锁，Rust4项vault测试通过，Flutter分析无问题。正在下载Mac首轮包实测，再推送epoch补丁生成最终包。

最终dbb9942的Actions 44093230639四个job全部success。Mac首轮62cfd30产物摘要与GitHub一致、codesign严格验证通过；CUA实测创建公开测试库、保存编辑账号、退出重开后主密码解锁且账号保留。测试主密码为公开fixture `Wencrypt Alpha public test 2026!`，仅本机测试数据。中文粘贴存在自动化AX文本与Flutter提交时机不一致，未计为通过，保留真实输入法验收。

2026-11-18：交付 0.2 Alpha d3ac1a5。Rust 绑定与还原真实库、独立进程 Touch ID 三轮及双库 WebDAV 模拟收发已验证。自动同步限定前台解锁，保留月度与滚动请求预算。浏览器来源识别、记录勾选及重复排除已加入。三端 CI 通过，实机范围见 reports/p0-status.md。

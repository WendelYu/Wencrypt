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

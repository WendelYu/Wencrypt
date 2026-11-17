> 0.1 Alpha 已开始实施。可用流程、免费坚果云预算与未完成验收见 [Alpha 使用说明](docs/08-alpha-guide.md)。

# Wencrypt

> 2026-11-17 更新：首期后端已改为坚果云 WebDAV。此前 OneDrive 首期说明由 [后端变更与构建说明](docs/07-jianguoyun-and-github.md) 覆盖；OneDrive 验证暂停。
本地离线优先、自有网盘同步的个人密码管理器。

当前阶段：P0 工程和验证。见 [实测记录](reports/p0-status.md) 与 [三端打包脚本](tools/package_p0.py)。

## 已确定的方向

- Windows / macOS / Android：Flutter + Dart 界面，Rust 共享核心，原生安全桥接。
- 首期同步：坚果云 WebDAV 免费版。
- 加密：Argon2id + 随机 256 位 DEK + HKDF-SHA-256 对象子密钥 + AES-256-GCM。
- 同步：不可变密文修订集合；基于父版本识别并发，不按设备时间覆盖。
- MVP：单用户、单活动库、离线增删改查、历史、OneDrive 同步、冲突处理、备份恢复与三端保护。

## 文档导航

1. [产品需求](docs/01-product-requirements.md)
2. [架构与同步后端选型](docs/02-architecture.md)
3. [加密格式与密钥生命周期](docs/03-crypto-format.md)
4. [同步与冲突协议](docs/04-sync-protocol.md)
5. [MVP 任务与验收标准](docs/05-mvp-backlog.md)

设计仍需经过协议评审、P0 技术验证和三端实机验证。这里的“确定”表示实施基线，不代表协议已审计或功能已实现。

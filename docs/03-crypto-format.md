# Wencrypt 加密格式 WENC v1 草案

状态：实施基线，未经独立密码学评审。P0/P1 完成测试向量和协议评审前，不应冻结为对外稳定格式。算法使用成熟实现，不自行编写密码学原语。

## 1. 密钥层次

1. OS CSPRNG 生成 16 字节 vault_id（UUIDv4 编码）、32 字节 DEK。
2. 主密码按原样 UTF-8 编码，禁止 trim 和 Unicode 归一化，最大 1,024 字节。创建时建议至少 16 字符或 6 个随机词；少于 12 个 Unicode 标量的密码不接受。
3. Argon2id v0x13，从主密码和 32 字节随机盐派生 32 字节 KEK。默认 m=65,536 KiB、t=3、p=1；这是工程初始参数，不声称等于 RFC 推荐配置，需低端 Android 实测。[RFC 9106](https://www.rfc-editor.org/rfc/rfc9106.html)
4. bootstrap 使用 KEK + AES-256-GCM 包裹 DEK；验证成功后立即清理 KEK 和主密码缓冲区。
5. 每个修订对象生成独立 32 字节 object_salt，以 HKDF-SHA-256(DEK, salt=object_salt, info=ASCII("wencrypt/v1/object/") || kind_u8 || vault_id) 派生 32 字节对象密钥，再用 AES-256-GCM 加密负载。
6. 每次新的加密操作都生成新的 12 字节 Nonce，GCM Tag 固定 16 字节，不截短。对象盐和 Nonce 均使用 OS CSPRNG；随机源失败即失败，不退回时间戳/普通随机。

DEK 是库根数据密钥，对象子密钥降低跨设备长期复用单个 GCM 密钥的风险；仍须审查随机源和密钥域分离。重试上传复用已落盘密文字节，不进行一次“相同对象的重新加密”。

## 2. WENC 二进制封装

所有整数使用无符号小端；无隐式对齐或填充。版本 1 固定算法套件，不接受算法协商/降级。

公共头部依次为：

1. magic：8 字节 ASCII `WENCRYPT`。
2. format_version：u16，值 1。
3. kind：u8，1=bootstrap，2=revision，3=backup_payload。
4. vault_id：16 字节 UUID 的固定网络字节顺序，与整数端序规则分开。
5. salt：32 字节；bootstrap 是 Argon2 盐，其他种类是 HKDF 对象盐。
6. nonce：12 字节。
7. cipher_len：u32，包含 16 字节 Tag，不含头部。

公共头部长度 75 字节。kind=1 时再追加 m_kib:u32、iterations:u32、parallelism:u32，bootstrap 头部为 87 字节。其余 kind 不允许 KDF 参数扩展。

AAD = 文件实际头部全部字节，不重新序列化。正文为 cipher_len 字节的 `ciphertext || tag`，末尾不得有额外数据。

bootstrap 明文恰为 32 字节 DEK，因此 cipher_len=48，文件总长=135 字节。vault_id 和 KDF 参数都被 Tag 认证。错误密码与认证失败统一返回“密码错误或文件无法验证”，避免伪造精确原因。

revision 明文为 CBOR，单对象文件上限 1 MiB；backup_payload 上限 256 MiB，需要先做长度检查再分配。bootstrap 解密前校验 KDF 资源上限：m 为 65,536～262,144 KiB，t=3～10，p=1～4；不支持的值拒绝并解释，不自动降参。每次仅执行一个 KDF 作业，防止并行内存耗尽。

上述限制是 v1 兼容边界。以后超出参数/容量范围须显式格式或能力升级，不让旧客户端静默损坏数据。

## 3. 修订明文

CBOR 采用 RFC 8949 length-first deterministic encoding（长度优先排序 map 键）、文本键和最短整数编码；UUID 使用固定16字节 bstr，而非带连字符字符串。禁止重复键、无限长度项、不合法 UTF-8、浮点数和未定义扩展。解码前后限制最大深度 16、字段个数、字符串长度、parents 数量（≤1,024）；未知 schema_version 拒绝处理，不覆盖旧对象。时间用有符号 Unix 毫秒整数，仅展示。可读结构定义位于 test-vectors/revision.cddl；语义限制需要额外代码实现。

revision schema_version=1 包含：

- revision_id：随机 UUIDv4，稳定用于幂等与父版本引用。
- entry_id：随机 UUIDv4，条目身份。
- parents：该条目直接父修订 UUID 集合，排序编码，不重复。
- device_id：本次安装生成的随机 UUID，只用于来源提示，不代表可信签名身份。
- updated_at：本地墙钟时间，不参与胜负选择。
- is_deleted：布尔墓碑。
- entry：完整条目快照；删除版本为 null，历史仍保留祖先条目。
- action：create/update/delete/resolve/restore/import。

entry 包含 title、username、password、urls、notes、tags、custom_fields。tags 为排序去重的标签文本集合，custom_fields 含稳定 UUID、label、value、sensitive。单文本字段上限 64 KiB，条目总 CBOR 上限受 1 MiB 对象约束。title 可为空但 UI 显示“未命名”；不得把 UI 占位值写成用户数据。

所有业务字段、父版本、设备信息、墓碑均在密文内。对象文件名为 SHA-256(整个 WENC 文件) 的小写 64 字符 hex 加 `.wenc`。哈希用于定位、传输校验与去重，不替代 GCM 认证。

## 4. bootstrap 与信任

远端布局中 bootstrap.wenc 创建一次后不可修改；本地首次成功主密码解锁后固定其 SHA-256 与 vault_id。后续变更视为异常，保留原副本，进入显式恢复流程。

新设备从同一账号指定库读取 bootstrap，以主密码验证，再建立本地固定值。不能仅凭网盘登录成功信任库内容。v1 无设备签名和成员权限，所有持有 DEK 的设备都具有写入权限；device_id 仅提示，不能作为防伪证明。

## 5. 备份格式 WENBACK1

备份 .wencrypt 是自包含容器，依次包含：ASCII `WENBACK1`（8 字节）、bootstrap_len:u32（v1 必须135）、原 bootstrap 字节、payload_len:u32、一个 kind=3 的 WENC 文件。禁止尾随数据，总长度上限 256 MiB + 1 KiB。

kind=3 用同一 DEK 派生独立对象密钥，其 CBOR 明文包含 backup_schema=1、bootstrap_sha256、snapshot_created_at、objects 数组（每项为 hash 与完整 kind=2 文件字节）、expected_object_count。备份对象集合在本地一致性快照事务下确定。

每次备份使用新盐和 Nonce。外层加密认证对象集合，内部每个对象再次校验哈希、Tag、vault_id 和版本图。导入不接受文件路径，不解压 ZIP，不写任意路径；不包含 Token 或设备解锁材料。

手动导出前重新输入主密码解开 bootstrap，并与当前 DEK 一致性校验；自动本地备份使用当前已解锁 DEK，不弹出日常密码输入。写临时文件、可靠落盘后原子替换，再完整试读。密文备份仍需要原主密码。备份超过上限时显式失败，不能截断历史。

若存在 pending/隔离对象，导出时明确告知“远端数据尚未完整验证”；可信快照不宣称覆盖这些对象，原隔离缓存不得因备份成功而删除。普通未上传但已验证的本地修订必须包含在快照中。

## 6. 主密码、恢复和撤销

v1 bootstrap 不原地改写，主密码更换通过新 vault_id、新 DEK、新 bootstrap 的完整迁移实现：

1. 处理当前设备 outbox 并检查远端；要求用户检查其他离线设备，不能声称知道所有设备已同步。
2. 导出并验证旧库备份；在新库重新加密完整可信历史和墓碑，保留 entry_id/revision_id，改变 vault_id 与对象封装。
3. 上传新库并逐项核对；新库可离线打开、备份可恢复后，切换活动库。
4. 旧库在本设备标为归档只读，其他设备重新关联新库并清除旧设备解锁缓存。旧设备后来的修改通过显式迁移导入处理，不自动跨库合并。
5. 删除旧云端副本是另一步用户操作；不保证云端版本历史/备份中的旧主密码副本消失。旧密码泄漏时应考虑账号密码本身的轮换。

简单重包裹 DEK 不能撤销持有旧 DEK 的设备，故不作为失窃设备处理方案。v1 没有远程擦除或设备成员协议；撤销需更换网盘授权/访问凭据并迁移新库，不能撤回已经泄漏的明文。

## 7. 必须验证的安全性质

- 三端通过相同测试向量：正确解密、错误密码、AAD 任一字段修改、Tag 修改、截断、附加字节均符合预期。
- 系统随机源错误导致保存失败；盐和 Nonce 每次新加密刷新；相同操作重传保持字节一致。
- 先验边界检查防止巨大长度、恶意 Argon2 参数、递归 CBOR 和异常父图耗尽资源。
- 密文无法验证时不释放未认证明文、不覆盖本地有效对象。
- 锁定清理密钥/索引、取消敏感回调，日志/磁盘/WAL/崩溃报告无业务明文。
- GCM 不能独立识别有效旧数据回滚；本地记住的对象集合可提示远端缺失，但全新设备无法证明云端给出的集合完整。独立备份承担恢复职责。

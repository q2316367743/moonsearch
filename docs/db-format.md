# MSDB v3.2 数据库格式

`moonsearch` 的持久化文件把一次扫描的全部派生结构写进单个文件：条目、名字池、物理
规范 id、合并规范顺序、字段字典、范围索引与 trigram posting。加载后查询直接使用这些
结构，不重新扫描、不重建字典、不重排 trigram。

- 文件扩展名：`.msdb`
- 默认路径：`$XDG_DATA_HOME/moonsearch/index.msdb`，否则
  `$HOME/.local/share/moonsearch/index.msdb`
- 字节序：全部小端；读取器逐字段组合，不依赖宿主对齐
- 版本：主版本 `3`，次版本 `2`；拒绝只允许合法 UTF-8 根路径的 v2
- 实现：`src/index/db_format.mbt`（容器）、`db_write.mbt`（编码）、`db_read.mbt`
  （解码与校验）、`db.mbt`（文件读取与大小限制）、`src/ids/codec.mbt`（Ids 资源边界）

## 1. Header（64 字节）

| 偏移 | 大小 | 字段 | 说明 |
| --- | --- | --- | --- |
| 0 | 4 | magic | ASCII `MSDB` |
| 4 | 2 | version_major | `3`；不匹配直接拒绝 |
| 6 | 2 | version_minor | `2`；更高的次版本允许加载 |
| 8 | 1 | endian | `1` = little-endian |
| 9 | 3 | reserved | 必须写 0，读取时忽略 |
| 12 | 4 | flags | bit0 = 存在 POSTINGS |
| 16 | 8 | built_at | 构建时的 Unix 秒 |
| 24 | 4 | folder_count | 文件夹条目数 |
| 28 | 4 | file_count | 文件条目数 |
| 32 | 4 | root_count | 根记录数 |
| 36 | 4 | exclude_count | EXCLUDES 中的规则数 |
| 40 | 4 | dict_count | DICT 键数 |
| 44 | 4 | range_count | RANGES 字段数 |
| 48 | 4 | trigram_count | 不同 trigram 键数 |
| 52 | 8 | section_table_off | 固定为 64 |
| 60 | 4 | section_count | 含 CHECKSUM 的 section 数 |

迁移计划的字段清单保留两个额外 `reserved u32` 时会超过 64 字节；实现省略这两个
保留字，使 header 正好落在文档规定的 64 字节内，字段顺序不变。

## 2. Section table

紧跟在 header 后面，每项 20 字节：

```text
kind   u32
offset u64
length u64
```

约束：

- `offset` 必须不小于表中的上一个 section 的结束位置；section 之间不允许重叠。
- `offset + length` 必须落在文件内，且不溢出。
- `kind` 不能重复；表项数不超过 32。
- CHECKSUM 必须是最后一个 section，且其结束位置必须恰好等于 EOF；CHECKSUM 之后的
  任何字节或 section 都拒绝加载，`verify=false` 也不例外。
- 未知 `kind` 只能出现在 CHECKSUM 之前；次版本升级时跳过，不影响已知 section。
- 写入顺序固定为 ROOTS、EXCLUDES、NAMES、FOLDERS、FILES、ORDER、DICT、RANGES、
  PARENT_PATHS、POSTINGS（可选）、CHECKSUM。

`kind` 取值：

| 值 | 名称 | 内容 |
| --- | --- | --- |
| 1 | ROOTS | 根路径与扫描统计 |
| 2 | EXCLUDES | 扫描时使用的排除规则快照 |
| 3 | NAMES | 前缀压缩名字表 |
| 4 | FOLDERS | 文件夹固定记录 |
| 5 | FILES | 文件固定记录 |
| 6 | ORDER | 规范顺序 |
| 7 | DICT | 字段字典 |
| 8 | RANGES | 范围索引 |
| 9 | POSTINGS | trigram 倒排 |
| 10 | CHECKSUM | 元数据与全文件校验和 |
| 11 | PARENT_PATHS | 文件夹完整路径到规范 id 的有序表 |

## 3. ROOTS

```text
count       u32            必须等于 header.root_count
每条记录:
  path_len  u32            原始路径字节数
  path      bytes          绝对路径，不要求合法 UTF-8
  flags     u32            bit0 = one_file_system
  folder    u32            最终规范根文件夹 id，必须 < folder_count
  files     u32            子树文件数
  folders   u32            子树文件夹数（不含根自身）
  size      i64            子树字节数
```

路径按 Unix 原始字节保存和恢复，读取器不做 UTF-8 解码；非法 UTF-8 根路径不会折叠为
替换字符串。排除规则保存在独立的 EXCLUDES section 中；`Index` 持有规则快照，
`update` 在没有 CLI 或配置文件替换规则时复用它。

## 4. EXCLUDES

```text
count       u32            必须等于 header.exclude_count
每条记录:
  kind       u8             0=fixed 1=glob 2=regex
  scope      u8             0=full_path 1=basename
  target     u8             0=both 1=files 2=folders
  active     u8             0=disabled 1=enabled
  pattern_len u32           UTF-8 字节数
  pattern    bytes          规则文本
```

- v3.1 始终写入该 section；空规则集也写一个 `count=0` 的 4 字节 section。
- 旧 v3.0 文件可以没有 EXCLUDES，此时 `exclude_count` 必须为 0，加载为空规则集。
- tag 和 `active` 的未知值、无效 UTF-8、非法 regex、count 不匹配和 section 尾随字节都
  拒绝加载。regex 在加载时重新编译，不持久化编译后的内部表示。
- 规则按扫描配置顺序保存；`update` 的优先级为 CLI `--exclude` > 配置文件 `excludes` >
  数据库快照。CLI 或配置规则列表非空时整体替换旧快照。
- 每条 pattern 上限 1 MiB，规则总数上限 1,000,000。

## 5. NAMES

```text
count       u32            不同名字数，必须 <= folder_count + file_count
每条记录:
  prefix_len u16           与上一条名字的公共前缀字节数
  suffix_len u16           本条剩余字节数
  suffix     bytes
```

- 名字在写入前去重，并按字节字典序排序；读取时要求严格递增（`prev < current`）。
- `prefix_len <= 上一条长度`，`prefix_len + suffix_len <= 65535`。
- 读取端把名字依次追加到新的 `NamePool`，并记录返回的 `NameRef`；FOLDERS/FILES
  记录里的 `name_index` 是这张表的序号，而不是池内字节偏移。这样去重后的名字只存
  一次，加载时一次性重建池。
- 名字总字节数上限 1 GiB，单条上限 65535 字节。

## 6. FOLDERS

`folder_count` 条固定 34 字节记录，无 section 内计数（数量来自 header）：

```text
parent       u32   0xFFFFFFFF = 根，否则必须 < folder_count
name_index   u32   必须 < NAMES.count
flags        u16   ENTRY_FLAG_* 位
size         i64   文件系统字节数；文件夹为子树总和
mtime        i64   Unix 秒
num_files    u32   直接子文件数
num_folders  u32   直接子文件夹数
```

新写入的记录按数组下标物理满足 `(name, path)` 自然序。构建时先使用临时插入 id，
排序后建立 `old_id -> new_id`，所有 `parent` 与 ROOTS.folder 都已回填到最终 id 空间。
同路径重复项使用所属根、父路径与条目字段做确定性 tie-break，因此嵌套根和乱序扫描得
到相同字节。加载后必须通过父链环检测：任何父链都必须在有限步内到达根，否则拒绝整个
文件。这样 `Store::folder_path` 的向上遍历不会因损坏输入而死循环。

## 7. FILES

`file_count` 条固定 26 字节记录：

```text
parent       u32   必须 < folder_count；0xFFFFFFFF 非法
name_index   u32   必须 < NAMES.count
flags        u16
size         i64
mtime        i64
```

文件数组同样按 `(name, path)` 自然序物理排列，`parent` 使用回填后的规范文件夹 id。
Dict、Ranges 与 POSTINGS 都在重排完成后构建，因此其中的全局 id 不需要加载时转换。

## 8. ORDER

`folder_count + file_count` 个 `u32`，按构建时的跨类型规范顺序（`(name, path)` 自然序）
存放全局 id。FOLDERS 与 FILES 各自已经规范排序，ORDER 是两者的线性归并结果，不再承担
数组内部重排：

```text
GlobalId = folder id                        0 .. folder_count - 1
         = folder_count + file id           folder_count .. total - 1
```

读取端要求它是 `0 .. total-1` 的排列：每个 id 在范围内且不重复。相邻条目还必须满足
`(name, path)` 单调：名字相同（自然序）时才比较完整路径；完全同键时文件夹在前。加载后
直接作为 `Store` 的 `order`，不重新排序；顺序损坏时拒绝整个文件。二进制布局未变，因此
版本仍为 v3.0；旧 v3 文件可通过 ORDER 保持查询顺序，新写入文件同时保证条目数组的物理
规范顺序。

## 9. DICT

```text
key_count   u32            必须等于 header.dict_count
每个键:
  kind        u8
  payload_len u16
  payload     bytes
  ids_len     u32          Ids 编码字节数
  ids         bytes        `Ids::to_bytes` 的完整输出
```

键种类：

| kind | 名称 | payload | 集合 |
| --- | --- | --- | --- |
| 0 | Extension | 扩展名原始字节，可空 | 该扩展名的文件 |
| 1 | All | 空 | 全部条目 |
| 2 | Files | 空 | 全部文件 |
| 3 | Folders | 空 | 全部文件夹 |
| 4 | Hidden | 空 | 名字以 `.` 开头 |
| 5 | Visible | 空 | 其余条目 |
| 6 | Category | 1 字节分类下标 | 内置分类的扩展名并集 |
| 7 | Root | 4 字节根下标 | 该根及其整棵子树 |

`ids` 使用 `src/ids/codec.mbt` 的 `IdsRef` 编码（bitmap 容器流或 delta-varint 排序
id）。写入顺序固定：五个基本键、按字节序的扩展名、按 `TypeCategory::all` 下标的分类、
按根下标的根集合，因此同一索引的字节完全确定。

读取端校验：

- 五个基本键必须各出现一次；分类下标覆盖全部内置分类；根下标覆盖全部根。
- 扩展名严格递增；分类/根下标不重复。
- Ids 解码先检查声明基数 `<= total`、block 范围与容器数量，再分配或展开；随后只检查
  集合基数和最大 block/id，不把 bitmap 复制成排序数组来做范围验证。
- 所有 id 落在 `0 .. total-1`。
- `all` 基数等于 `total`，`files`/`folders` 基数等于对应数组长度。
- `hidden` 与 `visible` 不相交且并集等于全集。

## 10. RANGES

```text
field_count u32            必须等于 header.range_count，<= 7
每个字段:
  field     u8             1=size 2=mtime 3=depth 4=childcount 5=parent
                           6=childfilecount 7=childfoldercount
  n         u32            条目数，必须 <= total
  values    n × i64
  ids       n × u32
```

- `values[i]` / `ids[i]` 按 `(value, id)` 升序；相同值内 id 严格递增。
- 每个字段内 id 不重复且 `< total`。
- 字段标签不重复。
- v3.2 始终持久化五个核心字段 `size`、`mtime`、`depth`、`childcount`、`parent`。
  `childfilecount` / `childfoldercount` 只有在 `--fast-fields` 选择时才构建并持久化；
  未选择时编译层明确退化为 scan。
- `--fast-fields` 控制加载时立即解码哪些字段，默认 `size,mtime`。其余已持久化字段
  以自有字节切片保留，首次访问时直接解码该切片，不调用 `build_*`、不重新排序。
  五个核心字段在 `index` 时总是构建，与加载时是否立即解码无关。

## 11. PARENT_PATHS

```text
count       u32            必须等于 folder_count
每条记录:
  path_len   u32            完整路径原始字节数
  path       bytes          绝对路径，不要求合法 UTF-8
  folder_id  u32            必须 < folder_count
```

- v3.2 始终写入该 section；每个文件夹恰好出现一次，因此 `count == folder_count`。
- 记录按 `(path, folder_id)` 升序；同一路径可对应多个 id，保留嵌套根的一对多语义。
- folder id 不重复；路径不含 NUL，单条长度不超过 `MAX_NAME_LEN`，总路径字节不超过 1 GiB。
- 加载时直接安装有序表，`parent:` 只做路径二分与父桶并集，不重新生成或排序路径。
- 旧 v3.0/v3.1 文件可没有该 section，此时仅在加载时从 Store 派生一次；新文件缺少它拒绝加载。

## 12. POSTINGS

仅当 header flags 的 bit0 置位时存在：

```text
count       u32            必须等于 header.trigram_count
short_names u32            长度 < 3 的名字数
每条:
  key       u32            24 位 trigram，高字节在前
  n         u32            posting 长度，> 0 且 <= total
  ids       n × delta-varint（首个为绝对值）
```

- key 严格递增且 <= `0xFFFFFF`。
- posting id 严格递增且 `< total`；解码时用 `Int64` 累加，超过 `Int32` 上限即拒绝。
- 每条 posting 至少一个字节；声明长度不能超过剩余字节数，避免为损坏输入预分配大数组。
- posting 数组与 DICT 的 Ids 解码共享同一次加载的资源预算。
- `--no-trigram` 写入的数据库没有 POSTINGS，flags bit0 为 0，`trigram_count` 为 0。
  加载后的 `Index::trigram()` 为 `None`，编译层把名字 term 退化为全量扫描。

## 13. CHECKSUM

```text
metadata_crc u32   覆盖 [0, section_table_end)
full_crc     u32   覆盖 [0, checksum_section.offset)
```

- 每次加载都校验 `metadata_crc`：仅覆盖 header + section table（含各 section 的偏移/长度）。
  当前 v3.2 的默认 metadata CRC **不覆盖** ROOTS、EXCLUDES 或其他 section 载荷；普通加载
  只认证元数据布局，载荷完整性必须使用 `verify=true`。
- `info --verify` 与库调用 `Index::read_database(path, verify=true)` 额外校验
  `full_crc`：覆盖 `[0, checksum_section.offset)` 的全部字节，包括已知/未知 section、gap
  与填充。8 字节 CHECKSUM trailer 自身不参与 CRC；它的两个记录值通过比较校验。
- CHECKSUM 必须位于 EOF 前最后 8 字节。附加尾部、把 CHECKSUM 放在中间或在其后追加
  section 都会在 CRC 计算前被结构校验拒绝，因此 `info --verify` 不会把未覆盖尾部报告为
  `verified`。
- 两者都是 CRC-32（IEEE，反射，多项式 `0xEDB88320`）。选择 CRC 而不是 SHA-256 是
  为了在 100 MB 级文件上把校验成本压到一次内存扫描；它足以发现截断、撕裂写与随机
  翻转，不用于对抗性完整性证明。
- 任一 CRC 不符返回 `DbError::Corrupt`，不返回部分索引。

## 14. 原子写入与锁

```text
1. Index::to_bytes 先在内存中完成序列化与校验
2. 创建父目录（递归、允许已存在）
3. 打开 <path>.lock，取独占锁（try_lock）
4. 创建并打开 <path>.tmp.<timestamp>
5. 写入全部字节，File::sync()，关闭临时文件
6. rename(tmp, path, replace=true)
7. 关闭锁文件
```

- 任一阶段失败都删除临时文件，旧数据库保持不变；随后关闭锁文件，失败不会泄漏锁。
- 读取方不加锁：POSIX rename 保证读者看到旧的完整文件或新的完整文件。并发测试交替
  替换两份不同数据库，多个读者只能读到其中一份完整内容。
- 另一个写进程持锁时返回 `DbError::Locked`，CLI 以退出码 2 报告。
- 私有写字节入口提供 write/sync/rename 三阶段故障注入；白盒测试分别写入部分字节后
  失败、sync 前失败和 rename 前失败，验证旧文件字节不变、临时文件清空且后续写仍成功。
- 临时文件名使用时间戳；同一进程的并发写仍由锁串行化。

## 15. 加载校验与资源上限

读取器是顺序、带边界检查的 `DbReader`；所有长度先验证再分配或切片，剩余长度判断使用
减法，避免 `pos + count` 溢出。文件路径先打开并检查大小，只读取已检查的字节数，再探测
一个额外字节以拒绝读取期间增长的文件。主要上限：

| 项目 | 上限 |
| --- | --- |
| header section 数 | 32 |
| 单文件字节数 | 2,147,483,647（2 GiB - 1，读取前检查） |
| 名字总字节 | 1 GiB |
| 单个名字 | 65535 字节 |
| trigram 键数 | 16,777,216 |
| POSTINGS 总条目数 | 2,147,483,647 |
| DICT 键数 | 1,000,000 |
| EXCLUDES 规则数 | 1,000,000 |
| 单条 exclude pattern | 1 MiB |
| 范围字段数 | 7 |
| PARENT_PATHS 记录数 | `<= folder_count`，v3.2 必须等于 |
| PARENT_PATHS 总路径字节 | 1 GiB |
| 条目总数 | 16,777,216 |
| 根记录数 | `<= folder_count` |
| 单个 Ids 基数 | `<= total`（空库也必须为 0） |
| bitmap block 数 / 最大 block | 32,768 / 32,767 |
| array container 长度 | 65,536 |
| bits container 字数 | 1,024 |
| 每次加载 Ids + POSTINGS 操作预算 | 100,000,000 |
| 每次加载 Ids + POSTINGS 估算内存预算 | 512 MiB |

`IdsDecodeBudget` 的操作单位覆盖解码值、扫描的 bitmap 字与 container 槽，内存单位是
解码分配的保守估算，不是进程 RSS。一次数据库加载创建一个预算并共享给全部 DICT Ids 与
POSTINGS，多个单独合法的集合不能绕过总上限。调用方可通过
`Index::read_database(..., budget=Some(...))`、`Index::from_bytes(..., budget=Some(...))`
或 `Ids::from_bytes_with_budget` 提供更严格的预算；预算耗尽返回 `DbError::TooLarge` /
`IdsError::LimitExceeded`。

普通加载（`verify=false`）只执行结构、引用和资源边界校验，不重算派生索引。
`verify=true` 在 full CRC 之后从恢复的 Store 重新构建并逐项比较：

- files/folders/hidden/visible 集合与条目类型、hidden flags 一致；
- 每个 extension、category、root 集合与名字及父链一致；
- 每个已持久化 RANGES 字段的覆盖范围、值和 id 与 Store 一致；`verify=true` 会立即解码全部字段；
- PARENT_PATHS 的每条路径和 folder id 与 Store 的完整文件夹路径一致；
- POSTINGS 的每个 key、短名计数和 posting id 集合与名字中的 ASCII-fold trigram 完全一致；
- ROOTS.path 与根文件夹重建路径一致。

因此，重算 CHECKSUM 后构造的“结构合法但语义错误”数据库会被 `verify=true` 拒绝。
`DbInfo::from_bytes` 和 CLI `info` 默认仍只读元数据；加 `--verify` 时会完整解码并执行
上述语义校验，成本高于普通 `info`。

任一失败路径返回 `DbError`（`Truncated` / `Corrupt` / `UnsupportedVersion` / `Io` /
`TooLarge`），不会 `panic`。测试覆盖每个截断长度、每个单字节翻转（`verify=true`）、
CHECKSUM 顺序与 EOF、未知 section、恶意 header/Ids 长度、共享预算、稀疏超大文件、
随机垃圾输入、重算 CRC 后的 Dict/RANGES/POSTINGS 语义篡改，以及固定长度与 CRC-32
组成的确定性 golden fingerprint。

## 16. 版本演进

- **主版本**：section 语义不兼容时递增；读取器拒绝其他主版本。v3 将 ROOTS
  从“必须合法 UTF-8”改为“Unix 原始字节”，因此拒绝 v2，避免旧读取器误拒新库或折叠路径。
- **次版本**：只增加 section 或字段时递增；读取器跳过未知 section，按已知字段加载。
- S05 规范 id 重排改变新写入记录的排列与 id 赋值，但不改变 section 布局；ORDER 仍可
  恢复旧 v3 文件的查询顺序，因此保持 v3.0。
- S07 只加强读取器校验、EOF/CHECKSUM 顺序约束和资源预算，不改变二进制布局或 CRC 覆盖
  范围，因此仍保持 v3.0；文档明确了 metadata CRC 的现有边界。
- S08 新增 EXCLUDES section 并启用 header.exclude_count，次版本升为 v3.1；旧 v3.0
  没有该 section 时按空规则集加载。读取器新增 `verify=true` 的 Store 派生语义校验，写路径
  增加故障注入与并发替换测试，但 CRC 覆盖范围和原子替换布局不变。
- S09 新增 PARENT_PATHS section，RANGES 增加两个可选 child-count 标签，并要求五个核心
  范围字段完整持久化，次版本升为 v3.2。`--fast-fields` 改为控制加载时立即解码的字段；
  未立即解码的字段从自有 DB 切片恢复，不再从 Store 重建。旧 v3.1 文件仍可加载，缺失的
  PARENT_PATHS 仅在加载时派生一次。
- 每次格式变更必须同步更新本文件与 `src/index/db_test.mbt` 的布局断言。

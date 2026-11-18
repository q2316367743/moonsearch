# MSDB v2 数据库格式

`moonsearch` 的持久化文件把一次扫描的全部派生结构写进单个文件：条目、名字池、规范
顺序、字段字典、范围索引与 trigram posting。加载后查询直接使用这些结构，不重新扫描、
不重建字典、不重排 trigram。

- 文件扩展名：`.msdb`
- 默认路径：`$XDG_DATA_HOME/moonsearch/index.msdb`，否则
  `$HOME/.local/share/moonsearch/index.msdb`
- 字节序：全部小端；读取器逐字段组合，不依赖宿主对齐
- 版本：主版本 `2`，次版本 `0`
- 实现：`src/index/db_format.mbt`（容器）、`db_write.mbt`（编码）、`db_read.mbt`
  （解码与校验）

## 1. Header（64 字节）

| 偏移 | 大小 | 字段 | 说明 |
| --- | --- | --- | --- |
| 0 | 4 | magic | ASCII `MSDB` |
| 4 | 2 | version_major | `2`；不匹配直接拒绝 |
| 6 | 2 | version_minor | `0`；更高的次版本允许加载 |
| 8 | 1 | endian | `1` = little-endian |
| 9 | 3 | reserved | 必须写 0，读取时忽略 |
| 12 | 4 | flags | bit0 = 存在 POSTINGS |
| 16 | 8 | built_at | 构建时的 Unix 秒 |
| 24 | 4 | folder_count | 文件夹条目数 |
| 28 | 4 | file_count | 文件条目数 |
| 32 | 4 | root_count | 根记录数 |
| 36 | 4 | exclude_count | 保留；当前恒为 0 |
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
- 未知 `kind` 在次版本升级时跳过，不影响已知 section。
- 写入顺序固定为 ROOTS、NAMES、FOLDERS、FILES、ORDER、DICT、RANGES、
  POSTINGS（可选）、CHECKSUM。

`kind` 取值：

| 值 | 名称 | 内容 |
| --- | --- | --- |
| 1 | ROOTS | 根路径与扫描统计 |
| 2 | EXCLUDES | 保留；当前不写入 |
| 3 | NAMES | 前缀压缩名字表 |
| 4 | FOLDERS | 文件夹固定记录 |
| 5 | FILES | 文件固定记录 |
| 6 | ORDER | 规范顺序 |
| 7 | DICT | 字段字典 |
| 8 | RANGES | 范围索引 |
| 9 | POSTINGS | trigram 倒排 |
| 10 | CHECKSUM | 元数据与全文件校验和 |

## 3. ROOTS

```text
count       u32            必须等于 header.root_count
每条记录:
  path_len  u32            UTF-8 字节数
  path      bytes          绝对路径
  flags     u32            bit0 = one_file_system
  folder    u32            根文件夹 id，必须 < folder_count
  files     u32            子树文件数
  folders   u32            子树文件夹数（不含根自身）
  size      i64            子树字节数
```

路径必须是合法 UTF-8；解码失败按损坏文件处理。排除规则属于配置而不是索引状态，
S12 不持久化，因此 `exclude_count` 为 0 且没有 EXCLUDES section。

## 4. NAMES

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

## 5. FOLDERS

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

加载后必须通过父链环检测：任何父链都必须在有限步内到达根，否则拒绝整个文件。这样
`Store::folder_path` 的向上遍历不会因损坏输入而死循环。

## 6. FILES

`file_count` 条固定 26 字节记录：

```text
parent       u32   必须 < folder_count；0xFFFFFFFF 非法
name_index   u32   必须 < NAMES.count
flags        u16
size         i64
mtime        i64
```

## 7. ORDER

`folder_count + file_count` 个 `u32`，按构建时的规范顺序（`(name, path)` 自然序）
存放全局 id：

```text
GlobalId = folder id                        0 .. folder_count - 1
         = folder_count + file id           folder_count .. total - 1
```

读取端要求它是 `0 .. total-1` 的排列：每个 id 在范围内且不重复。相邻条目还必须满足
`(name, path)` 单调：名字相同（自然序）时才比较完整路径。加载后直接作为 `Store` 的
`order`，不重新排序；顺序损坏时拒绝整个文件。

## 8. DICT

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
- 所有 id 落在 `0 .. total-1`。
- `all` 基数等于 `total`，`files`/`folders` 基数等于对应数组长度。
- `hidden` 与 `visible` 不相交且并集等于全集。

## 9. RANGES

```text
field_count u32            必须等于 header.range_count，<= 5
每个字段:
  field     u8             1=size 2=mtime 3=depth 4=childcount 5=parent
  n         u32            条目数，必须 <= total
  values    n × i64
  ids       n × u32
```

- `values[i]` / `ids[i]` 按 `(value, id)` 升序；相同值内 id 严格递增。
- 每个字段内 id 不重复且 `< total`。
- 字段标签不重复。
- 只写已经物化的字段。未写出的字段在加载后保持惰性，第一次查询时从恢复的 `Store`
  构建，因此 `--fast-fields size,mtime` 的磁盘成本与内存成本一致。

## 10. POSTINGS

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
- `--no-trigram` 写入的数据库没有 POSTINGS，flags bit0 为 0，`trigram_count` 为 0。
  加载后的 `Index::trigram()` 为 `None`，编译层把名字 term 退化为全量扫描。

## 11. CHECKSUM

```text
metadata_crc u32   覆盖 [0, section_table_end)
full_crc     u32   覆盖 [0, checksum_section.offset)
```

- 每次加载都校验 `metadata_crc`：header + section table（含各 section 的偏移/长度）。
- `info --verify` 与库调用 `Index::read_database(path, verify=true)` 额外校验
  `full_crc`：所有 section 载荷。
- 两者都是 CRC-32（IEEE，反射，多项式 `0xEDB88320`）。选择 CRC 而不是 SHA-256 是
  为了在 100 MB 级文件上把校验成本压到一次内存扫描；它足以发现截断、撕裂写与随机
  翻转，不用于对抗性完整性证明。
- 任一 CRC 不符返回 `DbError::Corrupt`，不返回部分索引。

## 12. 原子写入与锁

```text
1. 创建父目录（递归、允许已存在）
2. 打开 <path>.lock，取独占锁（try_lock）
3. 写 <path>.tmp.<Unix 纳秒>，sync=Full
4. rename(tmp, path, replace=true)
5. 关闭锁文件
```

- 失败时删除临时文件，旧数据库保持不变。
- 读取方不加锁：POSIX rename 保证读者看到旧的完整文件或新的完整文件。
- 另一个写进程持锁时返回 `DbError::Locked`，CLI 以退出码 2 报告。
- 文件名中的 pid 由单调时间戳替代；同一进程的并发写仍由锁串行化。

## 13. 加载校验与资源上限

读取器是顺序、带边界检查的 `DbReader`；所有长度先验证再分配或切片。主要上限：

| 项目 | 上限 |
| --- | --- |
| header section 数 | 32 |
| 单文件字节数 | 2 GiB（`Bytes`/`Buffer` 的 `Int32` 长度） |
| 名字总字节 | 1 GiB |
| 单个名字 | 65535 字节 |
| trigram 键数 | 16,777,216 |
| DICT 键数 | 1,000,000 |
| 范围字段数 | 5 |
| 条目总数 | 16,777,216 |
| 条目总数（`Int32` 理论上限） | 2,147,483,647 |

任一失败路径返回 `DbError`（`Truncated` / `Corrupt` / `UnsupportedVersion` /
`Io`），不会 `panic`。测试覆盖每个截断长度、每个单字节翻转（`verify=true`）以及
随机垃圾输入。

## 14. 版本演进

- **主版本**：section 语义不兼容时递增；读取器拒绝其他主版本。
- **次版本**：只增加 section 或字段时递增；读取器跳过未知 section，按已知字段加载。
- 每次格式变更必须同步更新本文件与 `src/index/db_test.mbt` 的布局断言。

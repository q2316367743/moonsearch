# core — 条目、名字池与统一 id 空间

`src/core` 是数据模型层：条目记录、名字池、规范化顺序、退出码与版本号。它不依赖查询、
索引或位图包，只依赖 `util` 的字节工具。

## 职责

- `NamePool`：分块字节池，名字以原始 UTF-8 字节追加，`NameRef { offset, length }` 零拷贝读取。
- `Entry`：父目录、名字引用、flags、大小、mtime、直接子项计数。
- `Store`：不可变内存索引，持有名字池、文件夹数组、文件数组与唯一的规范顺序。
- `GlobalId`：把文件夹与文件映射到同一个非负整数空间。

## 文件

| 文件 | 内容 |
| --- | --- |
| `name_pool.mbt` | 分块名字池、`NameRef`、长度上限 |
| `entry.mbt` | `Entry`、`EntryRef`、可见性/符号链接 flags、`GlobalId` 类型 |
| `store.mbt` | 计数、id 访问、路径重建、扩展名、规范顺序、全局 id 映射、数据库恢复构造 |
| `exit.mbt` / `version.mbt` | CLI 退出码与版本文本 |

## 两套 id

`FolderId` 与 `EntryId` 分别是文件夹数组、文件数组的下标，两者都从 0 开始。位图与字段
字典需要**跨类型唯一**的 id，因此 `Store` 提供第三套编号：

```text
GlobalId = folder id                             0 .. folder_count - 1
         = folder_count + file id                folder_count .. entry_count - 1
```

- `Store::global_id(entry : EntryRef) -> GlobalId`：正向映射，不校验越界。
- `Store::entry_at(id : GlobalId) -> EntryRef?`：反向映射，负 id 与越界 id 返回 `None`。
- 规范顺序数组仍存 `EntryRef`，不存 `GlobalId`；两者在需要时互相转换。

所有 `Ids` 集合、`Dict` 字典、后续的范围索引与 trigram posting 都使用 `GlobalId`。
这样 `files_all ∪ folders_all`、`ext:pdf OR folder:x` 这类跨类型集合运算才不会冲突。

## 规范顺序

`Store::new` 在构造时建立唯一一份预排序数组：文件夹与文件合并，按 `(name, path)` 的
自然顺序排序，最后用输入下标兜底，保证不同扫描顺序下结果确定。查询输出与 `--limit`
的提前停止都基于这份顺序，不再为每个排序键维护数组。

数据库加载使用 `Store::restore`：它接收已经校验过的名字池、条目数组、根记录与
ORDER 数组，跳过 `Store::new` 的排序，因为持久化的顺序就是原顺序。调用方负责保证
`order` 是全局 id 的排列、父链无环、名字引用可读；越界 id 在查询侧仍由 `entry_at`
降级为 `None`，不会直接索引越界。`RootInfo::new` 供扫描器与数据库加载器共同构造根
统计记录。

## 扩展名

`Store::entry_extension(entry)` 是输出层与排序层共用的扩展名入口：

- 文件返回名字最后一个点之后的原始字节，规则与 `util::extension_of` 一致；
- 文件夹恒为空，即使名字里含点——`ext:` 是文件字段，输出层必须与查询层一致；
- 字节原样返回，由调用方决定是否 ASCII 折叠。

## 错误与边界

- 负 id、越界 id 的条目访问返回 `None`；路径重建返回空 `Bytes`。
- 名字长度上限是 `UInt16` 能表示的最大字节数（65535）。
- 文件夹大小按子树累加，溢出时饱和到 `Int64` 边界。
- 根条目的 `parent` 是 `NO_PARENT`；路径拼接对根为 `/` 的情况避免双斜杠。

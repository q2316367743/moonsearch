# index — 扫描、构建器与字段字典

`src/index` 负责把目录树变成 `core.Store`，并在扫描结束后建立 S07 的字段字典 `Dict`。
它依赖 `core`、`ids`、`util` 与 `platform`，不依赖查询层。

## 职责

- 递归扫描根目录：排序后的 `readdir`、排除规则、隐藏文件、one-file-system、后序统计。
- `Builder`：追加根、文件夹、文件，维护名字池与两个条目数组。
- `Dict`：低基数字段的位图集合（扩展名、类型、隐藏、根、内置分类）。
- 排除规则的解析与匹配（`ExcludeRule`）。

## 文件

| 文件 | 内容 |
| --- | --- |
| `scanner.mbt` | 扫描配置、递归扫描、根规范化、`ScanReport` |
| `builder.mbt` | `Builder`：条目追加、子项计数、根统计、`finish` |
| `exclude.mbt` | `ExcludeRule`、`ExcludeScope`、`ExcludeTarget` |
| `dict.mbt` | `Dict`、`ExtensionEntry`、构建期物化 |
| `errors.mbt` | `IndexError` |

## 扫描与构建器

- 每个目录项先按名字的自然顺序排序，再决定 id，因此 `readdir` 顺序不会进入索引。
- 条目按前序分配 id：父目录一定在子条目之前；大小与子项计数在递归返回时后序累加。
- 符号链接不跟随，作为文件条目记录 `ENTRY_FLAG_SYMLINK`；特殊文件记录
  `ENTRY_FLAG_SPECIAL`；以 `.` 开头的名字记录 `ENTRY_FLAG_HIDDEN`。
- `Builder::finish` 生成不可变 `Store`，规范顺序在 `Store::new` 中建立。

## 字段字典 `Dict`

`Dict` 是 S07 的交付物，覆盖值种类少、查询为等值或集合匹配的字段：

| 集合 | 来源 | 用途 |
| --- | --- | --- |
| `extensions` | 每个文件的扩展名，ASCII 折叠 | `ext:pdf;txt` |
| `files_all` / `folders_all` | 两个条目数组 | `file:` / `folder:` 与类型域剪枝 |
| `hidden` / `visible` | `ENTRY_FLAG_HIDDEN` | `hidden:` / `nohidden:` |
| `roots` | 每个根及整棵子树 | 根范围过滤（后续 CLI 选项） |
| `categories` | 内置分类宏的扩展名并集 | `app:` / `archive:` / `audio:` / `doc:` / `pic:` / `video:` |

### id 空间

所有集合使用 `core.GlobalId`：文件夹占 `0 .. folder_count - 1`，文件从 `folder_count`
开始。`files_all` 与 `folders_all` 因此可以安全地做交集、并集与差集；`all` 是两者的并。

### 构建算法

```text
Dict::build(store):
  1. files_all / folders_all / all      一次 Range 构造
  2. hidden / visible                   扫描 flags，all \ hidden
  3. extensions                         遍历文件 -> Map[Bytes, ids]
                                        -> 按扩展名字节序排序成 ExtensionEntry[]
  4. categories                         每个分类 union 其扩展名桶
  5. roots                              父链解析所属根，按根分桶
```

- 扩展名统一用 `util.extension_of`，与扫描谓词共用同一份规则：以 `.` 开头的名字没有
  扩展名，结尾的点不开始扩展名，取最后一个点之后的部分。键再经 `util.ascii_fold`
  ASCII 折叠；非 ASCII 字节原样保留。
- 扩展名桶按字节字典序排序，查找是二分；空扩展名是一个真实桶，对应 `ext:`。
- 同一扩展名在目录中出现多次时只保留一个键；`Ids::from_sorted` 负责排序、去重与
  形态选择（稀疏 `Sorted`、稠密 `Bitmap`）。
- 内置分类的扩展名列表来自 `util.TypeCategory::extensions`；扫描引擎与字典读同一份
  列表，因此 `pic:` 在两套引擎上结果一致。
- 根集合按 `Store::roots()` 的顺序存放；根文件夹与全部后代进入同一个集合。父链解析
  带长度保护，损坏的父链或环不会死循环。
- 所有集合在构建结束时按 `entry_count` 调用 `Ids::normalize`，让稠密集合落到位图形态。
- 访问器按值返回集合但不复制；与 `Store` 一样，调用方必须把它们当作只读数据，不能在
  查询路径上调用 `Bitmap::add` / `remove`。

### 复杂度

- 构建：O(N) 遍历 + O(E log E) 扩展名排序（E 为不同扩展名数）+ 分类并集。
- 查询：扩展名一次二分 + 集合运算；`files_all` / `folders_all` / `hidden` / 分类都是
  O(1) 取值后做集合代数。
- 内存：每个扩展名一个 `Ids`；稀疏扩展名是 `Sorted` 数组，稠密集合是位图。

## 测试

- `dict_test.mbt`：统一 id、隐藏/可见划分、扩展名折叠与空扩展名、分类物化、根集合、
  确定性、空索引。
- `exec/dict_compat_test.mbt`：把字典结果逐项展开成路径，与扫描引擎的 `file:`、
  `folder:`、`hidden:`、`nohidden:`、`ext:`、内置宏查询结果对拍。

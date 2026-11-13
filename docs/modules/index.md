# index — 扫描、构建器、字段字典、范围索引与 trigram 倒排

`src/index` 负责把目录树变成 `core.Store`，并在扫描结束后建立 S07 的字段字典 `Dict`、
S08 的范围索引 `Ranges` 与 S09 的 trigram 倒排 `TrigramIndex`。它依赖 `core`、`ids`、
`util` 与 `platform`，不依赖查询层。

## 职责

- 递归扫描根目录：排序后的 `readdir`、排除规则、隐藏文件、one-file-system、后序统计。
- `Builder`：追加根、文件夹、文件，维护名字池与两个条目数组。
- `Dict`：低基数字段的位图集合（扩展名、类型、隐藏、根、内置分类）。
- `Ranges`：高基数与范围字段的有序 `(value, id)` 数组（大小、时间、深度、子项数、父目录）。
- `TrigramIndex`：名字的 3 字节倒排，为子串查询提供候选集。
- 排除规则的解析与匹配（`ExcludeRule`）。

## 文件

| 文件 | 内容 |
| --- | --- |
| `scanner.mbt` | 扫描配置、递归扫描、根规范化、`ScanReport` |
| `builder.mbt` | `Builder`：条目追加、子项计数、根统计、`finish` |
| `exclude.mbt` | `ExcludeRule`、`ExcludeScope`、`ExcludeTarget` |
| `dict.mbt` | `Dict`、`ExtensionEntry`、构建期物化 |
| `range.mbt` | `RangeField`、`RangeFieldSet`、`RangeIndex`、`Ranges`、`ParentPaths` |
| `trigram.mbt` | `TrigramIndex`、`TrigramPosting`、`TrigramLookup`、提取与交集 |
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

## 范围索引 `Ranges`（S08）

`RangeIndex` 覆盖值域大、查询为范围或等值匹配的字段。与 `Dict` 的分工是：值种类少用
位图，值种类多用有序数组。

| 字段 | 覆盖条目 | 值 |
| --- | --- | --- |
| `size` | 文件 + 文件夹 | 文件字节数；文件夹为子树总和 |
| `mtime` | 文件 + 文件夹 | Unix 秒 |
| `depth` | 文件 + 文件夹 | 根为 0，直接子项为 1 |
| `childcount` | 仅文件夹 | 直接子项总数 |
| `parent` | 文件 + 文件夹，根除外 | 父文件夹 id |

### 结构与查询

`RangeIndex` 是两条平行数组 `values : Int64[]`、`ids : Int32[]`，按 `(value, id)` 升序：
相同值连续，桶内 id 升序。查询只做二分与切片：

```text
equal(v)      [lower_bound(v), upper_bound(v))
range(lo, hi) [lower_bound(lo), lower_bound(hi))   // 半开
> v           [upper_bound(v), len)
>= v          [lower_bound(v), len)
< v           [0, lower_bound(v))
<= v          [0, upper_bound(v))
```

- 空区间或反向区间（`hi <= lo`）直接返回空集，不触碰数组。
- 区间切片的 id 按值排序而非 id 排序，因此统一经 `Ids::from_sorted` 排序去重；
  `total` 参与 S06 的密度规则，窄区间保持 `Sorted`，覆盖大部分索引时升为 `Bitmap`。
- 五个访问器共享 `Ranges::field`，构建后只读。

### parent 计数排序

`parent` 的键空间是文件夹 id，因此不需要比较排序：计数、前缀和、按条目 id 顺序回填，
复杂度 O(N + F)。根条目的 `parent` 为 -1，不进入索引——扫描引擎的 `parent:` 也永不
匹配根。`parent:` 按路径查询，路径到文件夹 id 的转换由 `ParentPaths` 完成：所有文件夹
路径按字节排序后二分，查不到路径即空集。路径精确匹配，尾斜杠由查询层归一化。

### 懒构建与 `--fast-fields`

`Ranges::build(store, eager~)` 只立即构建 `eager` 选中的字段，其余字段在第一次访问时
从 `Store` 构建并缓存，因此不需要第二次扫描。`RangeFieldSet` 负责解析
`--fast-fields`（默认 `size,mtime`，接受 `dm`、`children` 别名与空格）。`--stats` 只遍历
`is_loaded` 为真的字段，避免为了打印统计而触发懒构建。

### 语义对齐

- `depth` 用一次记忆化上溯填满所有文件夹，文件取父目录深度 + 1；与扫描引擎逐条
  `folder_depth` 的结果一致。
- `childcount` 只收录文件夹；`empty:` 等价于 `childcount` 等于 0。
- `size` / `mtime` 同时收录文件与文件夹，文件夹的 size 是子树总和。
- `mtime` 保存原始 Unix 秒；`dm:` 的日历解析仍在查询/编译层完成，再转成区间。
- `exec/range_compat_test.mbt` 把每个字段的查询结果展开成路径，与 `exec_scan` 对拍：
  size 的六种比较与反向区间、dm 的月份/比较/范围、depth 多层、childcount 与 `empty:`、
  parent 多级路径与不存在的路径。

### 复杂度

- 构建：四个字段各一次排序 O(N log N)；`parent` O(N + F)；`ParentPaths` O(F log F)。
- 查询：一次或两次二分 + 区间切片 O(log N + k)；`parent:` 额外一次路径二分
  O(log F · L)，L 为路径长度。
- 内存：每字段约 12 B/条目（`Int64` 值 + `Int32` id），与计划第 10 节的预算一致。

## Trigram 倒排 `TrigramIndex`（S09）

`TrigramIndex` 是第三个候选集来源：名字的三字节片段倒排，服务于普通子串查询。它只
索引名字（`Store::entry_name`），不索引路径；查询方拿到的永远是候选集，必须再对候选
逐条做真正的字节比较。

### 结构与构建

| 组成 | 说明 |
| --- | --- |
| 键 | 3 字节窗口打包成 24 位 `UInt32`，高字节在前 |
| posting | `TrigramPosting`，内部是升序无重复的 `Int32` id 数组 |
| 存储 | 升序 `keys : Array[UInt32]` + 平行 `postings : Array[TrigramPosting]` |

键和 posting 各用一个平行数组而不是 Map：查找是一次二分，构建结束后 hash 容器立即
释放，迭代顺序也天然确定。

```text
TrigramIndex::build(store):
  1. 按全局 id 顺序遍历文件夹与文件（文件夹 0..F-1，文件从 F 开始）
  2. 名字长度 < 3：计入 short_names，不产生键
  3. ASCII 折叠（只折叠 A-Z），逐窗口取 3 字节键
  4. 同一名字内按键排序去重
  5. 键 -> 追加 id；遍历本身按 id 升序，posting 因此天然有序
  6. Map 转数组、按键排序，构建期 hash 容器释放
```

- 文件夹与文件共用同一个 id 空间，文件夹名也会产生 posting；短名字（包括 `/r` 这样
  的根名）只计入 `short_name_count`。长度 < 3 的名字不可能包含长度 ≥ 3 的 needle，
  所以不需要候选列表。
- 重复窗口必须在名字内去重：`aaaa` 会切出三个 `aaa`，若直接追加会让同一 id 在
  posting 中出现多次，破坏 `Ids` 依赖的升序无重复不变量。
- 非 ASCII 字节原样参与切分；大小写折叠只覆盖 ASCII，与扫描引擎的匹配规则一致。

### 查询：取最短 posting 交集

```text
lookup(needle):
  1. needle < 3 字节                      -> 全量扫描
  2. 提取 needle 的全部去重 trigram
  3. 任一 trigram 没有 posting            -> 候选集必为空（missing）
  4. posting 基数 > N/5                   -> stop-gram，跳过
  5. 剩余 posting 按长度升序取前 3 个做交集
  6. 交集结果 -> Ids::from_sorted(..., total)
```

- **不漏报**：任何匹配的名字必须包含 needle 的每一个 trigram，因此只交集其中一部分
  仍是超集；任一 trigram 的 posting 缺失时结果一定为空。
- **stop-gram**：基数严格超过索引总条目 20% 的 posting 无法有效收窄候选，查询时
  跳过；恰好 1/5 仍然保留。若所有 trigram 都是 stop-gram，返回全量扫描。
- **短词退化**：needle < 3 字节时没有 trigram，`is_full_scan()` 为真，调用方在全集
  （或其他字段的集合）上求值。
- **大小写**：索引始终按 ASCII 折叠存储。大小写敏感的查询可以复用同一候选集：折叠
  只会放大候选，最终由逐字节比较裁决。
- **路径 / glob / regex**：本步只覆盖名字子串。`path:` 不能直接使用该候选集（needle
  可能只出现在父目录名里），glob/regex 也应回退扫描；这些取舍由 S10 编译层执行。

### 交集算法

`posting_intersect` 以较短列表驱动：

- 长度相近（短边 × 32 ≥ 长边）：归并式交集，一次线性扫描两个数组。
- 长度悬殊（短边 × 32 < 长边）：galloping。每个短边 id 在长边上做指数探测
  （步长 1、2、4…）再二分，并从上一次位置继续。

两条分支都保持结果升序无重复。`trigram_wbtest.mbt` 用嵌套循环的朴素交集作为 oracle，
分别覆盖两条分支以及空列表、无交集、全交集、末尾探测等边界。

### 统计与 `--no-trigram`

`index --stats` 增加一行：

```text
trigram: <keys> keys, <postings> postings, <short> short names, <stop> stop-grams, <bytes> B
```

`--no-trigram` 跳过 posting 构建，该行显示 `trigram: disabled`。`posting_bytes` 只统计
posting 的 `Int32` 数组（4 B/条），不含键与对象头；S12 持久化后会用 delta-varint
替换。`TrigramLookup::describe()` 提供稳定单行文本（`trigram: 3 keys, N candidate ids`
/ `trigram: scan` / `trigram: miss`），供 S10 的 `--explain` 使用。

### 复杂度与内存

- 构建：O(N·L) 字节遍历 + 每名字 O(L log L) 的键排序去重 + O(K log K) 键排序，
  K 为不同 trigram 数。
- 查询：O(k · (log K + log N)) 次二分，k ≤ 3；候选集只与命中规模相关。
- 内存：键 4 B/个，posting 4 B/id。100 万条目、约 1300 万 posting 时 posting 数组
  约 52 MB；这是内存定长形态，S12 的 delta-varint 会把磁盘体积压到计划估算的
  ~25 MB 量级。

## 测试

- `dict_test.mbt`：统一 id、隐藏/可见划分、扩展名折叠与空扩展名、分类物化、根集合、
  确定性、空索引。
- `range_test.mbt`：`RangeIndex` 的排序、上下界、半开区间、空/反向区间、重复值、密度
  形态；五个字段的构建结果；`parent` 计数排序与路径查找；懒构建；空索引与确定性。
- `trigram_test.mbt`：键序与 posting 升序、重复窗口去重、ASCII 折叠、非 ASCII 字节、
  短名字、空索引、缺失 trigram、stop-gram 跳过、确定性。
- `trigram_wbtest.mbt`：`name_trigrams` / `pack_trigram`、归并与 galloping 两条交集
  分支、`gallop_lower_bound` 边界。
- `exec/dict_compat_test.mbt`：把字典结果逐项展开成路径，与扫描引擎的 `file:`、
  `folder:`、`hidden:`、`nohidden:`、`ext:`、内置宏查询结果对拍。
- `exec/range_compat_test.mbt`：范围字段与扫描引擎的 `size:`、`dm:`、`depth:`、
  `childcount:`、`empty:`、`parent:` 对拍。
- `exec/trigram_compat_test.mbt`：S09 的核心性质测试——对每个名字的全部长度 ≥ 3
  子串分别以默认、`case:`、`exact:` 运行扫描引擎，断言每个命中 id 都在 trigram
  候选集内；同时覆盖缺失 trigram、短 needle、短名字、stop-gram 与 `path:` 的边界，
  并断言“至少一次走 posting、至少一次走全扫”。

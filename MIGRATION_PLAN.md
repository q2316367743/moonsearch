# moonsearch 迁移计划书

**从 FSearch（C / GTK3）到 MoonBit 原生检索引擎**

| 项目 | 内容 |
| --- | --- |
| 文档版本 | v0.2（架构修订：倒排索引 + 位图代数） |
| 日期 | 2026-11-11 |
| 状态 | 仅规划，不修改源码 |
| 上游参考 | FSearch 0.3-dev，commit `1208a34`，GPL-2.0（**仅作行为参考，不迁移代码**） |
| 目标仓库 | `/Users/esion/Documents/workspace/moonbit/moonsearch` |
| 目标形态 | 原生 CLI，无 GUI；索引一次，命令行查询多次 |
| 执行引擎 | trigram 倒排 + 位图集合运算 + 范围数组（Lucene 式） |

> 本文档只描述方案，不包含代码改动。当前仓库仍是 MoonBit 模板：根包为空，`cmd/main/main.mbt` 只打印 `Hello`。

---

## 0. 一页结论

1. **参考工具的共同架构是"预排序数组 + 线性扫描 + 逐条目求值"。** FSearch、Everything、fd、mdfind 都是这个形状：选一个有序数组，从头扫到尾，对每个条目跑一遍匹配函数。这条路线决定了它们的能力上限，本项目不走。
2. **本项目把文件搜索按检索引擎的架构组织。** 名字进 trigram 倒排，低基数字段（扩展名、类型、隐藏、根、内容类型）进位图，范围字段（大小、时间、深度、子项数、父目录）进有序数组，查询在编译期变成集合代数，在运行期只做集合运算。常用查询从"扫描十万到百万个名字"变成"几个集合的交并差"。
3. **保留一套线性扫描求值器作为基线。** 它同时承担三件事：`--live` 直接扫目录的模式、索引缺失时的降级路径、以及位图引擎的对拍 oracle。两套引擎在同一份索引上必须逐条返回相同结果，这是本项目最重要的测试手段。
4. **MoonBit 的表达优势正好落在这里。** `Ids = Bitmap | Sorted` 的代数数据类型、容器选择、计划重写、模式匹配求值，全部类型安全；不存在 C 里的函数指针分派、`void*` 万能节点和手工容器。
5. **主要风险从"Unicode 是否精确"转移到"索引体积与正确性对拍"。** 前者靠明确切范围控制（v1 只做 ASCII 折叠），后者靠两引擎对拍 + 性质测试控制。
6. **施工拆成 14 个步骤（第 11 节）**，每步有独立可交付物与验收标准，步与步之间只依赖前序产物。没有时间预估：完成一步就是一步。
7. **许可证不构成障碍。** 本项目是独立实现，不复制上游代码、注释、常量表；FSearch 与 Everything 只作为行为参考记录在 README。保持 Apache-2.0。

**MVP 边界（第一个可用版本）**：

```text
moonsearch index /home/user
moonsearch search 'report pdf'
moonsearch search 'ext:jpg;png size:>1mb' --sort size --reverse -n 20
moonsearch count 'ext:mp4'          # 直接返回位图基数，不扫描
```

MVP 包含：持久化索引、trigram 子串、位图字段过滤、范围字段、AND/OR/NOT/括号、`--sort name|size|mtime`、`--limit`、路径输出。glob、正则、日期、宏、Unicode 高级匹配、增量更新按步骤逐步加入。

---

## 1. 背景、目标与非目标

### 1.1 背景

FSearch 是一个受 Everything 启发的 Unix 文件搜索工具，C + GTK3 实现。它的工作方式不是每次查询都遍历文件系统，而是：

1. 启动时（或手动触发时）扫描配置的根目录，建立常驻内存索引；
2. 把索引持久化到二进制数据库文件；
3. 查询时只在内存中的预排序数组上做匹配，因此可以做到"输入即结果"。

它的问题不在实现质量，在架构：**查询的复杂度是 O(条目数 × 查询项数)**。多一个过滤条件，就多一次全量遍历。`ext:jpg size:>1mb dm:lastweek` 这种日常查询，代价是三倍的全表扫描。

当前 `moonsearch` 是一个 MoonBit 空模板。本次迁移的目标是把 FSearch 的**查询语义**、**索引构建流程**、**持久化思路**迁移到 MoonBit，并把执行引擎换成集合代数——让查询代价由"命中集的大小"决定，而不是由"索引的总大小"决定。

### 1.2 目标

- **语义对齐**：覆盖 FSearch 的查询语言（布尔、修饰符、字段、数值/大小/日期、宏），边界行为可测试、可文档化。
- **执行模型替换**：pre-sorted array + linear scan → inverted index + bitmap algebra。同一查询，两套引擎结果必须一致。
- **MoonBit 原生表达**：用 ADT、模式匹配、`Option`/`Result`、`BytesView`/`Buffer` 重写所有核心结构，而不是把 C 结构体逐字段翻译。
- **CLI 交互**：`index`、`update`、`search`、`count`、`info` 五个子命令；支持排序、过滤、限制条数、NUL 分隔、JSON 输出。
- **Unix 优先**：Linux 与 macOS；不需要 GUI、GTK、桌面环境。
- **可测量**：查询延迟、索引体积、索引构建耗时都有可重复的基准，并记录在 README。

### 1.3 非目标（本期不做）

- GTK 界面、列表视图、菜单、偏好设置、状态栏、预览、剪贴板、桌面文件启动。
- inotify / fanotify 实时监控与增量索引更新（先做全量重建）。
- 桌面环境集成（GVfs、GIO content type、图标、缩略图、回收站）。
- 多语言 UI（查询语法关键字仍是英文；错误信息可中文/英文）。
- Windows 路径语义（`\` 分隔符、盘符、大小写不敏感文件系统）。
- 文件内容全文搜索（FSearch 本身也不做；本项目同样只索引元数据）。
- 分布式 / 多进程分片（单机单进程足够）。

### 1.4 成功标准

| 维度 | 标准 |
| --- | --- |
| 语义 | 查询语言覆盖矩阵中的 P0 项全部通过；每个用例在两套引擎上结果一致 |
| 索引 | 100 万条目可构建、保存、加载；加载后无需重建任何索引结构 |
| 查询 | `ext:` + 范围 + 布尔组合在 100 万条目上 < 5 ms；trigram 子串 < 20 ms |
| 索引体积 | 额外索引开销 < 名字池与条目数组之和的 1.5 倍 |
| 内存 | 100 万条目常驻内存 < 400 MB（含倒排与位图） |
| 可靠性 | 损坏/截断 DB 不崩溃、不越界；CLI 错误退出码稳定 |
| 可维护性 | 核心包 `.mbti` 稳定；`moon fmt` / `moon test` / `moon info` 全绿 |

> 内存目标比 v0.1 放宽，并新增索引体积预算：位图与 trigram 的固有代价，换取查询延迟的数量级下降。第 10 节给出取舍明细。

---

## 2. 参考工具与它们的共同盲点

### 2.1 代码地图

上游 `src/` 共 55 个 C 文件、约 27,151 行。按职责划分：

| 领域 | 代表文件 | 约行数 | 本项目态度 |
| --- | --- | --- | --- |
| 核心数据与存储 | `fsearch_database_entry.c`、`fsearch_database_chunked_array.c`、`fsearch_array.c` | ~2,500 | **重写**为 id + 名字池 + 集合结构 |
| 索引与扫描 | `fsearch_database_index.c`、`fsearch_database_scan.c`、`fsearch_database_index_store.c` | ~3,000 | **迁移扫描算法**，**替换**建索引逻辑 |
| 持久化 | `fsearch_database_file.c` | ~1,400 | **重写格式**，保留 section table + 原子替换思路 |
| 排序 | `fsearch_database_sort.c` | ~257 | **只保留比较器语义**；不再预排序 5 组数组 |
| 查询 | `fsearch_query*.c/h` | ~2,500 | **迁移语义**，**重写**为 AST + 计划 + 集合求值 |
| 工具函数 | `fsearch_string_utils.c`、`fsearch_size_utils.c`、`fsearch_time_utils.c`、`fsearch_file_utils.c`、`fsearch_utf.c` | ~2,000 | **逐算法迁移**，用 MoonBit 重写 |
| 过滤器/宏 | `fsearch_filter*.c` | ~300 | **迁移**为配置 + 查询宏 |
| 包含/排除 | `fsearch_database_include*.c`、`fsearch_database_exclude*.c` | ~700 | **迁移**为规则 ADT |
| GUI / 平台集成 | 窗口、列表、对话框、状态栏、剪贴板、预览、监控 | ~12,000 | **不迁移** |

上游提供的是**行为规格**，不是实现模板。凡是"因为 C 只能这么写"而存在的结构（chunked array、`GNode`、函数指针匹配器、线程池分片），在本项目里都不需要存在。

### 2.2 上游的查询链路与其代价

```text
查询字符串
  → Lexer
  → Shunting-yard（中缀转后缀）
  → 后缀列表
  → GNode 二叉查询树
  → 选一个预排序数组（按 --sort）
  → for entry in 整个数组:            ← 代价 = 条目总数
        matches(tree, entry)          ← 每个叶子一次 strstr / 数值比较
  → 结果天然有序，取前 N 条
```

两个关键事实：

- **每次查询都至少遍历一遍全表。** 无论查询多具体，代价都以条目总数计。
- **过滤条件越多越慢。** `ext:jpg size:>1mb` 不是"先取 jpg 再筛大小"，而是"对每个条目先判 ext、再判 size"。
- **结果天然有序**是这条架构唯一的红利——本项目必须用另一种方式补回来（见 5.9）。

### 2.3 必须保留的思想与本项目要替换的部分

保留（语义层面）：

1. **持久化索引**：扫描成本只付一次；查询只读内存。
2. **父链代替完整路径**：只存 parent 指针和自身名字，路径按需拼接。
3. **顺序无关的确定性**：同一份索引、同一查询，输出必须逐条相同（不能依赖遍历顺序）。
4. **结果有序 + 提前停止**：`--limit 20` 在命中 20 条时就停，不收集全部结果。
5. **ASCII 快路径**、**懒构建匹配缓冲**。
6. **二进制数据库**：section table、原子替换、校验和、版本化。
7. **自然排序**（`strverscmp` 变体）作为 name/path 比较器。

替换（执行层面）：

| 上游做法 | 本项目做法 | 收益 |
| --- | --- | --- |
| 5 组预排序 id 数组，查询时线性扫描 | 倒排索引 + 位图，查询编译成集合运算 | 代价从 O(N) 变为 O(命中集) |
| 每个叶子函数指针分派 | `match` 到集合表达式 | 类型安全、可优化、可解释 |
| `ext:` 逐条目比较字符串 | 扩展名 → 位图，直接 `and` | 单次位图操作代替百万次比较 |
| 数值字段逐条目比较 | 有序 `(value, id)` 数组 + 区间二分 | 范围查询变成两次二分 |
| 子串全表 `strstr` | trigram 倒排交集 + 少量候选验证 | 只验证可能命中的条目 |
| 5 组数组各排一次 | 只有一份规范顺序（name+path），其余排序按结果集做 | 构建期少 N log N × 4 |
| chunked array 支持增量插入 | 只读索引 + 全量重建 | 结构简单，可序列化 |
| 线程池按条目切分 | 单进程；可选按集合分片与 trigram 并行构建 | 先正确后并行 |

`--count` 的收益最直观：上游要遍历全表并计数，本项目直接对最终集合取基数（popcount）。

---

## 3. 设计原则与关键决策

### 3.1 语义迁移，实现重写

判断标准：

- **保留**：查询优先级、字段语义、比较规则、排序规则、错误行为、持久化思想。
- **重写**：执行模型、容器、字符串、并发、错误处理。
- **删除**：GUI、GLib 对象系统、引用计数、`GNode`、函数指针表、事件队列、chunked array。
- **新增**：倒排索引、位图代数、查询计划、两引擎对拍。

一个具体例子：C 的 `FsearchQueryNode` 是"万能结构体"，同时承载运算符、字符串、数值、正则、函数指针、UTF 缓冲、每线程匹配数据。本项目拆成两层：

```moonbit
// 语法层：用户输入的结构
pub enum Query {
  Term(Term)
  And(Query, Query)
  Or(Query, Query)
  Not(Query)
}

// 执行层：编译后的集合表达式
pub enum Expr {
  Const(Ids)          // 预先算好的位图或有序集
  Trigram(TrigramPlan)// 候选集来自倒排，需验证
  Scan(Predicate)     // 无法索引的谓词，逐候选验证
  And(Expr, Expr)
  Or(Expr, Expr)
  Not(Expr)
}
```

"运算符节点不可能有 needle"、"trigram 节点不可能有数值"由类型系统保证；执行器只处理 `Ids`，不关心原始字符串。

### 3.2 许可证边界

FSearch 是 GPL-2.0。本项目的做法是**不复制任何代码**：

- 不读不抄函数体、注释、常量表、测试用例文本。
- 只依据公开文档、帮助页面、以及"输入 → 输出"的行为观察实现语义。
- 数据结构、模块边界、执行模型均为独立设计（位图代数在上游根本不存在）。
- `README` 中声明：受 FSearch 与 Everything 启发，独立实现。
- 许可证保持 **Apache-2.0**。

这条边界的成本只有一句 README 声明。不需要双角色流程，也不需要把项目改成 GPL。

### 3.3 MoonBit 优先的设计约束

1. **原生目标**：`moon.mod` 设 `preferred_target = "native"`；Wasm 没有通用文件系统。
2. **字节优先**：索引内部用 `Bytes`/`BytesView` 存 Unix 路径与名字；`String` 只用于查询解析、配置、JSON 输出。
3. **不可变索引**：构建完成后 `Store` 只读；查询不修改索引。位图与倒排只在构建期可变。
4. **单一数据源**：条目用 `Int32` id 引用；所有集合都是 id 集合，可序列化、可比较、可缓存。
5. **热路径不分配**：集合运算复用工缓冲区；验证谓词复用 `MatchCtx`。
6. **错误显式化**：用户输入、文件系统、数据库损坏都用 `raise`/`Result`；`panic` 只用于不变量被破坏。
7. **两套引擎**：位图引擎是默认路径，扫描引擎是对拍 oracle，不是遗留代码。

### 3.4 关键决策记录

| 决策 | 选择 | 理由 | 代价 |
| --- | --- | --- | --- |
| 构建目标 | native only | 需要通用文件系统 | 放弃浏览器/插件场景 |
| 路径/名字表示 | 原始字节池 + `BytesView` | Unix 路径是字节流；避免 UTF-16 膨胀 | 需自写字节比较/搜索 |
| 索引生命周期 | 构建后只读 | CLI 无实时监控；简化并发/持久化 | `update` 全量重建 |
| 执行模型 | 倒排 + 位图集合代数 | 代价由命中集大小决定 | 索引体积增大，需对拍 |
| 集合类型 | `Ids = Bitmap \| Sorted` | 稠密用位图、稀疏用数组，各取所长 | 运算符要按基数选策略 |
| 位图容器 | 数组容器 / 位图容器两种 | 稀疏位图浪费 125 KB | 容器切换与阈值调优 |
| 子串索引 | trigram（仅名字，仅 ASCII 折叠） | 3 字节片段足以过滤掉 99% 候选 | 短词（<3）退化为扫描 |
| 范围字段 | 有序 `(value,id)` 数组 + 二分 | 范围查询天然适合有序结构 | 与位图运算要先转换 |
| 结果顺序 | 单个规范顺序数组 + 位图 membership | 保留流式与提前停止 | `--sort` 其他键需排序结果集 |
| 查询解析 | 递归下降 + 优先级爬升 | 直接产出 AST，少两份中间结构 | 需处理隐式 AND 边界 |
| 通配符 | 自实现 glob（扫描谓词） | 语义可控，不转正则 | 无法走索引 |
| Unicode 折叠 | v1 仅 ASCII；表驱动列为后续 | 控制范围，避免第一个版本卡在数据表 | 非 ASCII 大小写不折叠 |
| 持久化 | 自定义 MSDB v2（含 postings/bitmaps） | 按需设计、可校验、可演进 | 不能直接读上游 DB |
| 并发 | 单线程为主，构建期可选并行 | async 是协作式单核 | 大索引构建慢一些 |

---

## 4. 目标架构

### 4.1 包结构

```text
moonsearch/
├── moon.mod                 # preferred_target = "native"
├── src/
│   ├── moon.pkg             # 门面：pub using 再导出
│   ├── core/                # Entry、Store、NamePool、Flags、错误类型
│   ├── util/                # 自然排序、扩展名、大小/日期解析、ASCII 搜索
│   ├── ids/                 # Ids ADT、位图容器、集合运算（项目的心脏）
│   ├── index/               # 扫描器、构建器、字典、postings、持久化
│   │   ├── dict/            #   字段字典：值 → Ids
│   │   ├── postings/        #   trigram → 有序 id 列表
│   │   └── db/              #   读写、校验、原子替换
│   ├── query/               # lexer、parser、AST、plan、compile
│   ├── exec/                # 位图执行器、扫描执行器、结果顺序
│   └── config/              # CLI/配置、XDG 路径、宏定义
├── cmd/moonsearch/          # 可执行入口，只做参数解析与调用
└── tests/                   # 端到端夹具、CLI golden、对拍
```

依赖方向单向：

```text
cmd → config/cli → exec → query → core
                     ↓
                   index → ids → util
```

`ids` 不依赖文件系统、不依赖查询层，可以用纯数组做单元测试；`core` 不依赖 `query`，可以用内存 Store 构造夹具。

### 4.2 数据流

```text
[index 命令]
  config roots/excludes
    → platform.scan(root)                 递归 readdir + lstat
    → EntryBuilder（临时 id、名字池、父索引）
    → 规范化排序（folders/files 按 name+path）→ 得到唯一规范顺序
    → 构建 no 倒排：
        dict.ext / dict.kind / dict.parent / dict.hidden → 位图
        range.size / range.mtime / range.depth / range.children → 有序数组
        postings.trigram(name) → 有序 id 列表
    → db.write（原子替换）

[search 命令]
  query string
    → lexer → parser → Query AST
    → plan：静态分析（类型域、可索引性、基数估算）
    → compile：Query → Expr（Const / Trigram / Scan / And / Or / Not）
    → optimize：按基数重排、常量折叠、空集短路
    → exec：求 Ids（位图与有序集的混合运算）
    → order：按规范顺序扫描 membership，或对结果集排序 + top-K
    → format → stdout
```

### 4.3 核心数据模型

```moonbit
// 示意：不是最终实现
pub typealias EntryId = Int32
pub typealias FolderId = Int32

pub enum EntryKind {
  File
  Folder
}

pub struct Entry {
  parent : FolderId      // 根为 -1
  name_off : UInt32      // NamePool 中的字节偏移
  name_len : UInt16      // 名字字节数（不是字符数）
  flags : UInt16         // 隐藏、符号链接等
  size : Int64           // 文件字节数；文件夹为子树总和
  mtime : Int64          // Unix 秒
  num_files : UInt32     // 仅文件夹
  num_folders : UInt32   // 仅文件夹
}

pub struct Store {
  names : Bytes                 // 所有名字的原始字节池
  folders : Array[Entry]
  files : Array[Entry]
  order_name : Array[EntryId]   // 唯一的规范顺序：name + path，自然排序
  dict : Dict                   // 低基数字段 → Ids
  ranges : Array[RangeIndex]    // 范围字段 → 有序 (value,id)
  trigrams : TrigramIndex       // 名字的 3 字节片段 → 有序 id 列表
  roots : Array[RootInfo]
  excludes : Array[ExcludeRule]
  built_at : Int64
}
```

为什么用 id 而不是指针：

- 可序列化：磁盘上直接存 id，加载后不需要"指针修复"。
- 集合友好：id 是位图与有序数组的天然元素。
- GC 友好：`Entry` 只含原始类型与偏移量，名字集中在 `Bytes` 池中。
- 可测试：构造 `Store` 不需要真实文件系统。

### 4.4 名称与路径表示

MoonBit 的 `String` 内部是 UTF-16 code units，必须是合法 UTF-16；而 Unix 文件名是任意字节流。因此：

- **索引内部不存 `String`**。名字以原始字节写入 `NamePool`（`Bytes`），`Entry` 存 `(off, len)`。
- **路径拼接用 `Buffer` 写字节**，输出时直接写 `Bytes`。
- **ASCII 查询直接走字节匹配**，不解码、不分配。
- **Unicode 查询/正则**才把候选名字 `decode_lossy` 成 `String`。
- **非法 UTF-8 名字**：字节层匹配与输出正常；JSON 使用 lossy 解码并记录告警。

路径拼接规则：

- 根条目的名字就是根路径（例如 `/home/user`，或 `/`）。
- 子条目路径 = 父路径 + `/` + 名字；根为 `/` 时不要产生 `//`。
- 路径按需构建，缓存到 `MatchCtx` 的 `Buffer`，不进入 `Entry`。

### 4.5 错误模型

```moonbit
pub suberror DbError {
  BadMagic(BytesView)
  UnsupportedVersion(Int32, Int32)
  Truncated(String)
  Corrupt(String)
  Io(String)
}

pub suberror QueryError {
  Lex(Int32, String)
  Parse(Int32, String)
  BadRegex(String)
  BadNumber(String)
  Unindexable(String)   // 需要索引但未建立
}

pub suberror IndexError {
  RootMissing(String)
  PermissionDenied(String)
  Other(String)
}
```

CLI 统一映射：

- 查询/参数错误 → stderr + 退出码 2。
- 无匹配 → 退出码 1（grep 约定）。
- 有匹配 → 退出码 0。
- 数据库缺失/损坏 → stderr + 退出码 2，并提示 `moonsearch index`。
---

## 5. 索引与查询执行

本节是 v0.2 的核心。5.1–5.2 描述数据怎么进来，5.3–5.7 描述索引怎么组织，5.8–5.9 描述查询怎么变成集合运算，5.10–5.11 描述语义层，5.12 描述怎么落盘。

### 5.1 扫描与建库

#### 5.1.1 扫描算法

fsearch 的扫描是单线程递归 `readdir` + `fstatat(AT_SYMLINK_NOFOLLOW)`，用 `dirfd` 避免为每个条目拼路径。本项目保留这个骨架，分两个实现阶段：

**阶段 A：纯 MoonBit**

使用 `moonbitlang/async/fs`：

- `@fs.opendir(path)` → `Directory`，`dir.next()` → `DirectoryEntry { name, is_dir }`
- `@fs.kind(path, follow_symlink=false)`、`@fs.mtime(...)`、`@fs.file_size(...)`

优点：零 FFI、跨平台、快速打通。
缺点：每个条目可能触发多次 path-based syscall；名字已被解码成 `String`，非法 UTF-8 会丢失；拿不到 `st_dev`。

**阶段 B：POSIX FFI**

在 `platform/posix` 包中用 `native-stub` 写最小 shim：

```c
typedef struct ms_dir ms_dir;
ms_dir *ms_opendir(const char *path);
int ms_readdir(ms_dir *d, const char **name, size_t *len, unsigned char *d_type);
int ms_fstatat(ms_dir *d, const char *name, ms_stat *out); // size, mtime, mode, dev, ino
void ms_closedir(ms_dir *d);
```

> FFI 不能把 MoonBit `Bytes` 当 `char*` 直接用。C shim 接收 `(ptr, len)`，名字复制到调用方缓冲区，避免跨语言内存所有权问题。

一次 `readdir` + 一次 `fstatat` 拿到名字字节、类型、大小、mtime、`st_dev`，并保留非法 UTF-8 文件名。

**取舍**：阶段 A 打通算法，阶段 B 只替换 `platform` 实现，不改变上层 `Scanner` 接口。

#### 5.1.2 递归与统计

```moonbit
struct DirStats {
  files : UInt32
  folders : UInt32
  size : Int64
}

fn scan_dir(path : StringView, parent : FolderId, out : EntryBuilder) -> DirStats raise IndexError
```

流程：

1. 目录不可读 → 记录错误并返回空统计（可配置为致命）。
2. 先为当前目录创建文件夹条目（预序），拿到 `folder_id`；递归结束后回填统计。
3. 遍历目录项：
   - 跳过 `.` / `..`；名字长度超过 `UInt16::MAX` 的跳过并告警。
   - `lstat` 失败则跳过；`one_file_system` 时比较 `st_dev`。
   - 先做基于名字的排除（隐藏文件、basename 规则），再做基于路径/类型的排除。
   - 目录 → 递归，累加子统计；非目录（含符号链接）→ 文件条目，累加 size。
4. 返回 `DirStats`，父目录累加。

与上游"每添加一个文件就向上更新所有祖先 size"不同：**后序返回统计**只做一次累加，O(n)，不会有负数/重复更新的边界问题。

#### 5.1.3 根目录与边界

- 根路径规范化（`@fs.realpath`）并去重；嵌套根默认拒绝，提供 `--allow-nested-roots`。
- 根为 `/` 时，根条目名字为 `/`，路径拼接特殊处理。
- 默认排除伪文件系统：`/proc`、`/sys`、`/dev`、`/run`（仅当根覆盖它们时）；`--no-default-excludes` 关闭。
- 符号链接不跟随；符号链接作为文件条目（与 `lstat` 行为一致）。
- 硬链接会重复计数；未来可选 `(dev, ino)` 去重。

#### 5.1.4 排除规则

```moonbit
pub enum ExcludeKind { Fixed; Glob; Regex }
pub enum ExcludeScope { FullPath; Basename }
pub enum ExcludeTarget { Both; Files; Folders }

pub struct ExcludeRule {
  kind : ExcludeKind
  scope : ExcludeScope
  target : ExcludeTarget
  pattern : String
  active : Bool
}
```

匹配顺序：

1. `exclude_hidden && basename.starts_with(".")` → 排除。
2. 对每条 active 规则：target 与 `is_dir` 不符则跳过；取 `path` 或 `basename`；Fixed 用字节相等，Glob 复用查询的 glob 匹配器，Regex 复用查询的正则。
3. 任一命中即排除。

### 5.2 条目、父链与规范顺序

#### 5.2.1 规范顺序

索引构建完成后做一次规范化排序：

- 文件夹按 `(name, path)` 排序；文件按 `(name, path)` 排序。
- 排序前用临时 id；排序后建立 `old_id -> new_id` 映射，回填所有 `parent`。
- `parent` 指向 `folders` 数组下标；根为 `-1`。

这个顺序是**唯一的预排序结果**，用途有两个：

1. 名字前缀压缩在"按 name 排序"的数组上效果最好。
2. 查询输出时用它恢复顺序（见 5.9），不再需要为 size/mtime/ext 各建一份有序数组。

> 只按 name 排序不是全序（不同目录可能同名），必须加 path 作为第二键，才能保证不同运行/不同扫描顺序下结果确定。

#### 5.2.2 路径比较

`cmp_paths` 是自然排序（`strverscmp` 变体）：

- `\0` 权重 0，`/` 权重 1，其他字节权重 `byte + 1`；
- 连续数字按数值比较（`file2` < `file10`）；
- 前导零遵循 `strverscmp` 规则；
- 用于 name/path 排序与 ext 排序的 tie-break。

合法 UTF-8 的字节序与码点序一致，因此按字节排序不破坏 Unicode 语义；非法 UTF-8 按原始字节序。测试必须覆盖 `file2`/`file10`、`a/b`/`a.b`、`007`/`7`、空串、相同前缀、非 ASCII 字节。

#### 5.2.3 扩展名

最后一个 `.` 之后；隐藏文件（以 `.` 开头）和以 `.` 结尾视为无扩展名。索引时统一折叠为 ASCII 小写。

#### 5.2.4 文件夹统计

- `size`：子树内所有文件 size 之和；空文件夹为 0。
- `num_files` / `num_folders`：**直接子项**计数（`childcount` 语义）。
- 溢出：`size` 用 checked add，饱和到 `Int64::MAX` 并告警。

### 5.3 集合抽象：`Ids`

整个项目只有一个查询中间表示：**id 集合**。它有两种物理形态，按稠密度选择。

```moonbit
pub enum Ids {
  Bitmap(Bitmap)            // 稠密：位运算，O(字数)
  Sorted(Array[Int32])      // 稀疏：升序数组，O(元素数)
}
```

```moonbit
pub fn Ids::cardinality(self : Ids) -> Int
pub fn Ids::contains(self : Ids, id : Int32) -> Bool
pub fn Ids::intersect(a : Ids, b : Ids) -> Ids
pub fn Ids::union(a : Ids, b : Ids) -> Ids
pub fn Ids::difference(a : Ids, b : Ids) -> Ids   // a \ b，用于 NOT
pub fn Ids::to_bitmap(self : Ids) -> Bitmap
pub fn Ids::filter(self : Ids, pred : (Int32) -> Bool) -> Ids  // 验证谓词下推
```

运算策略按形态与基数自动选择：

| 左 | 右 | 策略 | 代价 |
| --- | --- | --- | --- |
| Bitmap | Bitmap | 按 64 位字 `and`/`or`/`andnot` | O(N/64) |
| Sorted(小) | Bitmap | 逐元素 `contains` 探测 | O(\|小\|) |
| Sorted | Sorted | 归并 / galloping（长度差 > 8 时用 galloping） | O(\|短\|·log\|长\|) |
| Sorted(大) | Bitmap | 先转位图 | O(N/64 + \|大\|) |
| 空 | 任意 | 直接返回空集，短路 | O(1) |

**形态转换阈值**：当密度超过 1/32（`Sorted.length * 32 > 条目总数`）或长度 > 4096 时，转成 `Bitmap`；反之保持数组。这让 `ext:pdf`（稀疏）留在数组形态，`ext:jpg size:>1mb` 的中间结果自动升为位图。

这一层是类型安全的最大收益点：执行器只认 `Ids`，不认字符串、不认查询树。

### 5.4 位图容器

```moonbit
pub struct Bitmap {
  containers : Array[Container?]   // 下标 = id >> 16（高 16 位分块）
  len : Int                        // 基数缓存
  // 可选：Array[UInt32] 记录非空块下标，避免遍历空洞
}

pub enum Container {
  Array(Array[UInt16])             // 升序，块内 id & 0xFFFF
  Bits(Array[UInt64])              // 固定 1024 字 = 65536 位
}
```

规则：

- 每个块覆盖 65536 个 id（`UInt16` 空间）。
- 基数 ≤ 4096 用 `Array` 容器，否则用 `Bits`（4096 是 Lucene/CRoaring 的经典阈值：数组的 4096×2 字节 = 位图的 8192 字节）。
- 块级运算：数组×数组走归并，数组×位图走探测，位图×位图走字运算。
- 增删后检查容器类型是否需要翻转；为空则把块置 `None`。

为什么不用"每个字段一张稠密位图"：100 万条目一张位图 125 KB，几百个扩展名就是几十 MB 的稀疏浪费。容器化后，`ext:mbt` 这种只有几十条的集合占几百字节。

### 5.5 低基数字段字典（位图）

适用：值的种类少，且查询是**等值或集合**匹配。

```moonbit
pub enum DictKey {
  Ext(Bytes)             // 扩展名，ASCII 小写
  Kind(EntryKind)        // 文件 / 文件夹
  Hidden                 // 隐藏文件
  Root(Int32)            // 来自哪个根
  TypeCat(TypeCategory)  // 文档/图片/音频/视频/压缩包/代码……
}

pub struct Dict {
  map : Map[DictKey, Ids]
  files_all : Ids        // 所有文件 id
  folders_all : Ids      // 所有文件夹 id
}
```

- `ext:` 只作用于文件；`Kind(Folder)` 与 `files_all` 互斥。
- `files_all` / `folders_all` 是类型域剪枝的物理载体：`ext:` 直接与 `files_all` 相交是冗余的，但 `folder:` 与 `ext:` 组合时能立刻得到空集。
- `TypeCat` 由内置宏（`pic:`、`doc:`……）使用，本质是若干 `Ext` 的并集，构建期直接物化，避免运行期反复求并。
- 隐藏文件单独一张位图，`--exclude-hidden` 在建索引时就不收录，运行期只用于 `hidden:` 查询。

> **反例警戒**：不要为 `parent:` 建"每个文件夹一张位图"。100 万文件夹 = 100 万个 `Bitmap` 对象，对象头开销比数据还大。高基数字段一律走 5.6。

### 5.6 范围字段（有序数组）

适用：值的种类多、查询是**范围或精确值**。

```moonbit
pub struct RangeIndex {
  values : Array[Int64]      // 升序；相同值按 id 升序
  ids : Array[EntryId]       // 与 values 一一对应
}

pub fn RangeIndex::range(self : RangeIndex, lo : Int64, hi : Int64) -> Ids   // 半开 [lo, hi)
pub fn RangeIndex::equal(self : RangeIndex, v : Int64) -> Ids
```

字段与存储宽度：

| 字段 | 类型 | 宽度 | 默认 | 备注 |
| --- | --- | --- | --- | --- |
| `size` | Int64 | 8 + 4 | ✓ | 文件字节数；文件夹为子树总和 |
| `mtime` | Int32 | 4 + 4 | ✓ | Unix 秒 |
| `depth` | UInt16 | 2 + 4 | ✓ | 根为 0 |
| `childcount` | UInt32 | 4 + 4 | ✓ | 仅文件夹 |
| `parent` | FolderId | 4 + 4 | ✓ | 高基数等值字段，放这里而不是字典 |
| `childfilecount` | UInt32 | 4 + 4 | — | `--fast-fields` 开启；未建时该字段退化为扫描 |
| `childfoldercount` | UInt32 | 4 + 4 | — | 同上 |

默认构建 5 个范围索引（`size`、`mtime`、`depth`、`childcount`、`parent`），这是体积与覆盖面的折中；另外两个字段很少被查询，开启后体积只增加约 8 MB/100 万条目。

要点：

- **`parent:` 用范围索引**（等值查询 = 二分到区间），不能用位图，理由见 5.5 的警戒。
- `parent` 索引不需要比较排序：按父 id 做一次计数排序（桶 = 文件夹 id）即可，O(n)。
- 其余字段需要一次真实排序。为控制启动时间与内存峰值，`size` / `mtime` 启动即加载，`depth` / `childcount` 首次使用时从 DB 切片加载（`--fast-fields` 可改为启动即加载）。
- 范围查询结果是 `Ids::Sorted`（区间切片），与位图相交时按 5.3 的策略选择。

内存代价：5 个字段全量常驻约 10 字节 × N。100 万条目约 10 MB/字段，可接受；`--stats` 会打印每个结构的实际占用。

### 5.7 trigram 倒排（子串）

适用：普通子串查询（`report`、`发票` 的 ASCII 情况）。

构建：

1. 取名字的原始字节（不含路径）。
2. 折叠 ASCII 大写为小写（**只折叠 ASCII**，非 ASCII 字节原样保留）。
3. 长度 ≥ 3 时，对每个起点取 3 字节，打包成 `UInt32` 键（24 位）。
4. 键 → 追加 `EntryId`；所有 posting 最终升序（构建期先按"键, id"排序或分桶后排序）。
5. 长度 < 3 的名字进一个 `short_names` 列表（少量，用于短查询退化）。

```moonbit
pub struct TrigramIndex {
  map : Map[UInt32, PostingList]
  block : Buf                          // 构建期写缓冲
}

pub struct PostingList {
  ids : Array[Int32]                   // 升序
  // 磁盘上为 delta-varint；内存中保持定长，便于二分与 galloping
}
```

查询：

```text
1. 把 needle 折叠为 ASCII 小写，提取全部 trigram 键
2. 取下对应 posting，按长度升序（最短的最有选择性）
3. 取前 k 个（k = 3，或长度 < 3 个时全取）做交集，得到候选集
4. 对候选集逐个执行真正的字节子串匹配（Verify）
```

降级路径（必须显式记录在 `--explain` 里）：

| 情况 | 处理 |
| --- | --- |
| needle < 3 字节 | 无法用 trigram：对 `order_name` 做全量扫描（仍可用其他字段的集合先收窄） |
| needle 含非 ASCII 字节 | trigram 仍可用（按字节切），但大小写折叠只覆盖 ASCII；大小写不敏感的非 ASCII 查询退化为扫描 |
| 查询带 `/`（自动改路径搜索）或 `path:` | v1 不建路径 trigram，退化为对候选集做路径验证；若候选集为空则全扫 |
| posting 基数 > 20% N | 视为 stop-gram，查询时跳过（它过滤不掉任何东西） |

正确性性质（必须写成测试）：**trigram 过滤后的集合必须是线性扫描结果的超集**。即不存在漏报，只可能有误报，误报由 Verify 消除。

一句话对比：上游对 100 万个名字做 100 万次 `strstr`；本项目做 3 次 posting 交集（几千到几万个 id），再对几十到几百个候选做 `strstr`。

### 5.8 查询编译与计划

#### 5.8.1 静态分析

```moonbit
pub enum Domain { FilesOnly; FoldersOnly; Both; Never }

pub struct Analysis {
  domain : Domain
  indexable : Bool        // 是否全部能走索引
  est : Int64             // 基数估计
  needs_path : Bool
  needs_unicode : Bool
}
```

`Domain` 推导：

- `ext:` / `file:` → FilesOnly；`childcount` / `empty:` / `folder:` → FoldersOnly。
- `And(a,b)` → 交集（可能变 Never）；`Or(a,b)` → 并集；`Not(_)` → Both。
- `Never` → 直接返回空集，不碰索引。

#### 5.8.2 编译

```text
Query
  ├─ Term(Ext(list))        → Const(union(dict.ext[each]))  ∧ files_all
  ├─ Term(Kind(Folder))     → Const(folders_all)
  ├─ Term(Size(cmp))        → Const(ranges.size.range(...))
  ├─ Term(Plain(needle))    → Trigram(plan) 或 Scan(AsciiSubstring)
  ├─ Term(Glob(p))          → Scan(Glob)
  ├─ Term(Regex(p))         → Scan(Regex)
  ├─ Term(Parent(path))     → Const(ranges.parent.equal(lookup(path)))
  └─ And/Or/Not             → 对应算子
```

`Expr` 与 `Query` 分离的理由：`Query` 是用户语义，`Expr` 是可优化、可解释、可对拍的执行计划。`--explain` 直接打印 `Expr` 树。

#### 5.8.3 优化

1. **常量折叠**：`And(Const(空), x)` → `Const(空)`；`Or(Const(空), x)` → `x`。
2. **类型域剪枝**：`And(Const(files_all), Const(folders_all))` → 空。
3. **按基数重排 `And`**：先求估计基数小的子树，让交集尽早变空。
4. **`Or` 的顺序**不改变代价，但影响短路，按估计基数升序。
5. **谓词下推**：把 `Scan` 从 `And` 里提出来，变成"先算可索引部分，再对候选集过滤"（见 5.9）。这是本项目性能的关键一步：glob/regex 从"全表匹配"变成"候选集匹配"。

基数估计规则：

| 节点 | 估计 |
| --- | --- |
| `Const(Bitmap)` | `bitmap.len`（精确） |
| `Const(Sorted)` | `array.length`（精确） |
| `Trigram` | 参与交集的 posting 最短长度 |
| `Scan` | 候选集大小（若已下推），否则 N |
| `And` | `min(a,b)` |
| `Or` | `min(N, a+b)` |
| `Not` | `N - a` |

### 5.9 执行、顺序与提前停止

#### 5.9.1 求值

```moonbit
fn eval(expr : Expr, ctx : ExecCtx) -> Ids
```

- `And`：先求小的一侧，再求另一侧；若先求结果为空，直接短路（不求另一侧）。
- `Or`：两侧都要算，最后求并。
- `Not`：`difference(universe, x)`，`universe` 是该 `Domain` 对应的全集（`files_all` / `folders_all` / 两者之并）。
- `Trigram`：posting 交集 → `Ids::Sorted` → `filter(Verify)`。
- `Scan`：对传入的候选集（或全集）做 `filter(pred)`。

`--count`：`eval(...).cardinality()`，不生成任何输出。

#### 5.9.2 恢复顺序

集合运算不保序。输出顺序由**规范顺序 + membership** 决定：

```text
for id in order_name.files (或 .folders, 或两者归并):
    if matched.contains(id):
        emit(id)
        if emitted == limit: return
```

- membership 是两次数组下标 + 一次位运算（或一次二分），百万次约 1–3 ms。
- 保留流式与提前停止：命中 20 条就停，代价与命中位置有关，与总命中数无关。
- `--sort name`（默认）零成本：规范顺序就是 name+path 自然序。
- `--sort size|mtime|ext|type`：收集匹配 id → 排序 → 取前 N。结果集通常远小于全量；超大结果集用固定大小堆做 top-K。
- `--reverse`：反向迭代规范顺序，membership 检查不变。
- `--folders-first`：先遍历 folders 再遍历 files；默认两者按同一比较器归并。

#### 5.9.3 两套引擎的对拍接口

```moonbit
pub fn exec_indexed(store : Store, q : Query) -> Ids     // 位图引擎
pub fn exec_scan(store : Store, q : Query) -> Ids        // 线性扫描引擎
```

`exec_scan` 直接遍历 `order_name`，对每个条目用 5.11 的谓词求值，得到同样的 id 集合。它承担：

- `--live`（不读索引，直接扫目录）；
- `--engine scan`（调试与基准对照）；
- 全部测试的对拍 oracle。

两个函数**必须共用**同一套词法、语法、字段解析、谓词实现，只在"怎么得到候选集"上分叉。这样对拍才有意义。

### 5.10 查询语言

#### 5.10.1 词法

```moonbit
pub enum Token {
  Word(String)
  Field(String)        // name:
  FieldEmpty(String)   // name: 后没有值
  And; Or; Not
  Eq; Contains; Greater; GreaterEq; Smaller; SmallerEq
  LParen; RParen; Eos
}

struct Lexer {
  input : String
  mut pos : Int32        // UTF-16 code unit 索引
  mut peeked : Char?
}
```

规则：

- 跳过 ASCII 空白；`= : < <= > >= ! ( )` 是保留字符。
- `"..."` 引号内原样；`\` 转义下一个字符。
- `:` 后接空白/EOS → `FieldEmpty`，否则 `Field`。
- 只有大写的 `AND`/`OR`/`NOT` 是运算符；`and`/`or`/`not` 是普通搜索词。
- `&&` / `||` 等价于 `AND` / `OR`。

#### 5.10.2 语法

优先级 `NOT` > `AND` > `OR`，用优先级爬升直接产出 AST：

```moonbit
fn Parser::parse_expr(self : Parser, flags : Flags, min_prec : Int32) -> Query raise QueryError
```

隐式 AND：下一个 token 可以开始 primary（Word/Field/LParen/NOT），且上一个 token 结束了一个 primary（Word/Field/RParen）时，等价于遇到 `AND`。

必须保留的边界语义：

- 连续 NOT：统计个数，偶数抵消。
- 二元运算符后不是操作数：忽略该运算符。
- 左括号后连续的 AND/OR：丢弃。
- 右括号多于左括号：默认 `ParseError`（退出码 2）；`--compat` 下改为"匹配空集"。
- 空查询：`MatchAll`。
- `--regex`：整个查询作为一个正则 term，不做字段/布尔解析。

#### 5.10.3 修饰符作用域

修饰符是**前缀修饰符**，只作用于紧随其后的一个 term 或括号组，可链式组合：

```text
parse_primary(flags):
  Field(modifier) → parse_primary(apply(flags, modifier))
  LParen          → parse_expr(flags)，expect(RParen)
  Word            → parse_word(token, flags)
```

括号组内的修饰符不泄漏到组外。`--compat` 只影响错误恢复，不影响作用域。

#### 5.10.4 字段与宏

解析优先级：用户宏 → 修饰符 → 函数 → 未知字段（报错或 compat 下空集）。

宏展开：`{ name, query, flags }`；展开时用独立 `Lexer`/`Parser`，用 `Array[String]` 做循环检测；空 query 不产生 term。

内置宏：`app`、`archive`、`audio`、`doc`、`pic`、`video`。它们在构建期被物化为 `DictKey::TypeCat` 位图，运行期只是一次字典查找。

#### 5.10.5 数值、大小、日期

```moonbit
pub enum CmpOp { Equal; Greater; GreaterEq; Smaller; SmallerEq; Range }

pub struct Comparison {
  op : CmpOp
  lo : Int64
  hi : Int64   // 仅 Range，半开 [lo, hi)
}
```

- `field:value` → Equal；`field:=value` → Equal；`>`/`>=`/`<`/`<=` 对应比较。
- `field:a..b` → `[a,b)`；`..b` → `[0,b)`；`a..` → `[a,MAX)`；`a == b` 降级为 Equal。
- 大小单位 `k/K/kb/KB`、`m/M/mb/MB`、`g/G/gb/GB`、`t/T/tb/TB`，**1000 进制**；上界加 `unit - 50 - 1`，让 `size:1kb..2kb` 覆盖 1000–1999。
- 日期：显式格式（`YYYY[-MM[-DD[ HH[:MM[:SS]]]]]`、两位年）、`today`/`yesterday`、星期/月份常量、`last/this/past + 数字 + 单位`；本地时区；Equal 转 Range（`dm:january` = 整个一月）；范围半开。
- 日期运算优先用 `moonbitlang/x/time`；若与 `mktime` 的 DST 语义不一致，用 FFI 兜底。测试固定 `TZ`。

#### 5.10.6 自动大小写与自动路径

这两个行为是 **term 级**的：

- needle 含 `/` → 该 term 自动改为搜索完整路径。
- needle 含 Unicode 大写字母 → 该 term 自动改为大小写敏感。
- 命令行 `--case-sensitive` / `--search-path` 作为初始 flags，被 term 级行为叠加；显式 `case:` / `nocase:` / `path:` / `nopath:` 优先。

在构造 `Term` 时计算一次，写进 `Flags`；计划阶段据此决定 `needs_path` / `needs_unicode`。

### 5.11 验证谓词

索引负责"缩小候选集"，谓词负责"确认"。谓词必须与扫描引擎共用同一份实现。

```moonbit
pub struct MatchCtx {
  store : Store
  entry : EntryId
  kind : EntryKind
  path_buf : Buffer
  name_string : String?
  folded_name : String?
}
```

| 查询特征 | 谓词 |
| --- | --- |
| 全 ASCII、非正则、非通配 | `AsciiSubstring` / `AsciiExact`（Boyer–Moore–Horspool，needle ≤ 4 退化为朴素） |
| 含非 ASCII | `UnicodeSubstring` / `UnicodeExact`（decode + 折叠；v1 只折叠 ASCII） |
| 含 `*` / `?` | `Glob`（双指针 + 最近星号回溯；`?` 匹配一个 Unicode 标量） |
| `regex:` 或 `--regex` | `Regex`（`moonbitlang/core/regexp` 或 `moonbitlang/regexp`；不支持 lookaround/backref 时文档化） |
| `size` / `mtime` / `depth` / `child*` | `Numeric`（范围索引已处理，谓词仅用于扫描引擎） |
| `parent:` | `Parent`（父路径字节精确匹配） |
| `contenttype:` | `ContentType`（v1 用扩展名→MIME 表） |

要点：

- 名字始终先以 `BytesView` 访问；只有 Unicode/正则才 decode。
- 非法 UTF-8 名字：ASCII 谓词照常工作；Unicode 谓词视为不匹配；正则视为不匹配。
- 空 needle 匹配一切。
- 谓词的输入是**单个 id**，输出是 `Bool`；`Ids::filter` 负责遍历。

### 5.12 持久化

#### 5.12.1 设计目标

- 加载后**不需要重建任何索引**：直接恢复 `Store`、字典、范围数组、trigram postings。
- 名字前缀压缩；字节精确；可校验、可版本化、可拒绝损坏输入；原子写入。

#### 5.12.2 文件布局

```text
┌─────────────────────────────────────────────┐
│ Header (64 bytes, little-endian)            │
│  magic "MSDB" (4)                           │
│  major u16, minor u16                       │
│  endian u8, reserved[3]                     │
│  flags u32                                  │
│  created_at i64                             │
│  folder_count u32, file_count u32           │
│  root_count u32, exclude_count u32          │
│  dict_count u32, range_count u32            │
│  trigram_count u32, reserved u32            │
│  section_table_off u64, section_count u32   │
│  reserved u32                               │
├─────────────────────────────────────────────┤
│ Section Table: {kind u32, off u64, len u64} │
├─────────────────────────────────────────────┤
│ ROOTS       : 根路径、one_file_system 等     │
│ EXCLUDES    : 排除规则                       │
│ NAMES       : 前缀压缩的名字串               │
│ FOLDERS     : 固定记录                       │
│ FILES       : 固定记录                       │
│ ORDER       : 规范顺序（folder ids + file ids）│
│ DICT        : 字段字典（键 → 集合引用）      │
│ RANGES      : 范围数组（values + ids）       │
│ POSTINGS    : trigram → delta-varint ids     │
│ CHECKSUM    : SHA-256（元数据；--verify 全量）│
└─────────────────────────────────────────────┘
```

细节：

- 所有整数显式 little-endian；读取器逐字段 `read_u16/u32/i64`，不依赖宿主对齐。
- `NAMES` 使用 front coding：每条 `prefix_len u16`、`suffix_len u16`、`suffix bytes`；顺序 = folders（name 排序）→ files（name 排序）。
- `FOLDERS` 记录：`parent u32`（`0xFFFFFFFF` 为根）、`name_ref u32`、`flags u16`、`size i64`、`mtime i64`、`num_files u32`、`num_folders u32`。
- `FILES` 记录：`parent u32`、`name_ref u32`、`flags u16`、`size i64`、`mtime i64`。
- `ORDER`：先 `folder_count` 个 u32，再 `file_count` 个 u32；加载时校验 id 范围与单调性（按 name+path）。
- `DICT`：`key_count u32`；每个键 `kind u8`、`len u16`、`payload bytes`（`Ext` 是扩展名字节，`Root`/`TypeCat` 是 u32），后接 `Ids` 引用：`repr u8`（0=bitmap, 1=sorted）+ `len u32` + 数据。
  - Bitmap 序列化为容器流：`block_count u32`，每块 `block_idx u32`、`type u8`（0=array/1=bits）、`len u32`、数据。
- `POSTINGS`：`count u32`；每条 `key u32`（24 位 trigram）、`n u32`、`n` 个 delta-varint。
- `CHECKSUM`：默认只校验 header + section table + roots + excludes + 计数；`--verify` 校验全文件。用 `moonbitlang/x/crypto` 的 SHA-256（或 CRC32 提速）。
- 版本：主版本不兼容拒绝加载；次版本允许加载并跳过未知 section；每次格式变更更新 `docs/db-format.md` 与 golden 文件。

#### 5.12.3 原子写入与锁

1. 同目录创建 `index.msdb.tmp.<pid>`。
2. 写入、`sync`。
3. `rename` 覆盖旧文件（POSIX 原子）。
4. 失败时删除临时文件，保留旧 DB。
5. `index` 进程用 `.lock` 文件互斥；读进程不需要锁。

#### 5.12.4 加载与校验

- `BytesView` + `Reader { pos }` 顺序读取；每次读取做边界检查。
- 先校验 magic/version/endian/counts，再校验 section table 的 offset+len 不越界、不重叠。
- 读取 NAMES 时限制单条长度（u16）与总池大小；读取 postings 时限制总条数与单条长度，防止恶意文件导致 OOM。
- 读取集合引用时校验每个 id < 对应 count；`ORDER` 额外校验是排列（无重复）。
- 任何失败返回 `DbError`，不 `panic`。
- 用 quickcheck/模糊测试生成截断、随机翻转、超长长度字段的输入。

### 5.13 增量更新（延后，但结构已友好）

位图 + 追加式 id 对增量其实比"分块有序数组"更友好：

- 删除 = 清除若干位 + 从 postings 里移除；不需要移动数组。
- 新增 = 追加 id、置位、把 id 插入 posting（尾部追加 + 一次归并即可，不必块内插入）。
- 范围数组的插入需要有序插入（O(n) 移动），这是唯一不友好的部分。

因此 v1 仍做全量重建；未来若做监控，只需为范围数组准备分块结构，其余结构不用改。这一点是相对 v0.1 的额外收益。
---

## 6. MoonBit 语法优势映射

### 6.1 C 惯用法 → MoonBit 惯用法

| C / FSearch 惯用法 | MoonBit 替代 | 收益 |
| --- | --- | --- |
| `enum` + `void*` + 函数指针分派 | `enum Term` / `enum Expr` + `match` | 类型安全、穷尽检查、无非法状态 |
| `GNode` 二叉查询树 | 递归 `enum Query` | 无手工建树/释放/遍历 |
| `GList` 后缀列表 | 直接返回 `Query` | 少两份中间结构 |
| `char*` + `strlen` + `GString` | `StringView` / `BytesView` / `Buffer` | 零拷贝切片 |
| `NULL` / `gboolean` 返回值 | `Option[T]` / `Result[T,E]` / `raise` | 错误不可忽略 |
| 输出参数 + `goto fail` | 表达式返回值 + `defer`/`try` | 清理集中 |
| `malloc/free` + 引用计数 | 编译器管理 + 不可变数据 | 无泄漏/悬垂 |
| 位掩码 flags | `struct Flags` + `enum` | 可读、可组合 |
| `GHashTable` 宏表 | `Map[String, Macro]` | 标准容器 |
| `GPtrArray` 结果集 | `Ids`（`Bitmap` / `Sorted`） | 可序列化、可运算 |
| `pthread` / `GThreadPool` | 单线程 + 可选构建期并行 | 先正确后并行 |
| `PCRE2` 每线程 match data | 每查询一个 `MatchCtx` | 结构更清晰 |
| `GKeyFile` 配置 | `@json` + `FromJson` | 类型安全、易测试 |
| 手写位数组 | `Container` ADT + 块级运算 | 可测试、可选容器 |

### 6.2 代码示意

#### 6.2.1 集合求值

```moonbit
pub fn eval(expr : Expr, ctx : ExecCtx) -> Ids {
  match expr {
    Const(ids) => ids
    And(a, b) => {
      let left = eval(a, ctx)
      if left.cardinality() == 0 { return left }   // 短路
      left.intersect(eval(b, ctx))
    }
    Or(a, b) => eval(a, ctx).union(eval(b, ctx))
    Not(x) => ctx.universe().difference(eval(x, ctx))
    Trigram(p) => p.candidates(ctx).filter(fn(id) { p.verify(ctx, id) })
    Scan(pred) => ctx.candidates().filter(fn(id) { pred(ctx, id) })
  }
}
```

#### 6.2.2 位图块运算

```moonbit
fn Container::and(a : Container, b : Container) -> Container? {
  match (a, b) {
    (Array(xs), Array(ys)) => array_and(xs, ys)
    (Array(xs), Bits(words)) => array_probe(xs, words)
    (Bits(x), Bits(y)) => bits_and(x, y)
  }
}
```

#### 6.2.3 Lexer 的 peek/next

```moonbit
struct Lexer {
  input : String
  mut pos : Int32
  mut peeked : Char?
}

fn Lexer::peek(self : Lexer) -> Char? {
  match self.peeked {
    Some(c) => Some(c)
    None => self.input.get_char(self.pos)
  }
}
```

#### 6.2.4 CLI 入口

```moonbit
async fn main {
  let cmd = @argparse.Command(
    "moonsearch",
    about="Fast file search over a persistent inverted index",
    subcommands=[
      @argparse.Command("index", ...),
      @argparse.Command("update", ...),
      @argparse.Command("search", ...),
      @argparse.Command("count", ...),
      @argparse.Command("info", ...),
    ],
  )
  let matches = cmd.parse()
  match matches.subcommand {
    Some(("index", m)) => run_index(m)
    Some(("search", m)) => run_search(m)
    Some(("count", m)) => run_count(m)
    _ => println(cmd.render_help())
  }
}
```

---

## 7. CLI 设计

### 7.1 命令与参数

二进制名：`moonsearch`（可选别名 `ms`）。

```text
moonsearch <command> [options] [query...]

Commands:
  index    扫描根目录并写入索引数据库
  update   重新扫描配置的根目录（全量重建）
  search   查询索引（默认子命令）
  count    只输出匹配数量（直接取集合基数）
  info     显示索引统计（条目数、各字段基数、索引体积、构建耗时）
```

#### 7.1.1 通用选项

| 选项 | 说明 |
| --- | --- |
| `-D, --database <PATH>` | 数据库路径；默认 `$XDG_DATA_HOME/moonsearch/index.msdb` |
| `--config <PATH>` | 配置文件；默认 `$XDG_CONFIG_HOME/moonsearch/config.json` |
| `--no-config` | 不读配置文件 |
| `-v, --verbose` | 详细日志（扫描跳过项、耗时） |
| `-q, --quiet` | 只输出结果/错误 |
| `--stats` | 输出耗时、候选集大小、集合形态到 stderr |
| `--explain` | 输出执行计划（Expr 树 + 基数估计 + 降级原因）到 stderr |
| `-h, --help` / `-V, --version` | 帮助 / 版本 |

#### 7.1.2 `index` / `update`

| 选项 | 说明 |
| --- | --- |
| `-r, --root <PATH>` | 根目录，可重复 |
| `-x, --exclude <PATTERN>` | 排除规则，可重复；支持 `fixed:` / `glob:` / `regex:` 前缀 |
| `--exclude-scope <full_path\|basename>` | 默认 `full_path` |
| `--exclude-target <both\|files\|folders>` | 默认 `both` |
| `--exclude-hidden` | 排除以 `.` 开头的名字 |
| `--one-file-system` | 不跨文件系统 |
| `--no-default-excludes` | 不排除 `/proc`、`/sys` 等 |
| `--allow-nested-roots` | 允许嵌套根 |
| `--fast-fields <LIST>` | 启动时立即加载的范围索引，默认 `size,mtime`；其余字段首次使用时加载 |
| `--no-trigram` | 不建 trigram（子串查询退化为扫描，用于对照索引体积） |
| `--stats` | 打印构建各阶段耗时与各结构体积 |

#### 7.1.3 `search`

| 选项 | 说明 |
| --- | --- |
| `--type <any\|file\|folder>` | 类型过滤；等价于 `file:` / `folder:` |
| `-c, --case-sensitive` | 大小写敏感 |
| `-e, --exact` | 精确匹配（整名相等） |
| `-p, --search-path` | 在完整路径中搜索 |
| `-r, --regex` | 整个查询作为正则 |
| `--sort <name\|path\|size\|mtime\|ext\|type>` | 默认 `name` |
| `--reverse` | 降序 |
| `--folders-first` | 文件夹整体排在文件前 |
| `-n, --limit <N>` | 最多输出 N 条；0 = 不限 |
| `-0, --null` | 以 NUL 分隔输出 |
| `--json` | 每行一个 JSON 对象 |
| `--format <TEMPLATE>` | 自定义输出 |
| `--basename` | 只输出名字 |
| `--relative-to <DIR>` | 输出相对路径 |
| `--engine <bitmap\|scan>` | 引擎选择：默认 `bitmap`；`scan` 用于对照与调试 |
| `--live` | 不读索引，直接扫描 roots（等价于 `--engine scan` + 扫描器） |
| `--auto-index` | DB 不存在时先建索引 |
| `--compat` | 复刻上游的边界行为（见 5.10） |

查询参数：所有位置参数用单个空格连接；`--` 之后的参数也作为查询。

```bash
moonsearch search 'file: ext:pdf;epub size:>1mb'
moonsearch search -- 'ext:jpg path:/photos 2024'
moonsearch --sort size --reverse -n 20 'ext:mp4'
moonsearch count 'dm:lastweek ext:mp4'
```

`--live` 使用扫描引擎直接遍历 roots，边扫描边匹配，不写数据库；适合调试、临时目录与小范围搜索。

### 7.2 查询语法

完整语法见附录 C。摘录：

| 功能 | 语法 | 示例 | 走索引 |
| --- | --- | --- | --- |
| 隐式 AND | 空格 | `report pdf` | trigram |
| 显式 AND | `AND` / `&&` | `report && pdf` | trigram |
| OR | `OR` / `\|\|` | `pdf \|\| epub` | trigram |
| NOT | `NOT` / `!` | `!backup` | 位图差集 |
| 分组 | `( )` | `(pdf \|\| epub) !draft` | 视内容 |
| 引号 / 转义 | `"..."` / `\` | `"my folder"` | trigram |
| 大小写 | `case:` / `nocase:` | `case:README` | trigram |
| 精确 | `exact:` | `exact:Makefile` | trigram |
| 类型 | `file:` / `folder:` | `file: ext:pdf` | 位图 |
| 路径 | `path:` / `nopath:` | `path:/photos` | 降级扫描 |
| 正则 | `regex:` | `regex:"^IMG_[0-9]{4}\.jpg$"` | 降级扫描 |
| 扩展名 | `ext:` | `ext:jpg;png;webp` | 位图 |
| 大小 | `size:` | `size:>1mb`、`size:1kb..2mb` | 范围数组 |
| 修改时间 | `dm:` | `dm:lastweek`、`dm:2024-01` | 范围数组 |
| 深度 | `depth:` / `parents:` | `depth:<=3` | 范围数组 |
| 子项数 | `childcount:` 等 | `childfoldercount:1..5` | 范围数组 |
| 父目录 | `parent:` | `parent:/home/user` | 范围数组 |
| 空目录 | `empty:` | `empty:` | 范围数组 |
| 内容类型 | `contenttype:` | `contenttype:text` | 位图（扩展名 → MIME） |

**"走索引"这一列是产品的核心卖点，应直接印在 README 和 `--help` 里**：用户可以知道哪些查询是亚毫秒的，哪些会退化。

### 7.3 输出

默认：完整路径 + `\n`，文件系统原始字节尽量原样输出。

- `--null`：每条后输出 `\0`，便于 `xargs -0`。
- `--json`：JSON Lines。

```json
{"path":"/home/user/docs/report.pdf","name":"report.pdf","size":12345,"mtime":1712345678,"ext":"pdf","type":"document","kind":"file"}
```

- `--format` 占位符：`{path}` `{name}` `{dir}` `{size}` `{mtime}` `{ext}` `{type}` `{kind}`，支持 `\n` `\t` `\0`，不做 shell 求值。
- `--count`：只输出数字，来自 `Ids::cardinality()`。
- `--stats`：stderr 输出索引加载、候选集大小、集合形态、匹配耗时。
- 颜色：v1 不做；后续需要谓词返回 span。

退出码：

| 码 | 含义 |
| --- | --- |
| 0 | 至少一个匹配（或命令成功） |
| 1 | 无匹配 |
| 2 | 参数/查询/IO/DB 错误 |
| 130 | 被 SIGINT 中断 |

管道场景下游提前关闭（`| head`）会产生 EPIPE，应安静退出。

### 7.4 配置与环境变量

```json
{
  "database": "~/.local/share/moonsearch/index.msdb",
  "roots": [{"path": "/home/user", "one_file_system": false}],
  "exclude_hidden": false,
  "excludes": [
    {"pattern": "node_modules", "kind": "glob", "scope": "basename", "target": "folders"}
  ],
  "macros": {
    "code": "ext:rs;go;c;h;cpp;hpp;mbt;py;js;ts",
    "book": "ext:epub;mobi;azw3;pdf"
  },
  "search": {"sort": "name", "limit": 0, "folders_first": false},
  "engine": {"trigram": true, "fast_fields": ["size", "mtime"]}
}
```

- 路径展开：`~`、白名单环境变量（`$HOME`、`$XDG_*`），不做 shell 展开。
- 环境变量：`MOONSEARCH_DATABASE`、`MOONSEARCH_CONFIG`、`NO_COLOR`。
- XDG：数据 `~/.local/share/moonsearch/`，配置 `~/.config/moonsearch/`。

---

## 8. 兼容性矩阵

P0 = 必须具备；P1 = 后续步骤；P2 = 可选/未来。

| 功能 | 优先级 | 说明 |
| --- | --- | --- |
| 持久化索引 + 命令行查询 | P0 | 核心价值 |
| trigram 子串、大小写不敏感（ASCII） | P0 | 5.7 |
| `case:` / `nocase:` / `exact:` | P0 | |
| `file:` / `folder:` / `type:` | P0 | 位图 |
| AND / OR / NOT / 括号 / 隐式 AND | P0 | 集合代数 |
| `ext:` | P0 | 位图 |
| `size:` / `dm:` / `depth:` / `child*` / `parent:` / `empty:` | P0 | 范围数组 |
| `path:` / `nopath:` | P0 | 降级为候选集验证 |
| 通配符 `*` / `?` | P0 | 谓词，候选集下推 |
| 正则 | P0 | 谓词，候选集下推；语法子集 |
| 宏（内置 + 自定义） | P0 | 构建期物化 `TypeCat` |
| 包含/排除、隐藏文件、one-file-system | P0 | one-file-system 需 FFI |
| `--sort name` 零成本 | P0 | 规范顺序 |
| `--sort size/mtime/ext/type` | P0 | 结果集排序 + top-K |
| `--count` 取基数 | P0 | 位图 |
| DB 保存/加载/损坏检测 | P0 | |
| 两引擎对拍 | P0 | 测试要求，见 9.2 |
| Unicode casefold + NFD | P1 | 表驱动；v1 仅 ASCII |
| `contenttype:` 精确值（libmagic） | P1 | v1 用扩展名表 |
| PCRE2 兼容正则 | P2 | 可选 FFI |
| 路径 trigram（`path:` 也走索引） | P2 | 索引体积换延迟 |
| 增量监控（inotify / FSEvents） | P2 | 结构已友好，见 5.13 |
| GUI / 选择集 / 打开文件 | P2 | 非目标 |
| Windows | P2 | 非目标 |

---

## 9. 测试与验收

### 9.1 单元测试

| 模块 | 测试内容 |
| --- | --- |
| `util/size` | 所有单位、大小写、非法后缀、溢出、半开区间 |
| `util/time` | 显式格式、today/yesterday、星期/月、相对时间、DST、两位年份 |
| `util/extension` | 隐藏文件、尾点、多点、无点、大小写 |
| `util/cmp_paths` | 数字段、前导零、分隔符、非 ASCII |
| `ids/bitmap` | 容器切换（4096 阈值）、块边界、空块、popcount、序列化往返 |
| `ids/ops` | 四种形态组合的 `and`/`or`/`difference`，与朴素集合实现对照 |
| `index/range` | 区间边界（半开）、重复值、空区间 |
| `index/trigram` | 提取规则（<3、非 ASCII、重复片段）、posting 升序 |
| `query/lexer` | 引号、转义、字段空值、保留字符、连续 NOT |
| `query/parser` | 优先级、隐式 AND、括号、宏展开、修饰符作用域 |
| `query/compile` | 每个字段编译到预期 `Expr`；优化前后等价 |

### 9.2 两引擎对拍（本项目的核心测试）

```text
for fixture in 生成的目录树:
    store = build(fixture)
    for q in 查询语料:
        a = exec_indexed(store, parse(q))
        b = exec_scan(store, parse(q))
        assert set(a) == set(b)
        assert 按规范顺序展开(a) == 按规范顺序展开(b)
```

要点：

- 查询语料分三层：手写语义用例、随机生成的合法查询（quickcheck）、以及从 `--explain` 覆盖率反推的补漏用例。
- 任一不一致都是 P0 bug：要么索引漏报（正确性），要么谓词分叉（一致性）。
- 对拍要覆盖降级路径：`--no-trigram` 构建的索引、`needle < 3`、含非 ASCII、含 `/`。
- 用 `--engine scan` 跑同一份端到端 fixture，比对 stdout 字节级一致。

### 9.3 性质测试

- **无漏报性质**：trigram 候选集 ⊇ 线性扫描命中集。
- **集合代数性质**：`A∩(B∪C) = (A∩B)∪(A∩C)`；`A \ B = A ∩ ¬B`；位图与有序两种形态结果一致。
- **序列化性质**：任意 `Ids` 写出再读回，相等。
- **顺序性质**：同一查询在同一索引上的输出与遍历次数无关（多跑几次、打乱内部顺序）。
- **损坏输入**：随机截断/翻转字节，必须在有限时间内返回 `DbError`，不越界、不崩溃。

### 9.4 端到端

- 在临时目录生成夹具树（文件、目录、隐藏文件、符号链接、Unicode 名、非法 UTF-8 名、深层嵌套、大文件稀疏文件）。
- `index` → `search` / `count` / `info`，比较 stdout/stderr/退出码；golden 文件用 `moon test --update` 更新。
- 覆盖：`--limit`、`--reverse`、`--null`、`--json`、`--format`、`--count`、`--live`、`--engine scan`、损坏 DB、缺失 DB、无权限目录、EPIPE。

### 9.5 语义用例来源

上游的 `src/tests/test_query.c` 覆盖矩阵（大小写、通配符、正则、布尔、字段、宏、修饰符）是很好的**检查清单**。本项目按该清单重新编写等价用例，不复制其文本与代码；新增两类上游没有的用例：

- 索引正确性（trigram / 位图 / 范围）相关的边界；
- 降级路径（哪些查询走索引、哪些退化、退化后结果是否一致）。

### 9.6 验收清单

一个阶段可以交付，当且仅当：

1. `moon build --target native` 与 `moon test` 全绿，`moon fmt` 无 diff。
2. 新增公开 API 已在 `.mbti` 中稳定，且有文档注释。
3. 对拍测试通过（涉及查询的改动必须扩展语料）。
4. `--stats` 能打印新增结构的体积与耗时。
5. README 的"能力表"同步更新（哪些查询走索引）。

---

## 10. 性能目标与基准口径

### 10.1 目标

| 场景 | 条目数 | 目标 | 备注 |
| --- | --- | --- | --- |
| 扫描 + 建索引 | 100 万 | < 90 s | 含 trigram 提取与排序；阶段 B FFI 后重测 |
| DB 加载 | 100 万 | < 800 ms | 顺序读 + 无重建 |
| `ext:jpg`（纯位图） | 100 万 | < 1 ms | 一次字典查找 + 一次与 `files_all` 相交 |
| `ext:jpg size:>1mb`（位图 × 范围） | 100 万 | < 5 ms | 范围二分 + 混合交集 |
| `ext:jpg size:>1mb dm:lastweek` | 100 万 | < 8 ms | 三个集合 |
| `report`（trigram） | 100 万 | < 20 ms | 3 次 posting 交集 + 候选验证 |
| `report pdf`（两个 trigram 组） | 100 万 | < 40 ms | |
| `*.pdf`（glob，无索引） | 100 万 | < 120 ms | 候选集下推后 |
| `--count 'ext:mp4'` | 100 万 | < 1 ms | popcount |
| 空查询 + `-n 20` | 100 万 | < 1 ms | 规范顺序 + membership |
| 索引额外体积 | 100 万 | < 1.5× 名字池+条目 | 见 10.2 |
| 常驻内存 | 100 万 | < 400 MB | 含 postings 与位图 |

这些是工程目标，第一次基准后重新校准，最终数字写进 README。

### 10.2 体积预算

| 结构 | 100 万条目估算 | 说明 |
| --- | --- | --- |
| 名字池 | ~20 MB | 平均 15 字节/名 + 前缀压缩 |
| 条目数组 | ~40 MB | 文件夹 40B / 文件 32B |
| 规范顺序 | 8 MB | 两个 Int32 数组 |
| 范围索引（5 字段） | ~50 MB | ~10 B/条目/字段 |
| trigram postings | ~25 MB | ~13M 条，delta 后平均 2 B |
| 位图字典 | ~5 MB | 容器化，稀疏字段占用小 |
| **合计** | **~150 MB** | 相对"名字池 + 条目"（60 MB）额外约 1.5 倍 |

如果超出预算，按此顺序砍：`depth` / `childcount` 改为按需加载 → trigram 只索引长度 ≥ 5 的名字 → 范围数组用 delta 压缩 → 关闭 `--fast-fields` 的次要字段。

### 10.3 调优顺序

1. trigram 取最短 posting、跳过 stop-gram；
2. `And` 按基数重排 + 空集短路；
3. 谓词下推（先收候选集再验证）；
4. 位图容器阈值与块级运算；
5. 规范顺序输出的 membership 快路径（位图块索引缓存）；
6. 构建期并行（trigram 分片、范围排序）；
7. POSIX FFI 扫描；
8. 最后才考虑进程分片。

---

## 11. 施工步骤（S01–S14）

每一步都是可独立提交、可独立验收的产物。没有时间预估；完成一步进入下一步。除标注外，依赖前一步。

| # | 步骤 | 交付物 | 验收标准 |
| --- | --- | --- | --- |
| S01 | 工程骨架与 CLI 契约 | `moon.mod`（native）、包目录、`index/update/search/count/info` 的 `--help`、`--version`、退出码约定、CI | `moon build` / `moon test` 绿；`--help` 输出稳定，有 golden 测试 |
| S02 | 字节路径与名字池 | `core::NamePool`、`Entry`、`BytesView` 工具、自然排序 `cmp_paths` | 排序测试覆盖 `file2/file10`、`007/7`、非 ASCII、非法 UTF-8 字节；池不重复分配 |
| S03 | 扫描器与内存 Store | `platform`（async/fs 后端）、递归扫描、排除规则、后序统计、`index` 命令（仅内存） | 夹具目录扫描正确；符号链接/权限/one-file-system 行为有测试 |
| S04 | 查询词法与 AST | `query::lexer`、`query::parser`、`Query` ADT、修饰符作用域、宏展开 | 词法/语法单测全绿；错误位置与消息可断言 |
| S05 | 扫描引擎（基线 / oracle） | 谓词集合（ASCII 子串、glob、正则、数值、ext、parent）、`exec_scan`、`--engine scan`、`--live` | 全部语义用例在扫描引擎上通过；这是后续对拍的基准 |
| S06 | `Ids` 与位图容器 | `Ids` ADT、`Container`（array/bits）、块级 `and/or/andnot`、形态转换阈值、序列化 | 四种形态组合与朴素实现对照；容器切换阈值有边界测试 |
| S07 | 字典与位图字段 | `Dict`（ext/kind/hidden/root/type-cat）、`files_all`/`folders_all`、构建期物化 | `ext:`、`file:`、`folder:`、隐藏、宏的查询结果与扫描引擎一致 |
| S08 | 范围索引 | `RangeIndex`、5 个字段、`parent` 计数排序、区间二分、`--fast-fields` | 半开区间边界、重复值、空区间测试；与扫描引擎一致 |
| S09 | trigram 倒排 | 提取规则、posting 构建与排序、交集（归并 + galloping）、stop-gram、短词退化 | 「候选集 ⊇ 扫描结果」性质测试；`--no-trigram` 对照 |
| S10 | 查询编译与计划 | `compile`、`optimize`（折叠/剪枝/重排/下推）、基数估计、`--explain` | 每个字段编译结果可断言；优化前后结果等价；`--explain` 有 golden |
| S11 | 输出顺序与格式化 | 规范顺序 + membership、`--sort` 各键、top-K 堆、`--limit`、`--reverse`、`--null`/`--json`/`--format`、`count` | 输出与扫描引擎字节级一致；`-n 20` 在全量命中时仍提前停止 |
| S12 | 持久化 | MSDB v2 读写（含 DICT/RANGES/POSTINGS）、原子替换、校验、`info` | 100 万条目往返；加载后无需重建；截断/翻转字节不崩溃 |
| S13 | 对拍、性质测试与模糊测试 | 查询语料三层、对拍 runner、quickcheck 性质、损坏输入 fuzz | 对拍零不一致；fuzz 无 panic；CI 中可复现 |
| S14 | 基准、文档与演示 | 基准脚本与结果表、README（能力表 + 目标/实测）、`docs/db-format.md`、录屏 | 第 10 节目标逐项有实测数字；新人按 README 能跑通 |

依赖关系：

```text
S01 → S02 → S03 → S04 → S05 ─┬→ S06 → S07 → S08 → S09 ─┐
                              │                          ├→ S10 → S11 → S13 → S14
                              └──────────────────────────┘         ↑
                                                    S12 ────────────┘
```

说明：

- S05 刻意排在索引之前。**先把语义跑通再上索引**，否则你会在"结果不对"和"索引不对"之间来回猜。
- S06–S09 只增加"候选集来源"，不改变语义；每完成一个都可以立刻与 S05 对拍。
- S12 可以提前到 S11 之前：持久化不依赖输出层，早做能更早发现格式问题。
- S13 不是"最后补测试"，它依赖 S05 的 oracle 与 S10 的编译层；每次加新算子都要扩语料。

---

## 12. 风险与对策

| 风险 | 概率 | 影响 | 对策 |
| --- | --- | --- | --- |
| 索引体积超预算 | 中 | 中 | 容器化位图；trigram delta 压缩；次要范围索引按需加载；`--no-trigram` 对照 |
| trigram 构建太慢 | 中 | 中 | 分桶后排序而非全局排序；按名字长度跳过；构建期分片并行 |
| 短查询（<3 字节）退化严重 | 高 | 中 | 明确的降级路径 + `--explain` 提示；可选 1/2-gram 前缀索引（P2） |
| 两套引擎结果不一致 | 中 | 高 | 对拍作为 CI 门禁；两个引擎共用词法/语法/谓词，只分叉候选集 |
| 位图容器边界 bug | 中 | 高 | 与朴素 `Set` 对照；阈值边界用例；序列化往返测试 |
| 集合运算意外退化为 O(N) | 中 | 中 | `--stats` 打印形态与基数；对超大位图强制走位运算 |
| 结果无序导致排序成本 | 中 | 低 | 默认顺序零成本；其他键用 top-K 堆；超大结果集分页 |
| 目录/路径语义错误（根、`//`、非法 UTF-8） | 中 | 中 | 夹具覆盖；路径拼接单测；与 `find` 输出对照 |
| 数值/日期解析与上游不一致 | 中 | 低 | 表驱动测试；固定 `TZ`；`--compat` 开关 |
| DB 格式演进破坏兼容 | 中 | 中 | 主/次版本 + section table + golden + fuzz |
| 第 5 章设计在实现中被推翻 | 中 | 中 | S05 先跑通语义；S06 只加候选集；每个步骤都可回退 |
| MoonBit 生态 API 变动 | 中 | 低 | 固定依赖版本；`platform` 层隔离 |
| 灾难性正则回溯 | 低 | 中 | 限制 pattern 与输入长度；文档化 |
| 符号链接环 | 低 | 低 | 默认不跟随；未来用 `(dev, ino)` 去重 |
| 文件夹 size 溢出 | 低 | 低 | checked add + 饱和 + 告警 |

---

## 13. 许可证与合规

- 本项目是**独立实现**：不复制 FSearch 的代码、注释、常量表与测试文本；只依据公开文档与行为观察实现语义。
- `README` 明确写出：受 FSearch 与 Everything 启发，执行引擎为独立的倒排 + 位图设计。
- 许可证保持 **Apache-2.0**。
- 依赖：`moonbitlang/core`、`moonbitlang/x`、`moonbitlang/async` 均为 Apache-2.0（实施时确认具体版本）。
- 若引入 Unicode 数据表（CaseFolding.txt / UnicodeData.txt）：Unicode License，生成文件头部加 notice，并新增 `THIRD_PARTY_NOTICES.md`。
- 不引入 PCRE2、ICU 这类 C 依赖；若未来引入，单独记录其许可证。

> 本节不是法律意见；正式发布前由项目所有者确认。

---

## 14. 待确认问题

1. **索引体积上限**：150 MB / 100 万条目是否可接受？如果不可接受，优先牺牲 `depth`/`childcount` 范围索引还是 trigram 覆盖率？
2. **默认保留哪个范围索引**：`--fast-fields` 默认 `size,mtime`，其余按需构建，是否可以？
3. **trigram 覆盖范围**：只索引名字（推荐），还是也索引路径（体积翻倍，但 `path:` 与带 `/` 的查询能走索引）？
4. **非 ASCII 子串**：v1 接受"退化为扫描"，还是必须先把 Unicode 折叠表做掉？
5. **错误行为兼容程度**：无匹配右括号、未知字段、非法数字，是报错退出还是 `--compat` 下匹配空集？
6. **默认输出顺序**：files/folders 归并（推荐）还是 folders-first（上游 UI 行为）？
7. **正则引擎**：接受 `core`/`moonbitlang/regexp` 的语法子集（无 lookaround/backref），还是必须 PCRE2？
8. **`contenttype:`**：v1 用扩展名→MIME 表是否足够？

---

## 附录 A：上游模块清单

| 文件 | 行数 | 上游角色 | 本项目处理 |
| --- | --- | --- | --- |
| `fsearch_array.c/h` | 814 | 动态数组、排序、二分 | MoonBit `Array` + `sort_by` |
| `fsearch_database_entry.c/h` | 1075 | 条目、父链、比较器 | `core::Entry` |
| `fsearch_database_chunked_array.c/h` | 655 | 分块有序数组 | **不需要**；位图更易增量（5.13） |
| `fsearch_database.c/h` | 1504 | 数据库门面、重扫、配置 | `index` + `config` |
| `fsearch_database_index.c/h` | 1175 | 单根索引、扫描、事件 | `index::scanner`（去掉监控） |
| `fsearch_database_index_store.c/h` | 1546 | 多根合并、快速索引、搜索 | `index::store` + `exec`（执行模型替换） |
| `fsearch_database_file.c/h` | 1431 | 二进制持久化 | `index::db`（新格式，含 postings/bitmaps） |
| `fsearch_database_scan.c/h` | 319 | 递归扫描 | `index::scanner` |
| `fsearch_database_sort.c/h` | 257 | 排序链 | **只保留比较器语义**，不再预排序 5 组 |
| `fsearch_database_search_view.c/h` | 383 | 结果视图/选择 | 不迁移 |
| `fsearch_database_work.c/h` | 464 | 工作队列 | 不迁移 |
| `fsearch_database_include*.c/h` | ~400 | 根目录配置 | `config::Root` |
| `fsearch_database_exclude*.c/h` | ~500 | 排除规则 | `config::ExcludeRule` |
| `fsearch_query.c/h` | 220 | 查询门面 | `query::Query` |
| `fsearch_query_lexer.c/h` | 209 | 词法 | `query::lexer` |
| `fsearch_query_parser.c/h` | 772 | 语法 | `query::parser` |
| `fsearch_query_node.c/h` | 447 | 查询节点 | `query::Term` / `exec::Expr` |
| `fsearch_query_tree.c/h` | 302 | 后缀 → 树 | 不需要（直接 AST） |
| `fsearch_query_matchers.c/h` | 341 | 匹配器 | `exec::predicate`（验证用） |
| `fsearch_query_match_data.c/h` | 261 | 匹配上下文 | `MatchCtx` |
| `fsearch_string_utils.c/h` | 181 | 字符串工具 | `util::string` |
| `fsearch_size_utils.c/h` | 80 | 大小解析 | `util::size` |
| `fsearch_time_utils.c/h` | 555 | 日期解析 | `util::time` |
| `fsearch_file_utils.c/h` | 849 | 路径比较/文件信息 | `util::path` + `platform` |
| `fsearch_utf.c/h` | ~208 | ICU 折叠/规范化 | `unicode`（P1，表驱动） |
| `fsearch_filter*.c/h` | ~300 | 过滤器/宏 | `config::Macro` + `DictKey::TypeCat` |
| GUI 文件 | ~12,000 | GTK | 不迁移 |

---

## 附录 B：数据库格式草案（字段级）

```text
Header（固定 64 字节，小端）
  magic                 4 bytes  "MSDB"
  version_major         u16      = 2
  version_minor         u16      = 0
  endian                u8       1 = little
  reserved              u8[3]
  flags                 u32
  created_at            i64      Unix 秒
  folder_count          u32
  file_count            u32
  root_count            u32
  exclude_count         u32
  dict_count            u32
  range_count           u32
  trigram_count         u32
  reserved              u32
  section_table_off     u64
  section_count         u32
  reserved              u32

SectionTableEntry
  kind                  u32      Root/Exclude/Names/Folders/Files/Order/Dict/Ranges/Postings/Checksum
  offset                u64
  length                u64

Root
  path_len              u32
  path                  bytes    UTF-8 绝对路径
  flags                 u32      bit0 one_file_system
  last_scan_time        i64
  scan_duration_ms      u32

Exclude
  kind                  u8       Fixed/Glob/Regex
  scope                 u8       FullPath/Basename
  target                u8       Both/Files/Folders
  active                u8
  pattern_len           u32
  pattern               bytes    UTF-8

Names
  for each name (folders then files):
    prefix_len          u16
    suffix_len          u16
    suffix              bytes

FolderRecord
  parent                u32      0xFFFFFFFF = 根
  name_ref              u32
  flags                 u16
  size                  i64
  mtime                 i64
  num_files             u32
  num_folders           u32

FileRecord
  parent                u32
  name_ref              u32
  flags                 u16
  size                  i64
  mtime                 i64

Order
  folder_ids            u32[folder_count]
  file_ids              u32[file_count]

IdsRef
  repr                  u8       0 = Bitmap, 1 = Sorted
  len                   u32      元素数（Bitmap 为基数）
  data                  ---
    Bitmap:  block_count u32, 每块 { block_idx u32, type u8, len u32, payload }
             type 0 = Array（u16 升序）, type 1 = Bits（1024 × u64）
    Sorted:  delta-varint ids

Dict
  key_count             u32
  每个键:
    kind                u8       Ext/Kind/Hidden/Root/TypeCat
    payload_len         u16
    payload             bytes
    ids                 IdsRef

Ranges
  field_count           u32
  每个字段:
    field               u8       Size/MTime/Depth/ChildCount/ChildFile/ChildFolder/Parent
    n                   u32
    values              n × width（按字段宽度）
    ids                 n × u32

Postings
  count                 u32
  每条:
    key                 u32      24 位 trigram
    n                   u32
    ids                 n × delta-varint（首个为绝对值）

Checksum
  sha256                u8[32]   默认校验元数据；--verify 全量
```

---

## 附录 C：查询语法速查

```text
运算符
  空格 / AND / &&     隐式/显式 AND
  OR / ||             OR
  NOT / !             NOT
  ( )                 分组

转义
  "..."               引号内原样
  \x                  转义下一个字符

修饰符
  case:               大小写敏感
  nocase:             大小写不敏感
  exact:              整名精确匹配
  file: / files:      仅文件
  folder: / folders:  仅文件夹
  path:               搜索完整路径
  nopath:             只搜索名字
  regex:              正则
  noregex:            关闭正则

函数
  ext:<list>          扩展名，分号分隔；空值匹配无扩展名文件
  size:<size>         大小；支持 k/m/g/t、比较、范围
  dm:<date>           修改时间
  depth:<num>         目录深度
  childcount:<num>    直接子项总数
  childfilecount:<num>
  childfoldercount:<num>
  parent:<path>       父目录精确匹配
  empty:              空文件夹
  contenttype:<str>   内容类型（v1 基于扩展名）

数值
  field:value         = value
  field:=value        = value
  field:>value        > value
  field:>=value       >= value
  field:<value        < value
  field:<=value       <= value
  field:a..b          [a, b)
  field:..b           [0, b)
  field:a..           [a, MAX)

日期
  today, yesterday
  mon..sun / monday..sunday
  jan..dec / january..december
  YYYY, YYYY-MM, YYYY-MM-DD, "YYYY-MM-DD HH", "YYYY-MM-DD HH:MM", "YYYY-MM-DD HH:MM:SS"
  last/this/past + <number> + <unit>
  lastfiveweeks..yesterday

内置宏
  app, archive, audio, doc, pic, video
```

---

## 附录 D：参考资料

- FSearch 仓库：<https://github.com/cboxdoerfer/fsearch>
- FSearch 搜索语法帮助：`help/C/search_syntax*.page`
- Lucene 的倒排与 postings 设计（概念参考）：`org.apache.lucene.index`
- Roaring Bitmap 论文与 CRoaring 实现（容器与阈值参考）
- SQLite 文件格式文档（如果后续做 `moonlite` 类扩展）
- MoonBit 文档：<https://docs.moonbitlang.com>
- MoonBit 标准库：`moonbitlang/core`（`argparse`、`path`、`string`、`buffer`、`encoding/utf8`、`json`）
- `moonbitlang/x`：`time`、`unicode`、`crypto`、`path`
- `moonbitlang/async`：`fs`、`process`、`stdio`、`signal`
- Unicode 数据：<https://www.unicode.org/Public/UCD/latest/ucd/>
- GNU `strverscmp` 语义

---

## 附录 E：建议的下一步

1. 确认第 14 节的 8 个问题，尤其第 1、3、4 项（体积、trigram 覆盖、非 ASCII）。
2. 执行 **S01**：把模板改成 native，建包目录，让 `--help` 与退出码先稳定下来，并立刻提交。
3. 执行 **S02–S03**：名字池与扫描器，用夹具目录跑通 `index`（内存版）。
4. 执行 **S04–S05**：查询语义 + 扫描引擎。**在没有任何索引的情况下，所有语义用例必须先绿。**
5. 之后按 S06 → S14 推进；每完成一个索引结构，立刻接上 S05 的对拍。
6. 不要在 S10 之前动手写持久化格式；格式要等 `Expr` 定型后再定。

---

**文档结束。**

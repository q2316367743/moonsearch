# exec — 查询执行：扫描引擎、编译计划与位图执行器

`src/exec` 是 S05 建立、S07–S10 扩展的查询执行层。它包含两套引擎：

- **扫描引擎**：逐条遍历规范顺序，对每个条目求值；它是 S05 的基线，也是 S06 之后
  所有索引结构的对拍 oracle；
- **位图引擎**（S10）：把 `Query` 编译成只认 id 集合的 `Expr`，在 `@index.Index`
  的候选集上做集合代数。

两套引擎共用同一套词法、语法、字段解析与逐条目谓词，只在“怎么得到候选集”上分叉。
本模块不拥有索引结构，只读取 `core.Store`、`query.Query` 与 `index.Index`。

## 文件

| 文件 | 内容 |
| --- | --- |
| `compile.mbt` | `Query` → `ScanExpr`、名字匹配器、日期解析、扫描计划文本 |
| `predicate.mbt` | 逐条目谓词：名字、扩展名、类型、可见性、数值、父路径 |
| `content_type.mbt` | 扩展名 → MIME 表与 `contenttype:` |
| `scan.mbt` | `exec_scan` / `exec_count` / `ScanOptions` |
| `plan.mbt` | S10：`Expr`、类型域、编译、优化、基数估计、位图求值、`--explain` |
| `dict_compat_test.mbt` | S07 字典与扫描引擎的对拍 |
| `range_compat_test.mbt` | S08 范围索引与扫描引擎的对拍 |
| `trigram_compat_test.mbt` | S09 trigram 候选集 ⊇ 扫描结果的性质测试 |
| `plan_test.mbt` | S10：逐字段编译形状、优化前后等价、全语料对拍、explain golden |

## 编译

```text
Query
  → compile_term: flags → kind/visibility 过滤、regex 只编译一次、日期解析成绝对秒
  → ScanExpr { All, None, Test, And, Or, Not }
```

常量折叠与类型域剪枝发生在 `compile_query`：`None` 吸收 AND，`All` 吸收 OR，`Not`
互补。求值按 AND/OR 短路，`--limit` 在收集到足够条目时停止。

## 谓词

| 叶子 | 规则 |
| --- | --- |
| `Name` | 子串 / 整名 / glob / regex；`path:` 时对完整路径匹配 |
| `Kind` | `file:` / `folder:` |
| `Visibility` | `hidden:` / `nohidden:`，读取 `ENTRY_FLAG_HIDDEN` |
| `Category` | 内置分类的扩展名列表，仅文件 |
| `Extensions` | `ext:` 列表，仅文件；扩展名规则来自 `util.extension_of` |
| `Size` / `Modified` / `Depth` / `Child*` | 数值与日期比较 |
| `Parent` | 父目录完整路径字节相等 |
| `Empty` | 文件夹直接子项数为 0 |
| `ContentType` | 扩展名对应 MIME 类型 |

可见性检查与 `file:` / `folder:` 一样是 term 级过滤：一个 term 的 flags 可以同时带类型
和可见性，`file:hidden:doc:` 三个条件同时生效。

## 与字典共享的规则

S07 的对拍要求两套引擎在 `ext:`、`file:`、`folder:`、`hidden:`、内置宏上逐条一致，因此：

- `util.extension_of` 是唯一的扩展名提取实现，扫描谓词与 `index.Dict` 都调用它；
- `util.TypeCategory::extensions` 是唯一的分类扩展名来源，扫描谓词的 `Category` 与字典
  的分类集合都从它生成；
- 隐藏判定都读 `Entry::is_hidden()`（同一个 `ENTRY_FLAG_HIDDEN`）。

`exec/dict_compat_test.mbt` 把字典集合展开成路径，与 `exec_scan` 的结果排序后比较，
覆盖 `file:`、`folder:`、`hidden:`、`nohidden:`、`file:hidden:`、`folder:hidden:`、
`ext:`、空扩展名以及全部内置宏。

## 与范围索引共享的规则

S08 的 `index.Ranges` 必须与扫描谓词对同一字段给出同一集合。`exec/range_compat_test.mbt`
负责对拍，映射关系即 S10 的编译规则：

| 比较 | `RangeIndex` 方法 |
| --- | --- |
| `= v` | `equal(v)` |
| `> v` | `greater_than(v)` |
| `>= v` | `at_least(v)` |
| `< v` | `less_than(v)` |
| `<= v` | `at_most(v)` |
| `a..b`（半开） | `range(a, b)` |

需要保持的语义：

- `size` / `dm` / `depth` 同时作用于文件与文件夹；`childcount` 只作用于文件夹，
  `empty:` 等价于文件夹的 `childcount` 为 0；
- `depth` 的根为 0，文件等于父目录深度加 1；
- `parent:` 只匹配有父目录的条目，根永不匹配；路径按字节精确比较，尾斜杠在编译期
  归一化；
- `dm:` 的日历解析仍在 `compile.mbt` 完成，索引只接收解析后的绝对秒区间。

## 与 trigram 倒排共享的规则

S09 的 `index.TrigramIndex` 只负责把普通名字子串变成候选集，语义仍由扫描引擎的
`match_name` 定义。`exec/trigram_compat_test.mbt` 用性质测试固定这条边界：

```text
对每个名字的全部长度 ≥ 3 子串 s：
  scan(name_query(s))            ⊆ candidates(lookup(s))
  scan(case:name_query(s))       ⊆ candidates(lookup(s))
  scan(exact:name_query(s))      ⊆ candidates(lookup(s))
```

- 交集只取最短的若干个 posting，所以候选集是超集；候选必须再经过
  `util.find_bytes_with` / `eq_bytes` 等真正的字节比较，不能直接当作结果。
- 候选集为空（缺失 trigram）时，扫描结果也必须为空。
- needle < 3 字节、所有 trigram 都是 stop-gram 时 `candidates()` 返回 `None`，
  调用方对全集求值；这与“短名字没有 posting”一致，因为长度 < 3 的名字也不可能
  包含长度 ≥ 3 的 needle。
- 大小写折叠只会让候选变多，所以 `case:` 查询可以复用同一候选集。
- **不能**直接用于 `path:`、glob 与 regex：`path:` 的匹配可能只出现在父目录名中，
  glob/regex 的匹配文本也不一定是连续子串。S10 的编译层让这些 term 变成 `Scan`
  叶子（或成为其他字段候选集上的 `Filter`），不把它们当作 trigram 子串。

## 索引查询编译与计划（S10）

`plan.mbt` 把 `Query` 编译成 `Expr`，在 `index.Index` 上求值：

```text
Query
  → compile_plan：类型域剪枝 + 叶子选择（Const / Trigram / Scan）
  → optimize_plan：常量折叠、按基数重排、谓词下推
  → evaluate_plan：Ids 交、并、差
```

### `Expr`

| 节点 | 含义 |
| --- | --- |
| `Const(ConstLeaf)` | 字典或范围索引预先算好的集合；`label` 保留原始 term 文本 |
| `Trigram(TrigramLeaf)` | posting 候选集，仍要对每个候选执行字节级验证 |
| `Scan(ScanLeaf)` | 没有索引支撑的谓词，在全集上求值，带稳定降级原因 |
| `Filter(ScanLeaf, Expr)` | 优化器下推的谓词，只验证源集合的候选 |
| `And` / `Or` / `Not` | 集合交、并、全集差 |

`ConstLeaf` / `TrigramLeaf` / `ScanLeaf` 的字段都是私有的，外部只能通过
`ids()`、`label()`、`candidates()`、`key_count()`、`needle()`、`reason()` 读取；
`Expr` 的变体是公开的，测试与后续输出层可以直接模式匹配。

### 编译规则

| 查询 | 计划 |
| --- | --- |
| `MatchAll` / `MatchNone` | `Const(dict.all())` / `Const(empty)` |
| `file:` / `folder:` / `hidden:` / `nohidden:` | 字典集合 |
| `ext:` / 内置分类 | 扩展名桶 / 物化分类集合 |
| `size:` / `depth:` / `childcount:` / `dm:` / `parent:` / `empty:` | 范围索引切片 |
| 普通名字子串 / `exact:`，needle ≥ 3 字节 | `Trigram` |
| `*.pdf` / `regex:` / `path:` | `Scan`，原因 `glob` / `regex` / `path` |
| needle < 3 字节 | `Scan`，原因 `short-needle` |
| 全部 trigram 为 stop-gram | `Scan`，原因 `stop-grams` |
| 未建 trigram | `Scan`，原因 `no-trigram` |
| `childfilecount:` / `childfoldercount:` / `contenttype:` | `Scan`，字段名即原因 |

- term 级 `file:` / `folder:` / `hidden:` / `nohidden:` 在编译期与叶子集合相交；
  `Trigram` 候选也先收窄，再逐条验证。
- 必需 trigram 缺失时直接得到 `Const(empty)`：任何命中都必须包含该 trigram，无需验证。
- 候选收窄后为空时同样退化为 `Const(empty)`。
- `exact:` 可以复用子串候选：整名匹配是子串匹配的子集；`case:` 也可以复用，因为
  ASCII 折叠只会放大候选集。

### 类型域

`Domain { FilesOnly, FoldersOnly, Both, Never }`：

- `ext:` / `contenttype:` / 内置分类 → `FilesOnly`；
- `childcount` / `childfilecount` / `childfoldercount` / `empty:` → `FoldersOnly`；
- `file:` / `folder:` 修饰符与 body 求交；
- `And` 求交、`Or` 求并、`Not` 恒为 `Both`（与扫描引擎一致：补集在全集上）；
- `Never` 在编译期直接变成 `Const(empty)`，例如 `file:*.pdf folder:`。

### 优化

1. **常量折叠**：相邻 `Const` 合并；`And(空, x)` → 空；`Or(全集, x)` → 全集；
   `Not(Const)` 变成常量补集；双重 `Not` 抵消。
2. **按基数重排**：`And` 先求估计更小的一侧，尽早短路；`Or` 按估计升序排列。
3. **谓词下推**：`And(Scan(p), x)` → `Filter(p, x)`，`And(Scan(p), Scan(q))` 也把
   其中一个变成另一个的过滤器，让 glob / regex 只在候选集上运行。
4. **基数估计**：`Const` 精确；`Trigram` 取候选数；`Scan` 取全集；`And` 取两侧
   较小值；`Or` 求和并截断到 N；`Not` 取 `N - inner`。估计只影响顺序，不影响结果。

### 求值

`evaluate_plan` 只做集合运算：

- `Const` 直接返回存储的 `Ids`；
- `Trigram` / `Scan` / `Filter` 用与扫描引擎相同的 `eval_term` 逐 id 验证；
- `And` 左侧为空时短路；`Or` 求并；`Not` 用 `dict.all()` 求差；
- `Store::entry_at` 越界的候选按不匹配处理，不 panic。

`exec_indexed` 返回 `Ids`，`exec_indexed_count` 直接返回基数。把 `Ids` 变成有序输出
是调用方的事：`search` 遍历 `Store::entries_in_order()` 做 membership，保留
`--limit` 的提前停止。

### `--explain`

`Expr::describe(total)` 输出单行、确定性的计划：

```text
(const#1 (and (ext "pdf") (size >= 1000)))
(filter#4 (glob "*.pdf" nocase) (const#4 (size > 1000)))
(trigram#1 keys=3 (substring "report" nocase))
(scan#9 reason=short-needle (substring "re" nocase))
(const#8 (not (ext "pdf")))
```

- `node#N` 是估计基数；`keys=` 是实际参与交集的 posting 数；`reason=` 是降级原因。
- `PlanOptions::optimize=false` 保留编译直译树（`And` 而不是 `Filter`），测试用它
  验证“优化前后结果等价”。

### 测试边界

`exec/plan_test.mbt` 覆盖：

- 每个字段的编译形状：`Const` 与字典 / 范围集合逐 id 相等，`Trigram` 与
  `lookup().candidates()` 相等，`Scan` 的 reason 可断言；
- 类型域与优化形状：常量折叠、域矛盾、`!Const` 折叠、`Filter` 下推；
- 全语料对拍：每个查询在 `optimize=true`、`optimize=false` 与 `exec_scan` 三种路径
  上得到相同 id 集合，覆盖布尔组合、日期、glob/regex/path、短 needle、空查询与
  空索引；
- `--no-trigram` 索引上的名字查询仍与扫描引擎一致；
- explain golden 精确到空格与预估数字。

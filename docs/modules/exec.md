# exec — 查询执行：扫描引擎、编译计划与位图执行器

`src/exec` 是 S05 建立、S07–S11 扩展的查询执行层。它包含两套引擎：

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
| `scan.mbt` | `exec_scan` / `exec_scan_reverse_with` / `exec_count` / `ScanOptions` |
| `plan.mbt` | S10：`Expr`、类型域、编译、优化、基数估计、位图求值、`--explain` |
| `order.mbt` | S11：`SortKey`、`OrderOptions`、结果排序、`--reverse`、`--folders-first`、top-K |
| `format.mbt` | S11：`OutputFormat`、`--format` 模板、JSON Lines、`--null`、相对路径 |
| `dict_compat_test.mbt` | S07 字典与扫描引擎的对拍 |
| `range_compat_test.mbt` | S08 范围索引与扫描引擎的对拍 |
| `trigram_compat_test.mbt` | S09 trigram 候选集 ⊇ 扫描结果的性质测试 |
| `plan_test.mbt` | S10：逐字段编译形状、优化前后等价、全语料对拍、explain golden |
| `order_test.mbt` | S11：每个排序键、反向、分组、limit、top-K 与输入无关性 |
| `format_test.mbt` | S11：各输出格式、占位符、转义、JSON 转义、相对路径 |
| `differential_test.mbt` | S13：三层语料对拍 runner、多夹具、`--no-trigram`、explain 覆盖率门禁 |
| `property_test.mbt` | S13：trigram 无漏报、数据库往返查询等价、输出顺序无关性 |

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

## 输出顺序与格式化（S11）

S10 之前，`search` 只输出规范顺序并只支持 `--limit`。S11 把“结果集合”变成“用户看到
的行”，分成两个独立阶段，两套引擎共用：

```text
matches (Array[EntryRef], 规范顺序)
  → order_hits: 排序键、--folders-first、--reverse、--limit（必要时 top-K）
  → format_hits: 路径 / basename / JSON / 模板、--null、--relative-to
```

两个阶段都只读 `core.Store`，不重新查询索引，因此 `--engine scan` 与
`--engine bitmap` 在相同查询上输出逐字节一致。

### 排序

`SortKey { Name, Path, Size, MTime, Ext, Type }`，所有比较器最后都用
`(name 自然序, path 自然序, GlobalId)` 兜底，保证结果与输入顺序、扫描顺序无关。

| 键 | 主比较 | 说明 |
| --- | --- | --- |
| `name` | `cmp_paths(name)` | 默认；就是 `Store` 的规范顺序 |
| `path` | `cmp_paths(完整路径)` | 只按路径，不先按名字 |
| `size` | 数值升序 | 文件夹使用子树总大小 |
| `mtime` | 数值升序 | Unix 秒；`--reverse` 得到最新在前 |
| `ext` | 折叠后的扩展名字节序 | 文件夹与无扩展名条目为空，排在最前 |
| `type` | 文件夹 0 → 内置分类 1..6 → 其他文件 7 | 同类再按扩展名、规范顺序 |

- **`--folders-first`** 是先分组再排序：文件夹组在前、文件组在后，组内仍按所选键与
  `--reverse` 排序。它不改变“组内”语义。
- **`--reverse`** 反转整个比较器，包括同键时的规范顺序兜底。
- **`--limit`** 在排序之后应用：`--sort size -n 20` 取最小的 20 个命中，而不是先截断
  再排序。
- **提前停止** 对 `name` 顺序成立：正序用 `exec_scan_with` 流式前进，`--reverse`
  用 `exec_scan_reverse_with` 从规范顺序末尾后退；两者都在收集到 limit 条时停止。
  `--folders-first` 与其他排序键先由 `OrderOptions::streams_name_order()` 判定
  不能流式输出，再收集全部命中。
- **top-K**：`limit > 0` 且小于命中数时，`select_top_k` 用一个大小为 limit 的最大堆
  选出前 K 条，再排序；复杂度 O(N log K)，结果与全排序后截断逐条相同。
- **预计算排序键**：`path`、`ext`、`type` 在构建 `SortItem` 时一次性算出，比较器
  不再为每次比较分配路径或折叠扩展名；`type` 的扩展名→分类表每次查询只建一次。

### 输出格式

`FormatOptions { format, null_terminated, relative_to }`：

| 格式 | 输出 |
| --- | --- |
| `Paths`（默认） | 完整路径 |
| `Names`（`--basename`） | 条目名字 |
| `Json`（`--json`） | 每个命中一行 JSON 对象 |
| `Template`（`--format`） | 解析后的模板 |

- **分隔符**：换行模式在记录之间写 `\n`，最后一条不带换行（CLI 入口补最终换行）；
  `--null` 在每条之后写 `\0`，包括最后一条，供 `xargs -0` 使用。入口检测到文本以
  NUL 结尾时直接写原始字节，避免额外换行。
- **`--format` 占位符**：`{path}`、`{name}`、`{dir}`、`{size}`、`{mtime}`、`{ext}`、
  `{type}`、`{kind}`。转义只支持 `\n`、`\t`、`\0`、`\\`；其他反斜杠序列原样保留。
  未知占位符与未闭合的 `{` 在扫描前报错（退出码 2），不会输出半截结果。当前版本
  `{` 总是开始占位符，不能输出字面花括号。
- **`{dir}`**：绝对路径去掉最后一个分量，单分量路径得到 `/`；相对路径没有分隔符时
  得到 `.`。
- **`--relative-to`**：基准目录在用前先 `realpath`；等于基准的路径输出 `.`，位于基准
  下的路径去掉基准和一个 `/`，基准外的路径保持原样。`--json` 的 `path` 与
  `{path}` 都使用相对形式。
- **`{ext}` / `ext` 字段**：文件夹恒为空；文件扩展名 ASCII 小写。
- **`{type}` / JSON `type`**：文件夹为 `folder`；文件为内置分类名（`app`、`archive`、
  `audio`、`doc`、`pic`、`video`）；未收录扩展名为 `other`。分类表来自
  `util.TypeCategory`，与查询层、字典共用。
- **JSON 字段顺序**：`path`、`name`、`size`、`mtime`、`ext`、`type`、`kind`，固定
  顺序便于 golden 测试；字符串按 JSON 规则转义引号、反斜杠与控制字符。
- **编码**：路径按原始字节保存，输出经 `decode_lossy` 转成 `String`；非法 UTF-8 字节
  在输出层显示为替换字符。这是 S11 已知限制，字节级修复属于后续输出重构。

### 测试边界

- `exec/order_test.mbt` 覆盖每个排序键的完整期望顺序、同值 tie-break、`--reverse`
  对 tie-break 的翻转、`--folders-first` 分组、limit 在排序之后、top-K 与全排序
  逐条一致、不同输入顺序得到相同结果，以及 name 顺序正反两向的流式判定。
- `exec/format_test.mbt` 覆盖默认/basename/JSON/模板/空结果、NUL 终止、转义、
  JSON 引号/反斜杠/控制字符、相对路径（根、尾斜杠、基准内、基准外）与模板错误。
- `src/cli/cli_test.mbt` 逐项验证参数冲突与错误，并在同一夹具上对每个排序键、
  `--reverse`、`--folders-first`、`--limit` 与每种输出格式比较两套引擎的 stdout。
- `tests/cli.md` 固化可执行文件的排序、格式、错误消息与退出码。

## 对拍、性质与覆盖率（S13）

S13 把“两套引擎必须逐条一致”从若干针对性用例扩展成可复用的 runner，并把输入的
覆盖面交给确定性生成器。语料本身在 `testkit`（见 [testkit](testkit.md)），exec 只
负责比较与断言。

### 对拍 runner

`differential_test.mbt` 的 `diff_check` 对一条查询做四件事：

```text
scan   = exec_scan_with(store, q)            // 规范顺序的 oracle
expect = scan 的 id 序列（规范顺序）
for optimize in [false, true]:
    result = exec_indexed(index, q)          // 优化前/后的计划树
    assert result.to_sorted_ids() == sorted(expect)          // 集合
    assert canonical_expand(result) == expect                // 顺序
    assert exec_indexed_count(index, q) == expect.length()   // 计数
```

- `canonical_expand` 走 `Store::entries_in_order()` 做 membership，与 CLI 输出层
  的真实路径一致；因此一个“集合正确但顺序错误”的计划也会失败。
- `exec_indexed_count` 必须等于扫描命中数，避免位图基数与集合体不一致。
- 失败消息包含夹具标签、查询文本、`optimize` 模式与两侧 id 列表。

夹具矩阵：

| 夹具 | 目的 |
| --- | --- |
| 手写 7 条目 store | 固定的小规模语义边界 |
| 空 store | 所有计划形态在零条目上仍可编译与求值 |
| 三个随机树（seed 1/42/20241118，各 50 条目） | 目录层级、重复名字、大小/时间/隐藏/扩展名的组合 |
| unicode store | 中文、带空格名、大小写混合、emoji |
| stop-gram store（全部名字含 `test`） | 强制 `stop-grams` 降级 |
| `--no-trigram` 索引 | 强制 `no-trigram` 降级 |

每条查询在 normal 与 `--no-trigram` 索引上各跑一遍；随机树使用自己的 seed 生成
语料，手写/空/unicode/stop-gram 使用固定 seed，保证失败可复现。日期查询只在
exec 层运行，时钟固定为 2024-03-20 00:00:00 UTC。

### explain 覆盖率门禁

`the explain corpus reaches every plan node and degradation reason` 在三种索引
（普通、stop-gram、`--no-trigram`）上编译 `explain_queries()`，对优化前后两棵
计划树递归收集：

- 节点形态：`const`、`trigram`、`scan`、`filter`、`and`、`or`、`not`；
- 降级原因：`glob`、`regex`、`path`、`short-needle`、`no-trigram`、`stop-grams`、
  `childfilecount`、`childfoldercount`、`contenttype`。

集合必须完整覆盖上述清单。`no-index` 被排除：合法 trigram 索引跳过 posting 时
必然把该 posting 计入 stop-gram，因此“跳过且 stop-gram 数为 0”不可达；测试同时
断言该原因没有意外出现。新增算子或新降级路径时，必须扩展
`testkit.explain_queries()` / `scan_reasons()`，否则门禁失败。

### 性质测试

`property_test.mbt`：

- **trigram 无漏报**：在随机树上采样名字子串与任意短 needle，对默认、`case:`、
  `exact:`、`case:exact:` 四组 flags，扫描命中必须全部落在候选集内；lookup 判定
  missing 时扫描命中必须为 0。
- **持久化等价**：随机树的 `Index::to_bytes` → `from_bytes(verify=true)` 之后，
  对语料逐条比较 `exec_indexed` 与 `exec_indexed_count`；`--no-trigram` 库同样
  往返，且恢复后 `trigram()` 必须为 `None`。
- **顺序无关**：同一查询重复求值结果相同；索引集合的规范顺序展开等于扫描顺序；
  正向扫描与反向扫描互为镜像；每个排序键在打乱输入后得到相同输出。唯一的例外是
  `name` 正序且无 `--folders-first`：它按文档约定直接返回规范输入以便流式输出，
  测试显式跳过该组合并用规范输入单独验证。

这些性质与既有测试互补：`trigram_compat_test.mbt` 穷举固定夹具的全部子串，
`plan_test.mbt` 断言逐字段编译形状；S13 负责随机输入、跨夹具与持久化之后的不变量。

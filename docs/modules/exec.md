# exec — 线性扫描执行器与谓词

`src/exec` 是 S05 建立、S07–S09 扩展的扫描引擎。它逐条遍历规范顺序，对每个条目求值，
是位图引擎的对拍 oracle。本模块不拥有索引结构，只读取 `core.Store` 与 `query.Query`。

## 文件

| 文件 | 内容 |
| --- | --- |
| `compile.mbt` | `Query` → `ScanExpr`、名字匹配器、日期解析、计划文本 |
| `predicate.mbt` | 逐条目谓词：名字、扩展名、类型、可见性、数值、父路径 |
| `content_type.mbt` | 扩展名 → MIME 表与 `contenttype:` |
| `scan.mbt` | `exec_scan` / `exec_count` / `ScanOptions` |
| `dict_compat_test.mbt` | S07 字典与扫描引擎的对拍 |
| `range_compat_test.mbt` | S08 范围索引与扫描引擎的对拍 |
| `trigram_compat_test.mbt` | S09 trigram 候选集 ⊇ 扫描结果的性质测试 |

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
  glob/regex 的匹配文本也不一定是连续子串。S10 必须让这些 term 回退到扫描，或只
  使用其他字段产生的候选集。

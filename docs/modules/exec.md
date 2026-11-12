# exec — 线性扫描执行器与谓词

`src/exec` 是 S05 建立、S07 扩展的扫描引擎。它逐条遍历规范顺序，对每个条目求值，是位图
引擎的对拍 oracle。本模块不拥有索引结构，只读取 `core.Store` 与 `query.Query`。

## 文件

| 文件 | 内容 |
| --- | --- |
| `compile.mbt` | `Query` → `ScanExpr`、名字匹配器、日期解析、计划文本 |
| `predicate.mbt` | 逐条目谓词：名字、扩展名、类型、可见性、数值、父路径 |
| `content_type.mbt` | 扩展名 → MIME 表与 `contenttype:` |
| `scan.mbt` | `exec_scan` / `exec_count` / `ScanOptions` |
| `dict_compat_test.mbt` | S07 字典与扫描引擎的对拍 |

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

# P0 追溯矩阵

本文件把 [MIGRATION_PLAN.md](../MIGRATION_PLAN.md) 第 8 节的 P0 能力、第 9 节的
9.1–9.4 验收项映射到仓库中真实存在的测试与夹具。S11 的目标是“每一项都有测试或
明确的非目标说明”，因此新增功能或运算符时，必须同时更新本表与对应测试；只改实现
不补测试视为该步未完成。

测试数量不写进本文档，以每次质量门禁的实际输出为准。

## 运行方式

```sh
moon check --target native --deny-warn
moon build --target native
moon test --target native
moon testcli test tests/cli.md --target native
python3 -I tests/raw_bytes_linux.py        # 仅 Linux：非法 UTF-8 文件名
python3 -I tests/process_reliability.py    # POSIX：EPIPE / SIGINT
python3 -I tests/sparse_files.py           # POSIX：大稀疏文件端到端
python3 -I tests/executable_differential.py # POSIX：真实可执行文件差分语料
moon fmt --check
moon info
```

CI 在 Linux 上执行全部命令；macOS 执行构建、`moon test`（覆盖 DST、POSIX 后端与
字节文件名语义）、三个 POSIX Python 脚本；Windows 只构建并冒烟 `--version`，
因为测试夹具依赖 Unix 路径语义。

## 1. P0 能力矩阵

| # | P0 能力（§8） | 证据 |
| --- | --- | --- |
| 1 | 持久化索引 + 命令行查询 | `src/index/db_test.mbt`（往返、截断、翻转）、`src/cli/cli_test.mbt`（index→search/count/info、根删除后仍可查询）、`tests/cli.md` |
| 2 | trigram 子串、ASCII 大小写不敏感 | `src/index/trigram_test.mbt`（键序、折叠、短词/非 ASCII 退化）、`src/exec/trigram_compat_test.mbt`、`src/exec/differential_test.mbt` |
| 3 | `case:` / `nocase:` / `exact:` | `src/query/parser_test.mbt`、`src/exec/exec_test.mbt`（name matching modes）、`src/query/flags_test.mbt` |
| 4 | `file:` / `folder:` / `type:` | `src/index/dict_test.mbt`、`src/exec/dict_compat_test.mbt`、`src/exec/exec_test.mbt` |
| 5 | AND / OR / NOT / 括号 / 隐式 AND | `src/query/parser_test.mbt`（优先级、结合性、连续 NOT、分组作用域）、`src/exec/differential_test.mbt`（随机布尔形状）、`tests/executable_differential.py` |
| 6 | `ext:` | `src/index/dict_test.mbt`、`src/exec/dict_compat_test.mbt`、`src/util/bytes_test.mbt`（扩展名边界） |
| 7 | `size:` / `dm:` / `depth:` / `child*` / `parent:` / `empty:` | `src/index/range_test.mbt`、`src/exec/range_compat_test.mbt`、`src/util/time_test.mbt`、`tests/sparse_files.py` |
| 8 | `path:` / `nopath:` | `src/exec/exec_test.mbt`、`src/exec/trigram_compat_test.mbt`（名字 trigram 不覆盖路径项）、`tests/executable_differential.py` |
| 9 | 通配符 `*` / `?` | `src/util/glob_test.mbt`（含独立参考匹配器）、`src/query/lexer_test.mbt`（转义）、`src/exec/exec_test.mbt` |
| 10 | 正则 | `src/query/regex_test.mbt`、`src/exec/exec_test.mbt`（非法正则/日期）、`src/exec/plan_test.mbt`（域剪枝不得隐藏编译错误） |
| 11 | 宏（内置 + 自定义） | `src/query/builtin_test.mbt`、`src/query/macro_test.mbt`（嵌套、循环、修饰符作用域）、`src/index/dict_test.mbt`、`src/config/config_test.mbt` |
| 12 | 包含/排除、隐藏文件、one-file-system | `src/index/exclude_test.mbt`、`src/index/scanner_test.mbt`（one-file-system 四种设备路径、隐藏、权限）、`src/cli/cli_test.mbt`（真实设备号）、`tests/cli.md` |
| 13 | `--sort name` 零成本 | `src/exec/order_test.mbt`（规范顺序、流式前后向）、`tests/cli.md` |
| 14 | `--sort size/mtime/ext/type` + top-K | `src/exec/order_test.mbt`（每个键、稳定性、top-K 与全排序一致）、`src/cli/cli_test.mbt`、`tests/cli.md` |
| 15 | `--count` 取基数 | `src/exec/exec_test.mbt`、`src/ids/ids_test.mbt`、`tests/cli.md`、`tests/sparse_files.py` |
| 16 | DB 保存/加载/损坏检测 | `src/index/db_test.mbt`（逐截断/逐字节翻转、语义篡改）、`src/index/db_fuzz_test.mbt`（随机变异、预算化解码）、`src/index/db_write_wbtest.mbt`、`src/index/db_read_wbtest.mbt` |
| 17 | 两引擎对拍 | `src/exec/differential_test.mbt`、`src/cli/differential_test.mbt`、`tests/executable_differential.py`、`tests/cli.md` |

## 2. 9.1 单元测试

| 模块 | 覆盖内容 | 测试文件与用例 |
| --- | --- | --- |
| `util/size` | 全部单位、大小写、非法后缀、溢出、半开区间 | `src/query/value_test.mbt`：“size suffixes are decimal…”、“malformed sizes…”、“the largest representable size…”、“implicit numeric values are exact or half-open ranges”、“sizes accept leading zeros…” |
| `util/time` | 显式格式、today/yesterday、星期/月、相对时间、DST、两位年份 | `src/util/time_test.mbt`：显式日期与分隔符、today/yesterday、weekday/month、last/past/this、`DST transition days are 23 and 25 hours long`、`nonexistent local times resolve compatibly forward`、`ambiguous local times resolve to the earlier offset`、`fixed zones keep every day 24 hours long` |
| `util/extension` | 隐藏文件、尾点、多点、无点、大小写 | `src/util/bytes_test.mbt`：“extension extraction handles multi-dot, hidden, and trailing dots”；`src/util/category_test.mbt` |
| `util/cmp_paths` | 数字段、前导零、分隔符、非 ASCII | `src/util/path_test.mbt`：“cmp_paths compares digit runs numerically”、“…strverscmp for leading zeros”、“…separator before other bytes”、“…non-ASCII and invalid UTF-8 by raw bytes”、全序与反对称性 |
| `ids/bitmap` | 容器切换（4096 阈值）、块边界、空块、popcount、序列化往返 | `src/ids/bitmap_wbtest.mbt`：“containers flip between array and bits…”、“ids at a block boundary…”、“set operations preserve internal empty blocks…”；`src/ids/codec_test.mbt` |
| `ids/ops` | 四种形态组合的 and/or/difference，与朴素集合对照 | `src/ids/ids_test.mbt`：“set operations match the naive reference across every shape”、“large canonical sets…”、“empty operands short-circuit…”、“operations and filters apply the total-entry density rule”；`src/ids/property_test.mbt` |
| `index/range` | 区间边界（半开）、重复值、空区间 | `src/index/range_test.mbt`：“range is half-open and an empty interval selects nothing”、“equal returns the whole run of duplicate values”、“range index sorts pairs by value and then by id” |
| `index/trigram` | 提取规则（<3、非 ASCII、重复片段）、posting 升序 | `src/index/trigram_test.mbt`：“trigram keys and postings are strictly ordered”、“repeated windows are stored once per name”、“short and empty needles degrade…”、“non-ASCII needles use byte trigrams” |
| `query/lexer` | 引号、转义、字段空值、保留字符、连续 NOT | `src/query/lexer_test.mbt`（引号/转义/冒号/保留字符/UTF-16 位置）、`src/query/parser_test.mbt`（连续 NOT） |
| `query/parser` | 优先级、隐式 AND、括号、宏展开、修饰符作用域 | `src/query/parser_test.mbt`（优先级、结合性、分组、修饰符链）、`src/query/macro_test.mbt` |
| `query/compile` | 每个字段编译到预期 `Expr`；优化前后等价 | `src/exec/plan_test.mbt`（逐字段形状、优化前后与扫描引擎等价、explain）、`src/exec/plan_wbtest.mbt` |

## 3. 9.2 两引擎对拍

| 要求 | 证据 |
| --- | --- |
| 手写语义语料 | `src/testkit/corpus.mbt` 的 `semantic_queries`、`edge_queries`、`date_queries`、`explain_queries`；消费者 `src/exec/differential_test.mbt` |
| 随机生成合法查询 | `src/testkit/corpus.mbt` 的 `generated_queries`（固定种子、深度受限、叶子合法）；`src/exec/differential_test.mbt` 的 `indexed and scan engines agree on deterministic random trees` |
| `--explain` 覆盖率反推补漏 | `src/testkit/corpus.mbt` 的 `explain_queries` 与 `scan_reasons()`；`src/exec/differential_test.mbt` 的 `the explain corpus reaches every plan node and degradation reason` |
| id 集合与规范顺序一致 | `src/exec/differential_test.mbt`（每个查询比较 `exec_indexed` 与 `exec_scan` 的集合和顺序） |
| 降级路径：`--no-trigram`、短 needle、非 ASCII、含 `/` | `src/exec/differential_test.mbt` 的 `the --no-trigram index agrees with the scan engine`、`indexed and scan engines agree when every name is a stop-gram`、`indexed and scan engines agree on unicode names`；`src/index/trigram_test.mbt`、`src/exec/trigram_compat_test.mbt` |
| `--engine scan` 与持久化引擎 stdout 字节级一致 | `src/cli/differential_test.mbt`（扫描/位图/`--no-trigram`/`--live`/全部输出选项，比较 `CliResult` 字节）；`tests/executable_differential.py`（真实进程的 search、count、错误、`--compat`、输出选项） |
| 任一不一致视为 P0 bug | 对拍测试用 `abort` 终止并打印查询、引擎与双方输出；CI 失败即阻断 |

## 4. 9.3 性质与损坏输入

| 性质 | 证据 |
| --- | --- |
| 无漏报：trigram 候选 ⊇ 扫描命中 | `src/exec/property_test.mbt`：“trigram candidates never miss a linear-scan match”；`src/exec/trigram_compat_test.mbt`：“trigram candidates are a superset of every scan match” |
| 集合代数恒等式 | `src/ids/property_test.mbt`：“set algebra identities hold for random sets and shapes”、“skewed sorted sets match masks and exercise the galloping path”；`src/ids/ids_test.mbt` |
| 序列化往返 | `src/ids/property_test.mbt`：“id set serialization round-trips and rejects mutations safely”；`src/ids/codec_test.mbt`；`src/exec/property_test.mbt`：“a database round trip preserves every query result” |
| 顺序与遍历次数/输入顺序无关 | `src/exec/property_test.mbt`：“query output is independent of repetition and input order”；`src/exec/order_test.mbt`：“sorting is independent of the input order” |
| 损坏输入有限时间返回错误、不越界、不崩溃 | `src/index/db_test.mbt`（逐截断、逐字节翻转、语义篡改）、`src/index/db_fuzz_test.mbt`（600 个随机变异 + 300 个随机缓冲，`verify=false` 时仍探测全部访问器）；`src/ids/codec_test.mbt`（操作/内存预算、恶意长度先拒绝） |
| 模糊测试预算与超时 | `src/testkit/budget.mbt` 的 `FuzzBudget`（操作数 + 墙钟双上限）；`src/query/fuzz_test.mbt`（lexer/parser 各 2000 次、60 s）、`src/index/db_fuzz_test.mbt`（600/300 次、120 s）；DB 解码另有 `IdsDecodeBudget` 的操作/内存预算 |

## 5. 9.4 端到端

| 覆盖项 | 证据 |
| --- | --- |
| 临时夹具树：文件、目录、隐藏、符号链接、Unicode、非法 UTF-8、深层嵌套、大稀疏文件 | `src/cli/differential_test.mbt`（`cli_diff_fixture`：嵌套/隐藏/空目录/Unicode/深层）、`src/index/scanner_test.mbt`（符号链接/特殊文件）、`src/cli/byte_pipeline_test.mbt`（Linux 非法 UTF-8 全链路）、`tests/sparse_files.py`（1 TiB + 3 GiB+1 稀疏文件） |
| `index` → `search`/`count`/`info` 的 stdout/stderr/退出码 | `src/cli/cli_test.mbt`、`tests/cli.md`（mooncram golden）、`tests/sparse_files.py` |
| `--limit`、`--reverse`、`--null`、`--json`、`--format`、`--count`、`--live`、`--engine scan` | `src/exec/format_test.mbt`、`src/exec/order_test.mbt`、`src/cli/cli_test.mbt`、`tests/cli.md`、`tests/executable_differential.py` |
| 缺失 DB、损坏 DB、无权限目录 | `src/cli/cli_test.mbt`（missing/corrupt/verify tail）、`tests/cli.md`、`src/index/scanner_test.mbt`（unreadable policy） |
| EPIPE（含 `| head`）、`/dev/full`、SIGINT 130 | `tests/process_reliability.py` |
| 非法 UTF-8：scan → DB → match → raw output | `src/cli/byte_pipeline_test.mbt`（Linux，真实目录 + 序列化 + 重载 + 两引擎 + raw/NUL/JSON）、`tests/raw_bytes_linux.py`（真实进程） |
| 真实可执行文件的最小差分语料 | `tests/executable_differential.py`（40+ 查询 × search/count × 两引擎，持久化库/无 trigram/live/输出选项/非法查询/`--compat`） |

## 6. 非目标与延后项

以下项目明确不在 S11（也不在 v1 验收）范围内，因此没有“缺测试”的欠账：

| 项目 | 状态 | 说明 |
| --- | --- | --- |
| Unicode casefold / NFD | P1 延后 | v1 只做 ASCII 折叠；`src/util/bytes_test.mbt` 断言非 ASCII 字节不被改写 |
| `contenttype:` 精确 MIME（libmagic） | P1 延后 | v1 用扩展名 → MIME 表；`src/exec/content_type.mbt` 与 `exec_test.mbt` 覆盖该语义 |
| PCRE2 兼容正则 | P2 | 只支持文档化的语法子集；`docs/modules/query.md` 记录边界 |
| 路径 trigram（`path:` 走索引） | P2 | `path:` 故意降级为候选集验证；`trigram_compat_test.mbt` 断言名字 trigram 不覆盖路径项 |
| watcher 增量监控 | P2 | `update` 当前全量重建；`docs/modules/index.md` 记录结构预留 |
| GUI / 选择集 / 打开文件 | P2 | 非目标 |
| Windows MFT/USN 与 Windows 路径语义 | P2 | Windows 只构建；测试夹具依赖 POSIX 路径与设备号 |

## 7. CI 矩阵

| 平台 | 构建 | `moon test` | `testcli` | Python 进程测试 | 说明 |
| --- | --- | --- | --- | --- | --- |
| Linux | 是 | 全部 | 是 | 全部（含非法 UTF-8） | 主门禁；`moon check --deny-warn`、`fmt --check`、`moon info` 无 diff |
| macOS | 是（release 冒烟） | 是 | 否 | EPIPE/SIGINT、稀疏文件、可执行文件差分 | DST、POSIX 后端、字节文件名语义在此验证；非法 UTF-8 文件名被文件系统拒绝，相关用例按平台跳过 |
| Windows | 是（release 冒烟） | 否 | 否 | 否 | 只保证编译与 `--version`；路径语义测试假设 Unix |

## 8. 维护规则

- 新增查询字段/运算符：扩展 `src/testkit/corpus.mbt` 的三层语料、`scan_reasons()`、
  本表 §1/§3，并确认 `tests/executable_differential.py` 至少有一条真实进程用例。
- 新增 DB 分节/格式：更新 `docs/db-format.md`、布局断言、往返/截断/翻转测试与本表 §1
  第 16 行。
- 新增扫描选项：在 `src/index/scanner_test.mbt` 与 `src/cli/cli_test.mbt` 各补一条
  端到端用例，并更新 §1 第 12 行。
- 新增平台条件测试：同时更新 §7 的 CI 矩阵，避免“只在开发者机器上通过”。

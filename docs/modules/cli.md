# cli — 命令解析、执行编排与输出

`src/cli` 是命令行门面：把 argv 解析成 `Invocation`，选择引擎与索引来源，调用
`@exec` 得到命中，再交给 S11 的排序/格式化层。它不实现查询语义，也不实现集合运算；
所有语义都来自 `query` / `index` / `exec`。

## 文件

| 文件 | 内容 |
| --- | --- |
| `spec.mbt` | argparse 规格：全局选项、`index/update/search/count/info` 子命令、help 文本 |
| `invocation.mbt` | `Command`、`Invocation`、`parse` 与默认子命令 `search` |
| `run.mbt` | `CliResult`、退出码映射、子命令分发 |
| `database.mbt` | 数据库路径解析：`-D`、`MOONSEARCH_DATABASE`、XDG/HOME/LOCALAPPDATA 默认值 |
| `index_command.mbt` | `index` / `update`：扫描、构建 `@index.Index`、原子写库、汇总与 `--stats` |
| `search_command.mbt` | `search` / `count`：查询构建、索引来源、引擎选择、排序、格式化、诊断 |
| `info_command.mbt` | `info`：只读 header/section table，报告版本、条目数、大小与校验状态 |
| `cli_test.mbt` | 进程内 CLI 测试：help golden、参数错误、真实目录端到端、两引擎对拍 |
| `database_wbtest.mbt` | 白盒测试：`resolve_home` / `resolve_data_home` 的平台回退顺序 |
| `differential_test.mbt` | S13：三层语料在持久化库、`--no-trigram` 库、`--live` 与全部输出选项上的端到端字节对拍 |

## 执行流程

```text
argv
  → parse: subcommand + options/flags + positionals（默认 search）
  → build_query: -c/-e/-p/-r 作为 parser 初始 Flags；--type 解析后由
    query.constrain_kind 作为全局约束求交；--regex 应用自动路径/大小写规则
  → 校验输出参数：--sort、--limit、--json/--format/--basename/--null/--relative-to
  → query_source
      --live          : 扫描 roots → Store（不读写数据库）
      数据库存在      : Index::read_database → 字典/范围/posting 原样恢复
      数据库缺失      : --auto-index 时扫描 → 建 Index → 原子写库；否则报错并提示 index
  → 引擎
      scan   : exec_scan_with(collect_limit)
      bitmap : 持久化索引直接使用；live 时 Index::build(eager=size,mtime, trigram)
               → exec_indexed → 规范顺序 membership
  → order_hits: 排序、--reverse、--folders-first、--limit / top-K
  → format_hits: 路径 / basename / JSON / 模板、--null、--relative-to
  → CliResult + 退出码
```

`index`/`update` 完成扫描后构建同一个 `@index.Index`，再用
`Index::write_database` 做原子替换：临时文件 + `sync` + `rename`。`info` 只读
header 与 section table；`--verify` 额外校验全文件 CRC。默认数据库路径为
`$XDG_DATA_HOME/moonsearch/index.msdb`，未设置时为
`$HOME/.local/share/moonsearch/index.msdb`；Windows 上 `HOME` 未设置时回退到
`%LOCALAPPDATA%\moonsearch\index.msdb`，再回退到
`%USERPROFILE%\.local\share\moonsearch\index.msdb`。`-D/--database` 与
`MOONSEARCH_DATABASE` 覆盖默认值，路径开头的 `~/` 会按 `$HOME`
（Windows 上为 `%USERPROFILE%`）展开。

路径解析拆成两个纯函数：`resolve_home` 与 `resolve_data_home` 接受
`(String) -> String?` 查找器，因此 `database_wbtest.mbt` 可以在不触碰进程环境的
前提下覆盖各平台的回退顺序；`environment_value` 仍按“调用方 map → 进程环境”取值。

两个引擎产生同一命中集合；排序与格式化完全在 `@exec` 中共享，因此相同查询的输出
逐字节一致。`name` 顺序（正序或 `--reverse`，且无 `--folders-first`）把 `--limit`
直接传给引擎：正序前进、`--reverse` 从末尾后退，都保留提前停止；其他组合先收集全部
命中，再排序/top-K。

## 输出参数规则

- `--sort` 接受 `name|path|size|mtime|ext|type`（ASCII 大小写不敏感），默认 `name`。
- `--reverse` 反转整个比较器；`--folders-first` 先分组再在组内排序。
- `--limit` 在排序之后应用；`0` 表示不限。
- 记录格式三选一：默认路径、`--basename`、`--json`、`--format <模板>`。
  `--json` / `--format` / `--basename` 两两组合是用法错误；`--null` 可与任意格式
  组合，并把记录终止符从换行改为 NUL。
- `--format` 支持 `{path}`、`{name}`、`{dir}`、`{size}`、`{mtime}`、`{ext}`、
  `{type}`、`{kind}` 与 `\n`、`\t`、`\0`、`\\`。模板在扫描前解析，未知占位符或
  未闭合的 `{` 直接以退出码 2 失败。
- `--relative-to <DIR>` 先 `realpath`；基准内的路径去掉基准，等于基准输出 `.`，
  基准外保持绝对路径；作用于 `{path}` 与 JSON `path`。
- `--stats` 输出 `entries` / `matches` / `search` 等诊断到 stderr；持久化索引路径
  额外输出 `load: <ms>`，实时扫描输出 `scan: <ms>`；`index --stats` 还会打印
  `database: <path> (<bytes> bytes)`。`--explain` 输出查询文本与当前引擎的计划。
- `info` 输出 `database`、`format`、`built`、根/文件夹/文件/名字计数、文件大小、
  trigram 键数与各 section 字节数；`--verify` 会把 `checksum` 从 `metadata` 改为
  `verified`。

## 输出字节与退出码

- 格式化层返回 `FormatOutput { bytes, invalid_utf8_records }`；换行模式在记录之间写
  `\n`，`stdout_bytes()` 补最后一个换行。
- `--null` 生成每条以 NUL 结尾（包括最后一条）的字节；入口直接写 `Bytes`，不检测文本、
  不补换行，也不会改变文件名中的原始字节。
- 退出码：`0` 成功/help/version，`1` 无命中，`2` 参数/查询/IO/DB 错误，
  `130` SIGINT（见 `core::EXIT_*`）。
- Unix 扫描、索引、DB 与默认/basename/模板输出全程保留原始字节。JSON 使用合法 UTF-8，
  非法字节以 U+FFFD 替换，并由入口向 stderr 发出一次稳定告警。

## 测试边界

`cli_test.mbt` 覆盖：

- 顶层与各子命令 help 文本、版本、默认子命令、位置参数拼接、`--` 与全局选项；
- 参数错误：未知选项、缺值、`count` 拒绝输出选项、非法 `--sort`/`--limit`/
  `--format`/`--relative-to`、互斥格式组合；
- 真实目录：扫描汇总、排除规则、权限告警、`--one-file-system` 警告、`--quiet`；
- 持久化：`index` 写库、`info --verify` 读头、删除根目录后 `search`/`count` 仍从库中
  命中、bitmap 引擎直接读库、`--no-trigram` 库退化为扫描、损坏数据库以退出码 2 失败；
- `search`/`count` 的 `--live`、`--auto-index`、多 root、`--type`、`--regex`、
  `--explain`、`--stats`；`--compat` 把解析期与编译期的非法值、非法正则/日期变成空集；
- 每个排序键、`--reverse`、`--folders-first`、`--limit`、`--basename`、`--null`、
  `--json`、`--format`、`--relative-to` 的进程内输出；
- 同一夹具上 `--engine scan` 与 `--engine bitmap` 的 stdout 与退出码逐字节一致。

`differential_test.mbt`（S13）把这条对拍扩展到三层语料（手写语义、随机生成、
explain 覆盖）：

- **持久化库**：`index` 写库后，每条查询分别以 `--engine scan` 与
  `--engine bitmap` 运行 `search` 与 `count`，比较退出码、stdout 与失败文本；
  运行时才知道的 `parent:`/`path:` 查询追加在同一份语料后。
- **`--no-trigram` 库**：手写语义、explain 与 40 条生成查询重复同一比较，确认
  降级路径与扫描引擎一致。
- **`--live` 对比持久化 bitmap**：三分之一的语料在真实目录扫描与持久化索引之间
  比较 stdout 与退出码。
- **输出矩阵**：6 条查询 × 13 组排序/反向/分组/limit/JSON/NUL/basename/模板/
  相对路径选项 × 两引擎，比较 stdout 与退出码。

语料只依赖固定种子，失败消息带查询文本；日期查询不进入 CLI 对拍，避免两次引擎
调用跨越日历边界。

`tests/cli.md` 用可执行文件覆盖同样的排序、格式、错误消息与退出码，并保留 S01
以来的 help golden。

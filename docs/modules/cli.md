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
| `index_command.mbt` | `index` / `update`：扫描、构建 `@index.Index`、汇总与 `--stats` |
| `search_command.mbt` | `search` / `count`：查询构建、引擎选择、排序、格式化、诊断 |
| `cli_test.mbt` | 进程内 CLI 测试：help golden、参数错误、真实目录端到端、两引擎对拍 |

## 执行流程

```text
argv
  → parse: subcommand + options/flags + positionals（默认 search）
  → build_query: --type/-c/-e/-p/-r/--regex 与应用到 parser 的初始 Flags
  → 校验输出参数：--sort、--limit、--json/--format/--basename/--null/--relative-to
  → store_for_query: --live / --auto-index 扫描 roots（S12 之前没有持久化 DB）
  → 引擎
      scan   : exec_scan_with(collect_limit)
      bitmap : Index::build(eager=size,mtime, trigram) → exec_indexed → 规范顺序 membership
  → order_hits: 排序、--reverse、--folders-first、--limit / top-K
  → format_hits: 路径 / basename / JSON / 模板、--null、--relative-to
  → CliResult + 退出码
```

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
- `--stats` 输出 `entries` / `matches` / `search` 等诊断到 stderr；`--explain`
  输出查询文本与当前引擎的计划。

## 输出字节与退出码

- 换行模式由 CLI 生成“记录之间换行、最后一条不带换行”的文本，入口用 `println`
  补最终换行。
- `--null` 生成每条以 NUL 结尾（包括最后一条）的文本；入口检测到末尾 NUL 时直接
  写原始 UTF-8 字节，避免额外换行破坏 `xargs -0`。
- 退出码：`0` 成功/help/version，`1` 无命中，`2` 参数/查询/IO/DB 错误，
  `130` SIGINT（见 `core::EXIT_*`）。
- 路径在内部是原始字节；输出层用 `decode_lossy` 转成 `String`，非法 UTF-8 字节
  显示为替换字符。

## 测试边界

`cli_test.mbt` 覆盖：

- 顶层与各子命令 help 文本、版本、默认子命令、位置参数拼接、`--` 与全局选项；
- 参数错误：未知选项、缺值、`count` 拒绝输出选项、非法 `--sort`/`--limit`/
  `--format`/`--relative-to`、互斥格式组合；
- 真实目录：扫描汇总、排除规则、权限告警、`--one-file-system` 警告、`--quiet`；
- `search`/`count` 的 `--live`、`--auto-index`、多 root、`--type`、`--regex`、
  `--explain`、`--stats`；
- 每个排序键、`--reverse`、`--folders-first`、`--limit`、`--basename`、`--null`、
  `--json`、`--format`、`--relative-to` 的进程内输出；
- 同一夹具上 `--engine scan` 与 `--engine bitmap` 的 stdout 与退出码逐字节一致。

`tests/cli.md` 用可执行文件覆盖同样的排序、格式、错误消息与退出码，并保留 S01
以来的 help golden。

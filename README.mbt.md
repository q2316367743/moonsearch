# moonsearch

`moonsearch` 是一个带持久化倒排索引的文件搜索命令行工具，使用 MoonBit 编写。索引一次
文件系统，之后用字段查询、布尔组合与 glob/正则反复检索，不必每次遍历目录。

```bash
moonsearch index -r ~/Documents
moonsearch 'ext:pdf size:>1mb' -n 20
```

- 索引**文件系统条目**：名称、路径、扩展名、大小、mtime、父目录与子项计数。
- **不是**全文搜索引擎。文档内容搜索请用
  [`Lucius646/MoonSearch`](https://github.com/Lucius646/MoonSearch) 或
  [`moonbit-community/rg`](https://github.com/moonbit-community/rg.mbt)。
- **不是**每次调用都重新遍历的 `find`。一次性遍历直接用 `find` 更合适。
- 索引只加速部分查询：短查询串、glob、正则与 `path:` 会退化为全扫描。原因与实测边界
  见 [`docs/benchmarks.md`](docs/benchmarks.md)。

## 安装

```bash
moon install q2316367743/moonsearch/cmd/moonsearch
```

`moon install` 从 mooncakes 取源码并在本机编译，可执行文件装进 `$HOME/.moon/bin`
（Windows 为 `%USERPROFILE%\.moon\bin`），需要 MoonBit 工具链与 C 编译器。

每个 Release 也附带预编译包：

| 平台 | 文件 |
| --- | --- |
| Linux x86_64 | `moonsearch-<version>-linux-x86_64.tar.gz` |
| macOS arm64 | `moonsearch-<version>-macos-arm64.tar.gz` |
| Windows x86_64 | `moonsearch-<version>-windows-x86_64.zip` |

macOS 包最低要求 macOS 15（在 macOS 15 runner 上构建）。解压后可直接运行，或把二进制
放进 `PATH` 中的目录；`SHA256SUMS` 与压缩包放在同一 Release。

## 构建

需要 MoonBit 工具链；只支持 native 后端（Wasm 没有通用文件系统）。

```bash
moon build --target native --release
./_build/native/release/build/cmd/moonsearch/moonsearch.exe --version
```

开发时可用 `moon run cmd/moonsearch -- <参数>` 代替上面的可执行文件路径。

## 快速开始

```bash
# 建立索引，可指定多个根目录
moonsearch index -r ~/Documents -r ~/Downloads

# 查询（search 是默认子命令）
moonsearch 'ext:pdf size:>1mb'
moonsearch 'report dm:lastweek' --sort size --reverse -n 20

# 只输出命中数量
moonsearch count 'ext:mp4'

# 检查数据库完整性并查看统计
moonsearch info --verify
```

## 命令

```text
moonsearch <command> [options] [query...]
```

| 命令 | 用途 |
| --- | --- |
| `index` | 扫描根目录并写入索引数据库 |
| `update` | 重新扫描根目录并替换索引数据库 |
| `search` | 查询索引（默认子命令） |
| `count` | 输出命中数量 |
| `info` | 显示数据库统计信息；`--verify` 校验每个段 |

`search` 是默认子命令，因此 `moonsearch 'ext:pdf'` 等价于
`moonsearch search 'ext:pdf'`。完整选项列表用 `moonsearch <command> --help` 查看。

### 全局选项

可放在子命令之前或之后。

| 选项 | 说明 |
| --- | --- |
| `-D, --database <PATH>` | 数据库路径（`MOONSEARCH_DATABASE`） |
| `--config <PATH>` | 预留：配置文件尚未读取（`MOONSEARCH_CONFIG`） |
| `--no-config` | 预留：保留解析但不生效 |
| `-v, --verbose` / `-q, --quiet` | 详细进度 / 只输出结果与错误 |
| `--stats` | 向 stderr 输出耗时与索引体积 |
| `--explain` | 向 stderr 输出解析后的查询与执行计划 |
| `-h, --help` / `-V, --version` | 帮助 / 版本 |

## 数据库

默认路径为 `$XDG_DATA_HOME/moonsearch/index.msdb`，未设置 `XDG_DATA_HOME` 时为
`$HOME/.local/share/moonsearch/index.msdb`；Windows 上未设置 `HOME` 时用
`%LOCALAPPDATA%\moonsearch\index.msdb`。`-D/--database` 与
`MOONSEARCH_DATABASE` 可覆盖，路径开头的 `~/` 会展开。

`search` 与 `count` 默认读取该数据库。数据库缺失时会报错并提示先运行 `index`；
`--auto-index` 则在缺失时先扫描 `--root` 建库。

`--live` 完全跳过数据库，直接扫描 `--root` 指定的目录：

```bash
moonsearch search --live --root ~/Documents 'ext:jpg;png size:>1mb'
moonsearch count --live --root ~/Documents 'dm:lastweek ext:mp4'
```

## 建立索引

```bash
moonsearch index -r ~/Documents ~/Downloads   # 位置参数也可以
moonsearch update ~/Documents                 # 重新扫描并原子替换
```

`index` 与 `update` 行为相同：扫描、构建、原子写入；根目录必须显式给出。写入使用临时
文件、`sync` 与 `rename`，失败时保留原数据库。

| 选项 | 说明 |
| --- | --- |
| `-r, --root <PATH>` | 根目录，可重复；也可写成位置参数 |
| `-x, --exclude <RULE>` | 排除规则，可重复 |
| `--exclude-scope <SCOPE>` | 规则匹配对象：`full_path`（默认）或 `basename` |
| `--exclude-target <T>` | 规则作用对象：`both`（默认）、`files` 或 `folders` |
| `--exclude-hidden` | 跳过以点开头的名称 |
| `--no-default-excludes` | 不跳过 `/proc`、`/sys`、`/dev`、`/run` |
| `--allow-nested-roots` | 允许根目录相互嵌套 |
| `--fast-fields <LIST>` | 预建区间字段，默认 `size,mtime`；可选 `size`、`mtime`、`depth`、`childcount`、`parent` |
| `--no-trigram` | 不构建 trigram 倒排；名称查询将退化为全扫描 |
| `--one-file-system` | 不跨文件系统；当前纯 MoonBit 后端上为空操作并打印警告 |

排除规则写法：`fixed:` 做逐字节比较，`glob:` 支持 `*`、`?` 与 `\` 转义，不带前缀时
默认按 glob 处理。`regex:` 暂时被拒绝。

```bash
moonsearch index -r ~/Projects -x 'glob:*/node_modules' -x 'glob:*.tmp' --exclude-hidden
```

扫描完成后 stdout 输出稳定摘要：

```text
roots: 1
folders: 4
files: 3
bytes: 6
```

`skipped:` 与 `issues:` 行仅在非零时出现；`-v/--verbose` 会逐条报告不可读目录、扫描中
消失的条目等可恢复问题。`--stats` 追加计时、名称池、字典与 trigram 形态，以及数据库
路径和大小。

## 查询

### 基本匹配

裸词按**名称子串**匹配，默认 ASCII 大小写不敏感；包含 `/` 的裸词按**完整路径**匹配。
`"..."` 原样保留空格与特殊字符，`\` 转义下一个字符。含非 ASCII 大写字母的词项自动
改为大小写敏感（v1 只折叠 ASCII）。

glob 中 `*` 匹配任意字节序列，`?` 匹配**一个 Unicode 标量**（一个完整 UTF-8 字符，
非法字节算一个单位），`\*` / `\?` 表示字面量星号/问号。正则使用 MoonBit 内置引擎：
支持字符类、POSIX 类（`[[:digit:]]` 等）、`* + ? {n,m}` 量词、分组/替换、`^ $ \b`、
`(?i:...)`；不支持 `\d` / `\s` / `\w` 简写、lookaround、反向引用和 `\xHH` 字节转义。
`--regex` 同样应用上面两条自动路径/大小写规则。

```bash
moonsearch report            # 名称包含 report
moonsearch '"annual report"' # 单个词项内含空格时用引号
moonsearch docs/report       # 路径包含 docs/report
moonsearch '*.pdf'           # glob：以 .pdf 结尾
moonsearch -r '^report.*\.pdf$'   # 正则：整条查询作为正则
```

对应的一次性开关：

| 选项 | 说明 |
| --- | --- |
| `-c, --case-sensitive` | 大小写敏感 |
| `-e, --exact` | 整名精确匹配 |
| `-p, --search-path` | 按完整路径匹配 |
| `-r, --regex` | 整条查询作为正则 |
| `--type <any\|file\|folder>` | 限制结果类型，默认 `any` |
| `--engine <scan\|bitmap>` | 执行引擎，默认 `scan` |
| `--root <PATH>` | `--live` / `--auto-index` 使用的根目录，可重复 |
| `--live` | 跳过数据库，直接扫描 `--root` |
| `--auto-index` | 数据库缺失时先按 `--root` 建库 |
| `--compat` | 兼容上游错误恢复：未知字段、非法值变成空集 |

### 布尔运算

`AND` / `OR` / `NOT`（必须整词大写），也可写 `&&` / `||` / `!`。相邻词项隐式按
`AND` 组合；优先级为 `NOT` > `AND` > `OR`，括号可改变顺序。

```bash
moonsearch 'report AND pdf'
moonsearch '(report OR summary) NOT draft'
moonsearch 'file:(pdf OR doc) dm:lastweek'
```

### 字段

| 字段 | 含义 | 示例 |
| --- | --- | --- |
| `ext:` | 扩展名，`;` 分隔；空值表示无扩展名 | `ext:jpg;png`、`ext:` |
| `size:` | 大小（文件与目录；目录为子树总量） | `size:>1mb`、`size:1kb..2mb` |
| `dm:` | 修改时间（别名 `datemodified:`） | `dm:today`、`dm:2024-03` |
| `depth:` | 深度，根目录为 0（别名 `parents:`） | `depth:<=2` |
| `childcount:` | 直接子项数（目录） | `childcount:0` |
| `childfilecount:` | 直接子文件数（目录） | `childfilecount:>10` |
| `childfoldercount:` | 直接子目录数（目录） | `childfoldercount:1..3` |
| `parent:` | 父目录完整路径（不展开 `~`） | `parent:/home/user/Documents` |
| `empty:` | 空目录（不带值） | `empty:` |
| `contenttype:` | MIME 类型；只写主类型或子类型均可 | `contenttype:pdf`、`contenttype:text` |

`ext:` 与 `contenttype:` 仅匹配文件；子项计数与 `empty:` 仅匹配目录。使用
`--allow-nested-roots` 时同一路径可能被索引多次，`parent:` 会合并该路径的所有副本。

### 修饰符

修饰符是前缀写法，只作用于紧随其后的**一个词项或一个括号组**，不会泄漏到组外。

| 修饰符 | 作用 |
| --- | --- |
| `case:` / `nocase:` | 大小写敏感 / 不敏感 |
| `exact:` | 整名精确匹配 |
| `path:` / `nopath:` | 匹配完整路径 / 仅匹配名称 |
| `regex:` / `noregex:` | 正则 / 关闭正则 |
| `file:` / `files:` | 仅文件 |
| `folder:` / `folders:` | 仅目录 |
| `hidden:` | 仅隐藏条目 |
| `nohidden:` / `visible:` | 仅非隐藏条目 |

可以链式组合，例如 `file:hidden:doc:report`；`file:(a OR b)` 对两侧都生效，而
`file:a OR b` 只约束 `a`。单独使用 `file:`、`folder:`、`hidden:`、`nohidden:` 也是
有效的过滤器。命令行的 `--type` 是**全局约束**，作用于整条查询，不能被查询内的
`file:` / `folder:` 覆盖；因此 `--type file folder:` 匹配空集。

自定义宏按自己保存的 flags 独立解析，外部修饰符不会渗入展开结果；需要限制宏时，把
修饰符写进宏查询，或另写一个普通 term，例如 `book: file:`。

### 取值

- 大小使用十进制单位：`k`/`kb` = 1000，`m`/`mb` = 10⁶，`g`/`gb` = 10⁹，
  `t`/`tb` = 10¹²；不带单位表示字节。
- 比较符：`>`、`>=`、`<`、`<=`、`=`；不写比较符表示精确值。`==`（包括分开写的
  `= =`）是 `=` 的另一种写法。
- 区间为半开 `lo..hi`，两端可省略：`1kb..2mb` = `[1000, 2000000)`；
  `..1mb` 只给上界，`1mb..` 只给下界。
- 计数字段（`depth:`、`childcount:` 等）接受非负整数，同样支持比较符与区间。
- `dm:` 的区间同样是半开的：`dm:2020..2021` 覆盖 2020 但不覆盖 2021。

### 日期

`dm:` 按本地时区解析，支持：

- `today`、`yesterday`；星期名（`mon` / `monday`，最近一次出现）；月份名
  （`jan` / `january`，最近一次出现）；
- `last` / `past` / `inthelast` / `prev` / `previous` + 单位，可带计数：`lastweek`、
  `past3days`、`lastfiveweeks`；单位为 `year(s)`、`month(s)`、`week(s)`、`day(s)`、
  `hour(s)`、`min(s)`、`sec(s)`；
- `this` + 单位，表示当前日历单位（周从周一开始）；
- 显式日期 `YYYY[-MM[-DD[THH[:MM[:SS]]]]]`，支持两位年份。

裸日期表示整个单位，`dm:2024-03` 是整月；比较符作用于该单位的半开区间。

### 内置分类

`app:`、`archive:`、`audio:`、`doc:`、`pic:`、`video:` 直接匹配一组扩展名：

| 分类 | 扩展名 |
| --- | --- |
| `app:` | app, appimage, deb, desktop, dmg, exe, flatpak, msi, pkg, rpm, snap |
| `archive:` | 7z, bz2, cab, gz, gzip, iso, jar, lz4, lzma, rar, tar, tbz2, tgz, txz, xz, zip, zst |
| `audio:` | aac, ac3, aiff, alac, ape, au, flac, m4a, mka, mp3, oga, ogg, opus, wav, wma, wv |
| `doc:` | c, cc, chm, cpp, csv, cxx, doc, docx, epub, go, h, hpp, htm, html, ini, java, js, json, log, lua, md, mobi, mbt, odt, pdf, ppt, pptx, py, rb, rs, rtf, sh, tex, toml, ts, tsv, txt, xls, xlsx, xml, yaml, yml |
| `pic:` | avif, bmp, gif, heic, ico, jpeg, jpg, png, psd, svg, tif, tiff, webp, xcf |
| `video:` | 3gp, avi, flv, m4v, mkv, mov, mp4, mpeg, mpg, ogv, rmvb, vob, webm, wmv |

### 示例

```bash
# 大于 1 MB 的 PDF
moonsearch 'ext:pdf size:>1mb'

# 最近一周修改过的图片和视频
moonsearch 'pic: OR video: dm:lastweek'

# 两层以内的目录
moonsearch 'folder: depth:<=2' --sort path

# docs 目录下的非隐藏文件，按大小排序
moonsearch 'parent:/home/user/Documents/docs nohidden:file:' --sort size --reverse

# 空目录
moonsearch 'folder: empty:'

# 整个索引按名称列出前 20 条（空查询）
moonsearch '' -n 20

# 只统计数量
moonsearch count 'ext:mp4 dm:last30days'
```

### 什么时候查询会变慢

- 子串短于 3 字节（如 `re`）无法使用 trigram，退化为全扫描；
- glob、正则与 `path:` 没有索引支持，会在候选集上逐条验证；只有它们时就是全扫描；
- 高频 trigram（超过索引 20%）被当作停用词跳过；
- `childfilecount:`、`childfoldercount:`、`contenttype:` 尚无区间索引；
- 稠密区间（如 `size:>1kb`）需要把大切片排序并转成位图。

用 `--explain` 可以看到每个词项选了哪种来源、为什么退化。

## 排序与输出

`search` 的输出选项：

| 选项 | 说明 |
| --- | --- |
| `--sort <name\|path\|size\|mtime\|ext\|type>` | 排序键，默认 `name` |
| `--reverse` | 反转整个顺序（含平局判定） |
| `--folders-first` | 目录排在文件之前，组内保持所选键与方向 |
| `-n, --limit <N>` | 最多输出 N 条；`0` 表示不限，默认 `0` |
| `--basename` | 只输出名称 |
| `--json` | 每行一个 JSON 对象 |
| `--format <TEMPLATE>` | 自定义每条结果的格式 |
| `-0, --null` | 每条记录以 NUL 结尾（含最后一条），便于 `xargs -0` |
| `--relative-to <DIR>` | 输出相对该目录的路径 |

- `--limit` 在排序之后应用，因此 `--sort size -n 20` 得到最小的二十条；默认 `name`
  顺序会流式输出并在达到限制时提前停止。
- `--json` 字段：`path`、`name`、`size`、`mtime`、`ext`、`type`、`kind`。
- `--format` 占位符：`{path}`、`{name}`、`{dir}`、`{size}`、`{mtime}`、`{ext}`、
  `{type}`、`{kind}`；转义：`\n`、`\t`、`\0`、`\\`。非法模板在扫描前即以退出码 2
  失败。
- `--basename`、`--json`、`--format` 两两互斥；`--null` 可与任意格式组合。
- Unix 默认路径、basename 与模板输出保留文件系统原始字节，不要求名称是合法 UTF-8；
  `--null` 每条恰好输出一个 NUL，不额外添加换行。JSON 始终输出合法 UTF-8，非法字节以
  U+FFFD 替换字符表示，同时向 stderr 输出稳定告警；需要无损字节时请使用默认/NUL 输出。
- `--relative-to` 先解析 `realpath`：等于基准输出 `.`，其下路径去掉基准与一个分隔符，
  基准之外的路径保持绝对。
- 类型名：目录为 `folder`，文件为 `app`/`archive`/`audio`/`doc`/`pic`/`video`，
  未列出的扩展名为 `other`；目录的 `ext` 为空。
- `count` 只接受过滤选项，拒绝所有输出选项。

## 诊断

```bash
moonsearch --stats 'ext:pdf'          # 条目数、命中数、耗时；读库时还有 load，实时扫描为 scan
moonsearch --explain 'report pdf'     # 解析后的查询 + 执行计划
moonsearch info --verify              # 数据库各段校验
```

`--engine bitmap` 使用持久化索引执行，`--engine scan`（默认）线性扫描；两者结果一致，
后者是前者的语义基准。`--live` 下也可以指定 `--engine bitmap`，此时在内存中建索引。

## 退出码

| 码 | 含义 |
| --- | --- |
| `0` | 成功、帮助或版本 |
| `1` | 无命中 |
| `2` | 参数、查询、IO 或数据库错误 |
| `130` | 被 SIGINT 中断 |

## 文档

本文件是使用说明；实现与设计细节在 `docs/`：

| 文档 | 内容 |
| --- | --- |
| [`docs/modules/cli.md`](docs/modules/cli.md) | 命令解析、执行编排、输出规则 |
| [`docs/modules/query.md`](docs/modules/query.md) | 词法、语法与查询 AST |
| [`docs/modules/exec.md`](docs/modules/exec.md) | 扫描引擎、查询编译与位图执行 |
| [`docs/modules/index.md`](docs/modules/index.md) | 扫描器、字典、区间索引、trigram 倒排、持久化 |
| [`docs/db-format.md`](docs/db-format.md) | MSDB v2 数据库格式 |
| [`docs/benchmarks.md`](docs/benchmarks.md) | 基准口径、实测结果与调优待办 |
| [`MIGRATION_PLAN.md`](MIGRATION_PLAN.md) | 迁移计划与设计取舍 |

补漏计划按步骤验收；S02 已建立 Unix 字节安全扫描与原始字节输出。其余步骤与明确的
P1/P2 扩展（Unicode casefold、libmagic 内容类型、PCRE2 正则、路径 trigram、增量监控）
以 [`plan/补漏计划书.md`](plan/补漏计划书.md) 的状态为准。

## 开发

```bash
moon check --target native --deny-warn
moon test --target native
moon fmt
moon info
moon testcli test tests/cli.md --target native
```

基准与演示脚本位于 `bench/`，用法见 [`docs/benchmarks.md`](docs/benchmarks.md)。

## 许可证

Apache-2.0。本项目为独立实现：未复制任何 FSearch 代码、注释、常量表或测试文本。
FSearch 与 Everything 仅作为行为参考致谢。固定运行时依赖为 `moonbitlang/core` 与
`moonbitlang/x`（Apache-2.0）。

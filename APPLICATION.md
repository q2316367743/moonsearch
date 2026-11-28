# moonsearch 项目申报书

| 项目 | 内容 |
| --- | --- |
| 项目名称 | moonsearch：MoonBit 原生的文件系统元数据检索引擎 |
| 参赛者 | 落雨不悔（m17762618644@163.com），1 人 |
| 项目方向 | 开发者工具 / 工具库：MoonBit 库 + native CLI |
| 项目属性 | 参考已有开源项目的独立实现：查询语义对齐 FSearch，执行引擎、索引格式与代码重写（非代码移植） |
| 参考项目 | FSearch 0.3-dev（commit `1208a34`），https://github.com/cboxdoerfer/fsearch，GPL-2.0 |
| 许可证 | Apache-2.0（不复制上游代码） |
| 仓库 | https://github.com/q2316367743/moonsearch，不少于 16 个有效提交 |

## 一、项目价值与生态定位

**简介。** moonsearch 扫描目录树，把名字、路径、扩展名、大小、mtime、父目录、子项数写进可持久化的索引，用 FSearch 风格查询语言检索；形态是 MoonBit 库 + native CLI。

**痛点。** 大型工作树上反复用 `find`/`fd` 找文件，每条命令都重走一遍目录树；shell 管道能组合条件，但没有持久索引，也没有 `childcount:`、`parent:` 这类结构谓词。编辑器、文件管理器、构建工具要做同样的检索时，要么反复调用外部 `find`，要么各自重写查询语言、范围索引、trigram 和持久化格式。

**缺口。** mooncakes.io 上（截至 2026-11-18）已有 `Lucius646/MoonSearch`（全文检索）、`moonbit-community/rg`（内容 grep）、`cli/find`、`justjavac/walkdir`（遍历），但没有“文件系统元数据 + 持久索引 + 查询语言”这一层；FSearch 绑定 GTK/Linux，Everything 闭源且 Windows-only。moonsearch 补这一层：内容搜索用 MoonSearch/rg，元数据检索用 moonsearch。这不是再做一个搜索工具，而是补 MoonBit 工具链缺少的一层基础设施。

**通用性与优势。** 对 MoonBit 工具链，它是发布后可直接 `moon add` 的检索层：只依赖 `readdir`/`stat`，macOS/Linux 通用，同一棵树、同一查询、同一排序输出确定，库与 CLI 共用同一套实现。对 FSearch/Everything，它把桌面 GUI 搜索拆成可嵌入的库 + 无 GUI 依赖的 CLI，以 Apache-2.0 授权；对 `find`，它把重复查询从目录遍历变成索引查找——但只在“索引常驻、反复查询”时成立。

## 二、交付范围与工程边界

**交付与核心功能。** MoonBit 库 + native CLI：`index`/`update`/`search`/`count`/`info`；查询语言（布尔、前缀修饰符、范围/日期/大小/结构字段、类别宏、glob/regex）；字典位图、范围数组、trigram 倒排；`Ids = Bitmap | Sorted` 集合代数；MSDB v3 持久化（分节、校验和、原子替换、损坏恢复）；排序/`--limit`/JSON/NUL/模板输出。补漏计划 S01–S11 已按步骤验收（S12 基准与可复现材料待完成）；测试数量由每次质量门禁实际输出，不写死。

**不做。** 不做 GUI；不做文件内容全文检索；不做 Windows MFT/USN 与 Windows 路径语义；不做分布式分片；v1 只做 ASCII 大小写折叠；`update` 当前全量重建，watcher 增量更新留到后续。

**边界。** 它是“索引常驻、反复查询”的工具，不是 `find` 的通用替代品。短 needle、stop-gram、glob/regex/`path:`、稠密范围会退回 O(N) 扫描；小树上索引没有稳定优势。优势是条件性的。

## 三、实现路径与技术理解

**常见路径。** 每次查询遍历目录（`find`/`fd`），无构建成本但重复查询都是 O(N)；只在内存建索引（FSearch），查询快但每次启动/更新重建；持久化索引 + 查询编译，构建一次、加载多次，代价转到格式、加载和更新；FFI 绑定 C 库，省实现但失去 MoonBit 原生和许可证自由度。

**选择的路径。** 持久化索引，并保留遍历作为 `--live`、索引缺失时的降级路径和位图引擎的 oracle。FSearch 本身是单遍遍历、逐条目求值，多条件增加的是谓词成本，不是遍历次数；moonsearch 把执行层改成：字典/范围/trigram 生成候选 id 集合，做位图集合代数，最后只对候选做字节/glob/正则验证。两套引擎共用词法/语法/谓词，只换候选源，正确性逐查询对拍。

**需要的能力与独到理解。** 需要字节级文件名（MoonBit `String` 是 UTF-16 且必须合法，Unix 文件名是任意字节流，所以索引用分块 `NamePool` 存 `(offset, len)`）、倒排/位图/范围索引、查询编译、持久化与损坏恢复、确定性扫描、基准与差分测试。两个关键判断：成本由 posting 长度和候选规模决定，不由命中数决定（`source map` 450 命中 3.7 ms，`ing` 8,151 命中 0.6 ms）；trigram 的验收性质是“候选集必须是扫描结果的超集”，允许误报、不允许漏报。

## 四、预期使用场景

1. **monorepo 清理**：`moonsearch index -r ~/work/repo` 建一次索引，之后反复查 `folder:node_modules`、`ext:log size:>10mb dm:lastmonth`，用 `--null` 交给删除脚本；`find` 每次都要重走几十万条目。
2. **编辑器快速打开**：库嵌入编辑器，启动加载一次（122 万条约 1.1 s），按键查 `report file:ext:md`，`-n 20` 返回自然序前 20 条；索引查询 34 µs–4.4 ms。
3. **CI 产物审计**：`moonsearch count 'size:>100mb ext:zip dm:lastweek'`，按退出码判断是否遗留大产物；`--json` 输出清单，固定索引让同一提交的检查可复现。

## 五、实测、证据与仓库

**上游依据。** FSearch 0.3-dev（commit `1208a34`）：`src/fsearch_database_index_store.c:227` 的 worker 对每个 entry 调用 `fsearch_query_match()`，`src/fsearch_query.c:138` 的 `matches()` 在查询树上做 AND/OR 短路——一次查询只遍历一遍，多条件增加的是谓词成本，不是遍历次数。Everything 闭源，只作语义参考，不进入对照。

**同条件对照。** 297,595 条目（25,424 文件夹 + 272,171 文件），FSearch core 无 GUI、固定 1 线程，同树同查询同时区，取多次运行中位数；FSearch 1T 走完整搜索，moonsearch `bitmap count` 只看集合基数、`bitmap full` 还按规范顺序物化命中；`FSearch/full >1` 表示 moonsearch 更快。

| 查询 | 命中 | FSearch 1T | bitmap count | bitmap full | FSearch/full |
| --- | ---: | ---: | ---: | ---: | ---: |
| `report` | 192 | 14.403 | 0.049 | 2.730 | 5.3× |
| `source map` | 450 | 15.995 | 3.741 | 6.874 | 2.3× |
| `a`（1 字节） | 172,894 | 10.110 | 10.942 | 11.841 | 0.85× |
| `*.pdf`（glob） | 0 | 13.866 | 14.415 | 14.757 | 0.94× |
| `path:src` | 14,367 | 80.982 | 123.016 | 127.574 | 0.63× |
| `size:>1kb`（稠密） | 201,582 | 6.729 | 10.454 | 11.470 | 0.59× |

完整表中，选择性高且可索引的完整搜索相对 FSearch 单线程快 1.5–44×（`size:>1mb` 1.5×、`report pdf` 44×），`count` 快 4–300×；退化查询的 `FSearch/full` 为 0.19–0.94（moonsearch 慢 1.1–5.3×）。`source map` 只有 450 命中却要 3.741 ms，`ing` 有 8,151 命中只要 0.603 ms：成本由 posting 长度和候选规模决定，不由命中数决定。短 needle、stop-gram、glob/regex/`path:`、稠密范围退化为 O(N)，完整搜索可能比 FSearch 慢。代价：同一棵树构建 20.9 s（FSearch 4.8–7.6 s，但不建 trigram、不写库）、全量 `update` 21.2 s、查询态 96 MiB、加载 0.26 s；1,219,537 条目上（Apple M4 Pro，release）构建 75.4 s、加载 1.14 s、查询态 361.9 MiB。完整表格、原始 TSV 与 harness 见 [docs/benchmarks.md](docs/benchmarks.md) §6 与 [bench/fsearch-compare/](bench/fsearch-compare/)。

https://github.com/q2316367743/moonsearch。不少于 16 个有效提交（2026-11-11 起，首个提交 `93f613a`），沿 S01–S14 路线推进，每次是实质增量（实现、测试、文档或 CI）；没有空提交或凑数拆分。CI 跑 `moon check`、`fmt --check`、`test`、`testcli`。

后续：发布 mooncakes + 嵌入示例；常驻进程/共享缓存消掉每次 CLI 约 1.1 s 加载；watcher 增量更新；稠密范围分块与 mmap。

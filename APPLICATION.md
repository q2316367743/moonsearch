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

**交付与核心功能。** MoonBit 库 + native CLI：`index`/`update`/`search`/`count`/`info`；查询语言（布尔、前缀修饰符、范围/日期/大小/结构字段、类别宏、glob/regex）；字典位图、范围数组、trigram 倒排；`Ids = Bitmap | Sorted` 集合代数；MSDB v3 持久化（分节、校验和、原子替换、损坏恢复）；排序/`--limit`/JSON/NUL/模板输出。补漏计划 S01–S12 已按步骤交付；S12 的 12 项基准中 11 项达标，索引体积 2.86×/1.66× 未达 1.5× 目标（原因与后续计划见 [docs/benchmarks.md](docs/benchmarks.md)）。测试数量由每次质量门禁实际输出，不写死。

**不做。** 不做 GUI；不做文件内容全文检索；不做 Windows MFT/USN 与 Windows 路径语义；不做分布式分片；v1 只做 ASCII 大小写折叠；`update` 当前全量重建，watcher 增量更新留到后续。

**边界。** 它是“索引常驻、反复查询”的工具，不是 `find` 的通用替代品。短 needle、stop-gram、glob/regex/`path:`、稠密范围会退回 O(N) 扫描；小树上索引没有稳定优势。优势是条件性的。

## 三、实现路径与技术理解

**常见路径。** 每次查询遍历目录（`find`/`fd`），无构建成本但重复查询都是 O(N)；只在内存建索引（FSearch），查询快但每次启动/更新重建；持久化索引 + 查询编译，构建一次、加载多次，代价转到格式、加载和更新；FFI 绑定 C 库，省实现但失去 MoonBit 原生和许可证自由度。

**选择的路径。** 持久化索引，并保留遍历作为 `--live`、索引缺失时的降级路径和位图引擎的 oracle。FSearch 本身是单遍遍历、逐条目求值，多条件增加的是谓词成本，不是遍历次数；moonsearch 把执行层改成：字典/范围/trigram 生成候选 id 集合，做位图集合代数，最后只对候选做字节/glob/正则验证。两套引擎共用词法/语法/谓词，只换候选源，正确性逐查询对拍。

**需要的能力与独到理解。** 需要字节安全的文件名存储：MoonBit `String` 是 UTF-16 且必须合法，Unix 文件名却是任意字节流，因此索引把名字保存为 UTF-8 原始字节，放进按 64 KiB 块分配的 `NamePool`；条目只持有全局字节偏移和长度，读取时用块起始表定位，查询与排序都不假设名字是合法 UTF-8。还需要倒排/位图/范围索引、查询编译、持久化与损坏恢复、确定性扫描、基准与差分测试。两个关键判断：成本由 posting 长度和候选规模决定，不由命中数决定（合成 300k 上 `source map` 614 命中 2.774 ms，`package.json` 0 命中 0.039 ms）；trigram 的验收性质是“候选集必须是扫描结果的超集”，允许误报、不允许漏报。

## 四、预期使用场景

1. **monorepo 清理**：`moonsearch index -r ~/work/repo` 建一次索引，之后反复查 `folder:node_modules`、`ext:log size:>10mb dm:lastmonth`，用 `--null` 交给删除脚本；`find` 每次都要重走几十万条目。
2. **编辑器快速打开**：库嵌入编辑器，启动加载一次（100 万条约 0.18–0.20 s），按键查 `report file:ext:md`，`-n 20` 返回自然序前 20 条；可索引查询 37 µs–10 ms，纯 glob 约 76 ms。
3. **CI 产物审计**：`moonsearch count 'size:>100mb ext:zip dm:lastweek'`，按退出码判断是否遗留大产物；`--json` 输出清单，固定索引让同一提交的检查可复现。

## 五、实测、证据与仓库

**上游依据。** FSearch 0.3-dev（commit `1208a34`）：`src/fsearch_database_index_store.c:227` 的 worker 对每个 entry 调用 `fsearch_query_match()`，`src/fsearch_query.c:138` 的 `matches()` 在查询树上做 AND/OR 短路——一次查询只遍历一遍，多条件增加的是谓词成本，不是遍历次数。Everything 闭源，只作语义参考，不进入对照。

**同条件对照。** 300,000 条目确定性合成树（30,000 文件夹 + 270,000 文件，manifest SHA-256 `4cc38f96…3db18cf`，可由干净克隆重建），FSearch core 无 GUI、固定 1 线程，同树同查询同时区，取 5 次运行中位数；FSearch 1T 走完整搜索，moonsearch `bitmap count` 只看集合基数、`bitmap full` 还按规范顺序物化命中；`FSearch/full >1` 表示 moonsearch 更快。

| 查询 | 命中 | FSearch 1T | bitmap count | bitmap full | FSearch/full |
| --- | ---: | ---: | ---: | ---: | ---: |
| `report` | 8,972 | 19.713 | 0.684 | 1.402 | 14.06× |
| `source map` | 614 | 21.489 | 2.774 | 6.441 | 3.34× |
| `ext:jpg size:>1mb` | 0 | 13.061 | 0.045 | 0.453 | 28.80× |
| `a`（1 字节） | 119,812 | 16.780 | 15.695 | 17.853 | 0.94× |
| `*.pdf`（glob） | 271 | 13.114 | 22.061 | 25.021 | 0.52× |
| `path:src` | 150,760 | 104.947 | 125.151 | 127.855 | 0.82× |
| `size:>1kb`（稠密） | 283,530 | 10.174 | 15.553 | 16.270 | 0.63× |

完整表中，选择性高且可索引的完整搜索相对 FSearch 单线程快 2.65–47×，count 快约 4–585×；退化查询的 `FSearch/full` 为 0.50–0.99（moonsearch 慢 1.01–2×）。`source map` 只有 614 命中却要 2.774 ms，`package.json` 0 命中只要 0.039 ms：成本由 posting 长度和候选规模决定，不由命中数决定。短 needle、stop-gram、glob/regex/`path:`、稠密范围退化为 O(N)，完整搜索可能比 FSearch 慢。代价：300k 合成树构建 7.42 s（FSearch 3.56 s 是内存索引，不建 trigram、不写库）、加载 59.9 ms；1,030,056 条目上（Apple M4 Pro，release，热缓存）构建 28.0 s、加载 176 ms、查询态 332.2 MiB，索引额外体积 2.86×/1.66×（未达 1.5×，拆分与后续计划见基准文档）。完整表格、原始 TSV 与 harness 见 [docs/benchmarks.md](docs/benchmarks.md) §6 与 [bench/fsearch-compare/](bench/fsearch-compare/)；2026-11-18 的私有 297,595 条目快照只作历史补充，不替代该主口径。

https://github.com/q2316367743/moonsearch。不少于 16 个有效提交（2026-11-11 起，首个提交 `93f613a`），已沿 S01–S12 路线交付，每次是实质增量（实现、测试、文档或 CI）；没有空提交或凑数拆分。S13–S14 尚未声称完成。CI 跑 `moon check`、`fmt --check`、`test`、`testcli`。

后续：发布 mooncakes + 嵌入示例；常驻进程/共享缓存消掉每次 CLI 约 0.2 s 的加载；watcher 增量更新；`RANGES` 值列编码/分块、`PARENT_PATHS` 前缀压缩与 mmap，把索引额外体积从 2.86×/1.66× 压到 1.5× 以内。

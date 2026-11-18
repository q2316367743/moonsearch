# 基准测试与调优记录（S14）

本文说明 `moonsearch` 的基准口径、复现方式、实测结果和后续调优清单。原始报告由
`bench/run_bench.py` 生成：

- `bench/results.md` / `bench/results.json`：主数据集，1,219,537 条目。
- `bench/results-full-tree.md` / `bench/results-full-tree.json`：全量压力数据集，
  2,362,503 条目。
- `bench/fsearch-compare/results-plugin.md`：与 FSearch core library 的同条件
  对照，297,595 条目（见 §6）。

## 1. 测量口径

| 指标 | 工具 | 口径 |
| --- | --- | --- |
| 建索引 | `index --stats` + `/usr/bin/time -l` | 扫描、构建 `Store`、字典/范围/posting、原子写库的总墙钟；RSS 为进程峰值 |
| 数据库加载 | `moonsearch-bench` | `Index::read_database` 单次调用的墙钟，不含查询 |
| 引擎延迟 | `moonsearch-bench` | 一次加载后，对 `exec_indexed` / `exec_scan_with` 采样；包含查询编译，与 CLI 每次调用一致。`moonbitlang/core/bench` 用原生单调时钟，批量到约 100 ms，取中位数 |
| CLI 墙钟 | `bench/run_bench.py` | 正常可执行文件的一次完整调用：解析参数、加载数据库、执行、格式化、退出 |
| 查询态 RSS | `/usr/bin/time -l` | 一次 `count --engine bitmap report` 的进程峰值 |
| 索引体积 | `info` | 各 section 的字节数；基础体积 = NAMES + FOLDERS + FILES |

引擎延迟与 CLI 墙钟刻意分开：前者回答“索引结构本身多快”，后者回答“用户敲一次命令
等多久”。当前 CLI 每次调用都要重新加载数据库，所以 CLI 墙钟由加载时间主导。

环境：Apple M4 Pro、48 GiB、macOS 26.6.2、MoonBit `0.1.20261104`、release 构建。
查询延迟取多次样本的中位数；建索引与数据库加载是单次运行的墙钟。`--stats` 的毫秒值是粗粒度参考。

## 2. 复现

```bash
moon build --target native --release

# 主数据集：workspace 下的三棵子树
python3 bench/run_bench.py \
  --label workspace-1m \
  --root ~/Documents/workspace/app \
  --root ~/Documents/workspace/dashou-plugin \
  --root ~/Documents/workspace/plugin \
  --rebuild-index

# 全量：整个 workspace
python3 bench/run_bench.py --label workspace-2.36m \
  --root ~/Documents/workspace --rebuild-index
```

`run_bench.py` 在数据库缺失或传入 `--rebuild-index` 时先建索引，并把建索引的时间、
RSS 和 `--stats` 摘要写进 `<work-dir>/<label>-index.json`；复用数据库时读取该文件。
输出路径由 `--output` / `--json-output` 指定，默认 `bench/results.md` 与
`bench/results.json`。

`moonsearch-bench` 也可以单独使用：

```bash
moon run cmd/moonsearch-bench -- --database DB --engine bitmap --runs 10 'report'
moon run cmd/moonsearch-bench -- --database DB --engine scan   --runs 10 'report'
moon run cmd/moonsearch-bench -- --database DB --engine bitmap --count 'ext:mp4'
moon run cmd/moonsearch-bench -- --database DB --engine bitmap --first 20 ''
```

它每次输出一行 `LOAD` 和若干行 `BENCH`（TSV，最后一列是核心库的 JSON 摘要），不
打印命中路径，因此适合脚本和录屏之外的精确测量。

## 3. 主数据集（1,219,537 条目）

数据：`~/Documents/workspace/{app,dashou-plugin,plugin}`，113,665 个文件夹、
1,105,872 个文件、169,415 个不同名字；数据库 86.7 MiB。

### 3.1 建索引与加载

| 指标 | 目标（1M） | 实测 | 结论 |
| --- | --- | --- | --- |
| 扫描 + 构建 + 写库 | < 90 s | 75.4 s | 达标（按条目数线性折算目标 109.8 s） |
| 建索引峰值 RSS | 信息项 | 776.3 MiB | 含构建期 trigram 哈希表 |
| 数据库加载 | < 800 ms | 1136 ms | 未达标，按 1M 折算约 0.93 s |
| 查询态 RSS | < 400 MB | 361.9 MiB | 达标 |
| 索引额外体积 | < 1.5× 基础 | 1.58× | 略超 |

`--stats` 细节：`scan: 73937 ms`，`database: 90,950,983 bytes`，
`names: 1,219,537 names, 19,157,482 bytes`，
`trigram: 41,567 keys, 16,634,757 postings, 7,786 short names, 4 stop-grams, 66,539,028 B`。

### 3.2 引擎延迟

| 查询 | 目标 | bitmap 中位数 | scan 中位数 | 命中 | 结论 |
| --- | --- | --- | --- | --- | --- |
| `ext:jpg` | < 1 ms | 34.1 µs | 46.24 ms | 99 | 达标（约 1356×） |
| `ext:jpg size:>1mb` | < 5 ms | 309.2 µs | 48.88 ms | 2 | 达标（约 158×） |
| `ext:jpg size:>1mb dm:lastweek` | < 8 ms | 4.41 ms | 54.11 ms | 0 | 达标（约 12×） |
| `report` | < 20 ms | 76.6 µs | 65.13 ms | 726 | 达标（约 850×） |
| `report pdf` | < 40 ms | 183.3 µs | 68.92 ms | 0 | 达标（约 376×） |
| `*.pdf`（纯 glob） | < 120 ms | 72.29 ms | 92.67 ms | 6 | 达标；无索引可用，仅谓词下推 |
| `source map`（两组常见 trigram） | < 40 ms | 16.24 ms | 70.93 ms | 2,941 | 达标（约 4.4×） |
| `count ext:mp4` | < 1 ms | 34.0 µs | — | 5 | 达标 |
| 空查询 + `-n 20` | < 1 ms | 33.4 µs | 33.8 µs | 1,219,537 | 达标；规范化顺序提前停止 |

### 3.3 索引体积

| Section | 字节 |
| --- | --- |
| names | 2,592,055 |
| folders | 3,864,610 |
| files | 28,752,672 |
| order | 4,878,148 |
| dict | 1,730,103 |
| ranges | 29,268,902 |
| postings | 19,864,032 |
| roots + checksum | 217 |
| **total** | **90,950,983** |

基础体积（names + folders + files）33.6 MiB；额外 53.2 MiB，即 1.58×。`ranges`
（size + mtime 两个字段）和 `postings` 是主要增量。

### 3.4 CLI 墙钟

| 命令 | 中位数 |
| --- | --- |
| `search --engine bitmap 'ext:jpg'` | 1162 ms |
| `search --engine bitmap 'report'` | 1200 ms |
| `count --engine bitmap 'ext:mp4'` | 1096 ms |
| `search --engine bitmap -n 20 ''` | 1086 ms |

引擎本身只需几十微秒到几十毫秒，CLI 墙钟几乎全部是 1.1 s 左右的数据库加载。这是
当前交互体验的主要瓶颈，调优优先级高于查询算子。

## 4. 全量压力数据集（2,362,503 条目）

整个 `~/Documents/workspace`（含各项目的 `node_modules`、`_build` 等构建产物）：230,946 个文件夹、2,131,557 个文件、166.0 MiB 数据库。

| 指标 | 1M 目标 | 实测（2.36M） | 说明 |
| --- | --- | --- | --- |
| 扫描 + 构建 + 写库 | < 90 s | 150.0 s | 按条目折算约 63.5 s/1M |
| 建索引峰值 RSS | 信息项 | 1.4 GiB | trigram 构建期 |
| 数据库加载 | < 800 ms | 2453 ms | 约 1.04 s/1M |
| 查询态 RSS | < 400 MB | 679.3 MiB | 约 287 MiB/1M，达标 |
| `ext:jpg` | < 1 ms | 34.1 µs | 228 命中 |
| `ext:jpg size:>1mb` | < 5 ms | 728.3 µs | 2 命中 |
| `ext:jpg size:>1mb dm:lastweek` | < 8 ms | 4.98 ms | 0 命中 |
| `report` | < 20 ms | 116.9 µs | 1,389 命中 |
| `report pdf` | < 40 ms | 395.2 µs | 0 命中 |
| `*.pdf` | < 120 ms | 143.07 ms | 8 命中；折算约 61 ms/1M |
| `source map` | < 40 ms | 31.98 ms | 4,899 命中 |
| `count ext:mp4` | < 1 ms | 34.6 µs | 9 命中 |
| 空查询 + `-n 20` | < 1 ms | 33.7 µs | 2,362,503 命中 |
| 索引额外体积 | < 1.5× | 1.58× | RANGES 56.7 MB + POSTINGS 37.3 MB |

全量树上查询目标里唯一按原始数值未达标的是 `*.pdf`（143 ms vs 120 ms），但按条目数折算约为
61 ms/1M。它没有 trigram 可用，仍然要走 236 万条目的名字扫描；`ext:` 字典不能直
接回答 glob，除非优化器识别 `*.ext` 形式。其余查询目标全部达标。

## 5. 调优清单

按预期收益排序，均尚未实现；实现后需要重跑本文的两份报告。

1. **稠密范围切片的位图构建**。`RangeIndex::slice` 先复制并全局排序 id，再逐个
   `Bitmap::add`；对 150 万级集合（全量树的 `size:>1kb`、主数据集的
   `dm:thisyear`）分别达到 84 ms 和 31 ms。建议按 65536 的块分桶、块内排序去重、
   直接写 word；`And(小 Const, Range)` 可改为遍历小集合、按 id 查值，避免物化大
   范围集。目标是把稠密范围降到个位数毫秒。
2. **数据库加载**。1.22M 条目 1.14 s、2.36M 条目 2.45 s，距 800 ms/1M 目标还差
   约 20%。建议先做 section 级计时，区分读文件、解码 names、重建 `Store`、恢复
   ranges/postings 的耗时；再考虑零拷贝/mmap 或按需加载 `RANGES`。
3. **CLI 交互延迟**。每次调用都完整加载数据库；1.1–2.5 s 的启动成本不适合交互
   式反复查询。中期方案是常驻进程（daemon/keep-alive）或 `--database` 的共享内存
   缓存；短期可以在文档中明确“单次 CLI 不是 1 ms 级路径”。
4. **索引体积**。`RANGES` 已是 29.3 MB（1.22M）/ 56.7 MB（2.36M），是超出 1.5×
   预算的主因。可对 `(value, id)` 的值列做 delta 编码，或把 `mtime` 留作惰性字段；
   `POSTINGS` 已经是 delta-varint，继续压缩空间有限。
5. **`*.ext` 的 glob 快路径**。`*.pdf` 与 `ext:pdf` 语义等价（忽略文件名里含
   `/` 的边界），编译器可在纯净 `*.ext` 模式上直接取扩展名字典；这样 143 ms 的
   全量扫描会变成一次字典查找。需要同时在扫描引擎保持等价，避免两引擎分叉。
6. **建索引峰值 RSS**。构建期 776 MiB（1.22M）/ 1.4 GiB（2.36M），查询态只有
   362 MiB / 679 MiB。可把 trigram 构建拆成分片、尽早释放哈希表，或改成两遍扫描
   （先计数再写 posting）。

## 6. 与 FSearch 的同条件对照（S14 补充）

评审反馈要求补足上游依据和同条件对照。本节使用 FSearch 自身的 core library
（无 GUI）在同一棵树上测查询，回答“单遍逐条目求值”与“索引候选生成 + 集合代数”
在同数据、同查询下的实际差异。完整表格、原始 TSV 和复现脚本在
`bench/fsearch-compare/`；汇总报告是 `bench/fsearch-compare/results-plugin.md`。

### 6.1 方法

- 上游：FSearch 0.3-dev，commit `1208a34`。查询路径是单遍、逐条目求值：
  `src/fsearch_database_index_store.c:227` 的 worker 对每个 entry 调用
  `fsearch_query_match()`；`:1401` 的 `index_store_search()` 按线程切分；
  `src/fsearch_query.c:138` 的 `matches()` 对查询树做 AND/OR 短路。因此不存在
  “每个条件遍历一遍”。
- 数据：`~/Documents/workspace/plugin`，25,424 个文件夹 + 272,171 个文件 =
  297,595 个条目，2026-11-18 快照。
- 口径：FSearch worker pool 固定 1 线程，与单线程 moonsearch 对齐；取多次运行的
  中位数。另测 FSearch 默认多线程作为产品参考。
- 缓存：查询都在索引驻留后测量（FSearch 先建内存索引并热身，moonsearch 先加载
  数据库）；构建与加载是单独的冷路径，不计入查询延迟。
- 结果模式：`count` 只取集合基数；`full` 额外按规范顺序遍历并物化命中。两者分开，
  避免把“集合大小”当成“完整搜索结果”。
- moonsearch 的扫描引擎与位图引擎共用词法/语法/谓词，FSearch 与扫描引擎在语义上
  同构，因此“扫描 → 位图”的差异可以归因于候选源替换。
- Everything 闭源，只作语义参考，不作为性能基线。

### 6.2 代表性与退化结果（毫秒）

| 查询 | 命中 | FSearch 1T | moonsearch scan | bitmap count | bitmap full | FSearch/full |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `ext:jpg` | 9 | 8.581 | 7.060 | 0.037 | 1.030 | 8.3× |
| `ext:jpg size:>1mb` | 2 | 8.085 | 7.488 | 0.058 | 0.627 | 12.9× |
| `report` | 192 | 14.403 | 10.343 | 0.049 | 2.730 | 5.3× |
| `report pdf` | 0 | 16.327 | 11.433 | 0.054 | 0.371 | 44.0× |
| `index` | 18,139 | 13.904 | 11.829 | 1.071 | 5.062 | 2.7× |
| `size:>1mb` | 1,552 | 6.875 | 4.516 | 0.056 | 4.480 | 1.5× |
| `source map` | 450 | 15.995 | 11.051 | 3.741 | 6.874 | 2.3× |
| `a` (1 字节) | 172,894 | 10.110 | 9.709 | 10.942 | 11.841 | 0.85× |
| `ab` (2 字节) | 6,088 | 13.090 | 12.112 | 14.883 | 20.245 | 0.65× |
| `.js` (stop-gram) | 142,693 | 13.361 | 11.812 | 12.379 | — | — |
| `size:>1kb` (稠密) | 201,582 | 6.729 | 5.699 | 10.454 | 11.470 | 0.59× |
| `dm:thisyear` (99.98%) | 297,536 | 7.334 | 5.692 | 7.760 | 8.497 | 0.86× |
| `*.pdf` (glob) | 0 | 13.866 | 17.558 | 14.415 | 14.757 | 0.94× |
| `regex:^report.*\.pdf$` | 0 | 9.934 | 19.496 | 18.547 | 18.900 | 0.53× |
| `path:src` | 14,367 | 80.982 | 140.808 | 123.016 | 127.574 | 0.63× |
| 空查询 | 297,595 | 0.136 | 1.011 | 0.036 | 0.726 | 0.19× |

关键读数：

- 选择性高的可索引查询，完整搜索相对 FSearch 单线程快 1.5–44×；退化查询
  （短 needle、stop-gram、glob/regex/`path:`、稠密范围、空查询）反而更慢，
  `FSearch/完整` 为 0.19–0.94（即 moonsearch 慢 1.1–5.3×）。
- `source map` 只有 450 个命中却要 3.741 ms；`ing` 有 8,151 个命中只要 0.603 ms。
  成本由 posting 长度/交集决定，不由命中数决定。
- 结果物化不可忽略：`ext:jpg` 的集合是 0.037 ms，完整搜索是 1.030 ms；空查询是
  0.036 ms → 0.726 ms。
- 与 FSearch 默认多线程相比，完整搜索在 `report`（2.730 vs 2.075 ms）、
  `source map`（6.874 vs 2.301 ms）等场景已经落后；`count` 仍有优势（`report`
  0.049 vs 2.075 ms）。当前实现是单线程的，不能把这些场景说成“更快”。
- `size:>1kb` 的命中数 FSearch 为 201,582、moonsearch 为 201,557；差异来自
  符号链接尺寸（FSearch 计入文件夹子树的 `st_size`，moonsearch 按 0 字节索引）。
  `file:size:>1000` 两边一致（179,570）。

### 6.3 构建、更新与内存

| 指标 | moonsearch + trigram | moonsearch `--no-trigram` | FSearch 1T |
| --- | ---: | ---: | ---: |
| 构建 | 20.9 s | 18.0 s | 4.8–7.6 s |
| 构建峰值 RSS | 172 MiB | 160 MiB | 49 MiB |
| 数据库 | 22.5 MB | 17.5 MB | 未测 |
| 加载 | ~0.26 s | ~0.24 s | 未测 |
| 查询态 RSS | 96 MiB | — | 49 MiB（构建 + 查询） |
| `update` | 21.2 s，全量重建 | — | — |

FSearch 的数字是内存索引构建，不建 trigram、不写数据库；这不是同工作量的对比。
moonsearch 的构建成本不占优，用构建/更新/内存换查询。Trigram 的代价约为
+2.9 s（+16%）、+5.0 MB 数据库（+29%）、+11 MiB 峰值 RSS；收益集中在名字子串
（`report` 263×、`the` 228×、`node_modules` 99×、`index` 12.6×、`source map`
4.2×），对 glob/regex/`path:`/短 needle 没有帮助。

### 6.4 小树交叉点

同一套代码在 2,272 条目的 moonsearch 仓库上：moonsearch 构建 0.17 s、数据库
271 KB、加载 1.5–1.9 ms；FSearch 构建 0.024 s。查询上 FSearch 为 0.002–0.088 ms，
moonsearch 为 0.034–0.128 ms。小树上索引没有稳定优势，加载时间比多数查询还大。

### 6.5 结论

优势应表述为条件化的：大索引 + 选择性高且可索引的谓词，完整搜索相对 FSearch
单线程快 1.5–44×、count 快 4–300×；短 needle、stop-gram、glob/regex/`path:`、
稠密范围、小树和一次性搜索不占优，完整结果物化与 FSearch 多线程相比也可能落后。
代价是 20.9 s 构建、21.2 s 全量更新、96 MiB 查询态内存和每进程约 0.26 s 的加载。
这比“多条件必然多次全表遍历”“成本只由命中集决定”更准确，也更可检验。

复现：

```bash
# 示例查询；完整查询集合见 bench/fsearch-compare/results/*.tsv 的 QUERY/BENCH 名称
# 同一棵树上的 FSearch core harness（1 线程）
TZ=Asia/Shanghai /tmp/bench_fsearch --threads 1 --root ~/Documents/workspace/plugin \
  --runs 5 'ext:jpg' 'report' 'a' 'size:>1kb'

# moonsearch 两引擎
_build/native/release/build/cmd/moonsearch-bench/moonsearch-bench.exe \
  --database /tmp/plugin.msdb --engine bitmap --runs 5 'report'

# 合并报告（base + extra + common + stopgram 全量输入）
python3 bench/fsearch-compare/compare.py \
  --fsearch bench/fsearch-compare/results/fsearch-plugin-st.tsv \
  --fsearch bench/fsearch-compare/results/fsearch-plugin-extra.tsv \
  --fsearch bench/fsearch-compare/results/fsearch-common.tsv \
  --fsearch bench/fsearch-compare/results/fsearch-stopgram.tsv \
  --scan bench/fsearch-compare/results/scan.tsv \
  --scan bench/fsearch-compare/results/scan-extra.tsv \
  --scan bench/fsearch-compare/results/scan-common.tsv \
  --scan bench/fsearch-compare/results/scan-stopgram.tsv \
  --bitmap bench/fsearch-compare/results/bitmap.tsv \
  --bitmap bench/fsearch-compare/results/bitmap-extra.tsv \
  --bitmap bench/fsearch-compare/results/bitmap-common.tsv \
  --bitmap bench/fsearch-compare/results/bitmap-stopgram.tsv \
  --bitmap-full bench/fsearch-compare/results/bitmap-fullwalk-all.tsv \
  --no-trigram bench/fsearch-compare/results/bitmap-notrigram.tsv \
  --label plugin-297k --markdown /tmp/results.md
```

## 7. 演示与录屏

`bench/demo.sh` 在临时目录生成一棵小树，依次演示建索引、trigram 查询、位图 ×
范围、`--explain`、`count`、排序/JSON、扫描引擎对照和 `info --verify`。脚本只依
赖仓库自身的 release 二进制，不读写用户的数据库。

```bash
bash bench/demo.sh

# 若安装了 asciinema：
asciinema rec bench/demo.cast -c "bash bench/demo.sh"
```

录屏文件不提交到仓库；`demo.sh` 是可复现的演示源，输出顺序和查询都固定。

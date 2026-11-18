# 基准测试与调优记录（S14）

本文说明 `moonsearch` 的基准口径、复现方式、实测结果和后续调优清单。原始报告由
`bench/run_bench.py` 生成：

- `bench/results.md` / `bench/results.json`：主数据集，1,219,537 条目。
- `bench/results-full-tree.md` / `bench/results-full-tree.json`：全量压力数据集，
  2,362,503 条目。

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

## 6. 演示与录屏

`bench/demo.sh` 在临时目录生成一棵小树，依次演示建索引、trigram 查询、位图 ×
范围、`--explain`、`count`、排序/JSON、扫描引擎对照和 `info --verify`。脚本只依
赖仓库自身的 release 二进制，不读写用户的数据库。

```bash
bash bench/demo.sh

# 若安装了 asciinema：
asciinema rec bench/demo.cast -c "bash bench/demo.sh"
```

录屏文件不提交到仓库；`demo.sh` 是可复现的演示源，输出顺序和查询都固定。

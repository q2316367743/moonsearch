# 基准测试与调优记录（S12）

本文说明 `moonsearch` 的基准口径、复现方式、实测结果和后续调优清单。S12 起主口径改为
可由干净克隆重建的确定性合成数据集；私有工作树只作为补充快照，不再作为验收依据。

原始报告由 `bench/run_bench.py` 生成：

- `bench/results.md` / `bench/results.json`：**主口径**，`synthetic-1m`，
  1,030,056 条目。
- `bench/results-private.md` / `bench/results-private.json`：**补充口径**，私有三根
  快照，1,030,277 条目；无法由干净克隆重建。
- `bench/fsearch-compare/results-synthetic-300k.md`：可复现的 FSearch 同条件对照，
  300,000 条目。
- `bench/fsearch-compare/results-plugin.md`：2026-11-18 的私有历史快照，仅作参考。

## 1. 测量口径

| 指标 | 工具 | 口径 |
| --- | --- | --- |
| 建索引 | `index --stats` + `/usr/bin/time -l` | 扫描、构建 `Store`、字典/范围/posting、原子写库的总墙钟；RSS 为进程峰值 |
| 数据库加载 | `moonsearch-bench` | `Index::read_database` 单次调用的墙钟，不含查询 |
| 引擎延迟 | `moonsearch-bench` | 一次加载后，对 `exec_indexed` / `exec_scan_with` 采样；包含查询编译，与 CLI 每次调用一致。`moonbitlang/core/bench` 用原生单调时钟，批量到约 100 ms，取中位数 |
| CLI 墙钟 | `bench/run_bench.py` | 正常可执行文件的一次完整调用：解析参数、加载数据库、执行、格式化、退出；一次热身后的 3 次中位数 |
| 查询态 RSS | `/usr/bin/time -l` | 一次 `count --engine bitmap report` 的进程峰值 |
| 索引体积 | `info` | 各 section 的字节数；基础体积分别按“序列化 NAMES”和“原始 NamePool”两种口径计算，见 §3.4 |

引擎延迟与 CLI 墙钟刻意分开：前者回答“索引结构本身多快”，后者回答“用户敲一次命令
等多久”。当前 CLI 每次调用都要重新加载数据库，所以 CLI 墙钟由加载时间主导。

**冷/热缓存。** 本文所有加载与查询数字都是**热页缓存**：数据库刚由建索引写出或刚被
基准进程读过，没有执行 `purge`/`drop_caches`。因此它们不代表冷盘首次读取；冷启动可能
更慢。建索引本身是对目录树的一次性扫描，文件元数据是否在缓存中取决于运行前的系统状态，
本文没有单独控制。没有测量冷缓存数字，也不把热缓存数字说成冷启动。

**单次/中位数。** 建索引和数据库加载是单次墙钟；引擎延迟是进程内 5 次采样的中位数；
CLI 是 3 次采样的中位数；RSS 是单次峰值。

**环境。** Apple M4 Pro、48 GiB、macOS 26.6.2、MoonBit `0.1.20261126 (ccd306a
2026-11-26)`、release 构建。测量期间（2026-11-28 15:10–15:21）机器 load average
在 1 分钟 12–17、15 分钟 32–54 之间，明显高于空闲状态；绝对延迟因此偏保守。所有比较
使用同一时段内的中位数，但跨日比较仍应在空闲机器上重跑。测量提交见
`bench/results.json` 的 `machine.commit` 字段。

## 2. 复现

主基准完全由仓库内脚本生成，不读取用户目录：

```bash
# 1. 生成确定性数据集：1,030,056 条目，稀疏文件，固定 mtime
python3 bench/gen_dataset.py --dir bench/.data/synthetic-1m --entries 1030056 \
  --reference-time 2026-11-28T00:00:00Z \
  --manifest-json bench/.data/synthetic-1m.manifest.json

# 2. 构建 release 二进制并跑 12 项基准
moon build --target native --release
python3 bench/run_bench.py --label synthetic-1m \
  --root bench/.data/synthetic-1m --rebuild-index

# 3. 随时重新计算 manifest（不生成文件）
python3 bench/gen_dataset.py --manifest-only --dir bench/.data/synthetic-1m
```

生成器对固定 `--reference-time` 是确定性的：名字、扩展名、大小和相对 mtime 都由条目
序号推导，不使用随机数；文件是稀疏文件，不写内容。主数据集 manifest：

```text
entries              1,030,056 (103,006 folders + 927,050 files)
total_file_bytes     7,870,520,001
manifest_sha256      d907e16671e4547db803a128098df08f28c139e56c776e7a19d69c46aaed6c81
manifest_fields      relative_path, type, size, mtime_seconds
```

`bench/.data/` 与 `bench/.work/` 在 `.gitignore` 中，生成物不提交；脚本、manifest
命令和哈希提交。FSearch 对照的生成与运行命令见 §6 和
`bench/fsearch-compare/README.md`。

`run_bench.py` 在数据库缺失或传入 `--rebuild-index` 时先建索引，并把建索引的时间、
RSS 和 `--stats` 摘要写进 `<work-dir>/<label>-index.json`；复用数据库时读取该文件。

`moonsearch-bench` 也可以单独使用：

```bash
moon run cmd/moonsearch-bench -- --database DB --engine bitmap --runs 10 'report'
moon run cmd/moonsearch-bench -- --database DB --engine scan   --runs 10 'report'
moon run cmd/moonsearch-bench -- --database DB --engine bitmap --count 'ext:mp4'
moon run cmd/moonsearch-bench -- --database DB --engine bitmap --first 20 ''
```

它每次输出一行 `LOAD` 和若干行 `BENCH`（TSV，最后一列是核心库的 JSON 摘要），不
打印命中路径，因此适合脚本和录屏之外的精确测量。

## 3. 主口径：确定性合成数据集（1,030,056 条目）

数据：103,006 个文件夹、927,050 个文件、145,930 个不同名字；数据库 105.1 MiB
（110,179,928 字节）。构建参数与 manifest 见 §2。

### 3.1 十二项验收目标

目标来自 `MIGRATION_PLAN.md` §10.1，建索引/加载/RSS 按条目数线性折算
（1,030,056 / 1,000,000 = 1.030056）。

| # | 项目 | 目标（1M） | 折算目标 | 实测 | 结论 |
| ---: | --- | ---: | ---: | ---: | --- |
| 1 | 扫描 + 建索引 | < 90 s | 92.7 s | 28.4 s | 达标 |
| 2 | 数据库加载 | < 800 ms | 824 ms | 183 ms | 达标 |
| 3 | `ext:jpg` bitmap | < 1 ms | — | 36.2 µs | 达标 |
| 4 | `ext:jpg size:>1mb` | < 5 ms | — | 66.4 µs | 达标 |
| 5 | `ext:jpg size:>1mb dm:lastweek` | < 8 ms | — | 76.8 µs | 达标 |
| 6 | `report` | < 20 ms | — | 1.96 ms | 达标 |
| 7 | `report pdf` | < 40 ms | — | 2.02 ms | 达标 |
| 8 | `*.pdf`（glob） | < 120 ms | — | 72.71 ms | 达标 |
| 9 | `count ext:mp4` | < 1 ms | — | 36.6 µs | 达标 |
| 10 | 空查询 + `-n 20` | < 1 ms | — | 36.4 µs | 达标 |
| 11 | 索引额外体积 | < 1.5× | — | 2.86× / 1.66× | **未达标** |
| 12 | 查询态常驻内存 | < 400 MB | 412 MiB | 332.4 MiB | 达标 |

第 11 项的两个数字分别是“序列化 NAMES”与“原始 NamePool”口径，定义、拆分和后续计划
见 §3.4。其余 11 项在主口径上达标。

### 3.2 引擎延迟

`moonsearch-bench` 一次加载后采样，包含查询编译。中位数：

| 查询 | 目标 | bitmap 中位数 | scan 中位数 | 命中 | 结论 |
| --- | ---: | ---: | ---: | ---: | --- |
| `ext:jpg` | < 1 ms | 36.2 µs | 41.45 ms | 927 | 达标 |
| `ext:jpg size:>1mb` | < 5 ms | 66.4 µs | 48.56 ms | 3 | 达标 |
| `ext:jpg size:>1mb dm:lastweek` | < 8 ms | 76.8 µs | 55.66 ms | 0 | 达标 |
| `report` | < 20 ms | 1.96 ms | 43.88 ms | 30,805 | 达标 |
| `report pdf` | < 40 ms | 2.02 ms | 46.41 ms | 930 | 达标 |
| `*.pdf` | < 120 ms | 72.71 ms | 67.79 ms | 930 | 达标 |
| `source map` | < 40 ms | 9.11 ms | 46.21 ms | 2,111 | 达标 |
| `count ext:mp4` | < 1 ms | 36.6 µs | — | 925 | 达标 |
| 空查询 + `-n 20` | < 1 ms | 36.4 µs | 35.8 µs | 1,030,056 | 达标 |

### 3.3 CLI 墙钟

每次 CLI 调用都重新加载数据库，因此这一列是用户可见成本，不是 §3.2 的引擎成本。
一次热身后的 3 次中位数：

| 命令 | 引擎目标 | 中位墙钟 | 最小墙钟 |
| --- | ---: | ---: | ---: |
| `search 'ext:jpg'` | 1.0 ms | 201.9 ms | 201.4 ms |
| `search 'ext:jpg size:>1mb'` | 5.0 ms | 192.2 ms | 190.8 ms |
| `search 'ext:jpg size:>1mb dm:lastweek'` | 8.0 ms | 175.3 ms | 174.6 ms |
| `search 'report'` | 20.0 ms | 210.6 ms | 208.7 ms |
| `search 'report pdf'` | 40.0 ms | 207.6 ms | 203.1 ms |
| `search '*.pdf'` | 120.0 ms | 270.9 ms | 270.4 ms |
| `search 'source map'` | 40.0 ms | 219.2 ms | 212.0 ms |
| `count 'ext:mp4'` | 1.0 ms | 191.2 ms | 187.5 ms |
| `search -n 20 ''` | 1.0 ms | 189.0 ms | 187.5 ms |

CLI 墙钟由约 183 ms 的数据库加载主导；引擎本身是几十微秒到几十毫秒。交互式反复查询的
瓶颈在加载，不在查询算子。

### 3.4 索引体积：两种口径

第 11 项目标写作“< 1.5× 名字池+条目”。这个分母有两种合理解释，S12 同时报告：

| 口径 | 基础体积（分母） | 额外体积（分子） | 倍数 | 结论 |
| --- | ---: | ---: | ---: | --- |
| 序列化 NAMES | 28,554,707 B（NAMES + FOLDERS + FILES） | 81,625,221 B | **2.86×** | 未达标 |
| 原始 NamePool | 41,412,771 B（`name_bytes` + FOLDERS + FILES） | 68,767,157 B | **1.66×** | 未达标 |

- 序列化口径对应数据库里实际写出的 NAMES 段（前向编码后 949,203 B），是
  `bench/run_bench.py` 的 base 定义。
- 原始口径使用 `index --stats` 报出的 `name_bytes`（13,807,267 B，即名字原始字节
  总和），更接近“名字池”的字面含义，也更宽松。
- 即使按更宽松的原始口径，1.66× 仍比 1.5× 高约 10.7%。总文件 / 序列化基础为 3.86×。

Section 明细：

| Section | 字节 | 占额外体积 |
| --- | ---: | ---: |
| names | 949,203 | —（基础） |
| folders | 3,502,204 | —（基础） |
| files | 24,103,300 | —（基础） |
| ranges | 50,678,777 | 62.1% |
| parent-paths | 13,439,312 | 16.5% |
| postings | 11,890,699 | 14.6% |
| order | 4,120,224 | 5.0% |
| dict | 1,495,802 | 1.8% |
| excludes | 4 | 0.0% |
| roots + checksum + header/table | 403 | 0.0% |
| **total** | **110,179,928** | |

`ranges` 的五个核心字段每个是 `5 B 字段头 + 12 B × 条目数`（8 B value + 4 B id）：

| 字段 | 条目数 | 字节 |
| --- | ---: | ---: |
| size | 1,030,056 | 12,360,677 |
| mtime | 1,030,056 | 12,360,677 |
| depth | 1,030,056 | 12,360,677 |
| childcount | 103,006 | 1,236,077 |
| parent | 1,030,055 | 12,360,665 |
| field count | — | 4 |
| **合计** | | **50,678,777** |

**未达标原因。** `RANGES` 对每个条目的每个核心字段都存一对未压缩的 `(i64 value,
u32 id)`，五个字段共 50.7 MB，占额外体积的 62%。`size`、`mtime`、`depth` 都是每个
条目一条记录，即使值分布可以用 delta 或分块编码压缩，当前格式没有做。`parent-paths`
再占 13.4 MB（完整绝对路径）。`postings` 已是 delta-varint，继续压缩空间有限。

**后续计划（S12 不修改数据库格式）。**

1. 确认验收口径：建议以原始 NamePool 为分母，或明确“序列化 NAMES”；两种口径都保留
   在报告中，避免下次再出现 1.58× 与 1.66× 混淆。
2. `RANGES` 值列与 id 列分开，做 delta/varint 或分块（block）编码；`size`/`mtime`
   这类近似有序的值列收益最大。格式变更需要升次版本并同步 `docs/db-format.md` 与
   布局测试。
3. 评估 `depth` 是否必须全量持久化：它可由父链在加载时派生，或只存分块索引；这会把
   12.4 MB 从磁盘换到加载 CPU，需要同时测加载时间。
4. `PARENT_PATHS` 改成“父 id + 单段名字”或前缀压缩，去掉完整路径重复。
5. 任何格式变更后重跑 §3.1 全部 12 项，确认加载仍 < 800 ms/1M。

### 3.5 数据库加载：S12 前后

| 数据集 | S12 前 | S12 后 | 目标（折算） | 结论 |
| --- | ---: | ---: | ---: | --- |
| 私有三根，1,030,277 条目 | 949 ms | 192 ms | 824 ms | 达标 |
| 合成，1,030,056 条目 | — | 183 ms | 824 ms | 达标 |

S12 前，普通加载会用 `validate_canonical_order` 为每个同名条目物化完整路径，验证
ORDER 的 `(name, path)` 全序；在 1M 条目上这一步约占 740 ms。S12 把完整路径 tie-break
移入 `verify=true` 深语义分支（与 S08 的加载分层一致），普通加载保留：

- ORDER 是 `0..total-1` 的排列、无重复、id 在范围内；
- 相邻条目的名字非递减（按名字排序的查询不会在乱序 ORDER 上提前停止）。

`verify=true` 仍执行完整规范顺序、字典/范围/posting/父路径的语义重算。实测
`info --verify` 在合成库上 2.13–2.20 s，私有库 2.14–2.23 s；这是显式的深度校验成本，
不是普通加载路径。

**1M 折算方法。** 目标按 `800 ms × 条目数 / 1,000,000` 线性折算；实测是单次
`Index::read_database` 墙钟，不含查询与进程启动。

### 3.6 建索引与 trigram

`--stats` 细节：`scan: 26,340 ms`，`database: 110,179,928 bytes`，
`names: 1,030,056 names, 13,807,267 bytes`，`extensions: 11`，`hidden: 916`，
`ranges: size=1030056 mtime=1030056 depth=1030056 childcount=103006 parent=1030055`，
`trigram: 872 keys, 11,745,410 postings, 0 short names, 2 stop-grams, 46,981,640 B`。

建索引峰值 RSS 681.3 MiB，主要是构建期 trigram 哈希表；查询态 RSS 332.4 MiB。
trigram 在这个数据集上只增加 872 个键，因为名字模板重复度高；它的收益仍集中在名字
子串查询（§3.2 的 `report`、`source map`）。

## 4. 补充口径：私有三根快照（1,030,277 条目）

数据：`~/Documents/workspace/{app,dashou-plugin,plugin}`，93,689 个文件夹、
936,588 个文件、171,485 个不同名字；数据库 109.7 MiB。该树是私有工作区，
**不能由干净克隆重建**，只用于交叉验证主口径，不替代主口径。

各根的 metadata manifest（字段同上）：

| 根 | 条目 | manifest SHA-256 |
| --- | ---: | --- |
| `~/Documents/workspace/app` | 302,307 | `52fc49571ddde05143a4f7e2c50b383f8a661a63197642f0465671fe92afdb4a` |
| `~/Documents/workspace/dashou-plugin` | 705,445 | `c6f54b42ced235867631545b47911a023717d6cbc4e73140b8e0131b61c6e2a7` |
| `~/Documents/workspace/plugin` | 22,525 | `a1c91b0f02593e19c8a2ad3682bf0144670b93f99e6c4cab45127ee66990c3bc` |

实测：构建 27.4 s、加载 192 ms、查询态 RSS 371.8 MiB、数据库 115,005,406 B；
索引额外体积 2.80×（序列化 NAMES）/ 1.61×（原始 NamePool），同样未达 1.5×。

| 查询 | 目标 | bitmap 中位数 | scan 中位数 | 命中 | 结论 |
| --- | ---: | ---: | ---: | ---: | --- |
| `ext:jpg` | < 1 ms | 33.7 µs | 42.26 ms | 73 | 达标 |
| `ext:jpg size:>1mb` | < 5 ms | 301.1 µs | 51.67 ms | 2 | 达标 |
| `ext:jpg size:>1mb dm:lastweek` | < 8 ms | 3.42 ms | 59.53 ms | 0 | 达标 |
| `report` | < 20 ms | 73.0 µs | 47.48 ms | 419 | 达标 |
| `report pdf` | < 40 ms | 252.8 µs | 49.91 ms | 0 | 达标 |
| `*.pdf` | < 120 ms | 83.49 ms | 76.36 ms | 4 | 达标 |
| `source map` | < 40 ms | 12.20 ms | 49.19 ms | 2,445 | 达标 |
| `count ext:mp4` | < 1 ms | 34.0 µs | — | 25 | 达标 |
| 空查询 + `-n 20` | < 1 ms | 33.5 µs | 33.9 µs | 1,030,277 | 达标 |

私有库的 `ranges` 是 50,577,557 B（size/mtime/depth 各 12,363,329 B，childcount
1,124,273 B，parent 12,363,293 B），与合成库同量级；这确认体积问题不是合成数据
特有的。

## 5. 调优清单

按预期收益排序，均尚未实现；实现后需要重跑本文的两份报告。

1. **`RANGES` 压缩/分块**。见 §3.4 的后续计划；这是索引体积未达标的主因，也可能
   顺带降低加载时间。
2. **CLI 交互延迟**。每次调用加载约 183–192 ms；引擎只需几十微秒到几十毫秒。
   中期方案是常驻进程（daemon/keep-alive）或共享内存缓存；短期在文档中明确
   “单次 CLI 不是 1 ms 级路径”。
3. **`PARENT_PATHS` 前缀压缩**。13.4 MB 的完整绝对路径重复了父目录前缀；改成
   “父 id + 单段名字”需要改 section，属于下一次格式变更。
4. **稠密范围切片的位图构建**。`RangeIndex::slice` 先复制并全局排序 id，再逐个
   `Bitmap::add`；密集的 `size:>1kb`、`dm:thisyear` 仍达到十几毫秒。按 65536 分块
   排序或直接遍历小集合查值可把密集范围降到个位数毫秒。
5. **`*.ext` 的 glob 快路径**。`*.pdf` 与 `ext:pdf` 语义近似，编译器可在纯净
   `*.ext` 模式上直接取扩展名字典。需要扫描引擎保持等价，避免两引擎分叉。
6. **建索引峰值 RSS**。构建期 681 MiB（1M）/ 204 MiB（300k），查询态只有 332 MiB。
   可把 trigram 构建拆成分片、尽早释放哈希表，或两遍扫描。
7. **冷缓存基准**。本文没有冷盘数字；如需验收冷启动，应在独立机器上用 `purge`
   或重启后测量，并单独列表。

## 6. 与 FSearch 的同条件对照

评审反馈要求补足上游依据和同条件对照。本节使用 FSearch 自身的 core library
（无 GUI）在同一棵确定性合成树上测查询，回答“单遍逐条目求值”与“索引候选生成 +
集合代数”在同数据、同查询下的实际差异。完整表格、原始 TSV 和复现脚本在
`bench/fsearch-compare/`；主报告是 `results-synthetic-300k.md`。

### 6.1 方法

- 上游：FSearch 0.3-dev，commit `1208a34`。查询路径是单遍、逐条目求值：
  `src/fsearch_database_index_store.c:227` 的 worker 对每个 entry 调用
  `fsearch_query_match()`；`:1401` 的 `index_store_search()` 按线程切分；
  `src/fsearch_query.c:138` 的 `matches()` 对查询树做 AND/OR 短路。因此不存在
  “每个条件遍历一遍”。
- 数据：`bench/.data/synthetic-300k`，30,000 个文件夹 + 270,000 个文件 =
  300,000 个条目；manifest SHA-256
  `4cc38f9684090e853b1583a03e9e503cf701a97e76ddf3ae3bd1da53d3db18cf`。
- 口径：FSearch worker pool 固定 1 线程，与单线程 moonsearch 对齐；取 5 次运行的
  中位数。FSearch 的构建 3.56 s 是内存索引构建，不含持久库写入。
- 缓存：查询都在索引驻留后测量（FSearch 先建内存索引并热身，moonsearch 先加载
  数据库）；构建与加载是单独的冷路径，不计入查询延迟。均为热缓存。
- 结果模式：`bitmap` 只取集合基数；`bitmap full` 额外按规范顺序遍历并物化命中
  （`--first 400000`，大于命中数），与 FSearch 完整搜索同形。两者分开，避免把
  “集合大小”当成“完整搜索结果”。
- moonsearch 的扫描引擎与位图引擎共用词法/语法/谓词，FSearch 与扫描引擎在语义上
  同构，因此“扫描 → 位图”的差异可以归因于候选源替换。
- Everything 闭源，只作语义参考，不作为性能基线。

### 6.2 可复现结果（300,000 条目，毫秒）

| 查询 | 命中 | FSearch 1T | scan | bitmap count | bitmap full | FSearch/full |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 空查询 | 300,000 | 0.570 | 4.716 | 0.036 | 0.732 | 0.78× |
| `ext:jpg` | 269 | 11.243 | 12.376 | 0.037 | 2.729 | 4.12× |
| `ext:jpg size:>1mb` | 0 | 13.061 | 14.634 | 0.045 | 0.453 | 28.80× |
| `report` | 8,972 | 19.713 | 13.618 | 0.684 | 1.402 | 14.06× |
| `report pdf` | 271 | 20.251 | 14.354 | 0.703 | 3.575 | 5.66× |
| `source map` | 614 | 21.489 | 14.298 | 2.774 | 6.441 | 3.34× |
| `*.pdf`（glob） | 271 | 13.114 | 20.497 | 22.061 | 25.021 | 0.52× |
| `regex:^report.*\.pdf$` | 270 | 12.651 | 20.585 | 21.996 | 25.200 | 0.50× |
| `a`（1 字节） | 119,812 | 16.780 | 13.510 | 15.695 | 17.853 | 0.94× |
| `ab`（2 字节） | 0 | 19.912 | 14.297 | 16.723 | 16.584 | 1.20× |
| `size:>1kb`（稠密） | 283,530 | 10.174 | 6.684 | 15.553 | 16.270 | 0.63× |
| `dm:thisyear` | 233,916 | 11.080 | 7.046 | 9.939 | 11.148 | 0.99× |
| `path:src` | 150,760 | 104.947 | 124.300 | 125.151 | 127.855 | 0.82× |
| `package.json` | 0 | 19.688 | 12.538 | 0.039 | 0.452 | 43.58× |
| `node_modules` | 3,750 | 19.313 | 12.381 | 0.239 | 4.300 | 4.49× |
| `.js` | 54,138 | 20.454 | 14.349 | 4.467 | 5.347 | 3.83× |

完整 34 条查询见 `bench/fsearch-compare/results-synthetic-300k.md`。

关键读数：

- 选择性高且可索引的完整搜索相对 FSearch 单线程快 2.65–47×（`size:>1mb` 2.65×、
  `report` 14.06×、`package.json` 43.58×、`ing` 47.07×）；对这些可索引查询，count
  路径为 0.036–4.467 ms，FSearch 同查询为 6.956–23.855 ms。短 needle、glob/regex、
  稠密范围的 count 只有 0.57–1.19×（基本持平或更慢）。
- 退化查询（短 needle、stop-gram、glob/regex/`path:`、稠密范围、空查询）的
  `FSearch/full` 为 0.50–0.99，即 moonsearch 慢 1.01–2×。`path:src` 两边都在
  100 ms 级，是共同瓶颈。
- 结果物化不可忽略：空查询 0.036 → 0.732 ms，`report` 0.684 → 1.402 ms，
  `source map` 2.774 → 6.441 ms。
- 成本由 posting 长度/候选规模决定，不由命中数决定：`source map` 614 命中要
  2.774 ms，`package.json` 0 命中只要 0.039 ms。
- 两处命中数差异是解析语义，不是缺条目：`ext:jpg OR ext:png` 差 14 个隐藏
  `.png`（moonsearch 把前导点视为无扩展名，FSearch 报 `png`）；`dm:lastweek`
  FSearch 解释为上一个日历周，moonsearch 解释为过去 7 天，268 个 0–4 天前的文件
  只落在后者。

### 6.3 历史私有快照（2026-11-18，297,595 条目）

`results-plugin.md` 使用 `~/Documents/workspace/plugin` 的 2026-11-18 快照，
不是主口径，也不能由干净克隆重建。代表性读数：

| 查询 | 命中 | FSearch 1T | bitmap count | bitmap full | FSearch/full |
| --- | ---: | ---: | ---: | ---: | ---: |
| `report` | 192 | 14.403 | 0.049 | 2.730 | 5.3× |
| `source map` | 450 | 15.995 | 3.741 | 6.874 | 2.3× |
| `a`（1 字节） | 172,894 | 10.110 | 10.942 | 11.841 | 0.85× |
| `*.pdf` | 0 | 13.866 | 14.415 | 14.757 | 0.94× |
| `path:src` | 14,367 | 80.982 | 123.016 | 127.574 | 0.63× |
| `size:>1kb` | 201,582 | 6.729 | 10.454 | 11.470 | 0.59× |

它与合成主口径的方向一致：可索引的高选择性查询领先，glob/regex/`path:`/短 needle/
稠密范围落后。旧表里的符号链接计数差异只适用于该私有树，不适用于合成树。

### 6.4 构建、更新与内存

合成 300k（可复现）：

| 指标 | moonsearch + trigram | moonsearch `--no-trigram` | FSearch 1T |
| --- | ---: | ---: | ---: |
| 构建 | 7.42 s | 4.25 s | 3.56 s |
| 构建峰值 RSS | 204.1 MiB | 155.6 MiB | 未测 |
| 数据库 | 31.0 MB | 27.7 MB | 未测 |
| 加载 | 59.9 ms | 未测 | 未测 |

FSearch 的数字是内存索引构建，不建 trigram、不写数据库；这不是同工作量的对比。
moonsearch 的构建成本不占优，用构建/更新/内存换查询。Trigram 的代价约为 +3.17 s、
+3.5 MB 数据库、+48.5 MiB 峰值 RSS；收益集中在名字子串（`report` 22.5×、
`the` 25.2×、`node_modules` 60×、`package.json` 369×），对 glob/regex/`path:`/
短 needle 没有帮助。历史私有树的构建/更新/内存数字见
`bench/fsearch-compare/costs.md`。

### 6.5 结论

优势应表述为条件化的：大索引 + 选择性高且可索引的谓词，完整搜索相对 FSearch
单线程快 2.65–47×、count 快约 4–585×；短 needle、stop-gram、glob/regex/`path:`、
稠密范围、小树和一次性搜索不占优，完整结果物化与 FSearch 多线程相比也可能落后。
代价是 0.2 s/1M 量级的每进程加载、1M 条目 28 s 构建与 681 MiB 构建峰值内存。
这比“多条件必然多次全表遍历”“成本只由命中集决定”更准确，也更可检验。

复现命令：

```bash
# 1. 生成 300k 确定性树
python3 bench/gen_dataset.py --dir bench/.data/synthetic-300k --entries 300000 \
  --reference-time 2026-11-28T00:00:00Z

# 2. 构建 FSearch core harness（需要 FSearch 1208a34 checkout 与 glib/pango/pcre2/icu）
PKG_CONFIG_PATH="$(brew --prefix icu4c)/lib/pkgconfig" \
  bash bench/fsearch-compare/build.sh /path/to/fsearch /tmp/bench_fsearch

# 3. moonsearch 建库
moon build --target native --release
_build/native/release/build/cmd/moonsearch/moonsearch.exe \
  -D bench/.work/synthetic-300k.msdb index -r bench/.data/synthetic-300k --stats

# 4. 两边的查询集合见 results/*.tsv；合并报告
python3 bench/fsearch-compare/compare.py \
  --fsearch bench/fsearch-compare/results/synthetic-fsearch.tsv \
  --scan bench/fsearch-compare/results/synthetic-scan.tsv \
  --bitmap bench/fsearch-compare/results/synthetic-bitmap.tsv \
  --bitmap-full bench/fsearch-compare/results/synthetic-bitmap-full.tsv \
  --no-trigram bench/fsearch-compare/results/synthetic-bitmap-notrigram.tsv \
  --label synthetic-300k \
  --markdown bench/fsearch-compare/results-synthetic-300k.md \
  --json bench/fsearch-compare/results-synthetic-300k.json
```

## 7. 演示与录屏

`bench/demo.sh` 在临时目录生成一棵小树，依次演示建索引、trigram 查询、位图 ×
范围、`--explain`、`count`、排序/JSON、扫描引擎对照和 `info --verify`。脚本只依
赖仓库自身的 release 二进制，不读写用户的数据库：

```bash
bash bench/demo.sh
```

录屏产物是 `bench/demo.cast`（asciicast v2，由 `bench/record_demo.py` 实际运行
`bench/demo.sh` 捕获，不是手工拼接）。有 `asciinema` 时：

```bash
asciinema play bench/demo.cast
```

没有 `asciinema` 时，`bench/record_demo.py` 可以重新生成同一条录制：

```bash
python3 bench/record_demo.py bench/demo.cast
```

## 8. 已知限制

- **索引体积未达标**：2.86×（序列化 NAMES）/ 1.66×（原始 NamePool），目标 < 1.5×；
  主因是 50.7 MB 的五字段 `RANGES` 与 13.4 MB 的 `PARENT_PATHS`。后续计划见 §3.4，
  S12 不修改数据库格式。
- **CLI 每次调用都加载数据库**：约 183–192 ms/1M，远大于引擎延迟；没有 daemon
  或共享缓存。单次 CLI 不是 1 ms 级路径。
- **冷缓存未测**：本文全部加载/查询数字是热页缓存；没有 `purge`/`drop_caches`。
- **机器负载偏高**：测量时 load average 1 分钟 12.86、15 分钟 54.04；绝对数字偏保守，
  跨日比较应在空闲机器上重跑。
- **verify 成本**：`info --verify` / `verify=true` 在 1M 条目上约 2.1–2.2 s，是显式
  深度校验，不是普通加载。
- **私有快照不可重建**：§4 与 §6.3 的数字只作补充，不替代 §3 的合成主口径。
- **FSearch 对照条件**：FSearch 是内存索引构建，moonsearch 包含 trigram 与持久库
  写入；构建数字不是同工作量对比。日期与隐藏文件扩展名存在已记录的解析差异。

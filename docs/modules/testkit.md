# testkit — 确定性随机源与查询语料（仅测试使用）

`src/testkit` 是 S13 的对拍基础设施：一个与平台无关的伪随机数生成器，以及按
“手写语义 / 随机生成 / explain 覆盖”三层组织的查询语料。它只被各包的 blackbox
测试通过 `for "test"` 导入，不进入任何生产路径。

## 职责

- 用固定种子生成可复现的随机数，使失败的 quickcheck 用例可以仅凭种子重跑。
- 维护查询语料，所有消费者（exec、ids、index、cli）使用同一份字符串列表。
- 保证语料中的每条查询都能被查询解析器接受；生成器只组合合法叶子与合法布尔
  连接词，不依赖错误恢复。

## 文件

| 文件 | 内容 |
| --- | --- |
| `rng.mbt` | `Rng`：xorshift64 状态、`below`、`between`、`chance`、`pick` |
| `corpus.mbt` | 语义语料、日期语料、转义边界语料、explain 语料、随机生成器 |

包本身没有 import，因此任何包都可以在自己的测试目标里依赖它，不会形成
“被测包 → testkit → 被测包”的循环。

## 确定性随机源

```moonbit
pub struct Rng {
  mut state : UInt64
}
```

- `Rng::new(seed)`：种子 0 被替换为黄金比例常量，避免 xorshift 的零状态。
- `Rng::below(bound)`：`[0, bound)`；`bound <= 0` 返回 0，调用方不必单独处理空数组。
- `Rng::between(low, high)`：闭区间；`high <= low` 时返回 `low`。
- `Rng::chance(percent)`：百分比概率。
- `Rng::pick(values)`：从非空 `Array[String]` 取一个元素。

实现只使用 `UInt64` 移位与异或，不读时钟、不读环境变量，因此同一 seed 在 macOS、
Linux 与 CI 上产生同一序列。测试失败消息会带上查询文本；种子在调用点写成常量，
复现时不需要额外记录。

## 三层语料

| 层 | 函数 | 内容 |
| --- | --- | --- |
| 1. 手写语义 | `semantic_queries` | 查询语言的全部字段、修饰符、布尔组合与边界：名字/大小写/整名/路径、glob、regex、`ext:`/分类、`file:`/`folder:`/`hidden:`、大小/深度/子项数/父路径/内容类型、绝对日期、AND/OR/NOT/括号 |
| 1. 手写补充 | `edge_queries` | 引号、反斜杠转义、保留字符、空白形态、`size: = 1500` 这类“冒号 + 空格 + 操作符”写法 |
| 1. 手写补充 | `date_queries` | `today`/`yesterday`/`lastweek`/`lastmonth`/`thisyear` 等依赖当前时钟的查询 |
| 2. 随机生成 | `generated_queries(seed, count)` | 深度受限的表达式生成器：叶子来自固定词汇，组合使用隐式 AND、`AND`、`OR`、`&&`、`||`、`NOT`、括号 |
| 3. explain 覆盖 | `explain_queries` | 每个计划节点与每种降级原因至少一条查询 |
| 汇总 | `differential_queries(seed, count)` | 三层合并，供 exec 对拍 runner 使用 |

`date_queries` 单独存放是因为结果依赖“现在”。exec 测试注入固定时钟
（2024-03-20 UTC），可以安全地跑；CLI 端到端对拍只使用绝对日期，避免两次引擎
调用跨越日历边界。

### 随机生成器

```text
expr(depth):
  depth == 0 或 45% 概率  → 叶子
  否则依次选择：
    !(expr) | expr expr | expr AND expr | expr OR expr
    expr && expr | expr || expr | (expr)
```

- 叶子词汇包含：普通名字、短 needle（< 3 字节）、大小写变体、unicode、带 `/` 的
  路径、glob、regex、全部字段、全部修饰符前缀与独立修饰符。
- 叶子本身总是合法；连接词与括号不改变合法性。生成器最深 3 层，查询长度有界。
- 生成器不产生需要 `--compat` 才能解析的输入；错误恢复由 `query` 包自己的测试
  覆盖。

### explain 覆盖

`explain_queries` 的补漏目标是计划的全部形态：

| 覆盖项 | 触发方式 |
| --- | --- |
| `Const` | `ext:pdf`、`size:>1kb`、`file:` 等 |
| `Trigram` | `report`、`exact:report` |
| `Scan` | `re`（short-needle）、`*.pdf`（glob）、`regex:`、`path:` |
| `Filter` | `*.pdf report` 把 glob 下推到 posting 候选集 |
| `And` / `Or` / `Not` | 布尔组合；未优化计划保留原始形状 |
| `childfilecount` / `childfoldercount` / `contenttype` | 对应字段叶子 |
| `stop-grams` | 全部名字共享 `test` 的夹具上查询 `test` |
| `no-trigram` | `--no-trigram` 索引上的名字查询 |

`scan_reasons()` 列出除 `no-index` 外的全部降级原因。`no-index` 是防御分支：
合法的 `TrigramIndex` 在跳过 posting 时必然计入 stop-gram，因此该原因不可达；
exec 的覆盖率测试额外断言它没有意外出现。

## 消费者

| 包 | 测试 | 用途 |
| --- | --- | --- |
| `exec` | `differential_test.mbt` | 三层语料在两套引擎、两种优化模式、多种夹具上的对拍；explain 覆盖率门禁 |
| `exec` | `property_test.mbt` | trigram 无漏报、数据库往返查询等价、输出顺序无关性 |
| `ids` | `property_test.mbt` | 随机集合的代数恒等式与序列化变异 |
| `index` | `db_fuzz_test.mbt` | 随机截断/翻转/插入/删除后的损坏库行为 |
| `cli` | `differential_test.mbt` | 持久化库、`--no-trigram` 库、`--live` 与输出选项的端到端字节对拍 |

## 约束

- 语料必须能被 `query.parse` 接受；新增算子时同时扩展语料与 `scan_reasons`。
- 生成器只使用测试代码，不读取真实文件系统；夹具由各测试包自行构造。
- `Rng` 不是密码学随机源，也不追求分布质量；它只需要确定性与足够的覆盖面。

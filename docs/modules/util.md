# util — 字节、路径、时间与分类

`src/util` 是最底层的纯函数包：没有文件系统、没有查询或索引类型依赖。扫描器、谓词、
字典都从这里取共享规则。

## 文件

| 文件 | 内容 |
| --- | --- |
| `bytes.mbt` | ASCII 折叠、字节相等、子串搜索、glob 元字符、`extension_of` |
| `path.mbt` | `join_path`、`is_within`、自然排序 `cmp_paths` |
| `glob.mbt` | `*` / `?` / `\` 通配符匹配 |
| `time.mbt` | 日期文本解析、本地时区、`DateSpan` |
| `category.mbt` | 内置分类 `TypeCategory` 与扩展名列表 |
| `dst_fixture_test.mbt` | 测试夹具：`America/New_York` TZif 的嵌入字节 |
| `testdata/` | 夹具源文件与再生成说明（IANA tz database，public domain） |

## 扩展名规则

`extension_of(name)` 是扫描谓词和字段字典共用的唯一实现：

- 空名字、以 `.` 开头的名字没有扩展名（隐藏文件不是扩展名）；
- 结尾的点不开始扩展名；
- 否则取最后一个点之后的全部字节，原样返回，由调用方决定是否 ASCII 折叠；
- 非 ASCII 字节原样保留，不做 Unicode 规范化。

## 分类

`TypeCategory` 有六个值：`App`、`Archive`、`Audio`、`Doc`、`Pic`、`Video`。
`TypeCategory::all()` 返回稳定顺序，`index()` 给出该顺序中的稠密下标。字典按这个下标
存放每个分类的集合，查询层按名字解析到分类。

`extensions()` 返回本项目自己的常见格式列表（ASCII 小写、无点号）。列表是扫描引擎与
字典的共同数据源；修改分类只改这一处。

`TypeCategory::of_extension(ext)` 反向查询扩展名所属分类，ASCII 大小写不敏感、不带
前导点；空扩展名与未收录扩展名返回 `None`。扩展名同时出现在多个分类时按
`TypeCategory::all()` 的顺序取第一个。输出层从同一份 `extensions()` 列表构建一次
映射来回答 `--sort type`、`{type}` 与 JSON `type`（避免逐条扫描）；`of_extension`
是等价的单次查询入口。查询谓词与字典仍用 `extensions()`。

## 输出相关的字节规则

`--sort ext` 与 `{ext}` 依赖 `extension_of` + `ascii_fold`；文件夹的扩展名由
`core::Store::entry_extension` 统一置空，避免“名字含点的文件夹”在输出层出现扩展名。

## 自然排序

`cmp_paths` 用于名字、路径与规范顺序：`\0` 权重 0、`/` 权重 1、其他字节按值；连续数字
按数值比较，前导零遵循 `strverscmp` 语义。合法 UTF-8 的字节序与码点序一致，非法 UTF-8
仍有确定顺序。

## 时间与 DST

`resolve_date_span(text, now, zone)` 的日历运算全部在传入的 `zone` 中完成：

- 一天是 `[本地 00:00, 次日本地 00:00)`，因此夏令时切换日是 23 或 25 小时，而不是
  固定 86400 秒；`today`、`yesterday`、`dm:` 的整天范围都走这条路径；
- 显式时间（`2024-03-10 02:30`）交给 `@time.date_time`，默认 `Disambiguation::Compatible`：
  不存在的本地时间向前平移跨越间隙，歧义的本地时间取较早的偏移；调用方可用 `Reject`
  得到错误；
- 固定偏移 zone 没有切换，所以每一天都恰好 24 小时，这是测试中“固定 TZ”的对照。

DST 测试不读宿主机的 `/usr/share/zoneinfo`：`dst_fixture_test.mbt` 嵌入一份
`America/New_York` TZif（public domain），断言 2024-03-10 是 23 小时、2024-11-03 是
25 小时，并固定不存在/歧义时刻的 UTC 结果。这样 Linux 与 macOS CI 得到同一结论；
替换夹具后按 `testdata/README.md` 的 `moon tool embed` 命令重新生成。

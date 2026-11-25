# query — 词法、语法与查询 AST

`src/query` 把命令行输入的查询字符串变成类型化的 `Query` 树。它只描述用户语义，不包含
候选集合或执行策略；位图执行器在 `exec` 中消费这棵树。

## 文件

| 文件 | 内容 |
| --- | --- |
| `lexer.mbt` / `token.mbt` | 词法单元、引号/转义、字段空值、位置 |
| `parser.mbt` | 优先级爬升、隐式 AND、修饰符作用域、错误恢复 |
| `query.mbt` | `Query`、`Term`、`TermBody`、`describe` |
| `flags.mbt` | 大小写/精确/路径/正则/类型/可见性修饰符 |
| `field.mbt` | `ext:`、`size:`、`dm:`、`count`、`parent:` 等字段解析 |
| `value.mbt` | 数值、大小、日期的文本解析 |
| `macros.mbt` / `macro_expand.mbt` | 用户宏表与独立解析器展开 |
| `errors.mbt` | `QueryError` 与稳定错误文本 |
| `regex.mbt` | 查询与排除规则共用的正则编译、大小写包装与字节主体匹配 |

## 语法要点

- 优先级：`NOT` > 隐式/显式 `AND` > `OR`；括号分组。
- 隐式 AND：下一个 token 能开始 primary，且上一个 token 结束了 primary 时插入 AND。
- 修饰符是前缀修饰符，只作用于紧随其后的一个 term 或括号组，不泄漏到组外。
- 连续 `NOT` 成对抵消；二元运算符后没有操作数时忽略该运算符；`--compat` 把未知字段、
  非法值、多余右括号变成空集。
- `field:==value` 与 `field: = = value` 都解析为 `Equal`；词法层的 `=` 可以连续出现。
- 日期的 `last` / `past` 是同一滚动窗口语义；`past3days` 与 `last3days` 等价。
- 裸词含 `/` 自动搜索完整路径；含非 ASCII 大写字母自动改为大小写敏感。`--regex` 整条
  查询绕过解析器，但 CLI 用 `Flags::with_name_heuristics` 施加同样的两条规则。
- `--type` 不是修饰符：CLI 用 `constrain_kind` 把全局类型约束与查询求交，查询内的
  `file:` / `folder:` 不能覆盖它。

## glob 与正则

- glob：`*` 匹配任意字节序列；`?` 匹配一个 Unicode 标量（完整 UTF-8 字符，非法字节算
  一个单位）；`\*` / `\?` 是字面量。词法层会为 `\*` / `\?` 保留反斜杠，`has_glob_meta`
  因此把这类模式交给 glob 匹配器，而不是普通子串。
- 正则使用 MoonBit 内置 `@string.Regex`：字符类、POSIX 类、`* + ? {n,m}`、分组/替换、
  `^ $ \b`、`(?i:...)` 可用；`\d` / `\s` / `\w`、lookaround、反向引用、`\xHH` 不可用。
  非法模式在编译期抛出 `QueryError::BadRegex`。`query::compile_regex` 同时供查询 term 与
  索引排除规则复用；正则主体必须是合法 UTF-8，非法字节视为不匹配。

## 修饰符

| 修饰符 | 作用 |
| --- | --- |
| `case:` / `nocase:` | 大小写敏感 / 不敏感 |
| `exact:` | 整名精确匹配 |
| `path:` / `nopath:` | 完整路径 / 仅名字 |
| `regex:` / `noregex:` | 正则 / 关闭正则 |
| `file:` / `files:` | 仅文件 |
| `folder:` / `folders:` | 仅文件夹 |
| `hidden:` | 仅隐藏条目 |
| `nohidden:` / `visible:` | 仅非隐藏条目 |

`file:`、`hidden:` 等修饰符在链式书写时可以组合，例如 `file:hidden:doc:` 表示隐藏的
文档文件。没有后续 term 时变成独立的 `Kind` / `Visibility` 叶子，仍然是一个有效过滤。

## 内置分类宏

`app:`、`archive:`、`audio:`、`doc:`、`pic:`、`video:` 是内置宏，解析成
`TermBody::TypeCategory`。它们不是 `ext:` 的文本展开：词法层保留分类名，字典层在构建
期把每个分类物化成一张集合。分类的扩展名列表在 `util.TypeCategory::extensions`，扫描
引擎与字典共用。

解析优先级：用户宏 → 内置分类宏 → 修饰符 → 字段函数。用户可以在配置里定义同名宏覆盖
内置分类。宏用自己保存的 `flags` 和独立 `Lexer`/`Parser` 展开，外部修饰符不会渗入宏
内部；要限制宏结果，请把修饰符写进宏查询，或在宏旁边另写普通 term（如 `book: file:`）。

## describe 形式

`Query::describe()` 是测试与 `--explain` 使用的稳定文本：

```text
(and (ext "pdf" kind=file) (size > 1000000))
(type pic)
(visibility hidden)
(name "report" hidden)
```

`Flags::describe()` 按 `case`、`exact`、`path`、`regex`、`kind=`、`hidden|visible`
的顺序输出非默认标志。

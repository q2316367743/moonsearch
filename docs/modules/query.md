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

## 语法要点

- 优先级：`NOT` > 隐式/显式 `AND` > `OR`；括号分组。
- 隐式 AND：下一个 token 能开始 primary，且上一个 token 结束了 primary 时插入 AND。
- 修饰符是前缀修饰符，只作用于紧随其后的一个 term 或括号组，不泄漏到组外。
- 连续 `NOT` 成对抵消；二元运算符后没有操作数时忽略该运算符；`--compat` 把未知字段、
  非法值、多余右括号变成空集。

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
内置分类。

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

# 配置

`moonsearch` 使用 JSON 配置文件保存数据库路径、扫描根目录、排除规则、查询宏和搜索默认值。

## 文件位置与优先级

默认配置文件为：

```text
$XDG_CONFIG_HOME/moonsearch/config.json
```

未设置 `XDG_CONFIG_HOME` 时为：

```text
~/.config/moonsearch/config.json
```

默认文件不存在时使用内置默认值。显式指定的文件不存在、无法读取或内容非法时，命令以退出码 2 失败。

- `--config <PATH>` 或 `MOONSEARCH_CONFIG` 选择配置文件。
- `--no-config` 完全跳过配置文件，包括默认文件和显式文件。
- 设置值的优先级为 **CLI > 环境变量 > 配置文件 > 默认值**。当前环境变量覆盖用于
  `MOONSEARCH_DATABASE` 与 `MOONSEARCH_CONFIG`。
- `--help` 和 `--version` 不读取配置文件。

路径只展开前导 `~`、`~/`、`$HOME` 和 `$XDG_*`，也支持 `${NAME}`。不做 shell
展开、命令替换、递归展开或 `~user` 展开；未列入白名单的变量会报错。

## 完整示例

```json
{
  "database": "$XDG_DATA_HOME/moonsearch/index.msdb",
  "roots": [
    { "path": "~/Documents", "one_file_system": false },
    { "path": "$HOME/Projects", "one_file_system": true }
  ],
  "exclude_hidden": true,
  "exclude_scope": "full_path",
  "exclude_target": "both",
  "excludes": [
    {
      "pattern": "node_modules",
      "kind": "glob",
      "scope": "basename",
      "target": "folders"
    },
    {
      "pattern": "^build$",
      "kind": "regex",
      "scope": "basename",
      "target": "folders"
    }
  ],
  "macros": {
    "book": "ext:epub;mobi;azw3;pdf",
    "code": "ext:rs;go;c;h;cpp;hpp;mbt;py;js;ts",
    "sources": {
      "query": "ext:c;h;cpp;hpp;rs;mbt",
      "flags": { "case_sensitive": true }
    }
  },
  "search": {
    "sort": "name",
    "limit": 0,
    "reverse": false,
    "folders_first": false,
    "type": "any",
    "case_sensitive": false,
    "exact": false,
    "search_path": false,
    "regex": false
  },
  "engine": "bitmap",
  "fast_fields": ["size", "mtime"],
  "trigram": true,
  "one_file_system": false,
  "allow_nested_roots": false,
  "default_excludes": true,
  "unreadable_directories": "continue"
}
```

所有字段都可省略。顶层和嵌套对象中的未知字段、重复 JSON 键、错误类型以及非法枚举值都会报错。

## 扫描设置

| 字段 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `database` | string | XDG 数据目录 | 索引数据库路径 |
| `roots` | array | 空 | `{path, one_file_system?}` 对象数组 |
| `exclude_hidden` | bool | `false` | 跳过点开头的名称 |
| `exclude_scope` | string | `full_path` | 配置排除规则的默认匹配对象 |
| `exclude_target` | string | `both` | 配置排除规则的默认作用对象 |
| `excludes` | array | 空 | `{pattern, kind?, scope?, target?, active?}` 对象数组 |
| `one_file_system` | bool | 未设置 | 所有配置根的默认跨设备策略；单根可覆盖 |
| `allow_nested_roots` | bool | `false` | 允许根目录互相嵌套 |
| `default_excludes` | bool | `true` | 跳过 `/proc`、`/sys`、`/dev`、`/run` |
| `unreadable_directories` | string | `continue` | `continue` 记录问题并继续；`fatal` 终止扫描 |

`excludes[].kind` 为 `fixed`、`glob` 或 `regex`；`scope` 为 `full_path` 或
`basename`；`target` 为 `both`、`files` 或 `folders`。非法正则在读取配置时就会报错。
命令行提供 `-x/--exclude` 时，命令行规则列表替换配置中的规则列表；根目录列表也同样替换。

## 索引引擎设置

```json
{
  "engine": {
    "name": "bitmap",
    "trigram": true,
    "fast_fields": ["size", "mtime"]
  }
}
```

`engine` 既可以写成上面的对象，也可以直接写成 `"scan"` 或 `"bitmap"` 来设置查询引擎。
对象中的 `name` 可选。顶层 `fast_fields` 和 `trigram` 存在时覆盖对象中的同名字段。
`fast_fields` 接受 `size`、`mtime`、`depth`、`childcount`、`parent`、
`childfilecount`、`childfoldercount`。五个核心字段总是构建并持久化；该列表只额外选择
两个可选 child-count 字段，并控制加载数据库时立即解码哪些字段。未选择的可选字段在查询时
退化为 scan。

## 自定义宏

宏表会传给查询解析器，优先级为 **用户宏 > 内置分类宏 > 修饰符/字段函数**。因此配置中的
`audio:`、`doc:` 等名称可以覆盖同名内置分类。宏名按 ASCII 大小写不敏感，只能包含字母、
数字、`_` 和 `-`。

字符串是宏查询的简写。对象形式可以设置独立 flags：

```json
{
  "macros": {
    "book": "ext:epub;pdf",
    "upper": {
      "query": "report",
      "flags": {
        "case_sensitive": true,
        "exact": true,
        "search_path": false,
        "regex": false,
        "kind": "file",
        "visibility": "visible"
      }
    }
  }
}
```

宏使用独立词法和解析器，保留循环检测、256 层嵌套上限和独立子查询 flags。宏外部的
`case:`、`file:` 等修饰符不会渗入宏查询；需要限制宏时把修饰符写进宏查询，或另写普通 term。

## `update` 根目录

`update` 按以下顺序选择根目录：

1. 命令行的 `-r/--root` 和位置参数；
2. 配置文件的 `roots`；
3. 当前数据库 `ROOTS` 中持久化的根目录。

显式根目录优先。若数据库不存在且没有配置或命令行根目录，`update` 仍会报告缺少根目录。

## `update` 排除规则

排除规则按以下顺序选择：

1. 命令行 `-x/--exclude` 列表；
2. 配置文件 `excludes` 列表；
3. 当前数据库 `EXCLUDES` 中持久化的规则快照。

CLI 或配置列表非空时整体替换旧快照，不会追加。当前空数组与字段缺失都表示“未提供
规则”，因此 `update` 会继续复用数据库快照；需要替换时至少提供一条规则。显式新根目录
仍继承旧快照，尤其是 `full_path` 规则可能不适用于新根，可用 CLI 规则整体替换。

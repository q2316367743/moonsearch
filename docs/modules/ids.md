# ids — id 集合与压缩位图

`src/ids` 是 S06 的交付物：查询执行层唯一的中间表示 `Ids`，以及它背后的压缩位图
`Bitmap` / `Container`。本模块不依赖文件系统、查询或索引包，可以用纯数组单测。

## 职责

- 表示一个条目 id 集合，并在“升序数组”和“压缩位图”之间选择物理形态。
- 提供集合代数：交、并、差、过滤、基数、成员判断。
- 提供确定性序列化与带边界校验的反序列化，为 S12 的数据库 section 做准备。

id 空间是 `Int32`，非负。S06 本身只处理裸 id，不关心条目类型；S07 起所有集合使用
`core.GlobalId`：文件夹占 `0 .. folder_count - 1`，文件从 `folder_count` 开始，
详见 [core](core.md) 与 [index](index.md)。

## 文件

| 文件 | 内容 |
| --- | --- |
| `bitmap.mbt` | `Bitmap`、`Container`、块级 `and/or/andnot`、容器翻转、迭代 |
| `ids.mbt` | `Ids` ADT、形态选择阈值、集合运算、过滤器 |
| `codec.mbt` | `Ids::to_bytes` / `Ids::from_bytes`、varint、边界校验 |
| `*_test.mbt` | 与朴素集合对拍、阈值边界、序列化与损坏输入 |

## `Ids`：两种物理形态

```moonbit
pub enum Ids {
  Bitmap(Bitmap)
  Sorted(Array[Int32])
}
```

- `Sorted` 是严格升序、无重复的 `Int32` 数组。稀疏结果用它：每个 id 4 字节，
  归并运算简单。
- `Bitmap` 是分块压缩位图，基数缓存为 O(1)。稠密结果用它：交并差是字级并行，
  `--count` 直接读缓存。
- 两个形态表示同一个数学集合；`Ids::to_sorted_ids()` 是两者共同的展开方式。

### 形态选择阈值

`canonical_sorted` / `Ids::normalize` 是唯一的决策点：

| 条件 | 结果 |
| --- | --- |
| 基数 = 0 | `Sorted([])` |
| 基数 > `IDS_SORTED_MAX`（4096） | `Bitmap` |
| `total > 0` 且 `基数 * IDS_DENSITY_DIVISOR(32) > total` | `Bitmap` |
| 其余 | `Sorted` |

边界语义：

- 基数恰好 4096 → `Sorted`；4097 → `Bitmap`。
- 密度恰好 1/32（例如 `total=320, 基数=10`）→ `Sorted`；`基数=11` → `Bitmap`。
- `total` 未知（0）时只应用基数阈值。S07/S08 在知道索引总条目数时调用
  `Ids::normalize(total)` 重新定形。

`Ids::from_sorted(ids, total~)` 会丢弃负 id、排序、去重后规范化，调用方不必预排序。
公开的 enum 构造器仍可产生非规范值（例如大 `Sorted`），运算会按输入形态选择策略，
结果再经 `canonical_sorted` 规范化。

## `Bitmap`：分块容器

```moonbit
pub struct Bitmap {
  containers : Array[Container?]  // 下标 = id >> 16
  len : Int                        // 基数缓存
}

pub enum Container {
  Array(Array[UInt16])             // 升序块内偏移
  Bits(Array[UInt64])              // 固定 1024 字 = 65536 位
}
```

- 每个块覆盖 65536 个 id（`BITMAP_BLOCK_SIZE`），块内偏移是 `id & 0xFFFF`。
- `Array` 容器用于稀疏块；`Bits` 容器用于稠密块。
- 容器阈值 `CONTAINER_ARRAY_MAX = 4096`：4096 个 `UInt16` 与 1024 个 `UInt64`
  都是 8192 字节，正好在此持平。
  - 插入后数组长度 > 4096 → 翻成 `Bits`。
  - 删除后 `Bits` 基数 ≤ 4096 → 翻回 `Array`。
  - 块清空 → 置 `None`；末尾空块被裁剪，避免容器数组出现长尾。
- 负 id 的 `add` / `remove` / `contains` 被忽略（`contains` 返回 false）。
- `to_sorted_ids()` 按块序、块内偏移升序展开。

### 块级运算

| 左 | 右 | 交 | 并 | 差 |
| --- | --- | --- | --- | --- |
| Array | Array | 归并 | 归并 | 归并 |
| Array | Bits | 逐元素探测 | 复制位图并置位 | 逐元素探测取反 |
| Bits | Array | 逐元素探测 | 复制位图并置位 | 复制位图并清位 |
| Bits | Bits | 按字 `&` | 按字 `|` | 按字 `& ~` |

每个块运算完成后都会重新检查容器阈值，因此结果始终保持规范形态。集合运算不修改
操作数（需要写入时先 `clone_container`）。

## 集合运算策略

`Ids::intersect` / `union` / `difference` 按两个输入的形态分派：

| 左 | 右 | 策略 |
| --- | --- | --- |
| Bitmap | Bitmap | 块级位运算 |
| Sorted | Sorted | 归并 |
| Bitmap | Sorted（≤4096） | 逐元素 `contains` 探测，结果保持升序 |
| Bitmap | Sorted（>4096） | 先把 Sorted 转成 Bitmap，再块级运算 |
| 空集 | 任意 | 结果为空集 |

`Ids::filter(pred)` 按升序枚举（位图先展开为 id 列表），过滤后按基数重新定形：
把稠密位图过滤到几十条时会返回 `Sorted`。

`Ids::to_bitmap()` 对已经是位图的集合做深拷贝；`Ids::to_sorted_ids()` 总是返回副本。

## 序列化

`Ids::to_bytes()` 输出迁移计划附录 B 的 `IdsRef` 布局，全部小端：

```text
repr   u8      0 = bitmap, 1 = sorted
len    u32     集合基数
bitmap: block_count u32
        每个非空块（按块号升序）:
          block_idx  u32
          type       u8   0 = array, 1 = bits
          len        u32  元素个数（array = u16 个数，bits = 1024）
          payload        array: len × u16；bits: 1024 × u64
sorted: len 个无符号 LEB128 增量；首个值为绝对 id，后续为与前一个 id 的差
```

- bitmap 的 `len` 只表示非空块数量，不包含空洞块；块号必须严格升序。
- sorted 的增量必须严格递增（首个可以为 0）；声明基数必须与实际元素数一致。
- `Ids::from_bytes` 校验 representation tag、块号范围（≤32767）、块序、容器内容、
  声明基数，并拒绝尾随字节。
- 输入会按 `canonical_sorted` 规范化：声明为 sorted 但基数 >4096 的数据解码后
  变成 `Bitmap`；非规范容器（例如 5000 个元素的 array）也会翻转。因此
  `to_bytes(from_bytes(x))` 对规范输入是稳定的，非规范输入会被规范化。
- 所有长度字段先与剩余字节数比较，防止恶意长度导致 OOM；varint 超过 5 字节或
  第 5 字节高位越界会被拒绝。
- 解码失败返回 `IdsError::{Truncated, Corrupt(String)}`，不 panic、不越界。
  `IdsError::message()` 提供稳定文本，便于 CLI 映射为退出码 2。

## 测试

`moon test -p q2316367743/moonsearch/src/ids` 覆盖：

- 四种形态组合（Sorted/Sorted、Sorted/Bitmap、Bitmap/Sorted、Bitmap/Bitmap）的
  交、并、差与独立 `Array[Bool]` 参考实现逐项对拍；
- 大集合（2 万 + 1.3 万 id）对拍，以及大 `Sorted × Bitmap` 策略分支；
- 形态阈值边界：4096/4097、密度 1/32、`normalize(total)`；
- 容器阈值：4096/4097 翻转、删除回翻、块边界 65535/65536、负 id、重复插入；
- 序列化往返（空集、小 Sorted、稠密 Bits、跨块 mixed），编码稳定性；
- 损坏输入：截断、未知 tag、未知容器、基数不符、非升序、尾随字节、Int32 溢出。

## 接入状态

S07 已把 `Ids` 用作字段字典 `index::Dict` 的存储：`ext`、`files_all`/`folders_all`、
`hidden`/`visible`、`root`、`TypeCat` 都是 `Ids`，构建时按总条目数调用
`normalize(total)` 选择形态。CLI 的 `--engine bitmap` 仍然报“未实现”，因为位图执行器
还需要 S08 的范围索引，并由 S10 把 `Query` 编译到这些集合上。S08 将把范围查询结果
构造成 `Ids::Sorted`。

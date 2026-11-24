# Value 数值公式节点

用 Def 资源树表达"一个数怎么算"：叶子是常量，上层是运算（加 / 减 / 乘 / 百分比 / 分数 / 除法 / 取小 / 取大）。
凡是"该由策划配置的数值"字段，都放一个 `ValueDef` 而不是写死字面量；Value 只描述算法，不含任何业务字段。

## 怎么用

| 类 | 字段 | 计算 |
|---|---|---|
| `IntValueDef` | `value: int = 1` | 常量（整型） |
| `FloatValueDef` | `value: float = 1` | 常量（浮点） |
| `AddValueDef` | `value` + `addend` | 相加 |
| `SubtractValueDef` | `value` - `subtrahend` | 相减 |
| `MultiplyValueDef` | `value` * `multiplier` | 相乘 |
| `PercentValueDef` | `value` * `percent` / 100 | 百分比，`value` 留空按 1 |
| `FractionValueDef` | `numerator` / `denominator` | 分数 / 比例，除零回 0 |
| `DivideValueDef` | `value` / `divisor` | 公式除法，除零给 ±INF |
| `MinValueDef` / `MaxValueDef` | `a`、`b` | 取小 / 取大 |

三个取值接口（定义在 `ValueDef` 上）：

| 方法 | 用途 |
|---|---|
| `get_float(data) -> float` | 真实数值 |
| `get_int(data) -> int` | `ceili(get_float(data))`，向上取整 |
| `get_desc(data) -> String` | 展示 / 日志文本 |

`data` 是上下文，原样透传给子节点；Value 自己不用它，靠子类（如读存档的数值）解释。

```gdscript
# 读一个数值
var vd: ValueDef = some_def.value
var f := vd.get_float(context)
var i := vd.get_int(context)
print(vd.get_desc(context))
```

```gdscript
# 组合：1.2 * 30% = 0.36
var base := FloatValueDef.new()
base.value = 1.2

var p := IntValueDef.new()
p.value = 30

var pct := PercentValueDef.new()
pct.value = base
pct.percent = p
```

## 坑

1. `DivideValueDef` 与 `FractionValueDef` 语义不同，不要互相替代：前者是"算一个除法"，除零按极限给 `±INF`（`0/0` 给 `0`）；后者是"表示分数 / 比例"，除零回 `0`。源码注释里明确写了这条约束。
2. `get_int` 是 `ceili` 向上取整，不是四舍五入：按整数消费数值（比较、计数、扣减）时 0.1 会变成 1。
3. `PercentValueDef` 先把 `percent` 向上取整到 10 的倍数（15 → 20）再参与计算，所以百分比只按 10 的档位生效；`percent` 留空会直接空引用报错（只有 `value` 留空才按 1 处理）。
4. 组合节点普遍不做空判断：除 `PercentValueDef.value` 外，子 `ValueDef` 留空都会在 `get_float` 时空引用崩掉（Add / Subtract / Multiply / Divide / Fraction / Min / Max 都是裸调用）。
5. `get_desc` 只有部分子类覆写（Percent / Fraction / Add / Multiply）：Min / Max / Subtract / Divide / Float 用继承实现，描述会退化成结果数字。要展示表达式请用 `_to_string()`，但它对应原始子节点，与 `get_desc` 未必一致（例如 Percent 用未取整的百分比）。
6. 现状：`ValueDef` 目前只被 `ValueConditionDef`（Signal 模块）的 `value` / `target` 两个字段使用，项目侧没有其它引用，属于几乎未接入的模块。

## 文件结构

扁平单层：`Value/` 下只有 Def，没有 Entity / View / Tool。`ValueDef` 是 `@abstract` 基类，其余十个类各自一个文件、一个 `class_name`，全部 `@tool` 以便在编辑器里嵌套配置。

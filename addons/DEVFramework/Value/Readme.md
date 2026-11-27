# Value 数值公式节点

用 Def 资源树表达"一个数怎么算"：叶子是常量，上层是运算。凡"该由策划配置的数值"都放 `ValueDef` 而不是写死字面量；Value 只描述算法，不含业务字段。

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

| 取值接口（定义在 `ValueDef`） | 用途 |
|---|---|
| `get_float(data) -> float` | 真实数值 |
| `get_int(data) -> int` | `ceili(get_float(data))`，向上取整 |
| `get_desc(data) -> String` | 展示 / 日志文本 |

`data` 是上下文，原样透传给子节点；Value 自己不用它，靠子类（如读存档的数值）解释。

```gdscript
var f := some_def.value.get_float(context)
var i := some_def.value.get_int(context)

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

1. `DivideValueDef` 与 `FractionValueDef` 语义不同，不要互相替代：前者是"算一个除法"，除零按极限给 `±INF`（`0/0` 给 `0`）；后者是"表示分数 / 比例"，除零回 `0`。
2. `get_int` 是 `ceili` 向上取整，不是四舍五入：0.1 会变成 1。
3. `PercentValueDef` 先把 `percent` 向上取整到 10 的倍数（15 → 20）再参与计算，所以百分比只按 10 的档位生效；`percent` 留空会空引用报错（只有 `value` 留空才按 1 处理）。
4. 组合节点普遍不做空判断：除 `PercentValueDef.value` 外，子 `ValueDef` 留空都会在 `get_float` 时空引用崩掉。
5. `get_desc` 只有 Percent / Fraction / Add / Multiply 覆写，其余描述会退化成结果数字；要展示表达式用 `_to_string()`，但它对应原始子节点，与 `get_desc` 未必一致。

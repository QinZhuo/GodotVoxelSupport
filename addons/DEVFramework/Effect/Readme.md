# Effect 可附加效果

把"对某个东西施加影响"抽象成一对 `apply` / `revert`，效果可以组合成树。
效果本身是 Def（静态数据），施加与撤销由调用方驱动；组合效果正序叠加、逆序回滚，等价于一个 undo 栈。

| 类 | 职责 |
|---|---|
| `EffectDef` | `@abstract`：`apply(context)` / `revert(context)` / `get_desc(context)` / `_to_string()`；另有 `find_effect(condition)` / `find_effects(condition)` 沿效果树收集 |
| `EffectsDef` | `effects: Array[EffectDef]`：apply 正序逐个 await，revert 逆序 |
| `SystemEffectDef` | 行为由外部系统按 Def 名称内置实现，数据层不承载逻辑；`tr_desc` 从翻译读取 |
| `EffectResult` | 结算结果节点：`def` / `value` / `next`（链表） |

```gdscript
class_name FlagEffect extends EffectDef

@export var key: StringName

func apply(context) -> void:
	context[key] = true

func revert(context) -> void:
	context.erase(key)

var combo := EffectsDef.new()
combo.effects = [give_a, give_b]
await combo.apply(context)      # 正序施加
await combo.revert(context)     # 逆序撤销

var hits := def.find_effects(func(e): return e is FlagEffect)   # 全部命中
var one := def.find_effect(func(e): return e is FlagEffect)     # 首个命中，找不到回 null
```

`context` 由调用方定义并原样透传（Dictionary、节点、或某个持有者对象），Effect 自己不做类型假设。

## 坑

1. `revert` 默认是空实现（`pass`，不是 `@abstract`）：卸装备 / 读档时不该刷满 cannot revert 噪声，所以"只加不减"是合法实现；真正需要抵消的效果必须自己覆写。
2. `apply` / `revert` 可以是协程：`EffectsDef` 用 `await` 逐个执行。不 await 时异步效果会在第一次 await 处让出，完成时机不受调用方控制。
3. 逆序不是风格问题：正序叠加的状态必须倒序撤销才可逆，自己写组合类别改成正序。
4. `find_effect` / `find_effects` 是静态遍历：只认 `effect` / `effects` 字段（鸭子类型），**不进入条件分支**，也无法求值条件；候选里包含自身，`condition.call(self)` 命中时会拿到调用者本身。
5. `SystemEffectDef` 的 `apply` / `revert` 都是空实现：只是"名称 + 翻译"的数据占位，真实行为在外部系统里按 Def 名称分发；`tr_desc` 取 `name + "_desc"`，改 Def 名字就会掉翻译。
6. `EffectResult` 目前无任何引用（`def` / `value` / `next` 的结算链骨架）；框架内具体效果只有 `EffectsDef` 与 `SystemEffectDef`。

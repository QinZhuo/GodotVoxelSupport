@tool
@abstract class_name EffectDef extends Def

@abstract func apply(context)

## 撤销本效果（apply 的逆操作）。**默认什么都不做** ——
## 绝大多数效果是纯 apply 型（加 Buff / 造成伤害 / 转换符号…），本就无需撤销；
## 只有真正需要随 Item 卸载而回滚的效果才覆写（如 EffectsDef 逆序转发、持续型效果）。
## 注意：这里刻意不报错，否则卸装备 / 读档时会刷满 "cannot revert …" 噪声、掩盖真错误。
func revert(_context):
	pass

func get_desc(context) -> String:
	return _to_string()

func _to_string() -> String:
	return get_script().get_global_name()

## 沿效果链找**首个**命中 condition 的效果（找不到返回 null）—— 本方法的语义就是
## [method find_effects] 的"第一个命中"，两者共用同一份遍历，避免各写一份递归而漂移。
func find_effect(condition: Callable) -> EffectDef:
	var found := find_effects(condition)
	return found[0] if not found.is_empty() else null

## 沿效果链收集**全部**命中 condition 的效果（鸭子类型遍历：`effect` / `effects` 字段，
## 因此 `EffectsDef` / `ActiveUseEffectDef` 等包裹层无需任何配合代码）。
## ⚠️ 遍历不进入条件分支（`true_effect` / `false_effect`）：静态遍历无法求值条件，
## 分支内的效果只应由 `apply` 在条件成立时执行（与 `SelectionEffectDef` 的约定一致）。
func find_effects(condition: Callable) -> Array[EffectDef]:
	var out: Array[EffectDef] = []
	if condition.call(self):
		out.append(self)
	if "effect" in self and self.get("effect") is EffectDef:
		out.append_array(self.effect.find_effects(condition))
	if "effects" in self and self.get("effects") is Array:
		for e in self.effects:
			out.append_array(e.find_effects(condition))
	return out

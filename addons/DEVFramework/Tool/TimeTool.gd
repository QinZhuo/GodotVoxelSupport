@tool
## 时间缩放工具 — 基于 ModifierValue（×100）管理 Engine.time_scale
##
## base_value = 基础游戏速度（×100），其他 modifier 以 PERCENT 模式叠加。
## 最终值 = base_value × ∏pctᵢ / 100
class_name TimeTool

static var _mv: ModifierValue = null
static var _paused: bool = false

static func _ensure() -> void:
	if _mv != null:
		return
	_mv = ModifierValue.new()
	_mv.base_value = 100
	_mv.value_changed.connect(func(_m): Engine.time_scale = _mv.value / 100.0)

# ── 基础速度（用户设置） ──

static func set_base_speed(speed: float) -> void:
	_ensure()
	_mv.base_value = roundi(speed * 100)

static func get_base_speed() -> float:
	return _mv.base_value / 100.0 if _mv else 1.0

## 获取当前计算的最终 time_scale（base × modifiers）
static func get_current_scale() -> float:
	return _mv.value / 100.0 if _mv else 1.0

# ── 修改器管理 ──

## 设置 modifier（key 唯一标识），移除旧的再添加新的；scale=1.0 等价于移除
static func set_modifier(key: String, scale: float) -> void:
	_ensure()
	_mv.remove_modifiers(key)
	var pct := roundi(scale * 100)
	if pct != 100:
		_mv.add_modifier(Modifier.new(key, pct, Modifier.Mode.PERCENT))

## 移除指定 key 的 modifier
static func remove_modifier(key: String) -> void:
	if _mv == null:
		return
	_mv.remove_modifiers(key)

## 清空所有 modifier（保留 base 速度）
static func clear() -> void:
	if _mv == null:
		return
	_mv.clear_modifiers()
	_paused = false

# ── 暂停 ──

static func pause() -> void:
	if _paused:
		return
	set_modifier("pause", 0.0)
	_paused = true

static func resume() -> void:
	if not _paused:
		return
	remove_modifier("pause")
	_paused = false

static func is_paused() -> bool:
	return _paused

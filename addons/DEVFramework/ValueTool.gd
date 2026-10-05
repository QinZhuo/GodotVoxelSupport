@tool
class_name ValueTool extends RefCounted

## 数值安全上限（10⁹ = 1,000,000,000）
##
## 远高于任何正常对局中的实际数值（属性 < 10⁴，Buff 层数 < 500），
## 仅用于防范 64-bit 整数溢出（GDScript int 上限 ≈ 9.2×10¹⁸）。
## 所有通过 ModifierValue 计算的属性 / 所有 Buff 层数修改都经过此上限。
const MAX_VALUE := 999_999_999

# ============================================================
# 安全钳位
# ============================================================

## 安全钳位到 [0, MAX_VALUE]
static func clamp_value(v: int) -> int:
	return clampi(v, 0, MAX_VALUE)

## 安全钳位到 [-MAX_VALUE, MAX_VALUE]
static func clamp_signed(v: int) -> int:
	return clampi(v, -MAX_VALUE, MAX_VALUE)

# ============================================================
# 整数除法（封装浮点转换，消除重复的 / 2.0、/ 3.0 写法）
# ============================================================

## 除法向上取整。
## `ceil_div(10, 3)` → 4，等价于 `ceili(10 / 3.0)`
static func ceil_div(n: int, d: int) -> int:
	assert(d != 0, "ValueTool.ceil_div: divisor cannot be zero")
	return ceili(n / float(d))

## 除法向下取整。
## `floor_div(10, 3)` → 3，等价于 `floori(10 / 3.0)`
static func floor_div(n: int, d: int) -> int:
	assert(d != 0, "ValueTool.floor_div: divisor cannot be zero")
	return floori(n / float(d))

# ============================================================
# 百分比运算
# ============================================================

## 百分数缩放（整数结果，向上取整）。
## `percent_of(50, 30)` → 15（50 的 30%）
static func percent_of(value: int, percent: float) -> int:
	return ceili(value * percent / 100.0)

## 百分数缩放（整数结果，常规四舍五入）。
## `percent_round(50, 30)` → 15（50 的 30%）
static func percent_round(value: int, percent: float) -> int:
	return roundi(value * percent / 100.0)

# ============================================================
# 范围重映射（等价于 Unity Mathf.Remap / Unreal FMath::MapRange）
# ============================================================

## 将一个值从源范围映射到目标范围。
##
## `remap(5, 0, 10, 100, 200)` → 150
## `remap(0, 0, 10, 100, 200)` → 100
## `remap(10, 0, 10, 100, 200)` → 200
static func remap(value: float, from_min: float, from_max: float, to_min: float, to_max: float) -> float:
	return lerp(to_min, to_max, inverse_lerp(from_min, from_max, value))

## 整数版 remap，结果四舍五入。
static func remap_int(value: int, from_min: int, from_max: int, to_min: int, to_max: int) -> int:
	return roundi(remap(value, from_min, from_max, to_min, to_max))

# ============================================================
# 数值趋近（等效于 Unity Mathf.MoveTowards）
# ============================================================

## 从 current 向 target 移动 step 步，不会越过 target。
## `move_toward(5, 10, 3)` → 8
## `move_toward(5, 10, 1)` → 6
## `move_toward(5, 3, 3)` → 3
static func move_toward(current: int, target: int, step: int) -> int:
	if step <= 0: return current
	if current < target:
		return mini(current + step, target)
	elif current > target:
		return maxi(current - step, target)
	return current

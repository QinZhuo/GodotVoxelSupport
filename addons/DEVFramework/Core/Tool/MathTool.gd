@tool
class_name MathTool extends RefCounted

## 数值安全上限（10⁹ = 1,000,000,000）
const MAX_VALUE := 999_999_999

# ============================================================

## 安全钳位到 [0, MAX_VALUE]
static func clamp_value(v: int) -> int:
	return clampi(v, 0, MAX_VALUE)

## 安全钳位到 [-MAX_VALUE, MAX_VALUE]
static func clamp_signed(v: int) -> int:
	return clampi(v, -MAX_VALUE, MAX_VALUE)

# ============================================================

## 除法向上取整。
static func ceil_div(n: int, d: int) -> int:
	assert(d != 0, "MathTool.ceil_div: divisor cannot be zero")
	return ceili(n / float(d))

## 除法向下取整。
static func floor_div(n: int, d: int) -> int:
	assert(d != 0, "MathTool.floor_div: divisor cannot be zero")
	return floori(n / float(d))

# ============================================================

## 百分数缩放（整数结果，向上取整）。
static func percent_of(value: int, percent: float) -> int:
	return ceili(value * percent / 100.0)

## 百分数缩放（整数结果，常规四舍五入）。
static func percent_round(value: int, percent: float) -> int:
	return roundi(value * percent / 100.0)

# ============================================================

## 整数版范围重映射，结果四舍五入。
static func remap_int(value: int, from_min: int, from_max: int, to_min: int, to_max: int) -> int:
	return roundi(remap(value, from_min, from_max, to_min, to_max))

# ============================================================

## 整数版 move_toward：内置 [method @GlobalScope.move_toward] 只接受 float，这里保证
static func move_toward_int(current: int, target: int, step: int) -> int:
	if step <= 0:
		return current
	return int(move_toward(float(current), float(target), float(step)))

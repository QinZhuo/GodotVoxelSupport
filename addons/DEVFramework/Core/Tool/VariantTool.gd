@tool
class_name VariantTool extends RefCounted

## ======= Variant 规范化(全项目唯一入口) =======
## ## 为什么必须是单一入口(不是风格问题, 是正确性问题)
##      注意空白串必须先 strip_edges 再判, 否则 "  " 会被当成合法字符串值传下去。

# ============================================================

## 需要整体转成普通 Array 而非原样返回的类型。
const _PACKED_TYPES := [
	TYPE_PACKED_BYTE_ARRAY,
	TYPE_PACKED_INT32_ARRAY,
	TYPE_PACKED_INT64_ARRAY,
	TYPE_PACKED_FLOAT32_ARRAY,
	TYPE_PACKED_FLOAT64_ARRAY,
	TYPE_PACKED_STRING_ARRAY,
]

## 明确表示"真"的字符串字面量(小写比较前先 strip_edges + to_lower)。
## 如 DefTableView 的 bool 单元格: 它必须区分"匹配真"与"匹配假"好给出不同错误信息,
## 而 as_bool 的二态接口表达不了这第三种情况。此时复用常量表, 不要另抄一份字面量。
const BOOL_TRUE_LITERALS := ["true", "1", "yes", "on"]
## 明确表示"假"的字符串字面量。其余字符串一律回落缺省值, 不猜。
const BOOL_FALSE_LITERALS := ["false", "0", "no", "off"]


## "未填"的统一判据(R1): null、空串、纯空白串。
static func is_blank(v: Variant) -> bool:
	if v == null:
		return true
	if v is String:
		var s: String = v.strip_edges()
		return s.is_empty()
	return false


## 是否可当作数字使用: 数字本身, 或(R4 判据下)合法的数字字符串。
static func is_number(v: Variant) -> bool:
	if v is int or v is float:
		return true
	if v is String:
		var s: String = v.strip_edges()
		# is_valid_float 同时接受 "5" 与 "1.5", 故不需要再判 is_valid_int。
		return not s.is_empty() and s.is_valid_float()
	return false

# ============================================================

## 转 bool。接受: bool / 非零数字 / BOOL_TRUE_LITERALS / BOOL_FALSE_LITERALS。
static func as_bool(v: Variant, def: bool = false) -> bool:
	if v is bool:
		return v
	if v is int or v is float:
		return v != 0
	if v is String:
		var s: String = v.strip_edges().to_lower()
		if BOOL_TRUE_LITERALS.has(s):
			return true
		if BOOL_FALSE_LITERALS.has(s):
			return false
	return def


## 转 int。接受: int / float(截断) / bool(1|0) / 数字字符串(R4)。
static func as_int(v: Variant, def: int = 0) -> int:
	if v is int:
		return v
	if v is bool:
		return 1 if v else 0
	if v is float:
		return int(v)
	if v is String:
		var s: String = v.strip_edges()
		return s.to_int() if s.is_valid_int() else def
	return def


## 转 float。接受: float / int / bool / 数字字符串(含 "1.5")。
static func as_float(v: Variant, def: float = 0.0) -> float:
	if v is float:
		return v
	if v is int or v is bool:
		return float(v)
	if v is String:
		var s: String = v.strip_edges()
		return s.to_float() if s.is_valid_float() else def
	return def


## 转 String。
##   - null 返回 def, **不会**变成字面量 "null"(见类注释第 2 条坑)。
##   - Resource 返回 resource_path、Node 返回节点路径, 而不是 "[Resource:1234]"。
##     错误信息里前者能直接定位文件, 后者不能 —— 报错的可诊断性值得这两行。
static func as_string(v: Variant, def: String = "") -> String:
	if v is String:
		return v
	if v == null:
		return def
	if v is Resource:
		return (v as Resource).resource_path
	if v is Node:
		return str((v as Node).get_path())
	return str(v)


## 转 Array。接受: Array 原样返回 / 各种 Packed*Array 转普通 Array / 其余回落空数组。
static func as_array(v: Variant) -> Array:
	if v is Array:
		return v
	if typeof(v) in _PACKED_TYPES:
		return Array(v)
	return []


## 转 Dictionary。非 Dictionary(含 null)一律回落空字典, 理由同 as_array。
static func as_dict(v: Variant) -> Dictionary:
	return v if v is Dictionary else {}


## 转 Array[String]。比 as_array 多做一步**元素级**规范化, 因此多接受两种来源:
##   - Array / PackedStringArray: 逐元素 as_string(非字符串元素如 3 变 "3")
##   - String: 先当 JSON 数组还原, 失败再按逗号分隔(R1 会先剥掉首尾空白)
static func as_string_array(v: Variant) -> Array[String]:
	var out: Array[String] = []
	if v is String:
		var s: String = v.strip_edges()
		if s.is_empty():
			return out
		# 只在文本形如 JSON 时才尝试解析。否则每个普通逗号分隔串都会让引擎打一条
		if s.begins_with("[") or s.begins_with("{"):
			var parsed: Variant = parse_json(s)
			if parsed is Array:
				return as_string_array(parsed)
		for part in s.split(",", false):
			var t: String = part.strip_edges()
			if not t.is_empty():
				out.append(t)
		return out
	for e in as_array(v):
		out.append(as_string(e))
	return out

# ============================================================

## 键缺失**或**值为 null 都返回 def —— 这是 R1 在取键场景的直接推论:
## 客户端表达"未填"的两种方式(省略键 / 传 null)必须得到同一个结果, 否则
static func get_bool(src: Dictionary, key: String, def: bool = false) -> bool:
	return as_bool(src.get(key, def), def)


static func get_string(src: Dictionary, key: String, def: String = "") -> String:
	return as_string(src.get(key, def), def)


static func get_int(src: Dictionary, key: String, def: int = 0) -> int:
	return as_int(src.get(key, def), def)


static func get_float(src: Dictionary, key: String, def: float = 0.0) -> float:
	return as_float(src.get(key, def), def)


static func get_array(src: Dictionary, key: String) -> Array:
	return as_array(src.get(key, null))


static func get_dict(src: Dictionary, key: String) -> Dictionary:
	return as_dict(src.get(key, null))


static func get_string_array(src: Dictionary, key: String) -> Array[String]:
	return as_string_array(src.get(key, null))

# ============================================================

## JSON 文本 → Variant。非法文本返回 null, **不抛错**。
static func parse_json(text: Variant) -> Variant:
	if not text is String:
		return null
	var s: String = (text as String).strip_edges()
	if s.is_empty():
		return null
	return JSON.parse_string(s)


## Variant → JSON 可安全序列化的形式。
static func jsonable(v: Variant) -> Variant:
	if v is Resource:
		return {"__res": (v as Resource).resource_path}
	if v is Array or typeof(v) in _PACKED_TYPES:
		var arr: Array = []
		for e in as_array(v):
			arr.append(jsonable(e))
		return arr
	if v is Dictionary:
		var d := {}
		for k in v:
			d[k] = jsonable(v[k])
		return d
	return v


## 纯文本 → 尽量推断出最贴切的类型。非字符串原样返回。
static func infer(v: Variant) -> Variant:
	if not v is String:
		return v
	var s: String = (v as String).strip_edges()
	if s.is_empty():
		return v

	var low := s.to_lower()
	if low == "null" or low == "nil":
		return null
	if low == "true":
		return true
	if low == "false":
		return false

	# 无逗号: 只能是标量。
	if not s.contains(","):
		if s.is_valid_int():
			return s.to_int()
		if s.is_valid_float():
			return s.to_float()
		return v

	var nums := _components(s)
	if nums.is_empty():
		return v
	var all_int := true
	for x in nums:
		if not is_equal_approx(x, roundf(x)):
			all_int = false
			break

	match nums.size():
		2:
			return Vector2i(int(nums[0]), int(nums[1])) if all_int else Vector2(nums[0], nums[1])
		3:
			return Vector3i(int(nums[0]), int(nums[1]), int(nums[2])) if all_int else Vector3(nums[0], nums[1], nums[2])
		4:
			return Color(nums[0], nums[1], nums[2], nums[3])
		6:
			return AABB(Vector3(nums[0], nums[1], nums[2]), Vector3(nums[3], nums[4], nums[5]))
	return v


## 把值对齐到目标类型(已知目标类型时用这个, 未知时用 infer)。
static func coerce(v: Variant, target_type: int) -> Variant:
	if v == null:
		return null
	match target_type:
		TYPE_INT:
			return as_int(v)
		TYPE_FLOAT:
			return as_float(v)
		TYPE_BOOL:
			return as_bool(v)
		TYPE_STRING:
			return as_string(v)
	# 已经是目标类型, 或不是能解析的文本, 都原样返回。
	if typeof(v) == target_type or not v is String:
		return v
	var nums := _components(v as String)
	if nums.is_empty():
		return v

	match target_type:
		TYPE_VECTOR2:
			return Vector2(nums[0], nums[1]) if nums.size() == 2 else v
		TYPE_VECTOR2I:
			return Vector2i(int(nums[0]), int(nums[1])) if nums.size() == 2 else v
		TYPE_VECTOR3:
			return Vector3(nums[0], nums[1], nums[2]) if nums.size() == 3 else v
		TYPE_VECTOR3I:
			return Vector3i(int(nums[0]), int(nums[1]), int(nums[2])) if nums.size() == 3 else v
		TYPE_VECTOR4:
			return Vector4(nums[0], nums[1], nums[2], nums[3]) if nums.size() == 4 else v
		TYPE_VECTOR4I:
			return Vector4i(int(nums[0]), int(nums[1]), int(nums[2]), int(nums[3])) if nums.size() == 4 else v
		TYPE_COLOR:
			return Color(nums[0], nums[1], nums[2], nums[3]) if nums.size() == 4 else v
		TYPE_RECT2:
			return Rect2(nums[0], nums[1], nums[2], nums[3]) if nums.size() == 4 else v
		TYPE_RECT2I:
			return Rect2i(int(nums[0]), int(nums[1]), int(nums[2]), int(nums[3])) if nums.size() == 4 else v
		TYPE_PLANE:
			return Plane(nums[0], nums[1], nums[2], nums[3]) if nums.size() == 4 else v
		TYPE_QUATERNION:
			return Quaternion(nums[0], nums[1], nums[2], nums[3]) if nums.size() == 4 else v
		TYPE_AABB:
			if nums.size() == 6:
				return AABB(Vector3(nums[0], nums[1], nums[2]), Vector3(nums[3], nums[4], nums[5]))
			return v
	return v


## 把 "x, y, z" 形式的文本拆成数字分量。任何一项非法(或为空)即返回空数组,
static func _components(s: String) -> Array[float]:
	var body := s.replace("(", "").replace(")", "").replace("[", "").replace("]", "")
	var out: Array[float] = []
	for part in body.split(",", false):
		var t: String = part.strip_edges()
		if not t.is_valid_float():
			return [] as Array[float]
		out.append(t.to_float())
	return out
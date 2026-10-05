@tool
class_name VariantTool extends RefCounted

## ======= Variant 规范化(全项目唯一入口) =======
##
## 职责: 任何"从不可信来源取出一个值、当成某类型使用"的地方都走这里。
## 与 ValueTool 的分工 —— 两者不重叠:
##   ValueTool   管**数值运算**: clamp / 除法取整 / 百分比 / remap / move_toward
##   VariantTool 管**类型规范化**: 取值( get_* )与转换( as_* )
##
## ## 为什么必须是单一入口(不是风格问题, 是正确性问题)
## 裸转换在 GDScript 里几乎不报错, 只是**静默给出一个错的值**, 而且错的方向往往最坏:
##   1. `bool("false")` 是 true —— 非空字符串即真, 布尔参数**静默反转**。
##      最坏的方向是 dry_run 失效: AI 以为做了预演, 实际直接落盘。
##   2. `str(null)` 是 "null" —— 客户端把"未填"序列化成 null 而非省略键时,
##      路径变成字面量 "null", 报出"资源不存在: null"这类无从排查的错。
##   3. `int("abc")` / `int([])` 直接抛错; 就算被吞掉也只静默变 0, 于是
##      "参数传错了"表现为"深度为 0", 从结果里看不出是参数问题。
##   4. `Array("abc")` **不报错**, 而是逐字符遍历成 ['a','b','c'] —— 最隐蔽的一种。
##
## ## 五条统一规则(所有接口的行为都由这五条推导, 不允许各写一套)
##   R1 未填优先: null / 空串 / 纯空白串一律视为"未填", 返回缺省值, 不参与转换。
##      注意空白串必须先 strip_edges 再判, 否则 "  " 会被当成合法字符串值传下去。
##   R2 转换失败返回缺省值, **绝不抛错、绝不静默变 0**。缺省值由调用方显式给出。
##   R3 容器不做逐字符/逐键猜测: 非目标类型一律回落空容器。宁可空转, 不可走样。
##   R4 数字字符串只认内置 `is_valid_int()` / `is_valid_float()`, 不手写数字校验器
##      (手写版必然漏掉指数/负号/前后空格, 且各写各的会分叉)。
##   R5 bool 与 int/float 互转是**有意的**(云存档里 true 存 1 是常态), 但布尔字符串
##      只认明确列出的字面量 —— 绝不用 `s == "true"` 之外再兜底成真, 那正是 R1 要防的反转。
##
## ## 三层接口, 逐层组合而非各写一套
##   as_*  值 → 规范值。纯函数, 不知道字典存在, 也不知道键名。
##   get_* 字典 → 取键 → 规范值。完全等价于 `as_x(src.get(key, def), def)`,
##         单独存在只为让 60+ 处调用点不必重复写 `src.get(...)`。
##   infer/coerce/jsonable  文本 ⇄ 复杂类型 与 序列化方向, 见各自注释。

# ============================================================
# 判据(转换规则全部由这一段推导, 改这里等于改全局)
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
## 公开而非私有, 是为了让需要**三态**判定(真/假/都不是→报错)的调用方也能用同一份口径 ——
## 如 DefTableView 的 bool 单元格: 它必须区分"匹配真"与"匹配假"好给出不同错误信息,
## 而 as_bool 的二态接口表达不了这第三种情况。此时复用常量表, 不要另抄一份字面量。
const BOOL_TRUE_LITERALS := ["true", "1", "yes", "on"]
## 明确表示"假"的字符串字面量。其余字符串一律回落缺省值, 不猜。
const BOOL_FALSE_LITERALS := ["false", "0", "no", "off"]


## "未填"的统一判据(R1): null、空串、纯空白串。
##
## 单独暴露是因为业务里经常要问"这个参数到底填了没" —— 比如"没填 depth 就用默认深度,
## 填了才用"这类分支, 不该由调用方各自写 `v == null or str(v).is_empty()`。
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
# 第一层: as_* 值 → 规范值
# ============================================================

## 转 bool。接受: bool / 非零数字 / BOOL_TRUE_LITERALS / BOOL_FALSE_LITERALS。
##
## 显式不接受的情形走缺省值而非 false: 空串与 null 走 def, 无意义字符串也走 def,
## 这样 `as_bool(v, true)` 能表达"没填就默认开"。
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
##
## 不接受数组/对象 —— 它们不是"转不了", 是传错了(R3), 静默变 0 会把参数错误
## 伪装成"值恰好是 0", 是最难查的一类。
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
##
## 两处刻意与 `str()` 不同:
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
##
## 不做"字符串按逗号拆" —— 那是 as_string_array 的事, 且需要业务确认分隔符语义。
## 这里保持 R3: 拿不到就是拿不到, 空数组让下游 for 循环安全空转。
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
##
## 两种字符串来源都要, 是因为历史上真的两种都出现过: 手改的配置文件会写逗号分隔,
## 而 JSON 化过的会存 '["a","b"]'。缺任一种都会让配置项**静默变成空列表**,
## 而空列表不报错, 只是让后面的过滤条件失效。
static func as_string_array(v: Variant) -> Array[String]:
	var out: Array[String] = []
	if v is String:
		var s: String = v.strip_edges()
		if s.is_empty():
			return out
		# 只在文本形如 JSON 时才尝试解析。否则每个普通逗号分隔串都会让引擎打一条
		# "Parse JSON failed" —— 那并不是错误, 但会污染项目错误日志, 而基于日志的
		# 错误检查(get_game_errors)会把它当成真实问题上报, 逼着人去加忽略规则。
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
# 第二层: get_* 字典取值( = as_* + src.get(key, def) )
# ============================================================

## 键缺失**或**值为 null 都返回 def —— 这是 R1 在取键场景的直接推论:
## 客户端表达"未填"的两种方式(省略键 / 传 null)必须得到同一个结果, 否则
## "传 null"与"没传"会走两条不同分支, 而它们的语义本该完全相同。
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
# 第三层: 文本 ⇄ Variant 的往返与推断
# ============================================================

## JSON 文本 → Variant。非法文本返回 null, **不抛错**。
##
## 与 `JSON.parse_string` 的区别只有一点: 失败返回值统一为 null, 便于
## `if parse_json(s) is Dictionary` 这样的单点判空。非法 JSON 本来也只会返回 null,
## 但仍值得存在 —— 它让"解析并校验类型"这个动作有一个明确的落点。
static func parse_json(text: Variant) -> Variant:
	if not text is String:
		return null
	var s: String = (text as String).strip_edges()
	if s.is_empty():
		return null
	return JSON.parse_string(s)


## Variant → JSON 可安全序列化的形式。
##
## 解决的问题: JSON.stringify 遇到 Resource / NodePath / Vector2 等类型时,
## 要么静默变成 null, 要么生成客户端解析不了的形状 —— 表现为"响应里某个字段
## 莫名其妙是 null", 极难追。规则是把不可序列化的值换成**可读的定位信息**:
##   Resource → {"__res": 资源路径}, 其余标量与容器递归处理。
## 数组与 Packed*Array 统一转成普通 Array, 因为 stringify 对两者的输出形状不同。
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
##
## 用于"客户端只传来一段文字, 但它可能是坐标/颜色/数字/布尔"的场景
## (典型是编辑节点属性时手填的值)。判定规则刻意做成**无歧义**的:
##   "1,2"      → Vector2i   全整数
##   "1.0,2.0"  → Vector2    含小数
##   "1,2,3"    → Vector3i
##   "1,2,3.0"  → Vector3
##   "1,2,3,4"  → Color(RGBA, 缺 a 补 1.0)
##   "1,2,3,4,5,6" → AABB
##   "1,2,3,4" 视目标类型不同也可能是 Rect2, 故 Rect2 只在 coerce 里给, 不在此推断
##   "5" / "1.5" → int / float      "true"/"false" → bool
##   "null"/"nil" → null
##   其余 → 原样返回(不猜)
##
## 全整数给 i 版本而非一律给浮点版本, 是因为 UI 坐标与网格尺寸大量用整数,
## 一律给浮点会让拖拽时冒出 0.5 偏移。反过来"1.0,2.0"也不给整数版, 因为它显式
## 写了小数点, 是使用者在表达"这是浮点坐标"。
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
##
## 标量目标走第一层规则; 复合目标(Vectors/Color/Rect2...)走 infer 的分量解析,
## 因此**任何分量不是合法数字就原样返回**, 不做部分转换。
## 这一条修掉的是裸 `int(s)`/`float(s)` 的实际崩溃: 目标属性是 int 而客户端传
## "abc" 时, 裸转换直接抛错打断整个 handler, 这里只是安静地不转换。
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
## 表示"这不是一段可解析的分量文本" —— 调用方据此原样返回, 绝不猜。
static func _components(s: String) -> Array[float]:
	var body := s.replace("(", "").replace(")", "").replace("[", "").replace("]", "")
	var out: Array[float] = []
	for part in body.split(",", false):
		var t: String = part.strip_edges()
		if not t.is_valid_float():
			return [] as Array[float]
		out.append(t.to_float())
	return out
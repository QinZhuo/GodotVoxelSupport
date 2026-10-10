@tool
class_name QVoxelModifierSerializer
extends RefCounted

## 修改器与算子 ↔ JSON 的唯一实现 —— 链的落盘 / 读盘都从这里过。
## 【为什么叫 Serializer 而不是 Codec】`Codec`（coder + decoder）在业界指"内存表示 ↔ 压缩
## 字节流"的编解码器（本项目里那个是 QVoxelBlockCodec：五种块编码的 pick / pack / unpack）。
## 本类不做编码、不压缩、不定义字节格式，只做"对象 ↔ 普通字典/数组"的结构转换 —— 那正是
## 序列化器一词的含义。名字与能力对不上时，读代码的人会先去找并不存在的编码格式。
## 【为什么与 QVoxelDomain 分开】QVoxelDomain 管"域与链的语义规则"（这样排合不合法）；本类管
## "怎么写进文件、怎么读回来"。两者唯一的交点是都要提算子的类名，没有别的关系。
## 【为什么存"类名 + 参数"，而不是 Resource 序列化（var_to_bytes / .tres 内嵌）】
##   ① 可读可 diff 可手改：工程文件是给用户看的（`.qvx` 里 HEAD / NODE 本来就是 JSON）；
##   ② 跨版本稳定：var_to_bytes 里嵌着脚本路径与属性布局，插件目录一动、类一改名，整棵
##      算子树就失联；类名是稳定身份，解析入口只有 instantiate_op() 一处；
##   ③ 域既然由修改器子类类型表达，序列化也按类名解析，两处同思路。
## 【读盘失败一律返回 null，不回退成"空修改器"】类型失联（算子类被删 / 改名）或 kind
## 不认识时，凭空造一个空条目会让用户看到"链上多了一条不认识的东西"，比缺一条更难查。


# 修改器

## 按判别键造一个空修改器（对象的「加修改器」用它）。未知键返回 null。
static func new_modifier(kind: String) -> QVoxelModifier:
	match kind:
		QVoxelModifier.KIND_SDF:
			return QVoxelSdfModifier.new()
		QVoxelModifier.KIND_MODEL:
			return QVoxelModelModifier.new()
		QVoxelModifier.KIND_VOLUME:
			return QVoxelVolumeModifier.new()
		QVoxelModifier.KIND_TRANSFORM:
			return QVoxelTransformModifier.new()
	return null


## 修改器 → JSON。
static func modifier_to_dict(m: QVoxelModifier) -> Dictionary:
	return {} if m == null else m.to_dict()


## 反向。`kind` 不认识 / 算子类型失联 / 核类型不符，三者返回 null。
## 【缺 type 不是失败，是空修改器】QVoxelModifier 允许 op() == null 的占位条目（用户先加一条
## 再填算子）。to_dict 对空条目本就不写 type，读盘据此还原成空条目 —— 否则"加空修改器 → 保存
## → 打开"会静默少一条。这与"算子失联就丢弃整条、不造空壳"并不矛盾：前者是条目本来就空，
## 后者是条目有内容却认不出来。
static func modifier_from_dict(d: Variant) -> QVoxelModifier:
	if not (d is Dictionary):
		return null
	var dd: Dictionary = d
	var kind := str(dd.get("kind", ""))
	var m := new_modifier(kind)
	if m == null:
		push_warning("[QVX] 无法识别的修改器 kind「%s」（应为 %s）"
				% [kind, ", ".join(QVoxelModifier.KINDS)])
		return null
	m.enabled = bool(dd.get("enabled", true))
	m.combine = int(dd.get("combine", QVoxelDomain.Combine.UNION))
	m.blend = float(dd.get("blend", 2.0))
	m.seed = int(dd.get("seed", 0))
	m.label = str(dd.get("label", ""))
	if not dd.has("type"):
		return m
	var op := op_from_dict({"type": dd.get("type", ""), "params": dd.get("params", {})})
	if op == null or not m.set_op(op):
		return null
	return m


# 算子 ↔ JSON

## 类名 → 实例。仅接受全局类名（class_name），与 op_type_name() 对称。
## 不接受脚本路径：路径会随目录调整而失效，而类名是稳定身份。
static func instantiate_op(type_name: String) -> Resource:
	if type_name.is_empty():
		return null
	for e in ProjectSettings.get_global_class_list():
		if str(e.get("class", "")) != type_name:
			continue
		var script: Script = load(str(e.get("path", "")))
		if script != null and script.can_instantiate():
			return script.new()
		return null
	# 兜底：内建 Resource 子类（不用 class_name 的算子）
	if ClassDB.class_exists(type_name) and ClassDB.can_instantiate(type_name):
		var obj: Variant = ClassDB.instantiate(type_name)
		return obj if obj is Resource else null
	push_warning("[QVX] 找不到算子类型 %s（可能在改名/挪位后失联）" % type_name)
	return null


## 算子的类型名（落盘用）。**不用 get_class()**：GDScript 对象的 get_class() 给的是原生基类
## （Resource），而 class_name 注册在全局类表里，两者不是一回事。
static func op_type_name(op: Object) -> String:
	if op == null:
		return ""
	var script: Script = op.get_script()
	if script != null:
		var g := script.get_global_name()
		if not g.is_empty():
			return g
	return op.get_class()


## 算子 → { "type": 类名, "params": {属性: 值} }。嵌套的算子属性递归成同样的结构。
static func op_to_dict(op: Resource) -> Dictionary:
	if op == null:
		return {}
	var params := {}
	for name in exported_names(op):
		params[name] = value_to_json(op.get(name))
	return {"type": op_type_name(op), "params": params}


## 反向：从 {"type","params"} 重建算子。类型失联时返回 null（**不静默换成一个默认算子**：
## 那会让用户看到"链上凭空多了一个球"，比缺一个修改器更难查）。
static func op_from_dict(d: Variant) -> Resource:
	if not (d is Dictionary):
		return null
	var dd: Dictionary = d
	var op := instantiate_op(str(dd.get("type", "")))
	if op == null:
		return null
	var params: Variant = dd.get("params")
	if not (params is Dictionary):
		return op
	var props := _storage_properties(op)
	for k in (params as Dictionary):
		var key := str(k)
		if not props.has(key):
			continue  # 参数与当前类不匹配（旧文件/手改）：跳过而不是 set 进不存在的属性
		var raw: Variant = (params as Dictionary)[key]
		if int(props[key].get("type", TYPE_NIL)) == TYPE_ARRAY:
			# Array[T] 需要"元素类型"，而这只有属性现有的值知道（含脚本类）。见 _typed_array_from_json。
			op.set(key, _typed_array_from_json(raw, op.get(key)))
		else:
			op.set(key, value_from_json(raw, props[key]))
	return op


## @export 属性名（按声明顺序）。
static func exported_names(op: Object) -> PackedStringArray:
	var out := PackedStringArray()
	for name in _storage_properties(op):
		out.append(name)
	return out


## @export 属性：名字 → 属性描述（type / hint / hint_string / class_name…）。
## 【为什么过滤出 script 变量而不是直接用 get_property_list() 的全部条目】基类与内建的
## script / resource_path / resource_local_to_scene 等键会被写进工程文件，看起来像损坏；
## 而 STORAGE|EDITOR 正是"@export 属性"的标记（与 DEVFramework 的 ECS 序列化同一判据）。
## Dictionary 保持插入顺序，故遍历结果即声明顺序。
## 【为什么读盘也要它】set() 只认一部分类型转换（见 value_from_json），还原时必须知道
## 目标属性类型。属性描述是唯一能同时给出"名字 + 类型 + 元素类型"的来源。
static func _storage_properties(op: Object) -> Dictionary:
	var out := {}
	for p in op.get_property_list():
		var usage: int = p["usage"]
		if not (usage & PROPERTY_USAGE_STORAGE) and not (usage & PROPERTY_USAGE_EDITOR):
			continue
		var name := str(p["name"])
		if name.begins_with("_") or name == "script":
			continue
		out[name] = p
	return out


## 值 → JSON 可表达的形式。算子树递归成 op_to_dict。
## 【为什么不直接把 Variant 丢给 JSON.stringify】Godot 的 Vector3/Color/Transform3D 在 JSON
## 里会被写成字符串（"(1, 2, 3)"），读回来要靠解析字符串 —— 那是"能跑但脆"的方案。
## 这里显式转成数字数组，读回来按属性类型还原（属性类型是已知的，见 value_from_json 的说明）。
static func value_to_json(v: Variant) -> Variant:
	if v == null:
		return null
	if v is Resource:
		return op_to_dict(v)
	if v is Vector3:
		return [v.x, v.y, v.z]
	if v is Vector3i:
		return [v.x, v.y, v.z]
	if v is Vector2:
		return [v.x, v.y]
	if v is Vector2i:
		return [v.x, v.y]
	if v is Color:
		return [v.r, v.g, v.b, v.a]
	if v is Transform3D:
		var t: Transform3D = v
		return [t.basis.x.x, t.basis.x.y, t.basis.x.z,
				t.basis.y.x, t.basis.y.y, t.basis.y.z,
				t.basis.z.x, t.basis.z.y, t.basis.z.z,
				t.origin.x, t.origin.y, t.origin.z]
	if v is PackedByteArray or v is PackedInt32Array or v is PackedFloat32Array \
			or v is PackedStringArray or v is PackedVector3Array:
		return Array(v)
	if v is Array:
		var arr := []
		for e in (v as Array):
			arr.append(value_to_json(e))
		return arr
	if v is Dictionary:
		var dd := {}
		for k in (v as Dictionary):
			dd[str(k)] = value_to_json((v as Dictionary)[k])
		return dd
	if v is bool or v is int or v is float or v is String:
		return v
	# 未支持的类型：明确报出来，而不是让它烂在 JSON.stringify 里（那会连累整棵子树）
	push_warning("[QVX] 算子参数类型 %s 尚无 JSON 表达，已跳过" % type_string(typeof(v)))
	return null


## JSON → 值。**必须传属性描述** —— 还原目标类型不能指望 set() 替我们做。
## 【实测依据（Godot 4.7）】Object.set() 的类型转换能力是不齐全的：
##   ✅ Array → PackedInt32Array / PackedStringArray（标量元素的包数组可以）
##   ❌ Array → Vector3 / Vector3i（**静默无效**，属性保留默认值；除非属性自带 setter）
##   ❌ 无类型 Array → Array[T]（**静默变空数组**）
## 之前"set() 会做类型转换"的注释是错的：它会让工程文件里所有向量参数读回来都变默认值，
## 而且不报错（正是最坏的一种 bug）。所以这里按属性类型显式构造。
static func value_from_json(v: Variant, prop: Dictionary = {}) -> Variant:
	match int(prop.get("type", TYPE_NIL)):
		TYPE_VECTOR2:
			if v is Array and (v as Array).size() == 2:
				return Vector2(v[0], v[1])
		TYPE_VECTOR2I:
			if v is Array and (v as Array).size() == 2:
				return Vector2i(int(v[0]), int(v[1]))
		TYPE_VECTOR3:
			if v is Array and (v as Array).size() == 3:
				return Vector3(v[0], v[1], v[2])
		TYPE_VECTOR3I:
			if v is Array and (v as Array).size() == 3:
				return Vector3i(int(v[0]), int(v[1]), int(v[2]))
		TYPE_COLOR:
			if v is Array and (v as Array).size() == 4:
				return Color(v[0], v[1], v[2], v[3])
		TYPE_TRANSFORM3D:
			if v is Array and (v as Array).size() == 12:
				var t: Array = v
				return Transform3D(
						Basis(Vector3(t[0], t[1], t[2]), Vector3(t[3], t[4], t[5]),
								Vector3(t[6], t[7], t[8])),
						Vector3(t[9], t[10], t[11]))
		TYPE_PACKED_VECTOR3_ARRAY:
			if v is Array:
				var pv := PackedVector3Array()
				for e in (v as Array):
					pv.append(value_from_json(e, {"type": TYPE_VECTOR3}))
				return pv
	return _plain_from_json(v)


## 无类型线索的还原：字典若是算子形状就递归成算子，数组逐元素递归，标量原样返回。
static func _plain_from_json(v: Variant) -> Variant:
	if v is Dictionary and (v as Dictionary).has("type"):
		return op_from_dict(v)
	if v is Array:
		var out := []
		for e in (v as Array):
			out.append(_plain_from_json(e))
		return out
	return v


## `Array[T]` → Array[T]。必须造出**带元素类型**的数组：把无类型 Array 赋给 `Array[T]`
## 属性会被 Godot 静默丢弃（实测变空），而不是报错。
## 【为什么用属性现有值当模板，而不是解析 hint_string】`Array[T]` 的元素类型对**脚本类**
## （如 `Array[PcgWfcTile]`）必须连 Script 对象一起带上 —— 只给类名时 Godot 会按原生类校验，
## 报"Resource does not inherit from PcgWfcTile"（实测）。属性现有的空 `Array[T]` 恰好是
## 权威来源：`get_typed_builtin/get_typed_class_name/get_typed_script()` 三件套一次问清，
## 也不必赌 hint_string 的编码格式（"24/17:PcgWfcTile" 这类格式随版本变）。
static func _typed_array_from_json(v: Variant, template: Variant) -> Variant:
	if not (v is Array) or not (template is Array):
		return _plain_from_json(v)
	var t: Array = template
	var out := Array([], t.get_typed_builtin(), t.get_typed_class_name(), t.get_typed_script())
	var elem_prop := {"type": t.get_typed_builtin()}
	for e in (v as Array):
		out.append(value_from_json(e, elem_prop))
	return out


## 参与判脏用的算子签名：类型 + 实例 + 参数摘要。
## 【为什么含实例 id】同类型同参数的算子树可能有两棵，只按"类型+参数"判签名会把它们
## 误判为"没变"，于是改了一棵却复用了另一棵的结果。实例 id 保证语义不同的两棵树签名不同。
static func op_signature(op: Object) -> String:
	if op == null:
		return "-"
	var digest := str(op_to_dict(op)).hash()
	return "%s#%d@%d" % [op_type_name(op), op.get_instance_id(), digest]

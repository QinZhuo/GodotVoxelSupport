@tool
class_name QVoxWorld
extends Resource
## 世界 —— QVoxelier 的顶层编辑模型，也就是一份 `.qvox` 工程的**唯一常驻真值**。
##
## 【与 QVoxFile.QVoxDocument 的分工：一份真值 + 一个瞬时 DTO】
##   QVoxWorld    活的编辑状态（对象 + 手绘体素 + 修改器链），常驻内存、可被就地改写。
##   QVoxDocument QVoxFile 解析/序列化用的传输结构，**只在读写的那一瞬间存在**。
## 两者用 from_document() / to_document() 一对显式转换连接，**不允许同时常驻** ——
## 否则同一份体素会有两个账本，改动落哪边取决于调用顺序（这类静默数据丢失最难查）。
##
## 【为什么加载/保存要经一次转换，而不是直接编辑 Document】
## QVoxDocument 是"格式的忠实投影"：块表按 model_id 分桶、对象元数据散在 NODE 的 JSON 里、
## 没有"选择/焦点/撤销目标"这类编辑期概念。拿它当编辑模型，UI 每次都要自己拼装语义，
## 于是"格式细节"会渗透到每个面板里。转换一次（而不是每处各转一次）才能把格式关在 QVoxFile 内。
##
## 【head / materials / node / cach 原样保留】HEAD 与 NODE 都是 JSON，格式层不解释未知键
## （QVoxSpec §3/§7）。本类只解释自己拥有的键（world 设置、nodes[].steps / .size / .layer、
## layers、cameras），其余**原样写回** —— 于是"读进来再存出去"不会丢掉任何我们还没实现的东西。
##
## 【铁律：写入 = "替换"，绝不就地改嵌套结构】本类的改动由 QVoxPropertyCommand 撤销，
## 而它的快照是**浅**副本（见该类 _snapshot）。浅副本与活数据**共享**嵌套容器，所以
## `head["world"]["name"] = x` 这种就地写会让命令手里的"改前值"跟着一起变 ——
## 撤销于是"撤了个寂寞"，且全程不报错。故所有 setter 一律构造新容器再整体写回；
## 撤销的粒度也因此天然落在"数组 / 字典整体"上。

## HEAD JSON（qvox / channels 为必填键）。
@export var head: Dictionary = {}

## MATE：材质条目（每项 12 字节的语义结构 Dictionary，见 QVoxFile._parse_mate）。
## 索引即材质 ID，[0] 恒为空气。**这就是调色板本身**，不再另存一份"ID → Color"的映射。
@export var materials: Array = []

## NODE JSON（场景图 / 图层 / 相机）。本类只写 nodes[].steps / .size / .layer 与
## layers / cameras，其余键与其余节点**原样保留**。
@export var node: Dictionary = {}

## 对象列表。
@export var objects: Array[QVoxObject] = []

## CACH 块（派生数据，删掉语义为零）。求解缓存、缩略图这类东西放这里。
var cach: Array = []

## 每次"影响文件内容"的改动自增。UI 据此判断"是否需要提示保存"。
var revision := 0

signal content_changed


# ----------------------------------------------------------------------------
# 构造
# ----------------------------------------------------------------------------

## 新建空世界。HEAD 由格式常量组装（qvox 版本、必填 channels 等一律取自 QVoxSpec，
## 免得把"版本号"抄第二遍 —— 那正是升级格式时漏改一处的地方）。
static func create_empty() -> QVoxWorld:
	var w := QVoxWorld.new()
	w.head = {
		"qvox": QVoxSpec.VERSION,
		"channels": [{"name": QVoxSpec.DOMINANT_CHANNEL, "bpp": QVoxSpec.CHANNEL_BPP}],
		"block_size": QVoxSpec.DEFAULT_BLOCK_SIZE,
		"up_axis": QVoxSpec.DEFAULT_UP_AXIS,
		# 世界设置集中在 world 键下：HEAD 的其余键留给格式本身（§3）
		"world": {"name": "Untitled", "voxel_size": 0.1},
	}
	w.materials = [_air_entry()]
	return w


## 从解析结果转入编辑模型（加载路径）。**接管** doc 里的块表，不做深拷贝 ——
## doc 用完即弃（约定：不允许同时常驻），拷贝一份几百万格的数据纯属浪费。
static func from_document(doc: QVoxFile.QVoxDocument) -> QVoxWorld:
	var w := QVoxWorld.new()
	w.head = doc.head
	w.materials = doc.materials
	w.node = doc.node
	w.cach = doc.cach

	var bs := doc.get_block_size()
	var entries := _nodes_by_model(doc.node)
	for mid in doc.model_ids():
		var obj := QVoxObject.new()
		obj.model_id = mid
		obj.block_size = bs
		var blocks: Variant = doc.model_blocks(mid)
		obj.blocks = blocks if blocks is Dictionary else {}
		var entry: Variant = entries.get(mid)
		if entry is Dictionary:
			obj.object_name = str((entry as Dictionary).get("name", ""))
			obj.grid_size = _size_of_entry(entry, obj.blocks, bs)
			obj.layer = maxi(0, QVoxFile.as_index((entry as Dictionary).get("layer")))
			obj.modifiers = _modifiers_of_entry(entry)
		else:
			obj.object_name = "Model %d" % mid
			obj.grid_size = _infer_grid(obj.blocks, bs)
		w.objects.append(obj)
	return w


# ----------------------------------------------------------------------------
# 导出为传输结构（保存路径）
# ----------------------------------------------------------------------------

## 构出可交给 QVoxFile.serialize() 的文档。**每次调用都重新构**（Document 不常驻）。
func to_document() -> QVoxFile.QVoxDocument:
	var doc := QVoxFile.QVoxDocument.new()
	doc.head = head.duplicate(true)
	doc.head["block_size"] = block_size()  # 对象按它分块，必须与 HEAD 一致
	doc.materials = materials
	doc.node = _node_with_objects()
	doc.cach = cach
	for o in objects:
		if o == null:
			continue
		var blocks := _dense_blocks_of(o)
		if not blocks.is_empty():
			doc.models[o.model_id] = blocks
	return doc


# ----------------------------------------------------------------------------
# 世界级设置
# ----------------------------------------------------------------------------

func block_size() -> int:
	return int(head.get("block_size", QVoxSpec.DEFAULT_BLOCK_SIZE))


func world_name() -> String:
	return str(_settings().get("name", "Untitled"))


func set_world_name(value: String) -> void:
	_write_settings(_patched_settings("name", value))


## 一个体素在世界单位（米）下的边长。渲染与导出正交投影都读它。
func voxel_size() -> float:
	return float(_settings().get("voxel_size", 0.1))


## 【为什么改它要 _touch()】它一变，所有对象的实际尺寸跟着变 → 视口必须重排。
func set_voxel_size(value: float) -> void:
	_write_settings(_patched_settings("voxel_size", value))


# ----------------------------------------------------------------------------
# 材质（MATE 就是调色板本身）
# ----------------------------------------------------------------------------

## 材质颜色。ID 越界或条目缺失返回洋红（可见的错误色，而不是悄悄变黑）。
func material_color(material_id: int) -> Color:
	if material_id <= 0 or material_id >= materials.size():
		return Color.MAGENTA
	return _color_of(materials[material_id])


func set_material_color(material_id: int, color: Color) -> void:
	while materials.size() <= material_id:
		materials.append(_air_entry())
	var rgba := _rgba_of(color)
	# 换掉**整个条目**而不是就地改它的键：撤销走 QVoxPropertyCommand(world, &"materials") 时，
	# 快照只浅拷数组，就地改会让"改前值"一起变（见类头铁律）。
	var e: Dictionary = (materials[material_id] as Dictionary).duplicate()
	e["rgba"] = rgba
	e["r"] = (rgba >> 24) & 0xFF
	e["g"] = (rgba >> 16) & 0xFF
	e["b"] = (rgba >> 8) & 0xFF
	e["a"] = rgba & 0xFF
	materials[material_id] = e
	_touch()


## 追加一个新材质，返回其 ID。
func add_material(color: Color) -> int:
	var id := materials.size()
	materials.append(_air_entry())
	set_material_color(id, color)
	return id


func used_materials() -> Dictionary:
	var used := {}
	for o in objects:
		if o == null:
			continue
		for m in o.used_materials():
			used[m] = true
	return used


# ----------------------------------------------------------------------------
# 图层与相机（NODE 下的工程数据，§5.1）
# ----------------------------------------------------------------------------
# 【为什么它们没有自己的 Resource 类】图层与相机的唯一归宿是 `node` 这个 JSON 字典：
# 存盘要 JSON、读盘要 JSON。中间再过一层 Resource，只会凭空多出两处"字段改名"的机会 ——
# 而改名错位不报错，只静默丢字段。故本类直接读写 node 下的键，
# 与 HEAD 的 world 设置（_settings / _write_settings）同一手法。
#
# 【改图层怎么撤销】面板把一次改动包成 QVoxPropertyCommand(world, &"node") 即可 ——
# 本节 setter 一律**整体替换** node 下的数组，于是浅快照里的旧数组原封不动（见类头铁律）。
# "对象属于哪一层"则是 QVoxObject.layer，撤销走 QVoxPropertyCommand(obj, &"layer")。

## 图层数组（活引用，供面板遍历；**改动一律走下面的 setter**）。
func layers() -> Array:
	return _json_array_of(QVoxSpec.NODE_LAYERS_KEY)


## 相机书签数组（同上）。
func cameras() -> Array:
	return _json_array_of(QVoxSpec.NODE_CAMERAS_KEY)


## 图层数。**至少为 1** —— 文件没写 layers 时世界仍有隐含缺省层 0。
## 这个下界必须与 QVoxFile._build_scene 的判定一致，否则会出现
## "读得进来的 layer 值，写出去就被判越界"。
func layer_count() -> int:
	return maxi(1, layers().size())


## 图层某项的字段。越界 / 键缺失都回落到该键的缺省值（QVoxSpec.LAYER_FIELD_DEFAULTS），
## 于是调用方不必到处写 `get("visible", true)` —— 缺省只有一处。
func layer_field(index: int, key: String) -> Variant:
	return _entry_field(QVoxSpec.NODE_LAYERS_KEY, index, key, QVoxSpec.LAYER_FIELD_DEFAULTS)


func camera_field(index: int, key: String) -> Variant:
	return _entry_field(QVoxSpec.NODE_CAMERAS_KEY, index, key, QVoxSpec.CAMERA_FIELD_DEFAULTS)


## 改图层 / 相机某一项的一个字段。返回"是否真的改了"—— false 表示越界或值本来就相同，
## 调用方据此**不要**产生撤销单位（同"空手势不入栈"的约定）。
func set_layer_field(index: int, key: String, value: Variant) -> bool:
	return _set_entry_field(QVoxSpec.NODE_LAYERS_KEY, index, key, value)


func set_camera_field(index: int, key: String, value: Variant) -> bool:
	return _set_entry_field(QVoxSpec.NODE_CAMERAS_KEY, index, key, value)


## 追加图层，返回新下标（= 节点的 layer 值）。其余字段取缺省。
##
## 【为什么数组为空时要先落一条缺省层】"缺省层"隐含在"layers 为空"里，占着下标 0。
## 若直接 append，新层就顶掉了下标 0 —— 所有 layer == 0 的对象**当场换了层**，
## 而且没有任何提示（它们在文件里都写着 0）。所以先把这个隐含层实体化，再追加。
## 空数组这一状态本身仍保留给"从没建过图层"的最简文件（P2：缺省才是常态）。
func add_layer(layer_name := QVoxSpec.LAYER_DEFAULT_NAME) -> int:
	var next: Array = _json_array_of(QVoxSpec.NODE_LAYERS_KEY).duplicate()
	if next.is_empty():
		next.append(_seeded_entry(QVoxSpec.LAYER_FIELD_DEFAULTS, {}))
	next.append(_seeded_entry(QVoxSpec.LAYER_FIELD_DEFAULTS, {"name": layer_name}))
	_write_json_array(QVoxSpec.NODE_LAYERS_KEY, next)
	return next.size() - 1


## 追加相机书签，返回新下标。
func add_camera(camera_name := "camera") -> int:
	return _append_entry(QVoxSpec.NODE_CAMERAS_KEY, QVoxSpec.CAMERA_FIELD_DEFAULTS,
			{"name": camera_name})


## 删除一条图层，并把受影响的对象的 layer **整体左移**（被删层上的对象落到缺省层 0）。
##
## 【为什么删层必须连带搬 layer】不搬就会留下越界的 layer，存盘后 QVoxFile 会把它当越界
## 丢掉（§7）—— 对象的归属静默漂移到缺省层，而此刻界面上一切看起来都正常。
## 允许删到空数组：空数组 = 只有隐含缺省层，回到那个最简状态。
func remove_layer(index: int) -> bool:
	if not _remove_entry_at(QVoxSpec.NODE_LAYERS_KEY, index):
		return false
	for o in objects:
		if o == null:
			continue
		if o.layer == index:
			o.layer = 0
		elif o.layer > index:
			o.layer -= 1
	return true


func remove_camera(index: int) -> bool:
	return _remove_entry_at(QVoxSpec.NODE_CAMERAS_KEY, index)


# ----------------------------------------------------------------------------
# 对象
# ----------------------------------------------------------------------------

## 新建对象并接进世界。model_id 取"现有最大值 + 1"（而不是 size()）：
## 删掉中间某个对象后，ID 不会被新对象复用 —— 复用会让仍在引用旧 ID 的撤销命令改错对象。
func create_object(object_name := "", grid := Vector3i.ZERO) -> QVoxObject:
	var obj := QVoxObject.new()
	obj.model_id = next_model_id()
	obj.block_size = block_size()
	obj.grid_size = grid if grid.x > 0 and grid.y > 0 and grid.z > 0 else Vector3i(32, 32, 32)
	obj.object_name = object_name if not object_name.is_empty() else "Model %d" % obj.model_id
	objects.append(obj)
	_touch()
	return obj


func next_model_id() -> int:
	var top := -1
	for o in objects:
		if o != null:
			top = maxi(top, o.model_id)
	return top + 1


func find_object(model_id: int) -> QVoxObject:
	for o in objects:
		if o != null and o.model_id == model_id:
			return o
	return null


func remove_object(model_id: int) -> bool:
	var target := find_object(model_id)
	if target == null:
		return false
	objects.erase(target)
	_touch()
	return true


# ----------------------------------------------------------------------------
# 内部
# ----------------------------------------------------------------------------

func _touch() -> void:
	revision += 1
	content_changed.emit()


func _settings() -> Dictionary:
	var w: Variant = head.get("world")
	return w if w is Dictionary else {}


## 造一份"改过某个键"的设置副本。**不看原字典**（见类头铁律），缺了 world 键就得到一份
## 只含这个键的新字典 —— 这正是"缺了就补一个"的新写法：补的是副本，不是原地挖个洞。
func _patched_settings(key: String, value: Variant) -> Dictionary:
	var w := _settings().duplicate()
	w[key] = value
	return w


func _write_settings(w: Dictionary) -> void:
	head["world"] = w
	_touch()


## 取 node 下的 JSON 数组。缺失 / 类型不对一律回落到空数组 ——
## **不就地补键**：读路径不写数据，只有 setter 才写。
func _json_array_of(key: String) -> Array:
	var v: Variant = node.get(key)
	return v if v is Array else []


## 写回 node 下的 JSON 数组（**整体替换**，见类头铁律），并标脏。
func _write_json_array(key: String, arr: Array) -> void:
	node[key] = arr
	_touch()


func _entry_at(key: String, index: int) -> Dictionary:
	var arr := _json_array_of(key)
	if index < 0 or index >= arr.size() or not (arr[index] is Dictionary):
		return {}
	return arr[index]


func _entry_field(key: String, index: int, field: String, defaults: Dictionary) -> Variant:
	return _entry_at(key, index).get(field, defaults.get(field))


func _set_entry_field(key: String, index: int, field: String, value: Variant) -> bool:
	var arr := _json_array_of(key)
	if index < 0 or index >= arr.size() or not (arr[index] is Dictionary):
		return false
	if (arr[index] as Dictionary).get(field) == value:
		return false  # 值没变 → 不该占一次撤销
	var d: Dictionary = (arr[index] as Dictionary).duplicate()
	d[field] = value
	var next: Array = arr.duplicate()  # 新数组 + 新元素：旧的两份都留给浅快照
	next[index] = d
	_write_json_array(key, next)
	return true


## 造一条"先套缺省值、再盖上 seed"的新条目。**必须复制缺省表**：QVoxSpec 里的表是 const，
## 改它会直接运行期报错，而且会污染此后所有新条目。
func _seeded_entry(defaults: Dictionary, seed: Dictionary) -> Dictionary:
	var d := defaults.duplicate()
	for k in seed:
		d[k] = seed[k]
	return d


func _append_entry(key: String, defaults: Dictionary, seed: Dictionary) -> int:
	var next: Array = _json_array_of(key).duplicate()
	next.append(_seeded_entry(defaults, seed))
	_write_json_array(key, next)
	return next.size() - 1


func _remove_entry_at(key: String, index: int) -> bool:
	var arr := _json_array_of(key)
	if index < 0 or index >= arr.size():
		return false
	var next: Array = arr.duplicate()
	next.remove_at(index)
	_write_json_array(key, next)
	return true


## 对象 → 文件块表：丢掉全零块（= 空块不写入），并**排序键**。
## 【为什么排序】Dictionary 迭代顺序不保证稳定，而落盘字节、增量写的块搬运、
## 回归测试的逐字节哈希都要求"同一份数据 ⇒ 同一串字节"。
func _dense_blocks_of(o: QVoxObject) -> Dictionary:
	var out := {}
	var bs := o.block_size
	for k in o.block_keys():
		var buf := o.get_block(k)
		if buf.size() != QVoxSpec.block_volume(bs):
			continue
		var solid := false
		for m in buf:
			if m != 0:
				solid = true
				break
		if solid:
			out[k] = buf
	return out


## NODE JSON：把对象的 name / size / steps 写回各节点，其余键与其余节点**原样保留**。
##
## 【为什么是"打补丁"而不是"重新生成"】NODE 里还有变换、父子关系、动画、我们的未知键。
## 重新生成会静默丢掉它们；打补丁则只碰自己拥有的键（§7：格式不解释未知键）。
func _node_with_objects() -> Dictionary:
	var out := node.duplicate(true)
	var nodes: Array = []
	var raw: Variant = out.get("nodes")
	if raw is Array:
		nodes = raw
	# 现有节点按 model_id 建索引（保留顺序，只改匹配项）
	var at := {}
	for i in nodes.size():
		var e: Variant = nodes[i]
		if e is Dictionary and (e as Dictionary).has("model_id"):
			at[int((e as Dictionary)["model_id"])] = i
	for o in objects:
		if o == null:
			continue
		var idx: Variant = at.get(o.model_id)
		var entry: Dictionary = {}
		if idx != null:
			entry = (nodes[idx] as Dictionary).duplicate(true)
		entry["kind"] = "model"
		entry["model_id"] = o.model_id
		entry["name"] = o.object_name
		entry["size"] = [o.grid_size.x, o.grid_size.y, o.grid_size.z]
		# layer 缺省即 0（隐含缺省层），写 0 是冗语（P2）→ 只在非 0 时写。
		# 反向那次必须**删键**：不删的话"把对象挪回缺省层"会因为旧键残留而存不进去。
		if o.layer > 0:
			entry["layer"] = o.layer
		else:
			entry.erase("layer")
		var steps: Array = []
		for m in o.modifiers:
			if m != null:
				steps.append(QVoxModifierSerializer.modifier_to_dict(m))
		entry["steps"] = steps
		if idx != null:
			nodes[idx] = entry
		else:
			nodes.append(entry)
	if not nodes.is_empty() or out.has("nodes"):
		out["nodes"] = nodes
	return out


static func _nodes_by_model(node: Dictionary) -> Dictionary:
	var out := {}
	var nodes: Variant = node.get("nodes")
	if not (nodes is Array):
		return out
	for e in (nodes as Array):
		if e is Dictionary and (e as Dictionary).has("model_id"):
			out[int((e as Dictionary)["model_id"])] = e
	return out


## 节点里的 steps → 修改器链。认不出来的条目**跳过**（而不是让整份工程加载失败）：
## 一个失联的算子不该把用户另外九十九个对象一起拖下水。
static func _modifiers_of_entry(entry: Dictionary) -> Array[QVoxModifier]:
	var out: Array[QVoxModifier] = []
	var steps: Variant = entry.get("steps")
	if not (steps is Array):
		return out
	for d in (steps as Array):
		var m := QVoxModifierSerializer.modifier_from_dict(d)
		if m != null:
			out.append(m)
	return out


## 节点里显式写了 size 就用它；否则从块范围推断（外来文件可能没写 size）。
static func _size_of_entry(entry: Dictionary, blocks: Dictionary, bs: int) -> Vector3i:
	var s: Variant = entry.get("size")
	if s is Array and (s as Array).size() == 3:
		return Vector3i(int(s[0]), int(s[1]), int(s[2]))
	return _infer_grid(blocks, bs)


## 从块范围推断分辨率：取"最高块边界"，并向下取整到块边长的整数倍。
## 【为什么舍入到块边界】块是稀疏存储的分配单位，分辨率若不是它的整数倍，
## 最外一圈块就有一半永远用不到；外来文件本来也没记分辨率，取整是代价最小的还原。
static func _infer_grid(blocks: Dictionary, bs: int) -> Vector3i:
	var mx := Vector3i(bs, bs, bs)
	for k: Vector3i in blocks:
		mx.x = maxi(mx.x, (k.x + 1) * bs)
		mx.y = maxi(mx.y, (k.y + 1) * bs)
		mx.z = maxi(mx.z, (k.z + 1) * bs)
	return mx


static func _color_of(entry: Variant) -> Color:
	if not (entry is Dictionary):
		return Color.MAGENTA
	var e: Dictionary = entry
	return Color8(int(e.get("r", 255)), int(e.get("g", 0)), int(e.get("b", 255)),
			int(e.get("a", 255)))


static func _rgba_of(c: Color) -> int:
	var r := int(round(c.r * 255.0)) & 0xFF
	var g := int(round(c.g * 255.0)) & 0xFF
	var b := int(round(c.b * 255.0)) & 0xFF
	var a := int(round(c.a * 255.0)) & 0xFF
	return (r << 24) | (g << 16) | (b << 8) | a


## 空气条目（ID 0）。材质 ID 0 = 空，必须全零，否则 QVoxFile 会把它当实体材质。
static func _air_entry() -> Dictionary:
	return {"rgba": 0, "r": 0, "g": 0, "b": 0, "a": 0,
			"metal": 0, "rough": 0, "hardness": 0, "mass": 0,
			"e_r": 0, "e_g": 0, "e_b": 0}

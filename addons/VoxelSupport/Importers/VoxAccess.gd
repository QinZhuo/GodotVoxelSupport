class_name VoxAccess
## 加载.vox文件方法
## 已经过大量优化 可以快速加载完大型文件 大块数据加载到buffer后再读取 不要使用FileAccess的get函数 速度很慢
## 本类同时是 `.vox` 的**读口与写口**（Open / Save）—— 见 Save 的注释：坐标映射只有一处。

## 文件头魔数与写出的版本号。版本号只在写口用（读口把读到的版本原样打日志、不做分支）。
const VOX_MAGIC := "VOX "
const VOX_VERSION := 150

## 单个模型的边长上限。**格式本身没有这条限制**（SIZE 是 u32），是 MagicaVoxel 的实现上限：
## 超了它不报错，直接截断显示。XYZI 的坐标又是单字节，所以这里也是写口必须拦住的界。
## 放在这里当唯一出处 —— 上层要提前提醒用户时读它，而不是各自写一个 256。
const MODEL_LIMIT := 256

static func Open(path: String) -> VoxAccess:
	var time = Time.get_ticks_usec()
	var file := FileAccess.open(path, FileAccess.READ)

	if file == null:
		return null

	if file.get_32() != 0x20584F56:
		file.close()
		return null

	var version = file.get_32()
	var vox := VoxAccess.new(file)
	print_verbose("open .vox time: ", (Time.get_ticks_usec() - time) / 1000.0, "ms, version: ", version)
	file.close()
	return vox


## 写出 `.vox` —— **Open 的逆运算**，逐项取 read_chunk() 各分支的反向映射。
## 【为什么写口必须和读口住同一个文件】`.vox` 的坐标不是"随便挑一个约定"，而是 MagicaVoxel 的
## Z-up 经 `(x,y,z)→(x,z,-y)` 旋转后的样子，且 `VoxelModel.size` 还额外带着"按尺寸居中 + Z 取反"
## 那一套。读写两侧各维护一份映射，迟早有一侧悄悄跑偏，而症状是"导出看着挺对，其实整体镜像或
## 错开一格"——最难当场发现的那类错误。放在一起，改一侧就会看见另一侧。
## 【写出什么 / 不写什么】
##   · 写：models（SIZE + XYZI 逐模型）、调色板（RGBA，255 项）、场景图（nTRN / nGRP / nSHP）。
##   · 不写：MATL（PBR 参数）。`.vox` 的交换语义就是调色板，PBR 属 `.qvx` 的职责
##     （无损存盘走 QVoxelWorld.to_document，那里 MATE 才是完整的）。
## 【场景图按"节点类型反推"重建】读入时 nTRN / nGRP / nSHP 被摊平成同一个 VoxelNode，但信息
## 并未丢失：带 model_id 的帧 = nSHP、多子节点 = nGRP、其余 = nTRN。于是能原样写回结构，
## 而不是退化成"所有模型都堆在原点"。
static func Save(path: String, voxel: VoxAsset) -> Error:
	if voxel == null:
		return ERR_INVALID_PARAMETER
	var payload := StreamPeerBuffer.new()
	_write_models(payload, voxel)
	_write_palette(payload, voxel)
	_write_layers(payload, voxel)
	_write_scene(payload, voxel)

	var out := StreamPeerBuffer.new()
	out.put_data(VOX_MAGIC.to_ascii_buffer())
	out.put_32(VOX_VERSION)
	# MAIN 的 content 为空、children 为整段负载（与 Open 的读法一致：它只按 content 定位，
	# 子块靠顺序往下读，所以这里的 children 长度是给别的工具看的、也是标准要求的）。
	_chunk(out, "MAIN", PackedByteArray(), payload.data_array.size())
	out.put_data(payload.data_array)

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer(out.data_array)
	file.close()
	return OK


## 朝向解码缓存（索引即 `_r` 原始值；Basis 是值类型，缓存只省重复的位运算与列构造）。
static var _rotations: Array = []

## `_r` 的全部合法取值（官方文档列出的 24 个）。写口据此反查编码 —— 见 _encode_rotation。
## **单位矩阵是 4，不是 0**，故"没有旋转"也要显式写成 4。
const ROTATION_VALUES := [2, 4, 9, 17, 22, 24, 33, 38, 40, 50, 52, 57, 65, 70, 72, 82, 84, 89,
		98, 100, 105, 113, 118, 120]
const ROTATION_VALUE_IDENTITY := 4


## `.vox` 的 `nTRN._r`：MagicaVoxel 把 3×3 朝向矩阵压成 **7 位整数**（0–127）。
## 【为什么只留在这里】这是 `.vox` 独有的省字节布局：低 2 位 = 第 1 行的非零元所在列、
## 次 2 位 = 第 2 行，第 3 行由"三行必须是 {0,1,2} 的置换"推出，高 3 位是三个轴的符号；
## 并且整个编码带 Z-up 约定。它是 MagicaVoxel 的历史包袱而非通用表示，因此不外提成公共类，
## 也不要求 QVX 的 NODE 去模仿（那边用四元数，见 QVoxelAsset._node_transform）。
## 【索引不是 0–23】"24 种朝向"说的是**结果集合**，不是取值区间。合法取值恰好 24 个且不连续
## （官方文档列出：2, 4, 9, 17, 22, 24, 33, 38, 40, 50, 52, 57, 65, 70, 72, 82, 84, 89,
## 98, 100, 105, 113, 118, 120；**单位矩阵是 4，不是 0**）。故缓存按 128 项建，
## 且绝不能做任何"夹到 0–23"的处理——那会把多个不同朝向静默映射成同一个。
## 【非法值不崩、也不误读】位域本身只保证"每行一个非零元"，因此要挡两类无朝向可言的值：
##   · 行索引不是 {0,1,2} 的置换：如 `0`（推出 row2=3）与 `3`（行索引越界）；
##   · 行索引是置换、但行列式为 −1：位域允许 48 种"置换 × 符号"组合，其中一半是**镜像**，
##     官方文档同样不把它们算作合法旋转。
## 两类都按"无旋转"返回恒等——既不抛越界、也不构造退化矩阵，更不静默给模型套一个镜像。
## 【方向已核对】官方文档给的是**行主序**矩阵 `M[0][i0]=s0`（i0 为第 1 行非零元所在列，
## 第 3 行索引由 `3-i0-i1` 推出）；而 Godot 的 `Basis(x, y, z)` 以这三者为**列（轴）**，
## 因此下面"列 → 行/列重排"的写法恰好把 `M` 原样接过来，再补一次 Z-up→Y-up 换算
## （`C·M·C⁻¹`，C 即体素坐标那套 `(x,y,z)→(x,z,-y)`）——与官方 24 个朝向逐值比对零偏差。
## 解码结果是精确的轴对齐 Basis：整数坐标经它变换后仍是整数，往返无浮点误差。
static func _decode_rotation(value: int) -> Basis:
	if value < 0 or value > 127:
		return Basis()
	if _rotations.is_empty():
		_rotations.resize(128)
	var cached: Variant = _rotations[value]
	if cached != null:
		return cached
	var row0 := value & 3
	var row1 := (value >> 2) & 3
	var row2 := 3 - row0 - row1
	if row0 > 2 or row1 > 2 or row0 == row1 or row2 < 0 or row2 > 2:
		return Basis()
	var sign0 := 1.0 if ((value >> 4) & 1) == 0 else -1.0
	var sign1 := 1.0 if ((value >> 5) & 1) == 0 else -1.0
	var sign2 := 1.0 if ((value >> 6) & 1) == 0 else -1.0
	# 三行各有一个 ±1：第 i 行的非零元落在 rowX 指定的列上，其余为 0
	var cols := [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
	cols[row0] = Vector3(sign0, 0, 0)
	cols[row1] = Vector3(0, sign1, 0)
	cols[row2] = Vector3(0, 0, sign2)
	var col0: Vector3 = cols[0]
	var col1: Vector3 = cols[1]
	var col2: Vector3 = cols[2]
	# 源格式为 Z-up、Godot 为 Y-up：列重排即轴向转换。
	# 行/列重排与符号翻转都不改变行列式的正负，故直接用它筛掉镜像（见类注释）。
	var basis := Basis(
			Vector3(col0.x, col0.z, -col0.y),
			Vector3(col2.x, col2.z, -col2.y),
			Vector3(-col1.x, -col1.z, col1.y))
	if basis.determinant() < 0.0:
		return Basis()
	_rotations[value] = basis
	return basis

func _init(file: FileAccess):
	_file = file
	voxel = VoxAsset.new()
	# 索引 0 恒为 null（空气占位，遵循全项目统一材质契约）；1..255 预建并设好 id，
	# 使"数组下标 == 材质ID"成立（align_by_id、体素值查找都依赖这一点）。
	voxel.materials.resize(256)
	for i in range(1, voxel.materials.size()):
		var mat := VoxelMaterial.new()
		mat.id = i
		voxel.materials[i] = mat
	while file.get_position() < file.get_length():
		read_chunk()
	voxel.check_nodes()

var voxel: VoxAsset
var _file: FileAccess

func read_chunk():
	var id := _get_string(4)
	var size := _get_32()
	var chunks := _get_32()
	var end := _file.get_position() + size
	match id:
		"SIZE":
			var model := VoxAsset.VoxelModel.new()
			voxel.models.append(model)
			var x := _get_32()
			var y := _get_32()
			var z := _get_32()
			model.size = Vector3i(x, z, y)
		"XYZI":
			var model := voxel.models.back()
			var num_voxels = _get_32()
			var buffer = _file.get_buffer(num_voxels * 4)
			var pos: Vector3i
			for i in range(num_voxels):
				var offset = i * 4
				pos.x = buffer[offset]
				pos.z = - buffer[offset + 1]
				pos.y = buffer[offset + 2]
				var index = buffer[offset + 3]
				model.voxels[pos] = index
		"RGBA":
			var buffer = _file.get_buffer(255 * 4)
			for i in range(255):
				var offset = i * 4
				voxel.materials[i + 1].color = Color(buffer[offset] / 255.0, buffer[offset + 1] / 255.0, buffer[offset + 2] / 255.0, buffer[offset + 3] / 255.0)
		"nTRN":
			var node := _get_node()
			node.child_nodes.append(_get_32())
			_get_32() # reserved id (must be -1)
			node.layerId = _get_32()
			for i in _get_32():
				var frame_attributes := _get_dictionary()
				var frame_index := int(frame_attributes.get('_f', '0'))
				var frame := node.get_frame(frame_index)
				if frame_attributes.has('_t'):
					var position := frame_attributes['_t'].split_floats(' ')
					frame.position = Vector3(position[0], position[2], -position[1])
				if frame_attributes.has('_r'):
					frame.rotation = _decode_rotation(int(frame_attributes['_r']))
		"nGRP":
			var node := _get_node()
			for i in _get_32():
				node.child_nodes.append(_get_32())
		"nSHP":
			var node := _get_node()
			for i in _get_32():
				var model_id := _get_32()
				var model_attributes := _get_dictionary()
				var frame_index := int(model_attributes.get('_f', '0'))
				node.get_frame(frame_index).model_id = model_id
		"MATL":
			var material_id := _get_32()
			# 条目 0 是空气占位（null），只有 1..255 是真实材质
			if material_id >= 1 and material_id < 256:
				var material := voxel.materials[material_id]
				var attributes := _get_dictionary()
				var type = attributes.get("_type", "diffuse")
				match type:
					"_metal":
						material.metal = float(attributes.get("_metal", 0))
						material.rough = float(attributes.get("_rough", 0))
					"_emit":
						material.emission = float(attributes.get("_emit", 0))
					"_glass":
						material.trans = get_trans(attributes)
						material.rough = float(attributes.get("_rough", 0))
					"_blend":
						material.metal = float(attributes.get("_metal", 0))
						material.rough = float(attributes.get("_rough", 0))
						material.trans = get_trans(attributes)
					_:
						material.metal = 0
						material.rough = 1
		"LAYR":
			var layer := VoxAsset.VoxelLayer.new()
			layer.id = _get_32()
			layer.isVisible = _get_dictionary().get('_hidden', '0') != '1'
			voxel.layers[layer.id] = layer

		_:
			pass

	_file.seek(end)

func get_trans(attributes: Dictionary) -> float:
	var alpha := 0.0
	if attributes.has("_trans"):
		alpha = float(attributes.get("_trans", 0.0))
	elif attributes.has("_alpha"):
		alpha = float(attributes.get("_alpha", 0.0))
	return alpha

func _get_32() -> int:
	return _file.get_32()

func _get_string(length: int) -> String:
	return _file.get_buffer(length).get_string_from_ascii()

func _get_dictionary() -> Dictionary[String, String]:
	var dictionary: Dictionary[String, String]
	for _p in range(_get_32()):
		var key = _get_string(_get_32())
		dictionary[key] = _get_string(_get_32())
	return dictionary

func _get_node() -> VoxAsset.VoxelNode:
	var node := VoxAsset.VoxelNode.new()
	node.id = _get_32()
	var attributes := _get_dictionary()
	if attributes.has("_name"):
		node.name = attributes.get("_name")
	voxel.nodes[node.id] = node
	return node


# 写出（Save 的零件）
# 【为什么全部是 static】写口不需要读口的状态（_file / voxel），给它实例只会让人以为
# "得先 Open 一个空文件才能 Save"。Save 是纯函数：资产进、字节出。

## 读口映射 `(x,y,z)→(x,z,-y)`（Z-up → Y-up）的**逆**。体素、`_t` 平移、尺寸重排都只经它一处。
static func _to_file(v: Vector3) -> Vector3:
	return Vector3(v.x, -v.z, v.y)


## 尺寸是"长度"，不含方向 —— 故轴向重排后取绝对值。读口正是这样丢符号的：
## `model.size = Vector3i(x, z, y)`，而 XYZI 的 `pos.z = -buffer[offset+1]` 是带符号的。
static func _file_extent(size: Vector3) -> Vector3i:
	return Vector3i(_to_file(size).abs())


## 写一个块：**内容先写进子缓冲**，才拿得到长度填进块头（`.vox` 的块头带长度、不预留）。
static func _chunk(out: StreamPeerBuffer, id: String, body: PackedByteArray, children := 0) -> void:
	out.put_data(id.to_ascii_buffer())
	out.put_32(body.size())
	out.put_32(children)
	out.put_data(body)


## 属性字典（长度前缀的键值串对）。顺序即插入顺序，故构造时的显式顺序就是落盘顺序 ——
## 落盘字节稳定才能做"同数据同字节"的回归比对。
## 【长度必须取"字节数"而不是 `String.length()`】后者是字符数，一旦值里出现非 ASCII（比如节点的
## `_name` 是中文），两者就对不上：长度写小了，读口按它截取就会把后续字段整体读歪（不报错、只是
## 内容全乱）。所以先转成字节数组、再拿它的大小当长度，长度与内容同源。
static func _write_attributes(out: StreamPeerBuffer, attributes: Dictionary) -> void:
	out.put_32(attributes.size())
	for key in attributes:
		var kb := str(key).to_ascii_buffer()
		var vb := str(attributes[key]).to_ascii_buffer()
		out.put_32(kb.size())
		out.put_data(kb)
		out.put_32(vb.size())
		out.put_data(vb)


static func _node_attributes(node: VoxAsset.VoxelNode) -> Dictionary:
	return {"_name": node.name} if not node.name.is_empty() else {}


## 帧的 `_f` / `_t` / `_r`。position / rotation 为 null 时**不落键**（读口也是"有键才读"，
## 缺键即"这一帧没摆过"）—— 写个恒等值进去会凭空造出一条"显式摆过"的记录。
## 【`_r` 与官方规范的已知分歧】读口用 `to_int()` 解析 `_r`（即十进制串），而官方规范里 `_r`
## 是 3 字节原始序列、位语义未完整公开。写口**跟读口走**，保证本项目的往返一致；代价是
## "带旋转的"导出文件在 MagicaVoxel 里朝向可能不对。实际不受影响：正常导出路径
## （VoxAsset.from_world）不产生任何旋转帧，而读入真实 MagicaVoxel 文件时读口本就把 `_r`
## 解析成了单位旋转 —— 也就是说这条路本来就没有非单位旋转可写。
static func _frame_attributes(index: int, frame: VoxAsset.VoxelFrame) -> Dictionary:
	var a := {"_f": str(index)}
	if frame.position != null:
		var p := _to_file(frame.position)
		a["_t"] = "%s %s %s" % [p.x, p.y, p.z]
	if frame.rotation != null:
		a["_r"] = str(_encode_rotation(frame.rotation))
	return a


## Y-up 的 Basis → `_r` 的 7 位编码。**不去反推位域公式**：合法值只有 24 个（见 _decode_rotation
## 的注释），逐个解码比对即可 —— 逆函数因此永远与正函数同源，不会各自跑偏。
static func _encode_rotation(basis: Basis) -> int:
	for value in ROTATION_VALUES:
		if _decode_rotation(value).is_equal_approx(basis):
			return value
	return ROTATION_VALUE_IDENTITY


static func _write_models(out: StreamPeerBuffer, voxel: VoxAsset) -> void:
	for model in voxel.models:
		var extent := _file_extent(model.size)
		var size_body := StreamPeerBuffer.new()
		size_body.put_32(extent.x)
		size_body.put_32(extent.y)
		size_body.put_32(extent.z)
		_chunk(out, "SIZE", size_body.data_array)

		# 【为什么先筛一遍而不是边写边跳过】XYZI 的体素数是块头长度的一部分，写完再发现越界
		# 就没法回退了。越界的原始坐标写进去会被 put_8 截成另一个合法字节 → 读回来是**别的位置**
		# 上多了一个体素（不报错、不崩，只是模型变了形），故宁可丢弃并明确报出条数。
		var body := PackedByteArray()
		body.resize(model.voxels.size() * 4)
		var n := 0
		var dropped := 0
		for pos in model.voxels:
			var p := Vector3i(_to_file(Vector3(pos)))
			# 上界取 min(盒尺寸, MODEL_LIMIT)：XYZI 的坐标是**单字节**，超出的坐标会被截成
			# 另一个合法字节（同"越界静默变形"的坑），故与越界一视同仁。
			if p.x < 0 or p.y < 0 or p.z < 0 \
					or p.x >= mini(extent.x, MODEL_LIMIT) or p.y >= mini(extent.y, MODEL_LIMIT) \
					or p.z >= mini(extent.z, MODEL_LIMIT):
				dropped += 1
				continue
			body[n * 4] = p.x
			body[n * 4 + 1] = p.y
			body[n * 4 + 2] = p.z
			body[n * 4 + 3] = model.voxels[pos] & 0xFF
			n += 1
		if dropped > 0:
			push_warning("[VoxAccess] 写出时丢弃了 %d 个体素：原始坐标落在模型盒 %s 之外。"
					% [dropped, extent])
		body.resize(n * 4)
		var xyzi_body := StreamPeerBuffer.new()
		xyzi_body.put_32(n)
		xyzi_body.put_data(body)
		_chunk(out, "XYZI", xyzi_body.data_array)


## RGBA 恒写满 255 项（下标 1..255）。缺失的材质补白：读口的 255 项是定长块，
## 少写会让整份文件错位，而"缺项"在合法资产里本就意味着"未使用的调色板槽"。
static func _write_palette(out: StreamPeerBuffer, voxel: VoxAsset) -> void:
	var body := PackedByteArray()
	body.resize(255 * 4)
	for i in range(1, 256):
		var c := Color.WHITE
		if i < voxel.materials.size() and voxel.materials[i] != null:
			c = voxel.materials[i].color
		body[(i - 1) * 4] = _byte_of(c.r)
		body[(i - 1) * 4 + 1] = _byte_of(c.g)
		body[(i - 1) * 4 + 2] = _byte_of(c.b)
		body[(i - 1) * 4 + 3] = _byte_of(c.a)
	_chunk(out, "RGBA", body)


static func _byte_of(v: float) -> int:
	return int(round(v * 255.0)) & 0xFF


## LAYR（图层可见性）。**必须写**：读口的 `VoxelNode.get_models` 会跳过 `isVisible == false` 的
## 图层 —— 不写的话，本来藏着的体素会在重新读入时全部冒出来（在 MagicaVoxel 里同样如此）。
## 只写 `_hidden`，因为读口只认它（`_name` 在 VoxelLayer 上根本没有字段可放）。
static func _write_layers(out: StreamPeerBuffer, voxel: VoxAsset) -> void:
	for id in voxel.layers:
		var layer: VoxAsset.VoxelLayer = voxel.layers[id]
		if layer == null:
			continue
		var body := StreamPeerBuffer.new()
		body.put_32(layer.id)
		_write_attributes(body, {} if layer.isVisible else {"_hidden": "1"})
		_chunk(out, "LAYR", body.data_array)


## 场景图写出。两件事：**节点排序** + **类型反推**。
## 【排序】格式本身只靠 id 引用，没明文要求顺序；但官方写出的文件里父节点 id 恒小于子节点，
## 且多数第三方解析器默认"0 号是根、父先于子"。所以这里从 0 号根做广度优先，输出"父先于子"的
## 顺序 —— 读进来的文件本就是这个顺序，故通常只是原样输出；只有手工拼的资产会被理顺。
## 到不了的节点（没有根 / 有环）按插入序补在末尾，宁可多写也不静默丢。
## 【类型反推】每一档都对应读口的一条独有特征，故不会互相冒充：
##   · 有带 model_id 的帧        → nSHP（只有 nSHP 分支会填 model_id）
##   · 多于 1 个子节点            → nGRP（nTRN 只读 1 个子节点）
##   · 恰好 1 个子节点            → nTRN
##   · 0 个子节点（且无 model）   → nGRP（写 0 个孩子）
## 最后一档为什么是 nGRP 而不是 nTRN：nTRN 的块头里**必须**有一个子节点 id，没有就只能写 -1，
## 而读口会把 -1 塞进 child_nodes，`get_models` 随后去 `nodes[-1]` 取到 null 再调方法 —— 直接崩。
## 写成一个"空组"则既不崩、又保住了 id（父节点的引用不会悬空）。
static func _write_scene(out: StreamPeerBuffer, voxel: VoxAsset) -> void:
	for id in _node_order(voxel):
		var node: VoxAsset.VoxelNode = voxel.nodes[id]
		if not _shape_frames(node).is_empty():
			_write_shape(out, node)
		elif node.child_nodes.size() == 1:
			_write_transform(out, node)
		else:
			_write_group(out, node)


static func _node_order(voxel: VoxAsset) -> Array:
	var order: Array = []
	var seen := {}
	var queue: Array = [0] if voxel.nodes.has(0) else []
	while not queue.is_empty():
		var id: int = queue.pop_front()
		if seen.has(id) or not voxel.nodes.has(id) or voxel.nodes[id] == null:
			continue
		seen[id] = true
		order.append(id)
		for child in voxel.nodes[id].child_nodes:
			if not seen.has(child):
				queue.append(child)
	for id in voxel.nodes:
		if not seen.has(id) and voxel.nodes[id] != null:
			order.append(id)
	return order


## 该节点是不是 nSHP：任一帧带 model_id 即是。**只看帧、不看 child_nodes** ——
## 一个 nSHP 也可以有子节点（MagicaVoxel 允许），而"带 model_id 的帧"是它独有的特征。
static func _shape_frames(node: VoxAsset.VoxelNode) -> Array:
	var out: Array = []
	for index in node.frames:
		var frame: VoxAsset.VoxelFrame = node.frames[index]
		if frame != null and frame.model_id >= 0:
			out.append([index, frame])
	return out


static func _write_transform(out: StreamPeerBuffer, node: VoxAsset.VoxelNode) -> void:
	var body := StreamPeerBuffer.new()
	body.put_32(node.id)
	_write_attributes(body, _node_attributes(node))
	body.put_32(node.child_nodes[0])
	body.put_32(-1)  # reserved：读口明确要求它是 -1
	body.put_32(node.layerId)
	body.put_32(node.frames.size())
	for index in node.frames:
		_write_attributes(body, _frame_attributes(index, node.frames[index]))
	_chunk(out, "nTRN", body.data_array)


static func _write_group(out: StreamPeerBuffer, node: VoxAsset.VoxelNode) -> void:
	var body := StreamPeerBuffer.new()
	body.put_32(node.id)
	_write_attributes(body, _node_attributes(node))
	body.put_32(node.child_nodes.size())
	for child in node.child_nodes:
		body.put_32(child)
	_chunk(out, "nGRP", body.data_array)


static func _write_shape(out: StreamPeerBuffer, node: VoxAsset.VoxelNode) -> void:
	var frames := _shape_frames(node)
	var body := StreamPeerBuffer.new()
	body.put_32(node.id)
	_write_attributes(body, _node_attributes(node))
	body.put_32(frames.size())
	for item in frames:
		var frame: VoxAsset.VoxelFrame = item[1]
		body.put_32(frame.model_id)
		# `_model` 与前面的 model_id 重复，但它是 MagicaVoxel 的既有写法，照写（读口不看它）。
		_write_attributes(body, {"_f": str(item[0]), "_model": str(frame.model_id)})
	_chunk(out, "nSHP", body.data_array)

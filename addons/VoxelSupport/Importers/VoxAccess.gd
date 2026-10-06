class_name VoxAccess
## 加载.vox文件方法
## 已经过大量优化 可以快速加载完大型文件 大块数据加载到buffer后再读取 不要使用FileAccess的get函数 速度很慢

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

## 朝向解码缓存（索引即 `_r` 原始值；Basis 是值类型，缓存只省重复的位运算与列构造）。
static var _rotations: Array = []


## `.vox` 的 `nTRN._r`：MagicaVoxel 把 3×3 朝向矩阵压成 **7 位整数**（0–127）。
##
## 【为什么只留在这里】这是 `.vox` 独有的省字节布局：低 2 位 = 第 1 行的非零元所在列、
## 次 2 位 = 第 2 行，第 3 行由"三行必须是 {0,1,2} 的置换"推出，高 3 位是三个轴的符号；
## 并且整个编码带 Z-up 约定。它是 MagicaVoxel 的历史包袱而非通用表示，因此不外提成公共类，
## 也不要求 QVox 的 NODE 去模仿（那边用四元数，见 QVoxAsset._node_transform）。
##
## 【索引不是 0–23】"24 种朝向"说的是**结果集合**，不是取值区间。合法取值恰好 24 个且不连续
## （官方文档列出：2, 4, 9, 17, 22, 24, 33, 38, 40, 50, 52, 57, 65, 70, 72, 82, 84, 89,
## 98, 100, 105, 113, 118, 120；**单位矩阵是 4，不是 0**）。故缓存按 128 项建，
## 且绝不能做任何"夹到 0–23"的处理——那会把多个不同朝向静默映射成同一个。
##
## 【非法值不崩、也不误读】位域本身只保证"每行一个非零元"，因此要挡两类无朝向可言的值：
##   · 行索引不是 {0,1,2} 的置换：如 `0`（推出 row2=3）与 `3`（行索引越界）；
##   · 行索引是置换、但行列式为 −1：位域允许 48 种"置换 × 符号"组合，其中一半是**镜像**，
##     官方文档同样不把它们算作合法旋转。
## 两类都按"无旋转"返回恒等——既不抛越界、也不构造退化矩阵，更不静默给模型套一个镜像。
##
## 【方向已核对】官方文档给的是**行主序**矩阵 `M[0][i0]=s0`（i0 为第 1 行非零元所在列，
## 第 3 行索引由 `3-i0-i1` 推出）；而 Godot 的 `Basis(x, y, z)` 以这三者为**列（轴）**，
## 因此下面"列 → 行/列重排"的写法恰好把 `M` 原样接过来，再补一次 Z-up→Y-up 换算
## （`C·M·C⁻¹`，C 即体素坐标那套 `(x,y,z)→(x,z,-y)`）——与官方 24 个朝向逐值比对零偏差。
##
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

class_name VoxAccess
## `.vox` 加载器（**只读** —— 导出见 `VoxWriter`）。
## 已按"大块读进 buffer 再解析"优化：不要改回逐字段 `FileAccess` 读，那样大文件会慢一个量级。
## 【几何约定不在这里】坐标轴、朝向编码、调色板项下标全在 `VoxSpace`（读写两端唯一出处），
## 本类只负责"按 chunk 类型把字节搬进 `VoxAsset` 的形状"。

## 文件头魔数（读口据此校验；读到的版本号原样打日志、不做分支）。
const VOX_MAGIC := "VOX "


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


var voxel: VoxAsset
var _file: FileAccess


func _init(file: FileAccess):
	_file = file
	voxel = VoxAsset.new()
	# 索引 0 恒为 null（空气占位，遵循全项目统一材质契约）；1..255 预建并设好 id，
	# 使"数组下标 == 材质ID"成立（align_by_id、体素值查找都依赖这一点）。
	voxel.materials.resize(QVoxelSpec.MATERIAL_COUNT)
	for i in range(1, voxel.materials.size()):
		var mat := VoxelMaterial.new()
		mat.id = i
		voxel.materials[i] = mat
	while file.get_position() < file.get_length():
		read_chunk()
	voxel.check_nodes()


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
			model.size = VoxSpace.to_godot_size(Vector3i(x, y, z))
		"XYZI":
			var model := voxel.models.back()
			var num_voxels = _get_32()
			var buffer = _file.get_buffer(num_voxels * 4)
			for i in range(num_voxels):
				var offset = i * 4
				var pos := VoxSpace.to_godot_pos(Vector3i(
						buffer[offset], buffer[offset + 1], buffer[offset + 2]))
				# colorIndex 与 QVX 的材质 ID 同基（都 1 起、0 = 透明/空气），故零偏移。
				model.voxels[pos] = buffer[offset + 3]
		"RGBA":
			# 官方映射：文件项 0..254 → 调色板 1..255（调色板 0 恒为透明，不读）。
			var buffer = _file.get_buffer((VoxSpace.PALETTE_SLOTS - 1) * 4)
			for i in range(VoxSpace.PALETTE_SLOTS - 1):
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
					frame.position = VoxSpace.to_godot_vec3(Vector3(position[0], position[1], position[2]))
				if frame_attributes.has('_r'):
					frame.rotation = VoxSpace.decode_rotation(int(frame_attributes['_r']))
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
			if material_id >= 1 and material_id < QVoxelSpec.MATERIAL_COUNT:
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
			var attrs := _get_dictionary()
			layer.isVisible = attrs.get('_hidden', '0') != '1'
			layer.name = attrs.get('_name', '')
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

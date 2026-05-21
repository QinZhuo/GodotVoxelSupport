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
	prints("open .vox time:", (Time.get_ticks_usec() - time) / 1000.0, "ms")
	file.close()
	return vox

static var rot_cache: Array
static func decode_rotation(byte_value: int) -> Basis:
	if rot_cache[byte_value] != null:
		return rot_cache[byte_value]
	
	var row0_index = byte_value & 3
	var row1_index = (byte_value >> 2) & 3
	var row2_index = 3 - row0_index - row1_index
	
	var sign0 = 1 if ((byte_value >> 4) & 1) == 0 else -1
	var sign1 = 1 if ((byte_value >> 5) & 1) == 0 else -1
	var sign2 = 1 if ((byte_value >> 6) & 1) == 0 else -1
	
	var cols = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
	cols[row0_index].x = sign0
	cols[row1_index].y = sign1
	cols[row2_index].z = sign2
	
	var col0 = cols[0]
	var col1 = cols[1]
	var col2 = cols[2]
	
	var godot_col0 = Vector3(col0.x, col0.z, -col0.y)
	var godot_col1 = Vector3(col2.x, col2.z, -col2.y)
	var godot_col2 = Vector3(-col1.x, -col1.z, col1.y)
	var rotation := Basis(godot_col0, godot_col1, godot_col2)
	rot_cache[byte_value] = rotation
	return rotation

func _init(file: FileAccess):
	if not rot_cache.size():
		rot_cache.resize(256)
	_file = file
	voxel = VoxelData.new()
	voxel.materials.resize(256)
	for i in voxel.materials.size():
		voxel.materials[i] = VoxelData.VoxelMaterial.new()
	while file.get_position() < file.get_length():
		read_chunk()
	voxel.check_nodes()

var voxel: VoxelData
var _file: FileAccess

func read_chunk():
	var id := _get_string(4)
	var size := _get_32()
	var chunks := _get_32()
	var end := _file.get_position() + size
	match id:
		"SIZE":
			var model := VoxelData.VoxelModel.new()
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
					frame.rotation = decode_rotation(int(frame_attributes['_r']))
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
			if material_id < 256:
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
						material.trans = float(attributes.get("_trans", 1))
						material.rough = float(attributes.get("_rough", 0))
					"_blend":
						material.metal = float(attributes.get("_metal", 0))
						material.rough = float(attributes.get("_rough", 0))
						material.trans = float(attributes.get("_trans", 1))
					_:
						material.metal = 0
						material.rough = 1
		"LAYR":
			var layer := VoxelData.VoxelLayer.new()
			layer.id = _get_32()
			layer.isVisible = _get_dictionary().get('_hidden', '0') != '1'
			voxel.layers[layer.id] = layer

		_:
			pass

	_file.seek(end)
	
func _get_32() -> int:
	return _file.get_32()

func _get_string(length) -> String:
	return _file.get_buffer(length).get_string_from_ascii()

func _get_dictionary() -> Dictionary[String, String]:
	var dictionary: Dictionary[String, String]
	for _p in range(_get_32()):
		var key = _get_string(_get_32())
		dictionary[key] = _get_string(_get_32())
	return dictionary

func _get_node() -> VoxelData.VoxelNode:
	var node := VoxelData.VoxelNode.new()
	node.id = _get_32()
	var attributes := _get_dictionary()
	if attributes.has("_name"):
		node.name = attributes.get("_name")
	voxel.nodes[node.id] = node
	return node

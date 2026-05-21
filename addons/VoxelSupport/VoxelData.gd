class_name VoxelData

var models: Array[VoxelModel]

var materials: Array[VoxelMaterial]

var nodes: Dictionary[int, VoxelNode]

var layers: Dictionary[int, VoxelLayer]

func get_voxels(frame_index: int = 0) -> Dictionary[Vector3i, int]:
	if nodes.size() > 0:
		return nodes[0].get_voxels(self, frame_index)
	return {}

func get_mesh(frame_index: int = 0) -> ArrayMesh:
	if nodes.size() > 0:
		return nodes[0].get_mesh(self, frame_index)
	return null

func check_nodes():
	if nodes.size() == 0 and models.size() > 0:
		var node := VoxelNode.new()
		nodes[0] = node
		for i in models.size():
			var frame := VoxelFrame.new()
			frame.model_id = 0
			node.frames[i] = frame
			return nodes


func _to_string() -> String:
	return str("nodes:", nodes, "models:", models)

static func get_offset_voxels(voxels: Dictionary[Vector3i, int], offset: Vector3i):
	var result: Dictionary[Vector3i, int]
	for pos in voxels:
		result[pos + offset] = voxels[pos]
	return result

class VoxelModel:
	var size: Vector3:
		set(value):
			size = value
			offset = - (size / 2).floor()
			offset.z *= -1

	var offset: Vector3

	var voxels: Dictionary[Vector3i, int]

	var mesh: ArrayMesh

	func _to_string() -> String:
		return str(voxels.size(), ' ', size)

	func get_voxels():
		return VoxelData.get_offset_voxels(voxels, offset)

class VoxelMaterial:
	var id: int

	var color: Color

	var is_transparent: bool:
		get(): return trans > 0

	var trans: float = 0

	var metal: float = 0

	var rough: float = 1

	var emission: float = 0


class VoxelNode:
	var id: int

	var name: String

	var layerId := -1

	var child_nodes: Array[int]

	var frames: Dictionary[int, VoxelFrame]

	var models: Array[Array]

	func get_name(voxel: VoxelData, frame_index: int = 0, is_root: bool = true) -> String:
		if name:
			return name
		for i in child_nodes:
			var child_name := voxel.nodes[i].get_name(voxel, frame_index, false)
			if child_name:
				return child_name
		if is_root:
			return str("node_", id)
		else:
			return name

	func get_frame(index: int, merge: bool = false) -> VoxelFrame:
		if merge:
			if index == 0 and frames.size() > 0:
				return frames[0]
			var frame := VoxelFrame.new()
			for i in index + 1:
				if not frames.has(i):
					continue
				frame.merge_frame(frames[i])
			return frame
		else:
			if not frames.has(index):
				frames[index] = VoxelFrame.new()
			return frames[index]

	func get_models(voxel: VoxelData, frame_index: int, ignore_trans: bool = false) -> Array:
		if layerId in voxel.layers and not voxel.layers[layerId].isVisible:
			return models
		models.clear()
		if child_nodes.size() > 0:
			var tasks := []
			for i in child_nodes:
				tasks.append(WorkerThreadPool.add_task(voxel.nodes[i].get_models.bind(voxel, frame_index)))
			for task in tasks:
				WorkerThreadPool.wait_for_task_completion(task)
			for i in child_nodes:
				models.append_array(voxel.nodes[i].models)
		get_frame(frame_index, true).merge_models(voxel, models, ignore_trans)
		return models

	const MaxSurface = 2
	func get_mesh(voxel: VoxelData, frame_index: int) -> ArrayMesh:
		var result_mesh = ArrayMesh.new()
		var surface := SurfaceTool.new()
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		var models := get_models(voxel, frame_index)
		for face in MaxSurface:
			for i in models.size():
				var mesh: ArrayMesh = models[i][0].mesh
				if mesh.get_surface_count() <= face:
					break
				var transform: Transform3D = models[i][1]
				surface.append_from(mesh, face, transform)
			surface.commit(result_mesh)
			surface.clear()
		return result_mesh


	func get_voxels(voxel: VoxelData, frame_index: int, center: bool = false) -> Dictionary[Vector3i, int]:
		var voxels: Dictionary[Vector3i, int]
		var models := get_models(voxel, frame_index, center)
		var half_step = Vector3(0.5, 0.5, 0.5);
		for i in models.size():
			var model: VoxelModel = models[i][0]
			var transform: Transform3D = models[i][1]
			for pos in model.voxels:
				var new_pos := transform * Vector3(pos)
				voxels[Vector3i(new_pos)] = model.voxels[pos]
		return voxels

	func _to_string() -> String:
		return str('[', name, '] childs: ', child_nodes)

class VoxelFrame:
	var model_id := -1

	var position = null

	var rotation = null

	var transform: Transform3D:
		get(): return Transform3D(rotation if rotation else Quaternion.IDENTITY,
			position if position else Vector3.ZERO)

	func merge_models(voxel: VoxelData, models: Array[Array], ignore_trans: bool):
		if model_id >= 0:
			var model := voxel.models[model_id]
			models.append([model, Transform3D.IDENTITY.translated(model.offset)])
		if ignore_trans:
			return
		if rotation or position:
			for i in models.size():
				var model_transform: Transform3D = models[i][1]
				models[i][1] = transform * model_transform

	func merge_frame(other: VoxelFrame):
		if other.position:
			position = other.position
		if other.rotation:
			rotation = other.rotation
		if other.model_id >= 0:
			model_id = other.model_id


	func _to_string() -> String:
		return str(' model_id: ', model_id, ' position: ', position, ' rotation: ', rotation)

class VoxelLayer:
	var id: int;

	var isVisible: bool;

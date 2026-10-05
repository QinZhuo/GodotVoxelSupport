class_name VoxData

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

func check_nodes() -> Dictionary:
	# 当 .vox 无场景图(scene graph)时，为每个 model 建一个帧节点，确保能取到体素
	if nodes.size() == 0 and models.size() > 0:
		var node := VoxelNode.new()
		nodes[0] = node
		for i in models.size():
			var frame := VoxelFrame.new()
			frame.model_id = i
			node.frames[i] = frame
	return nodes


func _to_string() -> String:
	return str("nodes:", nodes, "models:", models)

static func get_offset_voxels(voxels: Dictionary[Vector3i, int], offset: Vector3i):
	var result: Dictionary[Vector3i, int]
	for pos in voxels:
		result[pos + offset] = voxels[pos]
	return result


# ----------------------------------------------------------------------------
# 从体素资产文件加载 —— .vox / .qvox 共用入口
# ----------------------------------------------------------------------------
# 本插件把两者都视为**模型资产**（同等地位），导入管线不该关心源格式。
# "扩展名 → 解析器"的分派因此收敛到这一处：
#   .vox  → VoxAccess（MagicaVoxel，外部格式）
#   .qvox → _from_qvox （QVox，本插件的一等容器格式）
# 新增格式只需在此加一行，4 个 EditorImportPlugin 无需改动。

## 导入管线支持的扩展名。各导入器统一引用，避免同一事实在多处重复。
const SUPPORTED_EXTENSIONS := ["vox", "qvox"]


## 导入面板选项名的单一出处：mesh/frame_index、mesh/scale 同时被 Mesh 与 Data 两个
## 导入器使用（VoxelMeshImporter / VoxelDataImporter），值必须与既有 .import 文件完全一致。
const OPT_FRAME_INDEX := "mesh/frame_index"
const OPT_SCALE := "mesh/scale"


## 按扩展名把资产文件解析为 VoxData；不支持的格式或解析失败返回 null。
static func from_asset(path: String) -> VoxData:
	if path.get_extension().to_lower() == "qvox":
		return _from_qvox(path)
	var access := VoxAccess.Open(path)
	return access.voxel if access != null else null


## .qvox → VoxData。
##
## 映射约定：
##   · 每个 VOX0 的 model_id → 一个 VoxelModel，体素存**绝对体素坐标**（offset = ZERO）。
##     QVox 的"块坐标 × block_size"本身就是世界体素坐标，不需要 .vox 那套
##     "按 size 居中 + Z 翻转"的 offset 约定。
##   · MATE → VoxelMaterial，**数组索引 == 材质ID**（索引 0 恒为空气占位），
##     与全项目统一材质契约一致。
##   · NODE 不参与转换：QVox 场景图（下标寻址 + model 引用）与 VoxData 的 node/frame
##     并非一一对应。导入时统一"每个 model 一个 frame"（等价 check_nodes() 的行为）。
##     需要完整场景图语义时，请直接使用 QVoxFile.parse() 得到的 doc.scene。
static func _from_qvox(path: String) -> VoxData:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[VoxData] 无法读取 %s" % path)
		return null
	var bytes := f.get_buffer(f.get_length())
	f.close()

	var rep := QVoxFile.QVoxReport.new()
	var doc: QVoxFile.QVoxDocument = QVoxFile.parse(bytes, true, rep, true)
	if doc == null:
		push_error("[VoxData] %s 解析失败：%s" % [path, rep.summary()])
		return null
	for w in rep.warnings:
		push_warning("[VoxData] %s: %s" % [path.get_file(), w])

	var out := VoxData.new()
	_qvox_fill_materials(doc, out)
	_qvox_fill_models(doc, out)
	out.check_nodes()
	return out


## MATE 条目 → VoxelMaterial（索引 == 材质ID）。
static func _qvox_fill_materials(doc: QVoxFile.QVoxDocument, out: VoxData) -> void:
	if doc.materials.is_empty():
		return
	out.materials.resize(doc.materials.size())
	for i in doc.materials.size():
		var e: Dictionary = doc.materials[i]
		var rgba := int(e.get("rgba", 0)) & 0xFFFFFFFF
		var a := float(rgba & 0xFF) / 255.0
		var m := VoxelMaterial.new()
		m.id = i
		m.color = Color(float((rgba >> 24) & 0xFF) / 255.0,
				float((rgba >> 16) & 0xFF) / 255.0,
				float((rgba >> 8) & 0xFF) / 255.0, a)
		m.trans = clampf(1.0 - a, 0.0, 1.0)
		m.metal = float(int(e.get("metal", 0))) / 255.0
		m.rough = float(int(e.get("rough", 0))) / 255.0
		m.hardness = float(int(e.get("hardness", 1)))
		m.mass = float(int(e.get("mass", 1)))
		# QVox 自发光是 RGB 三通道；VoxelMaterial 只有单通道强度，取三通道最大值近似。
		var er := float(int(e.get("e_r", 0))) / 255.0
		var eg := float(int(e.get("e_g", 0))) / 255.0
		var eb := float(int(e.get("e_b", 0))) / 255.0
		m.emission = maxf(er, maxf(eg, eb))
		out.materials[i] = m


## VOX0 块数组 → VoxelModel（绝对体素坐标）。
static func _qvox_fill_models(doc: QVoxFile.QVoxDocument, out: VoxData) -> void:
	var b := doc.get_block_size()
	if b <= 0:
		return
	var ids := doc.models.keys()
	ids.sort()
	for mid in ids:
		var blocks: Variant = doc.models[mid]
		if not (blocks is Dictionary) or (blocks as Dictionary).is_empty():
			continue
		var model := VoxelModel.new()
		model.offset = Vector3.ZERO
		var voxels: Dictionary[Vector3i, int] = {}
		for k in (blocks as Dictionary):
			var key: Vector3i = k
			var buf: PackedInt32Array = blocks[key]
			for idx in buf.size():
				var v := buf[idx]
				if v == 0:
					continue
				# 块内线性下标 → 局部坐标（与 QVoxSpec 一致：idx = x + y·B + z·B²）
				var lx := idx % b
				var ly := (idx / b) % b
				var lz := idx / (b * b)
				voxels[Vector3i(key.x * b + lx, key.y * b + ly, key.z * b + lz)] = v
		if voxels.is_empty():
			continue
		model.voxels = voxels
		out.models.append(model)


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
		return VoxData.get_offset_voxels(voxels, offset)


class VoxelNode:
	var id: int

	var name: String

	var layerId := -1

	var child_nodes: Array[int]

	var frames: Dictionary[int, VoxelFrame]

	var models: Array[Array]

	func get_name(voxel: VoxData, frame_index: int = 0, is_root: bool = true) -> String:
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

	func get_models(voxel: VoxData, frame_index: int, ignore_trans: bool = false) -> Array:
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
	func get_mesh(voxel: VoxData, frame_index: int) -> ArrayMesh:
		var result_mesh = ArrayMesh.new()
		var surface := SurfaceTool.new()
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		var models := get_models(voxel, frame_index)
		for face in MaxSurface:
			for i in models.size():
				var mesh: ArrayMesh = models[i][0].mesh
				if mesh.get_surface_count() <= face:
					continue
				var transform: Transform3D = models[i][1]
				surface.append_from(mesh, face, transform)
			surface.commit(result_mesh)
			surface.clear()
		return result_mesh


	func get_voxels(voxel: VoxData, frame_index: int, center: bool = false) -> Dictionary[Vector3i, int]:
		var voxels: Dictionary[Vector3i, int]
		var models := get_models(voxel, frame_index, center)
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

	func merge_models(voxel: VoxData, models: Array[Array], ignore_trans: bool):
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

class_name VoxAsset
extends RefCounted

## MagicaVoxel（`.vox`）资产的宿主：模型 / 材质 / 场景图（nTRN·nGRP·nSHP·LAYR）/ 动画帧。

const SUPPORTED_EXTENSIONS := ["vox", "qvx"]

## `.vox` 的扩展名（本类实际处理的格式）。
const VOX_EXTENSION := "vox"

## 按扩展名把资产文件解析为 VoxAsset；不支持的格式或解析失败返回 null。
static func from_asset(path: String) -> VoxAsset:
	if QVoxelAsset.handles(path):
		# 传错适配器是调用方输入问题（预期路径，返回 null），不是程序错 —— 见 QVoxelFile._flush_fatal 的判据。
		push_warning("[VoxAsset] %s 是 .qvx：请改用 QVoxelAsset.from_file()。"
				% path + "（VoxAsset 是 MagicaVoxel 专用适配器，硬塞会丢 NODE 与多模型信息）")
		return null
	var access := VoxAccess.Open(path)
	return access.voxel if access != null else null

# 内存结构（`.vox` 资产的字段）

var models: Array[VoxelModel]

var materials: Array[VoxelMaterial]

var nodes: Dictionary[int, VoxelNode]

var layers: Dictionary[int, VoxelLayer]

## 整个资产在第 frame_index 帧的体素（世界坐标）。
func get_voxels(frame_index: int = 0) -> Dictionary[Vector3i, int]:
	var ids: Array = [0] if (nodes.has(0) and nodes[0] != null) else top_node_ids()
	var out: Dictionary[Vector3i, int]
	for id in ids:
		var node: VoxelNode = nodes.get(id)
		if node != null:
			out.merge(node.get_voxels(self, frame_index))
	return out

## `[模型, 变换]` 列表 → 世界体素字典。
static func models_to_voxels(models: Array) -> Dictionary[Vector3i, int]:
	var voxels: Dictionary[Vector3i, int]
	for i in models.size():
		var model: VoxelModel = models[i][0]
		var transform: Transform3D = models[i][1]
		for pos in model.voxels:
			voxels[Vector3i((transform * Vector3(pos)).round())] = model.voxels[pos]
	return voxels

## 全局帧数 = 所有节点关键帧的最大帧号 + 1（至少 1）。
func frame_count() -> int:
	var n := 1
	for id in nodes:
		var node: VoxelNode = nodes[id]
		if node == null:
			continue
		for k in node.frames:
			n = maxi(n, int(k) + 1)
	return n

## 场景图里的"顶级对象"：折叠根部的结构壳样板链（MagicaVoxel 的 nTRN(0) → nGRP(1) → …）。
func top_node_ids() -> Array:
	if not nodes.has(0) or nodes[0] == null:
		# 没有 0 号根（手工拼装 / 畸形文件）：把"没有父节点的节点"当顶层，绝不再返回空 ——
		return _roots_without_parent()
	var id := 0
	var guard := 0
	while guard < 64 and is_structural_node(id) and nodes[id].child_nodes.size() == 1:
		id = int(nodes[id].child_nodes[0])
		guard += 1
	if is_structural_node(id):
		return Array(nodes[id].child_nodes)
	return [id]

func _roots_without_parent() -> Array:
	var has_parent := {}
	for id in nodes:
		var n: VoxelNode = nodes[id]
		if n == null:
			continue
		for c in n.child_nodes:
			has_parent[int(c)] = true
	var out: Array = []
	for id in nodes:
		if nodes[id] != null and not has_parent.has(int(id)):
			out.append(int(id))
	return out

## 结构壳 = 无名字、不属任何图层、无模型帧、但有子节点（纯结构的 nTRN / nGRP）。
func is_structural_node(id: int) -> bool:
	if not nodes.has(id) or nodes[id] == null:
		return false
	var n: VoxelNode = nodes[id]
	if not n.name.is_empty() or layers.has(n.layerId) or n.child_nodes.is_empty():
		return false
	return not has_model(n)

## 该节点在**任意帧**是否引用了有效模型。
func has_model(n: VoxelNode) -> bool:
	for k in n.frames:
		var f: VoxelFrame = n.frames[k]
		if f != null and f.model_id >= 0 and f.model_id < models.size():
			return true
	return false

func check_nodes() -> Dictionary:
	# 当 .vox 无场景图(scene graph)时，为每个 model 建一个**独立子节点**（根是结构壳）。
	if nodes.is_empty() and models.size() > 0:
		var root := VoxelNode.new()
		root.id = 0
		nodes[0] = root
		for i in models.size():
			var child := VoxelNode.new()
			child.id = i + 1
			var frame := VoxelFrame.new()
			frame.model_id = i
			child.frames[0] = frame
			nodes[child.id] = child
			root.child_nodes.append(child.id)
	return nodes

func _to_string() -> String:
	return str("nodes:", nodes, "models:", models)

static func get_offset_voxels(voxels: Dictionary[Vector3i, int], offset: Vector3i):
	var result: Dictionary[Vector3i, int]
	for pos in voxels:
		result[pos + offset] = voxels[pos]
	return result

# 导入面板的选项名已集中到 `VoxelImportOptions`（单一出处，含 mesh/frame_index、mesh/scale…

class VoxelModel:
	var size: Vector3:
		set(value):
			size = value
			offset = - (size / 2).floor()
			offset.z *= -1

	var offset: Vector3

	var voxels: Dictionary[Vector3i, int]

	func _to_string() -> String:
		return str(voxels.size(), ' ', size)

	func get_voxels():
		return VoxAsset.get_offset_voxels(voxels, offset)

class VoxelNode:
	var id: int

	var name: String

	var layerId := -1

	## 节点级可见性（`nTRN` 的 `_hidden`）。
	var hidden := false

	var child_nodes: Array[int]

	var frames: Dictionary[int, VoxelFrame]

	var models: Array[Array]

	## 节点显示名：自身名字优先，否则借第一个有名字的子孙（MagicaVoxel 的组名常记在子孙上）。
	func get_name(voxel: VoxAsset, _frame_index: int = 0, visited: Dictionary = {}) -> String:
		if not name.is_empty():
			return name
		if visited.has(id):
			return ""
		visited[id] = true
		for i in child_nodes:
			var child: VoxelNode = voxel.nodes.get(i)
			if child == null:
				continue
			var child_name := child.get_name(voxel, 0, visited)
			if not child_name.is_empty():
				return child_name
		return "node_%d" % id

	func get_frame(index: int, merge: bool = false) -> VoxelFrame:
		if not merge:
			if not frames.has(index):
				frames[index] = VoxelFrame.new()
			return frames[index]
		# 回溯语义：取 ≤index 的关键帧依次合成（关键帧只标"从这一帧起生效"，中间帧沿用）。
		var frame := VoxelFrame.new()
		for i in index + 1:
			if frames.has(i) and frames[i] != null:
				frame.merge_frame(frames[i])
		return frame

	## 递归收集本节点子树的 [模型, 变换] 列表（结果缓存在本节点的 models 字段）。
	func get_models(voxel: VoxAsset, frame_index: int, local: bool = false,
			path: Dictionary = {}) -> Array:
		if path.has(id):
			return []
		path[id] = true
		# 隐藏（节点级 `_hidden` 或所属图层不可见）时整棵子树不参与，返回**空数组**而不是
		if hidden or (layerId in voxel.layers and not voxel.layers[layerId].isVisible):
			models.clear()
			path.erase(id)
			return []
		models.clear()
		for i in child_nodes:
			var child: VoxelNode = voxel.nodes.get(i)
			if child != null:
				models.append_array(child.get_models(voxel, frame_index, false, path))
		get_frame(frame_index, true).merge_models(voxel, models, local)
		path.erase(id)
		return models

	func get_voxels(voxel: VoxAsset, frame_index: int, local: bool = false) -> Dictionary[Vector3i, int]:
		return VoxAsset.models_to_voxels(get_models(voxel, frame_index, local))

	func _to_string() -> String:
		return str('[', name, '] childs: ', child_nodes)

class VoxelFrame:
	var model_id := -1

	var position = null

	var rotation = null

	var transform: Transform3D:
		get(): return Transform3D(rotation if rotation else Quaternion.IDENTITY,
			position if position else Vector3.ZERO)

	## 把本帧（自身模型的居中偏移 + 本节点变换）合进 models 列表。
	func merge_models(voxel: VoxAsset, models: Array[Array], local: bool):
		# 越界检查：畸形文件的 nSHP 可以指向不存在的 model_id，不挡就是整条导入链路崩溃。
		if model_id >= 0 and model_id < voxel.models.size():
			var model := voxel.models[model_id]
			models.append([model, Transform3D.IDENTITY.translated(model.offset)])
		if local:
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

## `.vox` 的 LAYR：只承载"图层可见性 + 图层名"这两项**外部文件**信息。
class VoxelLayer:
	var id: int;

	var isVisible: bool;

	## 图层名（LAYR 的 `_name`）。
	var name: String = ""

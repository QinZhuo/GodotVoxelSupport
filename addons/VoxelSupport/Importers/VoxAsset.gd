class_name VoxAsset
extends RefCounted

## MagicaVoxel（`.vox`）资产的宿主：模型 / 材质 / 场景图（nTRN·nGRP·nSHP·LAYR）/ 动画帧。
##
## 【只服务 `.vox`】`.qvox` 的对应概念形状不同（一个 `model_id` 一个 `VOX0` + `NODE` 定位，
## 没有 `nSHP`/frame/`Z` 翻转那套约定），由 `QVoxAsset` 承载。把 `.qvox` 塞进本类会丢
## NODE 与多模型信息（详见 QVoxAsset 类注释），故 `from_asset()` 遇到 `.qvox` 会直接报错。

const SUPPORTED_EXTENSIONS := ["vox", "qvox"]

## `.vox` 的扩展名（本类实际处理的格式）。`SUPPORTED_EXTENSIONS` 是两个格式的合集，
## 供四个导入器统一声明"识别哪些扩展名"。
const VOX_EXTENSION := "vox"


## 按扩展名把资产文件解析为 VoxAsset；不支持的格式或解析失败返回 null。
static func from_asset(path: String) -> VoxAsset:
	if QVoxAsset.handles(path):
		push_error("[VoxAsset] %s 是 .qvox：请改用 QVoxAsset.from_file()。"
				% path + "（VoxAsset 是 MagicaVoxel 专用适配器，硬塞会丢 NODE 与多模型信息）")
		return null
	var access := VoxAccess.Open(path)
	return access.voxel if access != null else null


var models: Array[VoxelModel]

var materials: Array[VoxelMaterial]

var nodes: Dictionary[int, VoxelNode]

var layers: Dictionary[int, VoxelLayer]

func get_voxels(frame_index: int = 0) -> Dictionary[Vector3i, int]:
	if nodes.size() > 0:
		return nodes[0].get_voxels(self, frame_index)
	return {}


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


## 导入面板选项名的单一出处：mesh/frame_index、mesh/scale 同时被 Mesh 与 Data 两个
## 导入器使用（VoxelMeshImporter / VoxelDataImporter），值必须与既有 .import 文件完全一致。
const OPT_FRAME_INDEX := "mesh/frame_index"
const OPT_SCALE := "mesh/scale"

## 资产原点模式（取值见 VoxelData.OriginMode）。
## 【为什么两个导入器必须同名同义】同一个模型经 "导入成 mesh" 与 "导入成 data" 两条路进场景，
## 原点若各按各的习惯摆，位置就会差一截（本仓库实测差 0.35~0.50）；共用一个选项名与一套
## 语义，是"两条路结果一致"在选项层的表达。
const OPT_ORIGIN := "mesh/origin"


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

	var child_nodes: Array[int]

	var frames: Dictionary[int, VoxelFrame]

	var models: Array[Array]

	func get_name(voxel: VoxAsset, frame_index: int = 0, is_root: bool = true) -> String:
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

	## 递归收集本节点子树的 [模型, 变换] 列表（结果缓存在本节点的 models 字段）。
	## 直接递归：子节点的 models 字段本身就是缓存，交给线程池再立刻 wait 只会让
	## 父任务占着线程等子任务（层级深时可能饿死线程池），且任务返回值本身也取不到。
	func get_models(voxel: VoxAsset, frame_index: int, ignore_trans: bool = false) -> Array:
		if layerId in voxel.layers and not voxel.layers[layerId].isVisible:
			return models
		models.clear()
		for i in child_nodes:
			models.append_array(voxel.nodes[i].get_models(voxel, frame_index))
		get_frame(frame_index, true).merge_models(voxel, models, ignore_trans)
		return models

	func get_voxels(voxel: VoxAsset, frame_index: int, center: bool = false) -> Dictionary[Vector3i, int]:
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

	func merge_models(voxel: VoxAsset, models: Array[Array], ignore_trans: bool):
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

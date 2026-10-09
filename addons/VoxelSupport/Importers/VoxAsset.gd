class_name VoxAsset
extends RefCounted

## MagicaVoxel（`.vox`）资产的宿主：模型 / 材质 / 场景图（nTRN·nGRP·nSHP·LAYR）/ 动画帧。
##
## 【只服务 `.vox`】`.qvx` 的对应概念形状不同（一个 `model_id` 一个 `VXEL` + `NODE` 定位，
## 没有 `nSHP`/frame/`Z` 翻转那套约定），由 `QVoxelAsset` 承载。把 `.qvx` 塞进本类会丢
## NODE 与多模型信息（详见 QVoxelAsset 类注释），故 `from_asset()` 遇到 `.qvx` 会直接报错。

const SUPPORTED_EXTENSIONS := ["vox", "qvx"]

## `.vox` 的扩展名（本类实际处理的格式）。`SUPPORTED_EXTENSIONS` 是两个格式的合集，
## 供四个导入器统一声明"识别哪些扩展名"。
const VOX_EXTENSION := "vox"


## 按扩展名把资产文件解析为 VoxAsset；不支持的格式或解析失败返回 null。
static func from_asset(path: String) -> VoxAsset:
	if QVoxelAsset.handles(path):
		push_error("[VoxAsset] %s 是 .qvx：请改用 QVoxelAsset.from_file()。"
				% path + "（VoxAsset 是 MagicaVoxel 专用适配器，硬塞会丢 NODE 与多模型信息）")
		return null
	var access := VoxAccess.Open(path)
	return access.voxel if access != null else null


## 世界 → `.vox` 资产（"走出去"的出口，与 from_asset 恰成一对进出）。
##
## 【为什么整世界合成**一个**模型，而不是"每模型一个 nSHP + 场景图摆放"】
## QVoxelier 的树是**编辑期**的层级，MagicaVoxel 的多模型场景图是另一套东西：它要求每个模型
## 自带摆放，而摆放必须抵消 VoxelModel.offset 那套"按尺寸居中"的约定（见 QVoxelAsset 类注释
## 列出的三处失真）。硬凑出来的结果是"在 MagicaVoxel 里看着对、回到本项目就错位"这类只在
## 跨工具时才暴露的问题。而用户要的其实是一块**能拿去用的体素** —— 那就直接用框架里已有的
## 世界级求值（evaluate_world 已把各顶层节点按 origin 合成进一个紧致盒），导出的语义与画面上
## 看到的一致，且"世界怎么合成"这件事全项目仍然只有一份实现。
##
## 【多模型的结构去哪了】并入这一块体积，不保留。`.vox` 里想表达"多个对象"要靠场景图，
## 而那是另一条语义路径（需 QVoxelier 侧先有"每个模型独立摆放"的概念，当前没有）。
static func from_world(world: QVoxelWorld, ctx: QVoxelEvalContext = null) -> VoxAsset:
	var out := VoxAsset.new()
	# 索引 0 恒为 null 空气占位；1..255 预建并设好 id —— 与 VoxAccess._init 同一套约定，
	# 这样写出的 RGBA 块与读入的资产在"下标 == 材质ID"上完全对齐。
	out.materials.resize(256)
	for i in range(1, 256):
		var mat := VoxelMaterial.new()
		mat.id = i
		out.materials[i] = mat
	if world == null:
		return out
	for i in range(1, mini(256, world.materials.size())):
		out.materials[i].color = world.material_color(i)

	var res := QVoxelEvalEngine.evaluate_world(world,
			ctx if ctx != null else QVoxelEvalContext.new())
	var size := res.grid_size
	if res.volume.is_empty() or size.x <= 0 or size.y <= 0 or size.z <= 0:
		return out  # 世界为空（或全被差集挖空）：给一份"只有调色板"的资产，不造 0 尺寸模型

	var model := VoxelModel.new()
	model.size = Vector3(size)
	# 【为什么 Z 要平移 size.z - 1】原始坐标（.vox 的体素坐标经 `(x,y,z)→(x,z,-y)` 旋转后的样子）
	# 其 Z 轴落在 (-size.z, 0]，而世界盒的 z 在 [0, size.z)。平移后既落回合法区间、又**不镜像**
	# —— 若写成更"对称"的 -z，导出的模型会沿 Z 前后翻转（在 MagicaVoxel 里一眼看不出，
	# 因为对称的模型翻转后长得一样）。
	var z_shift := size.z - 1
	for i in res.volume.size():
		var material: int = res.volume[i]
		if material == 0:
			continue
		var p := PcgModel.pos_of(i, size)
		model.voxels[Vector3i(p.x, p.y, p.z - z_shift)] = material
	out.models.append(model)
	return out


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

## 资产原点模式（取值见 QVoxelSource.OriginMode）。
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
			# ignore_trans 必须继续往下传：漏传会让子树永远按 ignore_trans=false 展开，
			# 于是"忽略透明体素"这个选项只在当前层生效（层级一深就失效）。
			models.append_array(voxel.nodes[i].get_models(voxel, frame_index, ignore_trans))
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

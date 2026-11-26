@tool
class_name QVoxelSnapshot
extends RefCounted
## 快照（PNG 预览图）：参数组、取景盒与命名这一段**纯逻辑**。

## 尺寸档（像素，边长）。
const SIZES := [
	{"value": 512, "text": "512", "tip": "渲染成 512×512（快，适合当图标 / 缩略图）"},
	{"value": 1024, "text": "1K", "tip": "渲染成 1024×1024（默认档）"},
	{"value": 2048, "text": "2K", "tip": "渲染成 2048×2048（慢，适合当贴图 / 成品图）"},
]

## 默认尺寸。
const DEFAULT_SIZE := 1024

## 视图选项表：`[{value, text, tip}]`，顺序 = QVoxelViewCamera 角度表的顺序。
static func views() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for v in QVoxelViewCamera.VIEW_ANGLES_DEG:
		var name: String = QVoxelViewCamera.VIEW_NAMES[v]
		out.append({
			"value": v,
			"text": name,
			"tip": "以「%s」视图渲染（与视口同名按钮同一个角度）" % name,
		})
	return out

## 尺寸选项表，结构同 views()。
static func sizes() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for spec in SIZES:
		out.append(spec)
	return out

## 镜头选项表，结构同 views()。
static func lenses() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for l in QVoxelViewCamera.LENS_NAMES:
		var name: String = QVoxelViewCamera.LENS_NAMES[l]
		out.append({
			"value": l,
			"text": name,
			"tip": "%s投影（与视口的镜头开关同一套）" % name,
		})
	return out

## 取景盒：把求值结果的体素范围翻成世界坐标下的 AABB。
static func frame_aabb(res: QVoxelEvalResult, voxel_scale: float) -> AABB:
	if res == null or res.volume.is_empty():
		return AABB()
	return AABB(Vector3(res.origin) * voxel_scale, Vector3(res.grid_size) * voxel_scale)

## 文件名主干（不含扩展名）：`<世界名>_<视图名>`。
static func file_stem(world_name: String, view: int) -> String:
	var view_text: String = QVoxelViewCamera.VIEW_NAMES.get(view, "")
	var stem := world_name
	if not view_text.is_empty():
		stem = "%s_%s" % [world_name, view_text]
	# 消毒规则全项目一份（见 QVoxelNaming）：两个导出出口各写一份迟早分叉。
	return QVoxelNaming.safe_stem(stem)

## 该不该渲染：返回空串 = 可以，否则返回**给用户看的原因**。
static func blocker(world: QVoxelWorld) -> String:
	if world == null:
		return "还没有世界，先新建或载入一个"
	if world.all_models().is_empty():
		return "世界里还没有模型"
	return ""

## 预览图的一句话描述（状态行用）。
static func describe(size: int, view: int, lens: int) -> String:
	return "%d×%d · %s · %s" % [
		size, size,
		QVoxelViewCamera.VIEW_NAMES.get(view, "?"),
		QVoxelViewCamera.LENS_NAMES.get(lens, "?"),
	]

## 落盘后的一句话（应用层出用户文案）。
static func summary(path: String, size: int) -> String:
	return "已渲染 %d×%d → %s" % [size, size, path]

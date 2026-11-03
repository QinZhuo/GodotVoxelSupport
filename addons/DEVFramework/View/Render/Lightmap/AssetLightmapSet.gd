## 一个烘焙舞台产出的光照数据：图集引用 + 位置表，一个场景一份。
##
## 图集 —— [member data] 直接引用 LightmapGI 的烘焙数据，不复制贴图；
## 位置 —— 键是资源文件名，[method region_of] 靠 mesh 自己反查。
##
## 类比 LightmapGI 的 .lmbake：跟着烘焙场景走、放在场景同目录。
@tool
class_name AssetLightmapSet extends Resource

## 当前生效的光照库：加载方 set 一次，任何地方都能靠 mesh 自己补光。
## 换库时回收上一套光照名下的材质副本，并让已在树上的实例按新库重挂
## （否则先入树的实例会一直停在旧库 / 「无烘焙数据」状态）
static var current: AssetLightmapSet:
	set(value):
		if current == value:
			return
		if current != null:
			current._release()
		current = value
		AssetLightmapBinder.refresh_all()

## 烘焙数据本体，图集纹理由它提供
@export var data: LightmapGIData

## 键（= 资源文件名）→ [AssetLightmapRegion]
@export var regions: Dictionary = {}

## 图集只取一次，不必每次采样都问一遍烘焙数据
var _atlas: TextureLayered

## 编辑器兜底扫描根目录（项目设置，默认 res://Scenes）
const SCAN_DIR_SETTING := "dev_framework/lightmap/scan_dir"

## 编辑器兜底只扫一次目录
static var _fallback_done := false

## 场景路径 → 整合文件路径：<场景目录>/<场景名>_lightmap_set.res
static func path_of(scene_path: String) -> String:
	return "" if scene_path.is_empty() else scene_path.get_basename() + "_lightmap_set.res"

## 按产物路径接管：烘焙场景与使用场景分开时用它。
## 产物存在就加载生效，不存在返回 null 且**不动** current
static func attach_path(path: String) -> AssetLightmapSet:
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	current = load(path) as AssetLightmapSet
	return current

## 按场景路径接管：产物跟着**烘焙场景**走（使用场景通常传烘焙场景的路径）
static func attach(scene_path: String) -> AssetLightmapSet:
	return attach_path(path_of(scene_path))

## 整张图集，全场景共用。取不到就说明烘焙数据缺失
func atlas() -> TextureLayered:
	if _atlas == null and data != null:
		var textures := data.get_lightmap_textures()
		if not textures.is_empty():
			_atlas = textures[0]
	return _atlas

func region(key: String) -> AssetLightmapRegion:
	return regions.get(key) as AssetLightmapRegion

## 资源 → 光照键：键就是文件名，烘焙侧与运行侧都走这一份规则。
## 运行时拼出来的网格没有路径，退回 resource_name
static func key_of(res: Resource) -> String:
	if res == null:
		return ""
	return res.resource_path.get_file().get_basename() if not res.resource_path.is_empty() else res.resource_name

## 按网格资源反查：调用方不必知道自己的键
func region_of(mesh: Mesh) -> AssetLightmapRegion:
	return region(key_of(mesh))

## 给实例挂光：任何拿到 MeshInstance3D 的地方都能调，重复调无副作用。
## 没有光照数据时顺手把之前挂的摘掉，免得实例跨场景复用时顶着旧光
func bind(mi: MeshInstance3D) -> bool:
	var light := region_of(mi.mesh)
	var texture := atlas()
	if light == null or not light.has_area() or texture == null:
		AssetLightmapBinder.clear(mi)
		return false
	return AssetLightmapBinder.apply(mi, light, texture)

## 走 [member current] 的便捷版：实例创建完补一次，不必持有库。
## 没有库时照样擦干净——池化实例可能是带着别的场景的光过来的
static func bind_to(mi: MeshInstance3D) -> bool:
	if current == null:
		current = _editor_fallback()
	if current == null:
		AssetLightmapBinder.clear(mi)
		return false
	return current.bind(mi)

## 让编辑器兜底重新扫一遍：烘焙舞台导出新产物后调用，否则本次编辑会一直用旧结论
static func invalidate() -> void:
	_fallback_done = false

## 编辑器里没有项目侧加载入口来设 current：扫一份烘焙产物直接用，调光时能立刻看到效果。
## 只在编辑器、且第一次需要时扫一次
static func _editor_fallback() -> AssetLightmapSet:
	if _fallback_done or not Engine.is_editor_hint():
		return null
	_fallback_done = true
	for path in _all_produced(str(ProjectSettings.get_setting(SCAN_DIR_SETTING, "res://Scenes"))):
		var res := load(path) as AssetLightmapSet
		if res != null:
			return res
	return null

## 换库时回收旧光照名下的材质副本。实例上已挂的宿主材质不受影响，
## 只是下次重新 bind 时会重新复制一份
func _release() -> void:
	for light in regions.values():
		AssetLightmapBinder.release(light as AssetLightmapRegion)

static func _all_produced(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	for file in dir.get_files():
		if file.ends_with("_lightmap_set.res"):
			out.append(dir_path.path_join(file))
	for sub in dir.get_directories():
		if not sub.begins_with("."):
			out.append_array(_all_produced(dir_path.path_join(sub)))
	return out

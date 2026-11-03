## 一个烘焙舞台产出的光照数据：图集引用 + 位置表，一个场景一份。
##
## 图集 —— [member data] 直接引用 LightmapGI 的烘焙数据，不复制贴图；
## 位置 —— 键是资源文件名，[method region_of] 靠 mesh 自己反查。
##
## 类比 LightmapGI 的 .lmbake：跟着烘焙场景走、放在场景同目录。
@tool
class_name AssetLightmapSet extends Resource

## 当前生效的光照库：加载方 set 一次，任何地方都能靠 mesh 自己补光。
## 换库时顺手回收上一套光照名下的材质副本，缓存才不会一路堆到进程结束
static var current: AssetLightmapSet:
	set(value):
		if current != null and current != value:
			current._release()
		current = value

## 烘焙数据本体，图集纹理由它提供
@export var data: LightmapGIData

## 键（= 资源文件名）→ [AssetLightmapRegion]
@export var regions: Dictionary = {}

## 图集只取一次，不必每次采样都问一遍烘焙数据
var _atlas: TextureLayered

## 编辑器兜底只扫一次目录
static var _fallback_done := false

## 场景路径 → 整合文件路径：<场景目录>/<场景名>_lightmap_set.res
static func path_of(scene_path: String) -> String:
	return "" if scene_path.is_empty() else scene_path.get_basename() + "_lightmap_set.res"

## 整张图集，全场景共用。取不到就说明烘焙数据缺失
func atlas() -> TextureLayered:
	if _atlas == null and data != null:
		var textures := data.get_lightmap_textures()
		if not textures.is_empty():
			_atlas = textures[0]
	return _atlas

func region(key: String) -> AssetLightmapRegion:
	return regions.get(key) as AssetLightmapRegion

## 按网格资源反查：键就是文件名，调用方不必知道自己的键
func region_of(mesh: Mesh) -> AssetLightmapRegion:
	if mesh == null or mesh.resource_path.is_empty():
		return null
	return region(mesh.resource_path.get_file().get_basename())

## 给实例挂光：任何拿到 MeshInstance3D 的地方都能调，重复调无副作用。
## 没有光照数据时顺手把之前挂的摘掉，免得实例跨场景复用时顶着旧光
func bind(mi: MeshInstance3D) -> bool:
	var light := region_of(mi.mesh)
	var texture := atlas()
	if light == null or not light.has_area() or texture == null:
		AssetLightmapBinder.clear(mi)
		return false
	return AssetLightmapBinder.apply(mi, light, texture)

## 走 [member current] 的便捷版：实例创建完补一次，不必持有库
static func bind_to(mi: MeshInstance3D) -> bool:
	if current == null:
		current = _editor_fallback()
	return current != null and current.bind(mi)

## 编辑器里没有 [Game] 来设 current：扫一份烘焙产物直接用，调光时能立刻看到效果。
## 只在编辑器、且第一次需要时扫一次
static func _editor_fallback() -> AssetLightmapSet:
	if _fallback_done or not Engine.is_editor_hint():
		return null
	_fallback_done = true
	for path in _all_produced("res://Scenes"):
		var res := load(path) as AssetLightmapSet
		if res != null:
			return res
	return null

## 换库时回收旧光照名下的材质副本。实例上已挂的宿主材质不受影响，
## 只是下次重新 bind 时会重新复制一份
func _release() -> void:
	for light in regions.values():
		AssetLightmapBinder.release(light as AssetLightmapRegion)

static func _all_produced(dir_path: String, out: Array[String] = []) -> Array[String]:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	for file in dir.get_files():
		if file.ends_with("_lightmap_set.res"):
			out.append(dir_path.path_join(file))
	for sub in dir.get_directories():
		if not sub.begins_with("."):
			_all_produced(dir_path.path_join(sub), out)
	return out

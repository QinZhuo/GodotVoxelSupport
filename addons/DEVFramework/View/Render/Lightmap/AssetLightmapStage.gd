@tool
## 烘焙舞台：只在编辑器里用，运行时永远不实例化。
##
## 它做编辑器才能做的两件事：
##   1. 给每类资源摆一份实体（LightmapGI 只认场景里的实体几何体）；
##   2. 把每类资源在图集里占的位置记成 [AssetLightmapRegion]，写进一份
##      <场景名>_lightmap_set.res —— 位置固定跟着场景走，没有任何路径配置。
##      不复制贴图：图集由 [member AssetLightmapSet.data] 直接引用。
##
## 节点名就是资源键（= 资源文件名），光照位置和运行时挂光都靠它对齐，
## 所以不要再给副本套一层容器节点。
##
## 用法：点「烘焙并导出」。副本会自动同步，变动过就连烘焙一起跑完。
class_name AssetLightmapStage extends Node3D

## 每行摆几份、相邻副本间距。只影响烘焙时互不遮挡，和运行时容量无关
const PER_ROW := 10
const SPACING := 10.0

## 副本标记：sync 只清理带这个标记的节点
const META := &"bake_copy"

@export_group("要烘焙的资源")
## 逐个点名网格：目录里混着不需要烘焙的模型时用这个
@export var meshes: Array[ArrayMesh] = []
## 整目录扫描：目录里全是物品模型时用它，键 = 文件名
@export_dir var dirs: Array[String] = []

@export_tool_button("烘焙并导出") var export_button: Callable = export_all

## 键 = 资源文件名（不是路径）。节点名、光贴图、区域表都靠它对齐
static func key_of(res: Resource) -> String:
	var path := res.resource_path
	return path.get_file().get_basename() if path else res.resource_name

## 键 → 资源。目录内容在导出时才读，不和场景重复维护。
## 只收烘得动的：LightmapGI 对没有 UV2 的网格不写任何光照数据，
## 摆上去只会白占一份副本节点，还挤掉图集位置
func _collect() -> Dictionary:
	var out := {}
	for res in meshes:
		_take(out, res)
	for dir_path in dirs:
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		var files := dir.get_files()
		files.sort()
		for file in files:
			_take(out, ResourceLoader.load(dir_path.path_join(file)))
	return out

static func _take(out: Dictionary, res: Resource) -> void:
	if res is ArrayMesh and AssetLightmapBinder.can_bake(res):
		out[key_of(res)] = res

## 导出。副本同步是导出的前置步骤，所以不单独给按钮：
## 忘了同步就烘焙，等于拿旧几何体烘出来的光照去配新资源，而且不会有任何提示
func export_all() -> void:
	if not Engine.is_editor_hint():
		return
	var scene_path := _scene_path()
	if scene_path.is_empty():
		LogTool.warn("烘焙", "场景未保存，导出路径无法推导")
		return
	if not sync():
		LogTool.log("烘焙", "副本已变动，开始烘焙…")
		if not await bake():
			LogTool.warn("烘焙", "烘焙未完成，请点 LightmapGI 的 Bake Lightmaps 后再次导出")
			return

	var set := _export_set()
	if set == null:
		return
	var all := _collect()
	_report(set, all)

	var path := AssetLightmapSet.path_of(scene_path)
	if ResourceSaver.save(set, path) != OK:
		LogTool.warn("烘焙", "保存失败:", path)
		return
	LogTool.log("烘焙", "光照", set.regions.size(), "类 →", path)
	EditorInterface.get_resource_filesystem().scan()

## 两个方向都要报：数据里有资源没有（副本删了但烘焙快照还在），
## 资源有数据没有（副本被遮挡、UV2 缺失，烘完静默丢失）
static func _report(set: AssetLightmapSet, all: Dictionary) -> void:
	var unknown := []
	for key in set.regions:
		if not all.has(key):
			unknown.append(key)
	if not unknown.is_empty():
		LogTool.warn("烘焙", "这些光照没有对应资源（副本节点名必须等于资源文件名）:", unknown)
	var missing := []
	for key in all:
		if not set.regions.has(key):
			missing.append(key)
	if not missing.is_empty():
		LogTool.warn("烘焙", "这些资源没烘出光照（检查 UV2，或副本被遮挡）:", missing)

## 同步副本：补缺、清多余、按顺序摆位。返回 false 表示几何体变过，光贴图已过期
func sync() -> bool:
	var all := _collect()
	var fresh := true
	## 已有的副本保持原顺序：光照是按位置烘的，不能因为列表顺序变了就整体搬家
	var placed := 0
	for node in _copies():
		var key := String(node.name)
		## 资源被删/改名后留下的副本清掉，否则会被烘进图集却无人认领
		if not all.has(key):
			remove_child(node)
			node.queue_free()
			fresh = false
			continue
		if node.position != _slot(placed):
			node.position = _slot(placed)
			fresh = false
		if node.get_index() != placed:
			move_child(node, placed)
		placed += 1
	## 再补齐缺的
	for key in all:
		if get_node_or_null(NodePath(key)) != null:
			continue
		var node := _instantiate(all[key])
		if node == null:
			continue
		node.name = key
		node.set_meta(META, true)
		add_child(node)
		node.owner = self
		node.position = _slot(placed)
		placed += 1
		fresh = false
	if not fresh:
		LogTool.log("烘焙", "副本已同步", placed, "份")
	return fresh

## 引擎没给 LightmapGI 暴露烘焙 API，只能借检查器上那个按钮：选中它再按下。
## 找不到按钮（编辑器换语言/改版）就返回 false，让调用方退回手动
func bake() -> bool:
	var gi := _lightmap()
	if gi == null:
		LogTool.warn("烘焙", "找不到 LightmapGI")
		return false
	EditorInterface.edit_node(gi)
	## 检查器要下一帧才把按钮造出来
	for i in 8:
		await get_tree().process_frame
	var btn := _bake_button(EditorInterface.get_base_control())
	if btn == null:
		return false
	btn.pressed.emit()
	## 烘完每个副本在 user_data 里占一组，中途尺寸对不上。
	## 全量烘焙可能跑十几分钟，轮询只是兜底，别卡太紧
	var expect := _copies().size()
	for i in 18000:
		await get_tree().create_timer(0.05).timeout
		if not is_instance_valid(gi):
			return false
		var raw: Array = gi.light_data.get("user_data") if gi.light_data else []
		if raw.size() / 4 == expect:
			return true
	return false

## 按钮由编辑器插件自己造，没有可查询的入口，只能按文本认
static func _bake_button(node: Node) -> Button:
	if node is Button:
		var text: String = (node as Button).text
		if text.contains("Bake Lightmaps") or text.contains("烘焙光照"):
			return node as Button
	for child in node.get_children():
		var found := _bake_button(child)
		if found != null:
			return found
	return null

## 舞台下的副本。只认自己打过标记的节点：灯光、环境、相机这些烘焙辅助节点
## 和副本同居一个父节点，靠名字猜谁是副本迟早会删错东西
func _copies() -> Array[Node3D]:
	var out: Array[Node3D] = []
	for child in get_children():
		if child is Node3D and child.has_meta(META):
			out.append(child as Node3D)
	return out

## 只摆一份是因为光照按资源走，多摆的副本光照内容完全相同，白占图集
func _instantiate(res: ArrayMesh) -> Node3D:
	var mi := MeshInstance3D.new()
	mi.mesh = res
	return mi

static func _slot(index: int) -> Vector3:
	return Vector3((index % PER_ROW) * SPACING, 0.0, (index / PER_ROW) * SPACING)

## 本节点所在场景的路径（产物跟着它走）
func _scene_path() -> String:
	var tree := get_tree()
	var root := tree.edited_scene_root if tree else null
	return root.scene_file_path if root else ""

## 把烘焙结果读成位置表。user_data 每 4 项一组：副本路径、图集矩形、页号、实例序号
func _export_set() -> AssetLightmapSet:
	var gi := _lightmap()
	if gi == null or gi.light_data == null:
		LogTool.warn("烘焙", "找不到 LightmapGI 或其 light_data")
		return null
	var raw: Array = gi.light_data.get("user_data")
	var all := _collect()
	var set := AssetLightmapSet.new()
	set.data = gi.light_data
	var dead := 0
	for i in range(0, raw.size(), 4):
		var key := _key_of_path(str(raw[i]))
		if key.is_empty() or set.regions.has(key):
			continue
		## 烘焙数据是历史快照：副本删掉后 user_data 里那条还在，运行时却永远取不到
		if not all.has(key):
			dead += 1
			continue
		var light := AssetLightmapRegion.new()
		light.uv = raw[i + 1]
		light.slice = int(raw[i + 2])
		set.regions[key] = light
	if dead > 0:
		LogTool.warn("烘焙", "烘焙数据里有", dead, "条资源已不存在，已跳过；重新烘焙可清空")
	return set if not set.regions.is_empty() else null

## ../CardBox/Body → CardBox。副本节点名就是资源键，取 .. 之后的第一段
static func _key_of_path(path: String) -> String:
	var segs := path.split("/")
	var i := 0
	while i < segs.size() and segs[i] == "..":
		i += 1
	return segs[i] if i < segs.size() else ""

## LightmapGI 放在舞台里还是场景根节点下都能找到
func _lightmap() -> LightmapGI:
	var root := owner if owner else self
	var found := root.find_children("*", "LightmapGI", true, false)
	return found[0] as LightmapGI if not found.is_empty() else null

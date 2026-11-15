@tool
## 烘焙舞台：只在编辑器里用，运行时永远不实例化。
## 所以不要再给副本套一层容器节点。
class_name AssetLightmapStage extends Node3D

## 副本标记：sync 只清理带这个标记的节点
const META := &"bake_copy"

## 每行摆几份、相邻副本间距。只影响烘焙时互不遮挡，和运行时容量无关
const PER_ROW := 10
const SPACING := 10.0

## 逐个点名网格：目录里混着不需要烘焙的模型时用这个
@export var meshes: Array[ArrayMesh] = []
## 整目录扫描：目录里全是物品模型时用它，键 = 文件名
@export_dir var dirs: Array[String] = []

@export_tool_button("烘焙并导出") var export_button: Callable = export_all

## 键 → 资源。目录内容在导出时才读，不和场景重复维护。
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

## 节点名、光贴图、区域表都靠同一个键对齐（键规则见 [method AssetLightmapSet.key_of]）
static func _take(out: Dictionary, res: Resource) -> void:
	if not (res is ArrayMesh) or not AssetLightmapBinder.can_bake(res):
		return
	var key := AssetLightmapSet.key_of(res)
	if not key.is_empty():
		out[key] = res

## 导出。副本同步是导出的前置步骤，所以不单独给按钮：
func export_all() -> void:
	if not Engine.is_editor_hint():
		return
	var scene_path := _scene_path()
	if scene_path.is_empty():
		LogTool.warn("烘焙", "场景未保存，导出路径无法推导")
		return
	_warn_without_static_light()
	## SH 叠加层要读 l1（方向项）：不勾 Bake Directional 时图集里只有 l0，
	var gi := _lightmap()
	if gi != null and not gi.directional:
		gi.directional = true
		LogTool.log("烘焙", "已开启 LightmapGI 的 Bake Directional（SH 叠加层需要方向数据）")
	## 一次扫描供同步 / 导出 / 核对共用：导出中途目录内容不会变。
	## ⚠️ 同步必须无条件跑：它同时负责把副本摆进场景，短路掉就会拿着空舞台去烘
	var all := _collect()
	sync(all)
	LogTool.log("烘焙", "开始烘焙…")
	if not await bake():
		LogTool.warn("烘焙", "烘焙未完成，请点 LightmapGI 的 Bake Lightmaps 后再次导出")
		return

	var set := _export_set(all)
	if set == null:
		return
	_report(set, all)

	var path := AssetLightmapSet.path_of(scene_path)
	if ResourceSaver.save(set, path) != OK:
		LogTool.warn("烘焙", "保存失败:", path)
		return
	LogTool.log("烘焙", "光照", set.regions.size(), "类 →", path)
	## 场景必须一起存：LightmapGI 的 light_data 引用只在场景里，不存的话下次打开就没有烘焙数据，
	## ⚠️ 用 save_scene_as 显式给路径：save_scene() 在"当前场景"解析不到保存目标时
	## 注意它没有返回值（void），别写成 `if ... != OK`（会直接编译失败）
	EditorInterface.save_scene_as(scene_path)
	## 新产物立刻可用：否则编辑器兜底还拿着上一次的扫描结论
	AssetLightmapSet.invalidate()
	EditorInterface.get_resource_filesystem().scan()

## 4.4 起 Light3D.light_bake_mode 默认是 DYNAMIC：不进 lightmap，只靠"灯"烘的话结果全黑
func _warn_without_static_light() -> void:
	var visible := 0
	var baked := 0
	for node in _root().find_children("*", "Light3D", true, false):
		var light := node as Light3D
		if not light.is_visible_in_tree():
			continue
		visible += 1
		if light.light_bake_mode == Light3D.BAKE_STATIC:
			baked += 1
	if baked == 0:
		LogTool.warn("烘焙", "场景里没有 Static 烘焙模式的灯（可见灯 %d 个，全为 Dynamic/Disabled）——"
			% visible + "烘出来会全黑；把要参与烘焙的灯设为 Static 再重烘")

## 资源有数据没有（副本被遮挡、UV2 缺失，烘完会静默丢失）。
static func _report(set: AssetLightmapSet, all: Dictionary) -> void:
	var missing := []
	for key in all:
		if not set.regions.has(key):
			missing.append(key)
	if not missing.is_empty():
		LogTool.warn("烘焙", "这些资源没烘出光照（检查 UV2，或副本被遮挡）:", missing)

## 同步副本：补缺、清多余、按顺序摆位
func sync(all := {}) -> void:
	if all.is_empty():
		all = _collect()
	var changed := false
	## 已有的副本保持原顺序：光照是按位置烘的，不能因为列表顺序变了就整体搬家
	var placed := 0
	for node in _copies():
		var key := String(node.name)
		## 资源被删/改名后留下的副本清掉，否则会被烘进图集却无人认领
		if not all.has(key):
			remove_child(node)
			node.queue_free()
			changed = true
			continue
		if node.position != _slot(placed):
			node.position = _slot(placed)
			changed = true
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
		## owner 必须是场景根（PackedScene 只存 owner == 根 的节点）：
		node.owner = _root()
		node.position = _slot(placed)
		placed += 1
		changed = true
	if changed:
		LogTool.log("烘焙", "副本已同步", placed, "份")

## 引擎没给 LightmapGI 暴露烘焙 API，只能借检查器上那个按钮：选中它再按下。
func bake() -> bool:
	var gi := _lightmap()
	if gi == null:
		LogTool.warn("烘焙", "找不到 LightmapGI")
		return false
	if DisplayServer.get_name() == "headless":
		LogTool.warn("烘焙", "headless 下没有检查器按钮，无法触发烘焙")
		return false
	var expect := _copies().size()
	if expect <= 0:
		LogTool.warn("烘焙", "舞台里没有副本，没有东西可烘")
		return false
	EditorInterface.edit_node(gi)
	for i in 12:
		await get_tree().process_frame
	var btn := _bake_button(EditorInterface.get_base_control())
	if btn == null:
		LogTool.warn("烘焙", "检查器里找不到 Bake Lightmaps 按钮，请手动烘焙后再次导出")
		return false

	## 完成判据：副本数到位 **且** `.lmbake` 被重写。
	## ⚠️ 两个坑都别踩：
	var data_path := gi.light_data.resource_path if gi.light_data != null else ""
	var before_mtime := FileAccess.get_modified_time(data_path) if not data_path.is_empty() else 0
	## ⚠️ 预期噪音：编辑器在烘焙开始时重建 Inspector，按钮在信号发射途中被释放，
	btn.pressed.emit()
	for i in 18000:
		await get_tree().create_timer(0.05).timeout
		if not is_instance_valid(gi):
			LogTool.warn("烘焙", "烘焙过程中 LightmapGI 被销毁")
			return false
		if gi.light_data == null or gi.light_data.get_user_count() != expect or i < 30:
			continue
		## 以 .lmbake 落盘时间为准：副本数在按下瞬间就满足，实例 id 也会被编辑器提前换掉，
		if data_path.is_empty() or FileAccess.get_modified_time(data_path) > before_mtime:
			return true
	LogTool.warn("烘焙", "等待烘焙超时（%d 份副本未全部产出或数据未更新），请确认烘焙是否仍在进行" % expect)
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
func _export_set(all: Dictionary) -> AssetLightmapSet:
	var gi := _lightmap()
	if gi == null or gi.light_data == null:
		LogTool.warn("烘焙", "找不到 LightmapGI 或其 light_data")
		return null
	var raw: Array = gi.light_data.get("user_data")
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

## 搜索起点：整个场景（LightmapGI 放在舞台里还是场景根节点下都能找到）
func _root() -> Node:
	return owner if owner else self

## LightmapGI 放在舞台里还是场景根节点下都能找到
func _lightmap() -> LightmapGI:
	var found := _root().find_children("*", "LightmapGI", true, false)
	return found[0] as LightmapGI if not found.is_empty() else null

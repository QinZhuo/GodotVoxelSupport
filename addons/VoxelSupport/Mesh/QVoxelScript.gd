@tool
class_name QVoxelScript
extends RefCounted
## ======= 体素脚本接口（脚本 / MCP 的唯一入口）=======
## 与体素建模软件（QVoxelier）**同一套能力**：软件上能做的每个动作，这里都有一个方法，
## 参数与返回值也与界面字段对应。
## 【自动分流】运行时场景里有 QVoxelier（响应 `script_stats`）→ 走应用内部命令路径
## （看得见、可撤销）；否则（编辑器进程 / 纯运行时）→ 直接操作内存里的 `QVoxelWorld`。
## 【进程选择】改正在运行的应用用 `eval_code(process="game")`；`process="editor"` 一律落无头
## （不碰用户正开着的场景），生成完写文件即可。
## 【形状算法】`VoxelPrimitives`（与画笔同一份实现）产出格子集合，再交给 `paint`。
## 【节点 id】模型 = `model_id`（> 0）；组 = `-node_uid`（< 0，仅内存内稳定）。见 `nodes()`。

static var _world: QVoxelWorld = null
static var _active := 0


# ---------------- 文件 ----------------

## 新建空模型（整体替换当前世界）。返回 `info()`。
static func new_model(grid := Vector3i(32, 32, 32), block_size := 32) -> Dictionary:
	var app: Variant = _app()
	if app != null:
		app.call("script_new", grid)
		return info()
	if grid.x <= 0 or grid.y <= 0 or grid.z <= 0:
		grid = Vector3i(32, 32, 32)
	_world = QVoxelWorld.create_empty()
	if block_size > 0:
		_world.head["block_size"] = block_size
	_active = _world.create_model("Model", grid).model_id
	return info()


## 打开文件（`.qvx` 工程 / `.vox` 外部模型），活动模型取第一个有内容的。
static func open(path: String) -> bool:
	var app: Variant = _app()
	if app != null:
		return bool(app.call("script_open", path))
	var w := QVoxelFileIO.load_world(path)
	if w == null:
		return false
	_world = w
	var m := _first_model(w)
	_active = m.model_id if m != null else 0
	return m != null


## 存盘：按**扩展名**决定格式（`.qvx` 工程 / `.vox` 出口），没写扩展名按工程补。
## `.vox` 不合规（超 256 / 非 90° 朝向 / 非整数平移）时拒绝落盘并返回 false。
static func save(path := "user://voxel_model.qvx") -> bool:
	var app: Variant = _app()
	if app != null:
		return bool(app.call("script_save", path))
	return QVoxelFileIO.save(_w(), QVoxelFileIO.ensure_extension(path))


## 导入外部网格（glTF/OBJ）并**并入**当前世界；`resolution` = 最长边体素数。需要 `await`。
static func import_model(path: String, resolution := 96) -> bool:
	var app: Variant = _app()
	if app != null:
		return await app.call("script_import", path, {"resolution": resolution})
	var scene: Dictionary = await MeshAccess.load_scene(path)
	if scene.is_empty():
		return false
	var src: QVoxelWorld = await MeshVoxelWorld.to_world(scene, resolution)
	if src == null:
		return false
	var added := _w().merge_from(src)
	if added.is_empty():
		return false
	_active = added[0].model_id
	return true


## 导出三角网格（`.glb` / `.gltf`，由扩展名决定）。
static func export_mesh(path: String) -> bool:
	var app: Variant = _app()
	if app != null:
		return bool(app.call("script_export_mesh", path))
	var ext := path.get_extension().to_lower()
	var p := path if ext in QVoxelMeshExport.EXTENSIONS else path + "." + QVoxelMeshExport.EXTENSIONS[0]
	return QVoxelMeshExport.export(_w(), p) == OK


# ---------------- 对象树 ----------------

## 读 / 设活动模型：`active()` 读，`active(id)` 切换（非法 id 不变）。
static func active(id := -1) -> int:
	var app: Variant = _app()
	if app != null:
		return int(app.call("script_active", id))
	if id > 0 and _w().find_model(id) != null:
		_active = id
	return _active


## 全部模型：id / 名称 / 尺寸 / 摆放 / 可见 / 帧数 / 实心格数。
static func models() -> Array:
	var app: Variant = _app()
	if app != null:
		return app.call("script_models")
	var out: Array = []
	for m in _w().all_models():
		out.append({
			"id": m.model_id,
			"name": m.display_name(),
			"grid_size": [m.grid_size.x, m.grid_size.y, m.grid_size.z],
			"offset": [m.offset.x, m.offset.y, m.offset.z],
			"visible": m.visible,
			"frames": m.frame_count(),
			"solid": m.count_solid(),
		})
	return out


## 全部节点（含组，深度优先）：id / kind / 名称 / 父 id / 可见 / 帧数。
static func nodes() -> Array:
	var app: Variant = _app()
	if app != null:
		return app.call("script_nodes")
	var w := _w()
	var out: Array = []
	for n in w.all_nodes():
		var parent := w.find_parent(n)
		out.append({
			"id": w.node_id(n),
			"kind": n.kind(),
			"name": n.display_name(),
			"parent": w.node_id(parent) if parent != null else 0,
			"visible": n.visible,
			"frames": (n as QVoxelModel).frame_count() if n.is_model() else 0,
		})
	return out


## 新建模型并切为活动。`grid` 为 ZERO 时随当前模型尺寸。返回新 model_id。
static func add_model(name := "", grid := Vector3i.ZERO, parent_id := 0) -> int:
	var app: Variant = _app()
	if app != null:
		return int(app.call("script_add_model", name, grid, parent_id))
	if grid.x <= 0 or grid.y <= 0 or grid.z <= 0:
		var cur := _model()
		grid = cur.grid_size if cur != null else Vector3i(32, 32, 32)
	_active = _w().create_model(name, grid, _group(parent_id)).model_id
	return _active


## 新建组（容器，不持有体素）。返回组 id（负数）。
static func add_group(name := "Group", parent_id := 0) -> int:
	var app: Variant = _app()
	if app != null:
		return int(app.call("script_add_group", name, parent_id))
	var w := _w()
	return w.node_id(w.create_group(name, _group(parent_id)))


## 删除节点（连同子树）。最后一个模型不会被删（世界空了就无物可编）。
static func remove_node(id: int) -> bool:
	var app: Variant = _app()
	if app != null:
		return bool(app.call("script_remove_node", id))
	var w := _w()
	var n := _node(id)
	if n == null or (n.is_model() and w.all_models().size() <= 1):
		return false
	w.remove_node(n)
	if w.find_model(_active) == null:
		var first := _first_model(w)
		_active = first.model_id if first != null else 0
	return true


static func rename_node(id: int, name: String) -> bool:
	var app: Variant = _app()
	if app != null:
		return bool(app.call("script_rename_node", id, name))
	var n := _node(id)
	if n == null:
		return false
	n.node_name = name
	return true


## 挂到新父的 `index` 处（`parent_id = 0` = 顶层，`index < 0` = 末尾）。
static func move_node(id: int, parent_id: int, index := -1) -> bool:
	var app: Variant = _app()
	if app != null:
		return bool(app.call("script_move_node", id, parent_id, index))
	var n := _node(id)
	return n != null and _w().attach_node(n, _group(parent_id), index)


## 摆放：位置（体素格，相对父节点）。
static func set_offset(id: int, offset: Vector3i) -> bool:
	var app: Variant = _app()
	if app != null:
		return bool(app.call("script_set_offset", id, offset))
	var n := _node(id)
	if n == null:
		return false
	n.offset = offset
	return true


## 摆放：旋转（度，只接受 90 的倍数，与 `.vox` 的 nTRN 同构）。
static func set_rotation(id: int, degrees: Vector3) -> bool:
	var app: Variant = _app()
	if app != null:
		return bool(app.call("script_set_rotation", id, degrees))
	var n := _node(id)
	if n == null:
		return false
	var d := Vector3(_snap90(degrees.x), _snap90(degrees.y), _snap90(degrees.z))
	var xf := n.local_transform
	xf.basis = Basis.from_euler(d * (PI / 180.0))
	n.local_transform = xf
	return true


static func set_visible(id: int, on: bool) -> bool:
	var app: Variant = _app()
	if app != null:
		return bool(app.call("script_set_visible", id, on))
	var n := _node(id)
	if n == null:
		return false
	n.visible = on
	return true


## 改分辨率（输出盒 `[0,size)`）：保留新旧交集，超出部分丢弃。
static func resize(size: Vector3i, id := -1) -> bool:
	if size.x <= 0 or size.y <= 0 or size.z <= 0:
		return false
	var app: Variant = _app()
	if app != null:
		return bool(app.call("script_resize", size, id))
	var m := _model(id)
	if m == null or m.grid_size == size:
		return false
	m.resize_grid(size)
	return true


# ---------------- 材质 ----------------

## 追加材质，返回 id（从 1 起；0 = 空气）。参数即材质面板的四个字段。
static func material(color := Color(0.8, 0.8, 0.8), metal := 0.0, rough := 0.8,
		emission := 0.0) -> int:
	var app: Variant = _app()
	if app != null:
		return int(app.call("script_add_material", color, metal, rough, emission))
	var w := _w()
	var id := w.add_material(color)
	w.set_material_scalar(id, &"metal", metal)
	w.set_material_scalar(id, &"rough", rough)
	if emission > 0.0:
		w.set_material_scalar(id, &"emission", emission)
	return id


static func set_material_color(id: int, color: Color) -> bool:
	var app: Variant = _app()
	if app != null:
		return bool(app.call("script_set_material_color", id, color))
	var w := _w()
	if id <= 0 or id >= w.materials.size():
		return false
	w.set_material_color(id, color)
	return true


## 改 PBR 通道；传负数 = 该项不动。
static func set_material_pbr(id: int, metal := -1.0, rough := -1.0, emission := -1.0) -> bool:
	var app: Variant = _app()
	if app != null:
		return bool(app.call("script_set_material_pbr", id, metal, rough, emission))
	var w := _w()
	if id <= 0 or id >= w.materials.size():
		return false
	if metal >= 0.0:
		w.set_material_scalar(id, &"metal", metal)
	if rough >= 0.0:
		w.set_material_scalar(id, &"rough", rough)
	if emission >= 0.0:
		w.set_material_scalar(id, &"emission", emission)
	return true


## 调色板（不含 0 号空气槽）。
static func materials() -> Array:
	var app: Variant = _app()
	if app != null:
		return app.call("script_materials")
	var w := _w()
	var out: Array = []
	for i in range(1, w.materials.size()):
		out.append({
			"id": i,
			"color": w.material_color(i),
			"metal": w.material_scalar(i, &"metal"),
			"rough": w.material_scalar(i, &"rough"),
			"emission": w.material_scalar(i, &"emission"),
		})
	return out


# ---------------- 体素 ----------------

## 一批格落到活动模型。返回实际改动格数（越界格丢弃）。
static func paint(cells: Array[Vector3i], material_id := 1) -> int:
	if cells.is_empty():
		return 0
	var mat := maxi(material_id, 0)
	var app: Variant = _app()
	if app != null:
		return int(app.call("script_paint", cells, mat))
	var w := _w()
	var m := _model()
	if m == null:
		return 0
	while mat > 0 and w.materials.size() <= mat:
		w.add_material(Color(0.8, 0.8, 0.8))  # 引用未定义材质时补灰，免得画出"看不见的格"
	return m.paint_cells(cells, mat)


## 擦除（等价 `paint(cells, 0)`）。
static func erase(cells: Array[Vector3i]) -> int:
	return paint(cells, 0)


static func get_voxel(pos: Vector3i, id := -1) -> int:
	var app: Variant = _app()
	if app != null:
		return int(app.call("script_get_voxel", pos, id))
	var m := _model(id)
	return m.get_voxel(pos.x, pos.y, pos.z) if m != null else 0


static func count_solid(id := -1) -> int:
	var app: Variant = _app()
	if app != null:
		return int(app.call("script_count_solid", id))
	var m := _model(id)
	return m.count_solid() if m != null else 0


# ---------------- 帧动画 ----------------

## `{count, active, fps, loop, durations}`。
static func frames(id := -1) -> Dictionary:
	var app: Variant = _app()
	if app != null:
		return app.call("script_frames", id)
	var m := _model(id)
	if m == null:
		return {}
	var durs: Array = []
	for f in m.frames:
		durs.append(f.duration_ms)
	return {
		"count": m.frame_count(),
		"active": m.active_frame,
		"fps": m.anim_fps,
		"loop": m.anim_loop,
		"durations": durs,
	}


## 在当前帧之后插一帧并切过去（`duplicate` = 复制当前帧）。
## 静态模型先**就地转动画**（现有体素进第 0 帧），再在它之后插入 —— 与界面的「＋」同一语义。
static func add_frame(duplicate := false, id := -1) -> int:
	var app: Variant = _app()
	if app != null:
		return int(app.call("script_add_frame", duplicate, id))
	var m := _model(id)
	if m == null:
		return -1
	if not m.is_animated():
		m.make_animated()
	var f := m.frames[m.active_frame].clone() if duplicate else QVoxelFrame.new()
	var idx := m.add_frame(f, m.active_frame + 1)
	m.active_frame = idx
	return idx


static func remove_frame(index: int, id := -1) -> bool:
	var app: Variant = _app()
	if app != null:
		return bool(app.call("script_remove_frame", index, id))
	var m := _model(id)
	return m.remove_frame(index) if m != null else false


static func move_frame(from: int, to: int, id := -1) -> bool:
	var app: Variant = _app()
	if app != null:
		return bool(app.call("script_move_frame", from, to, id))
	var m := _model(id)
	return m.move_frame(from, to) if m != null else false


## 切到第 index 帧（只影响读路径：渲染 / 求值 / 统计）。
static func set_frame(index: int, id := -1) -> bool:
	var app: Variant = _app()
	if app != null:
		return bool(app.call("script_set_frame", index, id))
	var m := _model(id)
	if m == null or not m.is_animated() or index < 0 or index >= m.frame_count():
		return false
	m.active_frame = index
	return true


static func set_frame_duration(index: int, ms: int, id := -1) -> bool:
	var app: Variant = _app()
	if app != null:
		return bool(app.call("script_set_frame_duration", index, ms, id))
	var m := _model(id)
	var f := m.frame_at(index) if m != null else null
	if f == null:
		return false
	f.duration_ms = maxi(0, ms)
	return true


## 时间轴元数据（播放兜底帧率 / 是否循环）。
static func set_anim(fps := 12, loop := true, id := -1) -> bool:
	var app: Variant = _app()
	if app != null:
		return bool(app.call("script_set_anim", fps, loop, id))
	var m := _model(id)
	if m == null:
		return false
	m.anim_fps = maxi(1, fps)
	m.anim_loop = loop
	return true


# ---------------- 相机 ----------------

## 相机书签列表（`{name, pos, look, fov}`）。
static func cameras() -> Array:
	var app: Variant = _app()
	if app != null:
		return app.call("script_cameras")
	return _w().cameras().duplicate(true)


static func add_camera(name := "camera") -> int:
	var app: Variant = _app()
	if app != null:
		return int(app.call("script_add_camera", name))
	return _w().add_camera(name)


static func remove_camera(index: int) -> bool:
	var app: Variant = _app()
	if app != null:
		return bool(app.call("script_remove_camera", index))
	return _w().remove_camera(index)


## 改相机字段（`pos` / `look` / `fov` / `name`）。
static func set_camera(index: int, key: String, value: Variant) -> bool:
	var app: Variant = _app()
	if app != null:
		return bool(app.call("script_set_camera", index, key, value))
	return _w().set_camera_field(index, key, value)


# ---------------- 信息 ----------------

## 目标模型统计 `{live, grid_size, voxel_count, material_count, models, active, frames}`。
static func info() -> Dictionary:
	var app: Variant = _app()
	if app != null:
		var st: Dictionary = app.call("script_stats")
		st["live"] = true
		return st
	var w := _w()
	var m := _model()
	return {
		"live": false,
		"grid_size": [m.grid_size.x, m.grid_size.y, m.grid_size.z] if m != null else [],
		"voxel_count": m.count_solid() if m != null else 0,
		"material_count": maxi(0, w.materials.size() - 1),
		"models": w.all_models().size(),
		"active": _active,
		"frames": m.frame_count() if m != null else 0,
	}


# ---------------- 高级访问 ----------------

## 底层世界（实时分支 = 应用当前打开的，无头分支 = 内存里的）。
static func world() -> QVoxelWorld:
	var app: Variant = _app()
	return app.call("script_world") if app != null else _w()


## 目标模型对象（需要绕过本类直接调 QVoxelModel 时用）。
static func model(id := -1) -> QVoxelModel:
	var app: Variant = _app()
	return app.call("script_model", id) if app != null else _model(id)


# ---------------- 状态与寻址 ----------------

## 运行中的应用（有就说明要走实时路径）。编辑器进程一律返回 null：不去动用户开着的场景。
static func _app() -> Variant:
	if Engine.is_editor_hint():
		return null
	var scene := Engine.get_main_loop() as SceneTree
	var node: Node = scene.current_scene if scene != null else null
	return node if node != null and node.has_method("script_stats") else null


## 无头世界（惰性建一个默认 32³ 单模型，脚本可以上来就 paint）。
static func _w() -> QVoxelWorld:
	if _world == null:
		new_model()
	return _world


static func _model(id := -1) -> QVoxelModel:
	var w := _w()
	var m := w.find_model(id if id > 0 else _active)
	if m != null:
		return m
	var first := _first_model(w)
	return first


static func _node(id: int) -> QVoxelNode:
	return _w().find_node(id) if id != 0 else null


static func _group(id: int) -> QVoxelGroup:
	var n := _node(id)
	return n as QVoxelGroup if n != null and n.is_group() else null


## 第一个有内容的模型（打开文件后默认编辑它）；全都空则取第一个。
static func _first_model(w: QVoxelWorld) -> QVoxelModel:
	var first: QVoxelModel = null
	for m in w.all_models():
		if first == null:
			first = m
		if not m.is_empty():
			return m
	return first


static func _snap90(deg: float) -> float:
	return roundf(deg / 90.0) * 90.0

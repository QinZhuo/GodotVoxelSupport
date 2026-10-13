@tool
class_name QVoxelScript
extends RefCounted

## ======= 体素程序化生成的**脚本接口**(统一目标) =======
##
## 【用法】脚本里直接调(全局类, 无需 preload):
##     QVoxelScript.new_model(Vector3i(32,32,32), 32)
##     var id := QVoxelScript.material(Color(0.8,0.5,0.3))
##     QVoxelScript.paint(VoxelPrimitives.ball(Vector3i(8,8,8), 5), id)
##     QVoxelScript.resize(Vector3i(16,16,16))
##     print(QVoxelScript.info())
##     QVoxelScript.save("user://model.qvx")
##
## 【统一目标, 自动分流】每个方法内部: 运行时有 QVoxelier 应用就操作它的当前活动模型
## (可见、可撤销), 否则操作无头 `QVoxelBuilder`(可直接存 .qvx)。调用方无需判断。
##
## 【进程选择决定"是否可见"】
##   · 想改**正在运行的应用**: 用 `game_eval`(编辑器进程里 eval_code 摸不到游戏)。
##   · 编辑器里 eval_code: 本类**不把"编辑中的场景"当实时目标**(避免改用户正开着的场景),
##     一律落无头 builder; 想看得见就用 game_eval。
##   · 打包运行时: eval_code 就在游戏进程内, 直接生效、可见。
##
## 【想要完全控制】直接用 `QVoxelBuilder`(纯无头, 不参与分流): 见其类文档与 voxel_help。
## 【形状算法】一律 `VoxelPrimitives`(与编辑器画笔同一份实现)。

static var _b: QVoxelBuilder = null


# ---------------- 统一接口 ----------------

## 新建空模型。实时=整体替换当前模型; 无头=新建 builder。返回 info()。
static func new_model(grid := Vector3i(32, 32, 32), block_size := 32) -> Dictionary:
	if _app() != null:
		_app().call("script_new", grid)
	else:
		_b = QVoxelBuilder.new(grid, block_size)
	return info()


## 追加材质, 返回 id(从 1 起; 0=空气)。实时只认 color/metal/rough, 其余仅无头生效。
static func material(color := Color(0.8, 0.8, 0.8), metal := 0.0, rough := 0.8,
		hardness := 0.5, mass := 0.5, emission := Color(0, 0, 0)) -> int:
	if _app() != null:
		return int(_app().call("script_add_material", color, metal, rough))
	return _builder().add_material(color, metal, rough, hardness, mass, emission)


## 一批格落到当前目标。返回改动格数。
static func paint(cells: Array[Vector3i], material_id := 1) -> int:
	if cells.is_empty():
		return 0
	var mat := maxi(material_id, 0)
	var s = _live_session()
	if s != null:
		return int(s.call("apply_cells", cells, mat))
	var b := _builder()
	while mat > 0 and b.material_count() < mat:
		b.add_material(Color(0.8, 0.8, 0.8))  # 保证引用的材质存在(免得描到未定义材质)
	b.paint(cells, mat)
	return cells.size()


## 改分辨率(输出盒 [0,size)); 保留新旧尺寸交集、超出丢弃。返回是否真的变了。
static func resize(size: Vector3i) -> bool:
	if size.x <= 0 or size.y <= 0 or size.z <= 0:
		return false
	if _app() != null:
		return bool(_app().call("script_resize", size))
	var b := _builder()
	if size == b.grid_size:
		return false
	b.resize(size)
	return true


## 当前目标统计 {live, grid_size, voxel_count, material_count}。
static func info() -> Dictionary:
	if _app() != null:
		var st: Dictionary = _app().call("script_stats")
		st["live"] = true
		return st
	var b := _builder()
	return {
		"live": false,
		"grid_size": [b.grid_size.x, b.grid_size.y, b.grid_size.z],
		"voxel_count": b.voxels().size(),
		"material_count": b.material_count(),
	}


## 写 .qvx。实时走应用存档; 无头写 builder。返回是否成功。
static func save(path := "user://voxel_model.qvx") -> bool:
	if _app() != null:
		return bool(_app().call("script_save", path))
	return _builder().save(path)


## 无头 builder 原始访问(高级: 需要 put/line/box/ball/voxels/to_document 时用)。
static func builder() -> QVoxelBuilder:
	return _builder()


## 实时应用根(有 QVoxelier 且非编辑器进程), 无则 null。
static func app():
	return _app()


# ---------------- 内部 ----------------

static func _builder() -> QVoxelBuilder:
	if _b == null:
		_b = QVoxelBuilder.new()
	return _b


static func _app():
	if Engine.is_editor_hint():
		return null
	var scene = _live_scene()
	return scene if (scene != null and scene.has_method("script_stats")) else null


static func _live_scene():
	var tree := Engine.get_main_loop() as SceneTree
	return tree.current_scene if tree != null else null


static func _live_session():
	if Engine.is_editor_hint():
		return null
	var scene = _live_scene()
	if scene == null:
		return null
	var s = scene.get("session")
	if s != null and s.has_method("apply_cells"):
		return s
	return null

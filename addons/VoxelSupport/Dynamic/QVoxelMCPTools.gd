@tool
extends RefCounted

## ======= 体素建模 MCP 工具集(项目侧 provider) =======
##
## 由 MCPRuntimeServer 按项目设置 `dev_framework/mcp/runtime_providers` 加载并调用 `register`。
## 全部实现建立在**运行时类**之上(QVoxelBuilder + VoxelPrimitives + QVoxelFile), 故打包后可用。
## 框架层(DEVFramework)不认识本文件, 只认"一个提供 static register(add_tool) 的脚本" —— 分层:
## 机制在框架, 体素建模这套内容在项目(VoxelSupport)。

const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPToolSchema := preload("res://addons/DEVFramework/MCP/MCPToolSchema.gd")

static var _b: QVoxelBuilder = null


static func register(add_tool: Callable) -> void:
	add_tool.call("voxel_new",
		"新建一个空体素模型(替换当前的)。grid_size 仅作参考, block_size 决定分块粒度(默认 32)。返回空对象。",
		{"type": "object", "properties": {
			"grid_size": {"type": "integer", "description": "参考网格边长, 默认 32"},
			"block_size": {"type": "integer", "description": "块边长(2 的幂), 默认 32"}
		}},
		_new)
	add_tool.call("voxel_add_material",
		"向当前模型追加一个材质, 返回其 ID(从 1 起; 0 恒为空气)。color/emission 用 #rrggbb 十六进制。",
		{"type": "object", "properties": {
			"color": MCPToolSchema.str_arg("基色 #rrggbb, 默认 #cccccc"),
			"metal": {"type": "number", "description": "金属度 0..1, 默认 0"},
			"rough": {"type": "number", "description": "粗糙度 0..1, 默认 0.8"},
			"hardness": {"type": "number", "description": "硬度 0..1, 默认 0.5"},
			"mass": {"type": "number", "description": "质量 0..1, 默认 0.5"},
			"emission": MCPToolSchema.str_arg("自发光 #rrggbb, 缺省=不发光")
		}},
		_add_material)
	add_tool.call("voxel_box",
		"用当前材质填一个实心长方体(两角点含端点, 可给负坐标)。返回当前体素总数。",
		_box_schema(), _box)
	add_tool.call("voxel_line",
		"用当前材质画一条 3D 直线(26-连通)。返回当前体素总数。",
		_box_schema(), _line)
	add_tool.call("voxel_ball",
		"用当前材质填一个欧氏球。返回当前体素总数。",
		{"type": "object", "properties": {
			"x": {"type": "integer"}, "y": {"type": "integer"}, "z": {"type": "integer"},
			"radius": {"type": "integer", "description": "半径(体素), 0=单格"},
			"material": {"type": "integer", "description": "材质 ID, 缺省=1"}
		}, "required": ["x", "y", "z"]}, _ball)
	add_tool.call("voxel_put",
		"放置单个体素。返回当前体素总数。",
		{"type": "object", "properties": {
			"x": {"type": "integer"}, "y": {"type": "integer"}, "z": {"type": "integer"},
			"material": {"type": "integer", "description": "材质 ID, 缺省=1"}
		}, "required": ["x", "y", "z"]}, _put)
	add_tool.call("voxel_info",
		"查询当前模型统计: 体素数 / 材质数 / 体素包围盒(min/max, 含端点)。",
		MCPToolSchema.no_arg(), _info)
	add_tool.call("voxel_save",
		"把当前模型写成 .qvx(含 CRC)。发布版建议写 user:// 路径。返回路径与字节数。",
		{"type": "object", "properties": {
			"path": MCPToolSchema.str_arg("输出路径, 默认 user://voxel_model.qvx")
		}}, _save)


# ---------------- 实现 ----------------

static func _builder() -> QVoxelBuilder:
	if _b == null:
		_b = QVoxelBuilder.new()
	return _b


static func _mat_id(args: Dictionary) -> int:
	var m := VariantTool.get_int(args, "material", 1)
	return m if m > 0 else 1


static func _default_material() -> int:
	var b = _builder()
	if b.material_count() == 0:
		return b.add_material(Color(0.8, 0.8, 0.8))
	return 1


static func _new(args: Dictionary) -> Dictionary:
	var g := VariantTool.get_int(args, "grid_size", 32)
	var bs := VariantTool.get_int(args, "block_size", 32)
	_b = QVoxelBuilder.new(Vector3i(g, g, g), bs)
	return MCPResult.ok_json({"block_size": bs})


static func _add_material(args: Dictionary) -> Dictionary:
	var b = _builder()
	var col := _color(VariantTool.get_string(args, "color", "#cccccc"), Color(0.8, 0.8, 0.8))
	var emis := _color(VariantTool.get_string(args, "emission", ""), Color(0, 0, 0))
	var id := b.add_material(col,
		VariantTool.get_float(args, "metal", 0.0),
		VariantTool.get_float(args, "rough", 0.8),
		VariantTool.get_float(args, "hardness", 0.5),
		VariantTool.get_float(args, "mass", 0.5),
		emis)
	return MCPResult.ok_json({"id": id, "material_count": b.material_count()})


static func _box(args: Dictionary) -> Dictionary:
	_default_material()
	_builder().box(_v(args, 0), _v(args, 1), _mat_id(args))
	return _count_result()


static func _line(args: Dictionary) -> Dictionary:
	_default_material()
	_builder().line(_v(args, 0), _v(args, 1), _mat_id(args))
	return _count_result()


static func _ball(args: Dictionary) -> Dictionary:
	_default_material()
	var center := Vector3i(
		VariantTool.get_int(args, "x", 0),
		VariantTool.get_int(args, "y", 0),
		VariantTool.get_int(args, "z", 0))
	_builder().ball(center, VariantTool.get_int(args, "radius", 0), _mat_id(args))
	return _count_result()


static func _put(args: Dictionary) -> Dictionary:
	_default_material()
	var pos := Vector3i(
		VariantTool.get_int(args, "x", 0),
		VariantTool.get_int(args, "y", 0),
		VariantTool.get_int(args, "z", 0))
	_builder().put(pos, _mat_id(args))
	return _count_result()


static func _info(_args: Dictionary) -> Dictionary:
	var b = _builder()
	var vox: Dictionary = b.voxels()
	var lo := Vector3i(1 << 30, 1 << 30, 1 << 30)
	var hi := Vector3i(-(1 << 30), -(1 << 30), -(1 << 30))
	for p in vox:
		var v: Vector3i = p
		lo = Vector3i(mini(lo.x, v.x), mini(lo.y, v.y), mini(lo.z, v.z))
		hi = Vector3i(maxi(hi.x, v.x), maxi(hi.y, v.y), maxi(hi.z, v.z))
	var bounds := {} if vox.is_empty() else {"min": [lo.x, lo.y, lo.z], "max": [hi.x, hi.y, hi.z]}
	return MCPResult.ok_json({"voxel_count": vox.size(), "material_count": b.material_count(), "bounds": bounds})


static func _save(args: Dictionary) -> Dictionary:
	var path := VariantTool.get_string(args, "path", "user://voxel_model.qvx").strip_edges()
	if path.is_empty():
		return MCPResult.fail("path 不能为空")
	var ok := _builder().save(path)
	if not ok:
		return MCPResult.fail("写入失败: %s" % path)
	var size := 0
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		size = f.get_length()
		f.close()
	return MCPResult.ok_json({"path": path, "bytes": size})


# ---------------- 辅助 ----------------

static func _box_schema() -> Dictionary:
	var props := {}
	for k in ["x0", "y0", "z0", "x1", "y1", "z1"]:
		props[k] = {"type": "integer"}
	props["material"] = {"type": "integer", "description": "材质 ID, 缺省=1"}
	return {"type": "object", "properties": props, "required": ["x0", "y0", "z0", "x1", "y1", "z1"]}


static func _v(args: Dictionary, which: int) -> Vector3i:
	var a := "0" if which == 0 else "1"
	return Vector3i(
		VariantTool.get_int(args, "x" + a, 0),
		VariantTool.get_int(args, "y" + a, 0),
		VariantTool.get_int(args, "z" + a, 0))


static func _count_result() -> Dictionary:
	return MCPResult.ok_json({"voxel_count": _builder().voxels().size()})


static func _color(hex: String, fallback: Color) -> Color:
	var s := hex.strip_edges()
	return Color.html(s) if (not s.is_empty() and Color.html_is_valid(s)) else fallback

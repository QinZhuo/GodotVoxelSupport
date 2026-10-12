@tool
extends RefCounted

## ======= 体素**程序化生成** MCP 工具集(项目侧 provider) =======
##
## 由 MCPRuntimeServer 按项目设置 `dev_framework/mcp/runtime_providers` 加载并调用 `register`。
##
## 【只做生成, 不做"模拟人手"】不提供撤销 / 选区 / 复制粘贴 / 移动旋转 / 帧编辑 —— 那些是给人
## 按界面的, 程序化生成用不到。保留: 新建 / 材质 / 画图元 / 查询 / 存盘。
##
## 【统一接口, 而非 N 份并列实现】三条共性各自只收在一处:
##   · 形状入口: 所有图元都走 **voxel_draw(ops)** 一个批量入口;
##   · 形状算法: 一律交给 **VoxelPrimitives**(与编辑器画笔同一份实现);
##   · 落笔目标: 一律走 **`_commit(cells, material)`** —— 有实时 QVoxelier 会话就写它(可见、走它的
##     撤销与渲染), 否则落到无头 `QVoxelBuilder`(可直接存 .qvx)。两条路只在这一处分流。

const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPToolSchema := preload("res://addons/DEVFramework/MCP/MCPToolSchema.gd")

static var _b: QVoxelBuilder = null


static func register(add_tool: Callable) -> void:
	add_tool.call("voxel_reset",
		"新建空模型(仅无头模式; 实时模式请在应用界面里新建)。可选 grid_size / block_size。",
		{"type": "object", "properties": {
			"grid_size": {"type": "integer", "description": "参考网格边长, 默认 32"},
			"block_size": {"type": "integer", "description": "块边长(2 的幂), 默认 32"}
		}}, _reset)
	add_tool.call("voxel_material",
		"追加一个材质, 返回 ID(从 1 起; 0 恒为空气)。color / emission 用 #rrggbb 十六进制。",
		{"type": "object", "properties": {
			"color": MCPToolSchema.str_arg("基色 #rrggbb, 默认 #cccccc"),
			"metal": {"type": "number", "description": "金属度 0..1, 默认 0"},
			"rough": {"type": "number", "description": "粗糙度 0..1, 默认 0.8"},
			"hardness": {"type": "number", "description": "硬度 0..1, 默认 0.5"},
			"mass": {"type": "number", "description": "质量 0..1, 默认 0.5"},
			"emission": MCPToolSchema.str_arg("自发光 #rrggbb, 缺省=不发光")
		}}, _material)
	add_tool.call("voxel_draw",
		"按 ops **批量**生成形状(统一入口)。每项形如 {\"box\":[x0,y0,z0,x1,y1,z1]} 或 {\"line\":[同 box 六数]} 或 {\"ball\":[x,y,z,半径]} 或 {\"put\":[x,y,z]}, 可带 \"material\":ID(缺省 1; 传 0 = 挖空)。返回实际改动格数。",
		{"type": "object", "properties": {
			"ops": {"type": "array", "description": "形状列表(按序应用)", "items": {"type": "object"}}
		}, "required": ["ops"]}, _draw)
	add_tool.call("voxel_info", "当前模型统计(体素数 / 材质数 / 是否实时)。", MCPToolSchema.no_arg(), _info)
	add_tool.call("voxel_save",
		"把当前模型写成 .qvx(含 CRC)。实时应用走应用自身存档; 否则写无头 builder。发布版建议 user:// 路径。返回路径与字节数。",
		{"type": "object", "properties": {
			"path": MCPToolSchema.str_arg("输出路径, 默认 user://voxel_model.qvx")
		}}, _save)


# ---------------- 实现 ----------------

static func _reset(args: Dictionary) -> Dictionary:
	var g := VariantTool.get_int(args, "grid_size", 32)
	var bs := VariantTool.get_int(args, "block_size", 32)
	_b = QVoxelBuilder.new(Vector3i(g, g, g), bs)
	return MCPResult.ok_json({"block_size": bs, "live": false})


static func _material(args: Dictionary) -> Dictionary:
	var col := _color(VariantTool.get_string(args, "color", "#cccccc"), Color(0.8, 0.8, 0.8))
	var metal := VariantTool.get_float(args, "metal", 0.0)
	var rough := VariantTool.get_float(args, "rough", 0.8)
	var sc = _live_scene()
	if sc != null and sc.has_method("script_add_material"):
		return _result({"id": int(sc.call("script_add_material", col, metal, rough))})
	var id := _builder().add_material(col, metal, rough,
		VariantTool.get_float(args, "hardness", 0.5),
		VariantTool.get_float(args, "mass", 0.5),
		_color(VariantTool.get_string(args, "emission", ""), Color(0, 0, 0)))
	return _result({"id": id})


static func _draw(args: Dictionary) -> Dictionary:
	var ops: Variant = args.get("ops", [])
	if not (ops is Array):
		return MCPResult.fail("ops 必须是数组")
	var changed := 0
	for op in (ops as Array):
		if not (op is Dictionary):
			continue
		var d: Dictionary = op
		var cells := _cells_of(d)
		if cells.is_empty():
			continue
		changed += _commit(cells, int(d.get("material", 1)))
	return _result({"changed": changed})


static func _info(_args: Dictionary) -> Dictionary:
	var sc = _live_scene()
	if sc != null and sc.has_method("script_stats"):
		var st: Dictionary = sc.call("script_stats")
		st["live"] = true
		return MCPResult.ok_json(st)
	return MCPResult.ok_json({
		"live": false,
		"voxel_count": _builder().voxels().size(),
		"material_count": _builder().material_count(),
	})


static func _save(args: Dictionary) -> Dictionary:
	var path := VariantTool.get_string(args, "path", "user://voxel_model.qvx").strip_edges()
	if path.is_empty():
		return MCPResult.fail("path 不能为空")
	var sc = _live_scene()
	if sc != null and sc.has_method("script_save"):
		if not bool(sc.call("script_save", path)):
			return MCPResult.fail("实时应用保存失败: %s" % path)
		return _saved(path)
	if not _builder().save(path):
		return MCPResult.fail("写入失败: %s" % path)
	return _saved(path)


# ---------------- 统一内核 ----------------

## 一批格落到**唯一目标**: 有实时会话写它, 否则写无头 builder。返回改动格数。
static func _commit(cells: Array[Vector3i], material: int) -> int:
	if cells.is_empty():
		return 0
	var mat := maxi(material, 0)
	var s = _live_session()
	if s != null:
		return int(s.call("apply_cells", cells, mat))
	var b := _builder()
	while mat > 0 and b.material_count() < mat:
		b.add_material(Color(0.8, 0.8, 0.8))  # 保证引用的材质存在(免得描到未定义材质)
	b.paint(cells, mat)
	return cells.size()


## ops 项 → 格子: box/line/ball/put 四种形状的**唯一**解析处(形状算法在 VoxelPrimitives)。
static func _cells_of(d: Dictionary) -> Array[Vector3i]:
	if d.has("box"):
		var c := _corners(d.get("box"))
		if c.size() == 2:
			return VoxelPrimitives.box(c[0], c[1])
		return [] as Array[Vector3i]
	if d.has("line"):
		var c := _corners(d.get("line"))
		if c.size() == 2:
			return VoxelPrimitives.line(c[0], c[1])
		return [] as Array[Vector3i]
	if d.has("ball"):
		var v: Array = d.get("ball") if d.get("ball") is Array else []
		if v.size() < 4:
			return [] as Array[Vector3i]
		return VoxelPrimitives.ball(Vector3i(int(v[0]), int(v[1]), int(v[2])), int(v[3]))
	if d.has("put"):
		var v: Array = d.get("put") if d.get("put") is Array else []
		if v.size() < 3:
			return [] as Array[Vector3i]
		var one: Array[Vector3i] = [Vector3i(int(v[0]), int(v[1]), int(v[2]))]
		return one
	return [] as Array[Vector3i]


## 六数坐标数组 → 两个角点; 不足六数返回空。
static func _corners(v: Variant) -> Array:
	if not (v is Array) or (v as Array).size() < 6:
		return []
	var a: Array = v
	return [Vector3i(int(a[0]), int(a[1]), int(a[2])), Vector3i(int(a[3]), int(a[4]), int(a[5]))]


# ---------------- 目标 / 辅助 ----------------

static func _builder() -> QVoxelBuilder:
	if _b == null:
		_b = QVoxelBuilder.new()
	return _b


## 正在运行的应用场景(承载实时建模 UI 的那个)。鸭子类型: 只按"有没有 session/script_*"识别,
## 不写 QVoxelierApp 类型 → 编译期不依赖 QVoxelier, 把它排除出包时本文件照样能编译。
static func _live_scene():
	var tree := Engine.get_main_loop() as SceneTree
	return tree.current_scene if tree != null else null


static func _live_session():
	var scene = _live_scene()
	if scene == null:
		return null
	var s = scene.get("session")
	if s != null and s.has_method("apply_cells"):
		return s
	return null


static func _result(d: Dictionary) -> Dictionary:
	d["live"] = _live_session() != null
	return MCPResult.ok_json(d)


static func _saved(path: String) -> Dictionary:
	var size := 0
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		size = f.get_length()
		f.close()
	return _result({"path": path, "bytes": size})


static func _color(hex: String, fallback: Color) -> Color:
	var s := hex.strip_edges()
	return Color.html(s) if (not s.is_empty() and Color.html_is_valid(s)) else fallback

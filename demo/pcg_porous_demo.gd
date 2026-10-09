@tool
extends Node3D

## 单技法场景：SDF 多孔岩（`SdfRepeat` 域重复 + `SdfSubtract` 差集）。
##
## 【这一场景讲的是"用两条 SDF 算子批量挖洞"】
## `SdfRepeat` 把子字段沿各轴以 `spacing` 为周期**无限重复**；把它放进 `SdfSubtract` 的
## 被减项，就成了"按晶格批量挖洞"——洞的数量、大小、排布全由两个参数决定，
## 不需要写一行循环。这正是 SDF 相对"逐体素写循环"的价值：**形状是函数的组合**。
##
## 【三块对照】
##   细孔：spacing 小 → 海绵状密孔。
##   粗孔：spacing 大 → 溶洞状大孔。
##   竖井：复用 `SdfRepeat` 但**只沿 XZ 重复**（Y 轴 spacing 传 0 即不重复），
##         子字段换成圆柱 → 一排竖井。同一算子，换个子字段就是另一种"岩"。
##
## 【一条容易踩的坑】洞要真的通/真的深，得让子字段在 Y 方向足够长或干脆不重复；
## 若三轴都重复且间距大于盒子厚度，减出来的就只是"表面凹坑"。

@export var voxel_scale: float = 0.2
## 加载半径：三块的 chunk 都要落进来。
@export var view_distance: float = 46.0

const GRID := Vector3i(64, 32, 64)

const ROCK_MATERIALS := [
	[1, Color(0.52, 0.5, 0.46), 0.95],
	[2, Color(0.4, 0.5, 0.42), 0.9],   # 苔痕（仅备用）
]


func _ready() -> void:
	_build_porous("Porous_Fine", Vector3(-16.0, 0.0, 0.0), 3.0, Vector3(7.0, 7.0, 7.0))
	_build_porous("Porous_Coarse", Vector3(0.0, 0.0, 0.0), 6.0, Vector3(14.0, 14.0, 14.0))
	_build_bores("Porous_Bores", Vector3(16.0, 0.0, 0.0))
	_setup_camera()
	print("[PCG多孔岩Demo] 细孔 / 粗孔 / 竖井 三块已提交生成")


## 石台减掉"按晶格重复的球" → 成团的孔隙。
func _build_porous(model_name: String, pos: Vector3, radius: float, spacing: Vector3) -> void:
	var holes := SdfSphere.new()
	holes.center = Vector3.ZERO
	holes.radius = radius
	holes.material_id = 1   # 差集只取距离，材质沿用被减项（a），此处值无关紧要

	var lattice := SdfRepeat.new()
	lattice.child = holes
	lattice.spacing = spacing

	_add_carved(model_name, pos, lattice)


## 石台减掉"按晶格重复的竖井" → 一排竖向孔洞。
## spacing.y = 0 表示该轴不重复，于是圆柱在 Y 上保持贯通（否则会被折成一节节的坑）。
func _build_bores(model_name: String, pos: Vector3) -> void:
	var bore := SdfCylinder.new()
	# 圆柱要贯通石台的**整个高度**：石台 y∈[1,31]，故让圆柱覆盖 y∈[-14,46]。
	# 若只让圆柱居中于 0、高 44（y∈[-22,22]），顶面以上 9 体素仍是实心 → 顶面看不到任何孔。
	bore.center = Vector3(0.0, 16.0, 0.0)
	bore.radius = 3.5
	bore.height = 60.0
	bore.material_id = 1

	var lattice := SdfRepeat.new()
	lattice.child = bore
	lattice.spacing = Vector3(11.0, 0.0, 11.0)

	_add_carved(model_name, pos, lattice)


## 公共外壳：长方体石台 ⊖ 传入的洞字段。
func _add_carved(model_name: String, pos: Vector3, holes: Sdf) -> void:
	var block := SdfBox.new()
	block.center = Vector3(32.0, 16.0, 32.0)
	block.size = Vector3(60.0, 30.0, 60.0)
	block.material_id = 1

	var field := SdfSubtract.new()
	field.a = block
	field.b = holes

	var node := PcgSceneKit.add_model(self, model_name, pos, QVoxelModel.of_source(field, GRID), GRID,
			PcgSceneKit.materials(ROCK_MATERIALS), false, voxel_scale)
	(node as VoxelRenderer).view_distance = view_distance


func _setup_camera() -> void:
	var cam := get_node_or_null("Camera3D") as Camera3D
	if cam == null:
		cam = Camera3D.new()
		cam.name = "Camera3D"
		add_child(cam)
	cam.current = true
	cam.fov = 60.0
	cam.far = 400.0
	cam.global_position = Vector3(0.0, 14.0, 32.0)
	cam.look_at(Vector3(0.0, 5.0, 0.0), Vector3.UP)
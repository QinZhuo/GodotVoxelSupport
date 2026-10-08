extends TestCase

## 网格拾取（QVoxGridPick）的契约测试。
##
## 它补的是内核不回答的那半句：新建的模型是空的，而 `VoxelRay` 只在实心格上给命中 ——
## 空图上射线永远打不到东西，第一笔就画不下去。这里钉死四条承诺：
##   ① 体素命中优先：打得到实心格时，地板完全不参与；
##   ② 空图时打在网格底面上，且落笔格正好是底层（hit.y = FLOOR_LAYER、normal = +Y ⇒ +1 格 = y 0）；
##   ③ 边界不糊：平行 / 反向 / 出界 / 超距，一律算没命中（视口据此不建命令）；
##   ④ 与既有约定零特判：地板上的擦除被工具的"越界裁剪"吃掉，表现为没改动、不占撤销单位。
##
## 索引对齐：MAT 是材质 ID，值 0 = 空。

const MAT := 1
const GRID := Vector3i(8, 8, 8)


# ----------------------------------------------------------------------------
# 夹具
# ----------------------------------------------------------------------------

## 会话（含显示层）+ 可选的一批实心格：拾取要读的就是显示层。
func _session(solid := {}) -> QVoxEditSession:
	var w := QVoxWorld.create_empty()
	w.add_material(Color(1, 0, 0)) # ID 1
	var obj := w.create_model("m", GRID)
	var s := QVoxEditSession.create_for(obj, w)
	for p: Vector3i in solid:
		s.data.set_voxel(p, solid[p], false)
	return s


## 打一条竖直向下的射线（相机在地板上方），返回拾取结果。
func _look_down(s: QVoxEditSession, xz := Vector2(2.5, 3.5)) -> Dictionary:
	return QVoxGridPick.hit(s.data, Vector3(xz.x, 5.0, xz.y), Vector3.DOWN, s.output_size())


# ----------------------------------------------------------------------------
# ① 体素命中优先
# ----------------------------------------------------------------------------

func test_voxel_hit_wins_over_the_floor() -> void:
	var s := _session({Vector3i(2, 1, 3): MAT})
	var info := _look_down(s)
	assert_eq(info[VoxelRay.KEY_HIT], Vector3i(2, 1, 3), "打得到实心格时给的是体素命中")
	assert_eq(info[VoxelRay.KEY_NORMAL], Vector3i.DOWN, "法线是入射面（从上方来）")
	assert_eq(info[VoxelRay.KEY_MATERIAL], MAT, "材质来自数据层（面笔/填充要用）")
	assert_ne(info[VoxelRay.KEY_HIT].y, QVoxGridPick.FLOOR_LAYER, "地板不得抢答")


func test_ray_starting_inside_a_solid_voxel_keeps_the_kernel_answer() -> void:
	# 起点就在实心格内：内核明确给 normal = ZERO（"没有入射面"），不得被地板回退掩盖。
	var s := _session({Vector3i(2, 5, 3): MAT})
	var info := QVoxGridPick.hit(s.data, Vector3(2.5, 5.5, 3.5), Vector3.DOWN, s.object.grid_size)
	assert_eq(info[VoxelRay.KEY_HIT], Vector3i(2, 5, 3), "起点所在格即命中格")
	assert_eq(info[VoxelRay.KEY_NORMAL], Vector3i.ZERO, "没有入射面就不编一个出来")
	assert_false(s.pick_from_hit(info).valid(), "无入射面 ⇒ 无处落笔（视口据此不建命令）")


# ----------------------------------------------------------------------------
# ② 空图落在地板上
# ----------------------------------------------------------------------------

func test_empty_grid_lands_on_the_bottom_layer() -> void:
	var s := _session()
	var info := _look_down(s)
	assert_eq(info[VoxelRay.KEY_HIT], Vector3i(2, QVoxGridPick.FLOOR_LAYER, 3), "命中地板层，坐标 = 射线与 y=0 的交点所在列")
	assert_eq(info[VoxelRay.KEY_NORMAL], Vector3i.UP, "法线朝上（落笔格往 +Y 长）")
	assert_eq(info[VoxelRay.KEY_MATERIAL], 0, "地板不是体素，材质为空")


func test_floor_pick_puts_the_first_stroke_on_y_zero() -> void:
	var s := _session()
	var pick := s.pick_from_hit(_look_down(s), false, MAT)
	assert_true(pick.valid(), "空图上也要能落笔 —— 这是这个类存在的理由")
	assert_eq(pick.place, Vector3i(2, 0, 3), "落笔格 = 底层格子")
	assert_true(s.begin(pick), "手势起笔")
	assert_true(s.release(), "空图上的第一笔必须真的写下去")
	assert_eq(s.object.get_voxel(2, 0, 3), MAT, "对象上落到了底层")
	assert_true(s.can_undo(), "这一笔占一个撤销单位")


# ----------------------------------------------------------------------------
# ③ 边界不糊
# ----------------------------------------------------------------------------

func test_floor_outside_the_grid_is_not_a_hit() -> void:
	var s := _session()
	assert_true(_look_down(s, Vector2(-0.5, 3.5)).is_empty(), "网格左外侧：不该落笔（留白是留白）")
	assert_true(_look_down(s, Vector2(7.5, 3.5)).has(VoxelRay.KEY_HIT), "最后一列（7）在网格内")
	assert_true(_look_down(s, Vector2(8.5, 3.5)).is_empty(), "越过后一列就不在网格里了")
	assert_true(_look_down(s, Vector2(2.5, -0.5)).is_empty(), "z 方向同理")


func test_parallel_or_upward_rays_never_hit_the_floor() -> void:
	var s := _session()
	var g := s.object.grid_size
	assert_true(QVoxGridPick.hit(s.data, Vector3(2.5, 5, 3.5), Vector3.RIGHT, g).is_empty(),
		"与地板平行的射线：永不相交")
	assert_true(QVoxGridPick.hit(s.data, Vector3(2.5, 5, 3.5), Vector3.UP, g).is_empty(),
		"朝上的射线交点在反向延长线上（t < 0）")
	assert_true(QVoxGridPick.hit(s.data, Vector3(2.5, -5, 3.5), Vector3.DOWN, g).is_empty(),
		"从地板下方朝下打：t < 0")


func test_floor_respects_max_distance() -> void:
	var s := _session()
	var g := s.object.grid_size
	assert_true(QVoxGridPick.hit(s.data, Vector3(2.5, 50, 3.5), Vector3.DOWN, g, 100.0).has(VoxelRay.KEY_HIT),
		"50 格内看得见地板")
	assert_true(QVoxGridPick.hit(s.data, Vector3(2.5, 500, 3.5), Vector3.DOWN, g, 100.0).is_empty(),
		"超出 max_distance 就不算命中（和内核同一条距离约定）")


func test_zero_grid_has_no_floor() -> void:
	var s := _session()
	assert_true(QVoxGridPick.hit(s.data, Vector3(2.5, 5, 3.5), Vector3.DOWN, Vector3i.ZERO).is_empty(),
		"没有网格尺寸就无从判断地板覆盖到哪，不猜")


# ----------------------------------------------------------------------------
# ④ 与既有约定零特判
# ----------------------------------------------------------------------------

func test_erasing_on_the_floor_writes_nothing() -> void:
	# 擦除的落笔格 = 命中格本身 = 地板层（网格外）→ 工具的越界裁剪吃掉它。
	# 于是"空图上右键"既不报错也不占撤销单位 —— 不需要为地板写任何擦除特判。
	var s := _session()
	var pick := s.pick_from_hit(_look_down(s), true, MAT)
	assert_true(pick.valid(), "手势能起笔（右键不会像失灵）")
	assert_true(s.begin(pick), "起笔成功")
	assert_false(s.release(), "没东西可擦：不算改动")
	assert_false(s.can_undo(), "空手势不入撤销栈")


func test_brush_paints_on_the_floor_with_the_current_material() -> void:
	var s := _session()
	s.tool.brush_size = 2
	var pick := s.pick_from_hit(_look_down(s), false, MAT)
	s.begin(pick)
	s.release()
	# 笔刷尺寸 2 ⇒ 以落笔格为中心、半径 1 的球（欧氏）；网格内应出现一片底层格子。
	assert_eq(s.object.get_voxel(2, 0, 3), MAT, "中心格必在")
	assert_eq(s.object.get_voxel(3, 0, 3), MAT, "加粗到邻近列（底层仍是 y = 0）")
	assert_eq(s.object.get_voxel(2, -1, 3), 0, "越界那一格被丢弃：地板上不会写出网格外的体素")

extends TestCase

## 工程文件（`QVoxelProject`）的契约测试 —— **世界 ⇄ 字节 ⇄ 磁盘** 这一段接线。
## 为什么值得单独钉：这一段是"看着能跑、其实在丢东西"的重灾区。插件侧的序列化本身有测试
## （`test_world_engineering_data_roundtrip`），但"编好字节之后有没有原样落到盘上、读回来
## 还是不是同一份世界、写坏了能不能退回上一版"是**应用层新加的一环**，不测就是靠信仰。
## 钉三件事：
##   ① 往返不丢：体素 / 网格尺寸 / 材质 / 相机 / 节点树（组 + 组内坐标 + 链上的条目）—— 存了再读必须一模一样；
##   ② 落盘走 `SaveTool`（原子写 + 滚动备份），所以主档损坏还能退回上一次的存档；
##   ③ 坏输入一律返回 null：视口据此提示用户，而不是半路换掉正在编辑的东西。

const DIR := "user://qvoxelier_project_test"
const MAIN := DIR + "/a.qvx"

## 本用例写过的路径，cleanup 里无条件清掉。
var _paths: Array[String] = []


## 收尾（每个 test_ 之后无条件调用，必须幂等）：写盘用例绝不能在 user:// 里留垃圾。
func cleanup() -> void:
	for p in _paths:
		_remove(p)
	_paths.clear()
	for i in range(1, SaveTool.MAX_BACKUPS + 1):
		_remove("%s.%d.bak" % [MAIN, i])
	_remove(MAIN)
	_remove(MAIN + ".tmp")
	DirAccess.remove_absolute(DIR)


# 夹具

## 一份"每个维度都有东西"的世界：体素、材质、相机、组、对象名、链上的摆放与条目。
## 单测一个空世界会漏掉"存了但读回是空"的假绿。
func _world() -> QVoxelWorld:
	var w := QVoxelWorld.create_empty()
	w.set_world_name("测试世界")
	var m1 := w.add_material(Color(1.0, 0.0, 0.0))
	w.add_material(Color(0.0, 1.0, 0.0))
	# PBR 标量也要过一遍存档：MATE 把自发光存成 e_r/e_g/e_b，属"看着能存、读回变味"的高危字段。
	w.set_material_scalar(m1, &"metal", 0.5)
	w.set_material_scalar(m1, &"rough", 0.25)
	w.add_camera("主视角")
	var g := w.create_group("组一")
	var obj := w.create_model("方块", Vector3i(16, 16, 16), g)
	# 组内坐标不再挂在节点上：它是一条平移条目（见 PcgTransform 类头）
	obj.add_modifier(QVoxelTransformModifier.of(PcgTransform.translate(Vector3i(2, 0, 0))))
	obj.add_modifier(QVoxelTransformModifier.of(PcgTransform.repeat(0, 2)))
	obj.set_voxel(1, 2, 3, 1)
	obj.set_voxel(4, 0, 0, 2)
	return w


func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


# 用例

func test_round_trip_keeps_the_world() -> void:
	var w := _world()
	var back := QVoxelProject.decode(QVoxelProject.encode(w))
	assert_ne(back, null, "编成字节再读回来不该是 null")
	if back == null:
		return

	assert_eq(back.world_name(), "测试世界", "世界名")
	assert_eq(back.materials.size(), w.materials.size(), "材质数")
	assert_eq(back.material_scalar(1, &"metal"), w.material_scalar(1, &"metal"), "金属度存活")
	assert_eq(back.material_scalar(1, &"rough"), w.material_scalar(1, &"rough"), "粗糙度存活")
	assert_eq(back.cameras().size(), w.cameras().size(), "相机数")
	assert_eq(back.nodes.size(), 1, "顶层只有那个组（模型是它的子节点，不是平级）")
	assert_eq(back.all_models().size(), 1, "模型数")

	var obj := back.all_models()[0]
	assert_eq(obj.node_name, "方块", "对象名")
	assert_eq(obj.grid_size, Vector3i(16, 16, 16), "网格尺寸")
	assert_eq(obj.modifiers.size(), 2, "链上的条目")
	var place := (obj.modifiers[0] as QVoxelTransformModifier).transform
	assert_eq(place.mode, PcgTransform.Mode.TRANSLATE, "组内坐标是链上的平移条目")
	assert_eq(place.offset, Vector3i(2, 0, 0), "组内坐标存活")
	assert_eq(obj.count_solid(), 2, "实心格数")
	assert_eq(obj.get_voxel(1, 2, 3), 1, "第一笔的体素与材质")
	assert_eq(obj.get_voxel(4, 0, 0), 2, "第二笔的体素与材质")


## 材质 PBR 标量（金属度 / 粗糙度 / 自发光）：写进去的强度必须原样读回来。
## 【为什么自发光要单独盯】MATE 把自发光存成 `e_r/e_g/e_b` 三个字节（发光颜色），单通道强度只能
## 从它还原。若照"基色 × 强度"写，读回会再乘一遍基色亮度（本例基色最大分量只有 0.8），滑条一松手
## 就跳值。这条断言钉住"读回 == 写入"，也钉住渲染侧（`VoxelMaterial.from_mate`）看到同一强度。
func test_material_pbr_scalars_round_trip() -> void:
	var w := QVoxelWorld.create_empty()
	var id := w.add_material(Color(0.8, 0.4, 0.2))
	var before := w.material_color(id)
	w.set_material_scalar(id, &"metal", 0.5)
	w.set_material_scalar(id, &"rough", 0.25)
	w.set_material_scalar(id, &"emission", 0.6)
	assert_eq(w.material_scalar(id, &"metal"), 128.0 / 255.0, "金属度：写 0.5 读回 128/255")
	assert_eq(w.material_scalar(id, &"rough"), 64.0 / 255.0, "粗糙度：写 0.25 读回 64/255")
	assert_eq(w.material_scalar(id, &"emission"), 153.0 / 255.0,
		"自发光：基色最大分量只有 0.8，仍要读回 0.6（= 153/255）")
	assert_eq(w.material_color(id), before, "写 PBR 不该动到基色")
	assert_eq(VoxelMaterial.from_mate(w.materials[id], id).emission, 153.0 / 255.0,
		"渲染侧（from_mate）看到同一强度 —— UI 滑条与画面不会各说各话")


func test_save_then_load_lands_on_disk() -> void:
	_paths.append(MAIN)
	assert_eq(QVoxelProject.save(_world(), MAIN), OK, "落盘成功")
	assert_true(FileAccess.file_exists(MAIN), "文件真的写出来了")

	var back := QVoxelProject.load_world(MAIN)
	assert_ne(back, null, "读得回来")
	if back == null:
		return
	assert_eq(back.world_name(), "测试世界", "世界名")
	assert_eq(back.all_models()[0].get_voxel(1, 2, 3), 1, "体素在")
	assert_eq(back.all_models()[0].count_solid(), 2, "实心格数")


func test_saving_nothing_is_refused() -> void:
	assert_eq(QVoxelProject.save(null, MAIN), ERR_INVALID_PARAMETER, "没有世界就不该写盘")
	assert_eq(QVoxelProject.save(_world(), ""), ERR_INVALID_PARAMETER, "没有路径就不该写盘")
	assert_false(FileAccess.file_exists(MAIN), "以上两种都不该留下文件")
	assert_eq(QVoxelProject.encode(null), PackedByteArray(), "空世界的编码是空字节")


func test_missing_or_empty_input_is_null() -> void:
	assert_eq(QVoxelProject.load_world(DIR + "/never_written.qvx"), null, "文件不存在 ⇒ null")
	assert_eq(QVoxelProject.load_world(""), null, "空路径 ⇒ null")
	assert_eq(QVoxelProject.decode(PackedByteArray()), null, "空字节 ⇒ null")


## 坏字节不能让应用崩。这里会打出一行引擎错误日志 —— 那是插件故意的 FATAL 记录
## （`QVoxelFile._flush_fatal`），正是"不崩、只返回 null"这条路径的证明，不是用例出错了。
func test_garbage_bytes_are_rejected() -> void:
	_paths.append(MAIN)
	DirAccess.make_dir_recursive_absolute(DIR)
	var f := FileAccess.open(MAIN, FileAccess.WRITE)
	f.store_buffer("这不是一个 qvx 文件".to_utf8_buffer())
	f.close()
	assert_eq(QVoxelProject.load_world(MAIN), null, "垃圾字节 ⇒ null")
	assert_eq(QVoxelProject.decode("不是 qvox".to_utf8_buffer()), null, "垃圾字节 ⇒ null")


## 主档损坏必须能退回上一次的存档 —— 这是"原子写 + 滚动备份"存在的全部理由。
func test_corrupt_main_falls_back_to_backup() -> void:
	_paths.append(MAIN)
	assert_eq(QVoxelProject.save(_world(), MAIN), OK, "第一版落盘")

	var second := _world()
	second.set_world_name("第二版")
	second.all_models()[0].set_voxel(7, 7, 7, 1)
	assert_eq(QVoxelProject.save(second, MAIN), OK, "第二版落盘（第一版被滚成 .1.bak）")
	assert_true(FileAccess.file_exists(MAIN + ".1.bak"), "滚动备份确实生成了")

	var f := FileAccess.open(MAIN, FileAccess.WRITE)
	f.store_buffer("写坏了".to_utf8_buffer())
	f.close()

	var back := QVoxelProject.load_world(MAIN)
	assert_ne(back, null, "主档坏了要能退回备份，而不是报 null")
	if back == null:
		return
	assert_eq(back.world_name(), "测试世界", "退回的是第一版")
	assert_eq(back.all_models()[0].get_voxel(7, 7, 7), 0, "第二版那一笔不该出现在退回的版本里")


func test_extension_helpers() -> void:
	assert_true(QVoxelProject.is_project_path("a/b/c.qvx"), "小写后缀")
	assert_true(QVoxelProject.is_project_path("C:/tmp/C.QVX"), "大写后缀也要认")
	assert_false(QVoxelProject.is_project_path("a/b/c.vox"), ".vox 不是工程文件")
	assert_false(QVoxelProject.is_project_path("a/b/c"), "没有后缀不算")
	assert_eq(QVoxelProject.ensure_extension("a/b/c"), "a/b/c.qvx", "缺后缀要补上")
	assert_eq(QVoxelProject.ensure_extension("a/b/c.qvx"), "a/b/c.qvx", "已有后缀不动它")

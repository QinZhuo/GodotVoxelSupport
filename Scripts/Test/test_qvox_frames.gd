extends TestCase

## QVX 帧动画（§12）链路测试：FRAM 从资产读取 → 导入器切帧 → 编辑器帧结构编辑与撤销。
##
## 钉死四件事 —— 每一条都对应"FRAM 落地后很容易悄悄弄坏"的点：
##   ① 帧是**入参 / 静态快照**，不是隐藏状态：同一份资产按 frame 取出不同世界，
##      且包围盒 / 原点**逐帧各算**（第 k 帧才长出的部分不会整体偏移）；
##   ② 一个 model_id 只有一个体素源（VXEL XOR FRAM，§12.2）：静态 ⇄ 动画的切换必须原子，
##      撤销到一半绝不能出现"两个源都非空"（那是序列化期的 FATAL 文件）；
##   ③ 撤销记住"改的是第几帧"，**与当前预览游标无关**（切帧后撤销不得改错帧）；
##   ④ 逐帧导出（frame_index / split_by_frame）真的按帧产出，而不是静默退化成按模型。
##
## 索引对齐：MAT 是材质 ID，值 0 = 空。

const TEST_DIR := "user://qvx_frames_test"
const MAT := 1
const BLOCK_KEY := Vector3i(0, 0, 0)


func cleanup() -> void:
	_remove_dir(TEST_DIR)


# ----------------------------------------------------------------------------
# ① 资产读取：帧数 / 元数据 / 逐帧查询
# ----------------------------------------------------------------------------

func test_asset_exposes_frames_and_metadata() -> void:
	var path := TEST_DIR + "/anim_meta.qvx"
	_write_animated_qvx(path, [
		{"cells": [Vector3i(1, 1, 1)], "duration_ms": 100},
		{"cells": [Vector3i(1, 1, 1), Vector3i(1, 9, 1)], "duration_ms": 120},
	], {}, {"loop": false, "fps": 8, "tags": [{"name": "walk", "from": 0, "to": 1}]})
	var qvx := QVoxelAsset.from_file(path)
	assert_true(qvx != null, "应能解析 FRAM 文件")
	if qvx == null:
		return
	assert_true(qvx.is_animated(0), "model_id=0 应是动画")
	assert_false(qvx.is_animated(1), "不存在的 model 不是动画")
	assert_eq(qvx.frame_count(0), 2, "两帧")
	assert_eq(qvx.total_frame_count(), 2, "整资产可切 2 帧")
	assert_eq(qvx.all_model_ids().size(), 1, "动画模型也要进 all_model_ids（摆放枚举读它）")
	assert_eq(qvx.all_model_ids()[0], 0, "动画模型的 id 正确")

	var anim := qvx.animation_of(0)
	assert_eq(bool(anim.get("loop", true)), false, "loop 元数据应透传")
	assert_eq(int(anim.get("fps", 0)), 8, "fps 元数据应透传")
	assert_eq((anim.get("tags", []) as Array).size(), 1, "tags 元数据应透传")


func test_static_asset_has_one_frame_and_ignores_frame() -> void:
	var path := TEST_DIR + "/static.qvx"
	_write_static_qvx(path)
	var qvx := QVoxelAsset.from_file(path)
	assert_true(qvx != null, "应能解析静态 .qvx")
	if qvx == null:
		return
	assert_eq(qvx.total_frame_count(), 1, "全静态资产 = 只有一帧")
	assert_false(qvx.is_animated(0), "静态模型不是动画")
	assert_eq(qvx.frame_count(0), 0, "静态模型没有帧")
	# 静态模型传任何 frame 都给出同一份块表：调用方不必先判有没有动画
	assert_eq(qvx.frame_blocks(0, 0), qvx.frame_blocks(0, 7), "静态模型忽略 frame")
	assert_eq(qvx.block_buffers(0), qvx.block_buffers(5), "block_buffers 对静态资产忽略 frame")


func test_frame_blocks_out_of_range_is_empty_not_clamped() -> void:
	var path := TEST_DIR + "/range.qvx"
	_write_animated_qvx(path, [
		{"cells": [Vector3i(1, 1, 1)]},
		{"cells": [Vector3i(1, 1, 1), Vector3i(1, 9, 1)]},
	])
	var qvx := QVoxelAsset.from_file(path)
	if qvx == null:
		return
	# 越界返回空（不 clamp）：把"播到头了"与"帧号算错了"区分开是调用方的事（播放器才懂 loop）
	assert_true(qvx.frame_blocks(0, 2).is_empty(), "越界帧返回空块表")
	assert_true(qvx.frame_blocks(0, -1).is_empty(), "负帧返回空块表")
	assert_eq(qvx.voxel_count(0), 1, "帧 0 只有 1 个体素")
	assert_eq(qvx.voxel_count(1), 2, "帧 1 有 2 个体素")
	assert_eq(qvx.voxel_count(2), 0, "越界帧没有体素")


# ----------------------------------------------------------------------------
# ② 包围盒 / 原点 / 融合：都随帧变
# ----------------------------------------------------------------------------

func test_bounds_grid_and_origin_vary_per_frame() -> void:
	var path := TEST_DIR + "/bounds.qvx"
	_write_animated_qvx(path, [
		{"cells": [Vector3i(1, 1, 1)]},
		{"cells": [Vector3i(1, 1, 1), Vector3i(1, 9, 1)]},
	])
	var qvx := QVoxelAsset.from_file(path)
	if qvx == null:
		return
	assert_eq(qvx.grid_size(0), Vector3i(1, 1, 1), "帧 0 的包围盒尺寸")
	assert_eq(qvx.grid_size(1), Vector3i(1, 9, 1), "帧 1 的包围盒随内容变高")
	var o0 := qvx.origin_offset(QVoxelSource.OriginMode.CONTENT_CENTER, 0)
	var o1 := qvx.origin_offset(QVoxelSource.OriginMode.CONTENT_CENTER, 1)
	assert_ne(o0, o1, "原点由包围盒导出，必须逐帧各算（否则第 1 帧整体偏移）")


func test_fused_path_applies_placement_per_frame() -> void:
	var path := TEST_DIR + "/fused.qvx"
	_write_animated_qvx(path, [
		{"cells": [Vector3i(1, 1, 1)]},
		{"cells": [Vector3i(1, 1, 1), Vector3i(1, 9, 1)]},
	], {"t": [0, 32, 0]})
	var qvx := QVoxelAsset.from_file(path)
	if qvx == null:
		return
	assert_false(qvx.is_block_importable(), "带位移必须走逐体素融合路径")
	var f0 := qvx.fused_voxels(0)
	assert_true(f0.has(Vector3i(1, 33, 1)), "帧 0：模型内 (1,1,1) + 位移 (0,32,0)")
	assert_false(f0.has(Vector3i(1, 41, 1)), "帧 0 还没有长出来的体素")
	var f1 := qvx.fused_voxels(1)
	assert_true(f1.has(Vector3i(1, 41, 1)), "帧 1 才长出的体素也要应用位移")
	assert_eq(qvx.voxel_count(0), 1, "帧 0 融合后 1 个体素")
	assert_eq(qvx.voxel_count(1), 2, "帧 1 融合后 2 个体素")


# ----------------------------------------------------------------------------
# ③ 导入器：QVoxelSource 快照 / 逐帧 MeshLibrary
# ----------------------------------------------------------------------------

func test_voxel_data_snapshot_per_frame() -> void:
	var path := TEST_DIR + "/data.qvx"
	_write_animated_qvx(path, [
		{"cells": [Vector3i(1, 1, 1)]},
		{"cells": [Vector3i(1, 1, 1), Vector3i(1, 9, 1)]},
	])
	var qvx := QVoxelAsset.from_file(path)
	if qvx == null:
		return
	var mode := QVoxelSource.OriginMode.CONTENT_CENTER
	var d0 := QVoxelSource.from_qvx(qvx, mode, 0)
	var d1 := QVoxelSource.from_qvx(qvx, mode, 1)
	assert_eq(d0.get_voxel_count(), 1, "帧 0 快照 1 个体素")
	assert_eq(d1.get_voxel_count(), 2, "帧 1 快照 2 个体素")
	assert_true(d0.has_voxel(Vector3i(1, 1, 1)), "帧 0 含 (1,1,1)")
	assert_false(d0.has_voxel(Vector3i(1, 9, 1)), "帧 0 不含帧 1 才长出的体素")
	assert_true(d1.has_voxel(Vector3i(1, 9, 1)), "帧 1 含 (1,9,1)")
	assert_eq(d1.grid_size, qvx.grid_size(1), "grid_size 按帧取包围盒")
	assert_eq(d1.center_offset, qvx.origin_offset(mode, 1), "center_offset 按帧算原点")
	assert_ne(d1.center_offset, d0.center_offset,
			"同一资产两帧的原点必须不同（否则第 1 帧整体偏移）")


func test_mesh_library_split_by_frame_names_each_frame() -> void:
	var path := TEST_DIR + "/split.qvx"
	_write_animated_qvx(path, [
		{"cells": [Vector3i(1, 1, 1)]},
		{"cells": [Vector3i(1, 1, 1), Vector3i(1, 9, 1)]},
	])
	var qvx := QVoxelAsset.from_file(path)
	if qvx == null:
		return
	var opts := _mesh_options()
	opts[VoxelMeshLibraryImporter.mesh_mode] = VoxelMeshLibraryImporter.MeshMode.split_by_frame
	var lib := VoxelMeshGenerator.generate_mesh_library_from_qvx(qvx, opts, "")
	assert_true(lib != null, "应能生成 MeshLibrary")
	if lib == null:
		return
	assert_eq(lib.get_item_list().size(), 2, "逐帧应得 2 项（而不是静默退化成 1 个模型项）")
	assert_eq(lib.get_item_name(0), "frame_0", "第 0 帧项名")
	assert_eq(lib.get_item_name(1), "frame_1", "第 1 帧项名")


func test_mesh_library_model_split_follows_frame_index() -> void:
	var path := TEST_DIR + "/model_frame.qvx"
	_write_animated_qvx(path, [
		{"cells": [Vector3i(1, 1, 1)]},
		{"cells": [Vector3i(1, 1, 1), Vector3i(1, 9, 1)]},
	])
	var qvx := QVoxelAsset.from_file(path)
	if qvx == null:
		return
	var opts := _mesh_options()
	opts[VoxelMeshLibraryImporter.mesh_mode] = VoxelMeshLibraryImporter.MeshMode.split_by_model
	opts[VoxelMeshImporter.frame_index] = 0
	var lib0 := VoxelMeshGenerator.generate_mesh_library_from_qvx(qvx, opts, "")
	opts[VoxelMeshImporter.frame_index] = 1
	var lib1 := VoxelMeshGenerator.generate_mesh_library_from_qvx(qvx, opts, "")
	assert_eq(lib0.get_item_list().size(), 1, "按模型分项：动画模型也要出一项（走 all_model_ids）")
	assert_eq(lib0.get_item_name(0), "model_0", "项名带 model_id")
	var a0: AABB = lib0.get_item_mesh(0).get_aabb()
	var a1: AABB = lib1.get_item_mesh(0).get_aabb()
	assert_true(a1.size.y > a0.size.y + 0.01,
			"frame_index=1 应导出更高的网格（第 1 帧才长出的体素），实得 %.3f vs %.3f"
			% [a1.size.y, a0.size.y])


# ----------------------------------------------------------------------------
# ④ 撤销：帧号随命令走，不随游标
# ----------------------------------------------------------------------------

func test_edit_command_remembers_its_frame() -> void:
	var obj := _animated_model()
	assert_eq(obj.frame_count(), 2, "夹具应有 2 帧")

	var cmd := QVoxelEditCommand.begin(obj, 1)
	assert_true(cmd.set_voxel(2, 2, 2, MAT), "第 1 帧落笔应写入")
	assert_true(cmd.commit(), "有真实改动 → 入栈")
	assert_eq(cmd.edited_frame(), 1, "命令记住改的是第 1 帧")
	assert_true(cmd.get_label().contains("第 1 帧"), "撤销菜单要能看出改的是哪一帧")

	# 用户在落笔后把预览游标切到第 0 帧，再撤销 —— 必须只回滚第 1 帧
	obj.active_frame = 0
	cmd.undo()
	assert_eq(obj.frames[1].blocks.size(), 0, "第 1 帧的笔迹被回滚（空块被回收）")
	assert_eq(obj.frames[0].blocks.size(), 1, "第 0 帧纹丝不动（撤销不跟着游标走）")
	cmd.redo()
	assert_eq(obj.get_frame_block(1, BLOCK_KEY).size(), VoxelChunk.CHUNK_VOLUME,
			"重做把块写回第 1 帧")
	assert_eq(obj.get_voxel(2, 2, 2), 0,
			"重做后 active_frame=0，读的是第 0 帧 → 看不到第 1 帧的笔迹（读写游标一致）")


# ----------------------------------------------------------------------------
# ⑤ 属性命令 extras：静态 ⇄ 动画的两个源同生共死
# ----------------------------------------------------------------------------

func test_property_command_extras_keep_sources_in_sync() -> void:
	var obj := QVoxelModel.new()
	obj.grid_size = Vector3i(32, 32, 32)
	obj.set_voxel(3, 3, 3, MAT)
	assert_false(obj.is_animated(), "初始是静态模型")

	# "静态 → 动画"必须同时改 frames 与 blocks 两个字段，故 extras 必须一起入栈
	var cmd := QVoxelPropertyCommand.begin(obj, &"frames")
	cmd.also_write(obj, &"blocks")
	obj.make_animated()   # 静态内容搬进第 0 帧，静态源清空
	assert_true(cmd.commit(), "帧数组或静态源真变了 → 入栈")

	# 提交后：恰好一个体素源（§12.2）
	assert_eq(obj.frames.size(), 1, "动画生效")
	assert_true(obj.blocks.is_empty(), "动画生效即静态源让位")
	assert_eq(obj.get_voxel(3, 3, 3), MAT, "体素搬进了第 0 帧，内容不丢")

	# 撤销：两个字段必须**同时**回到静态态，绝不留"VXEL + FRAM 并存"的中间态
	cmd.undo()
	assert_eq(obj.frames.size(), 0, "撤销回到静态（帧数组清空）")
	assert_eq(obj.blocks.size(), 1, "静态源被还原（extras 一起生效）")
	assert_false(obj.is_animated(), "撤销后是合法静态模型，不是并存态")
	assert_eq(obj.get_voxel(3, 3, 3), MAT, "静态内容完好")

	# 重做回到动画态
	cmd.redo()
	assert_eq(obj.frames.size(), 1, "重做恢复动画")
	assert_true(obj.blocks.is_empty(), "重做同样清空静态源")


# ----------------------------------------------------------------------------
# ⑥ 模型帧结构编辑入口
# ----------------------------------------------------------------------------

func test_model_frame_edit_entries() -> void:
	var obj := QVoxelModel.new()
	obj.grid_size = Vector3i(32, 32, 32)
	obj.set_voxel(3, 3, 3, MAT)
	assert_false(obj.is_animated(), "初始静态")

	# 静态 → 动画：现有内容原样搬进第 0 帧，零拷贝（字典换持有者）
	var f0 := obj.make_animated()
	assert_ne(f0, null, "首次搬迁应返回第 0 帧")
	assert_true(obj.is_animated(), "变成动画")
	assert_true(obj.blocks.is_empty(), "静态源让位")
	assert_eq(obj.frame_count(), 1, "搬迁后 1 帧")
	assert_true(obj.make_animated() == null, "已是动画时不再搬迁（否则会覆盖帧内容）")

	# 追加 / 插入
	assert_eq(obj.add_frame(QVoxelFrame.new()), 1, "追加到末尾，返回落点下标")
	assert_eq(obj.add_frame(QVoxelFrame.new(), 0), 0, "插入到开头")
	assert_eq(obj.frame_count(), 3, "共 3 帧")
	assert_eq(obj.add_frame(null), -1, "null 帧不入表")

	# 帧游标：动画模型夹取（越界写回静态源会造出 FATAL 文件）
	assert_eq(obj.blocks_for(99), obj.frames[2].blocks, "越界夹到最后一帧")
	assert_eq(obj.blocks_for(-5), obj.frames[0].blocks, "负帧夹到第一帧")
	obj.active_frame = 99
	assert_eq(obj.source_blocks(), obj.frames[2].blocks, "读路径游标同样夹取")

	# 删除：最后一帧不删（删掉会退回静态，而静态源是空的 → 静默清空内容）
	assert_false(obj.remove_frame(9), "越界删除无效")
	assert_true(obj.remove_frame(0), "删掉第 0 帧")
	assert_eq(obj.frame_count(), 2, "剩 2 帧")
	assert_true(obj.remove_frame(0), "再删一帧")
	assert_false(obj.remove_frame(0), "最后一帧不删")

	# 重排
	obj.add_frame(QVoxelFrame.new())
	assert_eq(obj.frame_count(), 2, "重新补到 2 帧")
	assert_true(obj.move_frame(0, 1), "重排有效")
	assert_false(obj.move_frame(0, 0), "原地不动无效")
	assert_false(obj.move_frame(-1, 0), "越界无效")


func test_static_model_ignores_frame_in_model() -> void:
	var obj := QVoxelModel.new()
	obj.set_voxel(1, 1, 1, MAT)
	assert_eq(obj.blocks_for(5), obj.blocks, "静态模型 blocks_for 恒返回静态源")
	assert_eq(obj.source_blocks(), obj.blocks, "静态模型 source_blocks 恒返回静态源")


# ----------------------------------------------------------------------------
# ⑦ 世界往返：frames / anim 元数据 / require 声明
# ----------------------------------------------------------------------------

func test_world_roundtrip_preserves_frames_and_anim() -> void:
	var w := QVoxelWorld.create_empty()
	w.add_material(Color(1, 0, 0))
	var m := w.create_model("m", Vector3i(32, 32, 32))
	m.set_voxel(1, 1, 1, MAT)
	m.make_animated()
	var f1 := QVoxelFrame.new()
	f1.duration_ms = 120
	m.add_frame(f1)
	m.anim_loop = false
	m.anim_fps = 8
	m.anim_tags = [{"name": "walk", "from": 0, "to": 1}]

	var doc := w.to_document()
	assert_true(doc.frames.has(m.model_id), "动画模型进 frames")
	assert_false(doc.models.has(m.model_id), "同一 model_id 不得同时进 models（§12.2）")
	assert_true((doc.head.get("require", []) as Array).has(QVoxelSpec.BLOCK_FRAM),
			"含 FRAM 的文件必须声明 require（旧读者 fail-fast）")

	var rep := QVoxelFile.QVoxelReport.new()
	var parsed: QVoxelFile.QVoxelDocument = QVoxelFile.parse(
			QVoxelFile.serialize(doc), true, rep, true)
	assert_true(parsed != null and rep.ok(), "往返解析应成功（%s）" % rep.summary())
	if parsed == null:
		return
	var w2 := QVoxelWorld.from_document(parsed)
	var m2 := w2.find_model(m.model_id)
	assert_true(m2 != null, "应找回模型")
	if m2 == null:
		return
	assert_true(m2.is_animated(), "往返后仍是动画")
	assert_eq(m2.frame_count(), 2, "帧数不变")
	assert_eq(m2.frames[1].duration_ms, 120, "逐帧时长不变")
	assert_true(m2.blocks.is_empty(), "动画模型不读静态源")
	assert_false(m2.anim_loop, "loop 元数据往返")
	assert_eq(m2.anim_fps, 8, "fps 元数据往返")
	assert_eq(m2.anim_tags.size(), 1, "tags 元数据往返")
	assert_eq(m2.get_voxel(1, 1, 1), MAT, "第 0 帧的体素往返")


func test_world_static_roundtrip_does_not_declare_fram() -> void:
	var w := QVoxelWorld.create_empty()
	w.add_material(Color(0, 0, 1))
	var m := w.create_model("s", Vector3i(32, 32, 32))
	m.set_voxel(1, 1, 1, MAT)
	var doc := w.to_document()
	assert_true(doc.models.has(m.model_id), "静态模型进 models")
	assert_false(doc.frames.has(m.model_id), "静态模型不进 frames")
	assert_false((doc.head.get("require", []) as Array).has(QVoxelSpec.BLOCK_FRAM),
			"全静态文件不声明 FRAM（免得老读者白白拒掉本可读的文件）")


# ----------------------------------------------------------------------------
# ⑧ 播放内核：纯逻辑，直接喂 delta
# ----------------------------------------------------------------------------

## 内核现在是编辑器预览与运行时播放器**共用**的唯一循环实现，所以它错了两个消费者会一起错；
## 而"预览看着像在播"几乎暴露不出问题。它是纯逻辑，喂 delta 即可驱动，不必起场景树。
func test_clock_forward_loop_wraps_by_duration() -> void:
	var c := QVoxelFrameClock.new()
	c.configure(_durations([100, 200, 300]), 12, true)
	assert_eq(c.count(), 3, "3 帧")
	c.play()
	assert_true(c.is_playing(), "3 帧可播")
	assert_eq(c.index(), 0, "从第 0 帧起")
	assert_eq(c.delay_ms(), 100, "首帧到期待 100ms")
	assert_false(c.advance(99), "不足一帧不该换帧")
	assert_true(c.advance(1), "补满 100ms 换帧")
	assert_eq(c.index(), 1, "第 1 帧")
	assert_true(c.advance(200), "第 1 帧自己的 200ms")
	assert_eq(c.index(), 2, "第 2 帧")
	assert_true(c.advance(300), "第 2 帧自己的 300ms")
	assert_eq(c.index(), 0, "循环回到第 0 帧")


## 逐帧时长为 0 = 跟随帧率（§12.3）。这个兜底以前在编辑器面板里有一份，现在只有这一份。
func test_clock_falls_back_to_fps_when_duration_is_zero() -> void:
	var c := QVoxelFrameClock.new()
	c.configure(_durations([0, 0]), 10, true)
	assert_eq(c.frame_ms(0), 100, "10fps → 100ms")
	c.play()
	assert_false(c.advance(99), "不足一帧不换")
	assert_true(c.advance(1), "满 100ms 换帧")
	assert_eq(c.index(), 1, "第 1 帧")


## 非法帧率不能把推进变成忙循环：帧长下限兜住。
func test_clock_clamps_illegal_fps() -> void:
	var c := QVoxelFrameClock.new()
	c.configure(_durations([0, 0]), 0, true)
	assert_eq(c.frame_ms(0), 1000, "fps<=0 夹到 1 → 1000ms")
	c.play()
	assert_true(c.is_playing(), "仍可播（不崩、不忙循环）")


## 标签区间 + reverse：播放范围与方向都由标签决定 —— 这正是编辑器过去"只存不读"的那部分。
func test_clock_tag_reverse_plays_range_backwards() -> void:
	var c := QVoxelFrameClock.new()
	c.configure(_durations([10, 20, 30, 40]), 12, true,
			[{"name": "back", "from": 1, "to": 3, "direction": "reverse"}])
	c.play("back")
	assert_eq(c.index(), 3, "反向从区间末尾进入")
	assert_eq(c.range(), Vector2i(1, 3), "播放区间就是标签区间")
	assert_eq(c.tag_name(), "back", "标签名可回读")
	c.advance(40)
	assert_eq(c.index(), 2, "往回退一帧")
	c.advance(30)
	assert_eq(c.index(), 1, "退到区间起点")
	c.advance(20)
	assert_eq(c.index(), 3, "循环回**区间**末尾，不是整段末尾")


## pingpong：到顶折返、到底再折返。
func test_clock_pingpong_bounces_within_range() -> void:
	var c := QVoxelFrameClock.new()
	c.configure(_durations([10, 10, 10]), 12, true,
			[{"name": "p", "from": 0, "to": 2, "direction": "pingpong"}])
	c.play("p")
	var seen := [c.index()]
	for i in 6:
		c.advance(10)
		seen.append(c.index())
	assert_eq(seen, [0, 1, 2, 1, 0, 1, 2], "0→1→2→1→0→1→2 折返")


## 非循环：播到区间尽头自己停，is_playing() 如实转 false（UI 靠它灭播放键）。
func test_clock_non_loop_stops_at_range_end() -> void:
	var c := QVoxelFrameClock.new()
	c.configure(_durations([10, 10, 10]), 12, false)
	c.play()
	c.advance(10)
	c.advance(10)
	assert_eq(c.index(), 2, "走到最后一帧")
	assert_true(c.is_playing(), "最后一帧自己那一帧的时长还没走完，不该提前停")
	c.advance(10)
	assert_false(c.is_playing(), "尽头停播")
	assert_eq(c.index(), 2, "停在最后一帧")


## 长 delta 一次跨多帧（低帧率 / 切后台回来），且余量要保留而不是丢掉。
func test_clock_skips_frames_on_large_delta() -> void:
	var c := QVoxelFrameClock.new()
	c.configure(_durations([100, 100, 100, 100]), 12, true)
	c.play()
	assert_true(c.advance(350), "跨 3 帧")
	assert_eq(c.index(), 3, "落在第 3 帧")
	assert_eq(c.delay_ms(), 50, "余量 50ms 被保留")


## 标签查询：点进命名区间就预览那个区间 —— 这是编辑器开始消费 direction 的入口。
func test_clock_tag_name_at_picks_containing_tag() -> void:
	var c := QVoxelFrameClock.new()
	c.configure(_durations([10, 10, 10, 10]), 12, true, [
		{"name": "walk", "from": 0, "to": 1},
		{"name": "idle", "from": 2, "to": 3},
	])
	assert_eq(c.tag_name_at(0), "walk", "第 0 帧属 walk")
	assert_eq(c.tag_name_at(1), "walk", "区间含端点")
	assert_eq(c.tag_name_at(3), "idle", "第 3 帧属 idle")
	assert_eq(c.tag_name_at(9), "", "越界无命中 → 整段")


## 标签非法（名字对不上 / 区间越界 / 方向拼错）一律退化到"整段正放"，绝不拒绝播放。
func test_clock_invalid_tag_degrades_to_whole_range() -> void:
	var c := QVoxelFrameClock.new()
	c.configure(_durations([10, 10, 10]), 12, true,
			[{"name": "x", "from": 5, "to": 99, "direction": "sideways"}])
	c.play("nope")
	assert_true(c.is_playing(), "名字对不上也要能播")
	assert_eq(c.tag_name(), "", "退化成整段")
	assert_eq(c.range(), Vector2i(0, 2), "整段区间")
	c.play("x")
	assert_eq(c.tag_name(), "x", "命中标签")
	assert_eq(c.range(), Vector2i(2, 2), "越界区间被夹进合法范围")
	assert_false(c.is_playing(), "夹完只剩一帧 → 没有时间轴可播")


## 只有一帧（静态模型）不该进入播放态：如实返回 false，UI 不必特判。
func test_clock_single_frame_is_not_playable() -> void:
	var c := QVoxelFrameClock.new()
	c.configure(_durations([100]), 12, true)
	c.play()
	assert_false(c.is_playing(), "一帧没有时间轴")
	assert_eq(c.delay_ms(), 0, "不播放时调度间隔为 0")


# ----------------------------------------------------------------------------
# ⑨ 块表替换：切帧的落点
# ----------------------------------------------------------------------------

## `apply_block_table` 是"整份内容替换"的唯一入口。返回"真改了几块"——
## 未变的块必须整块跳过（FRAM 的块级增量就是靠这个才省下来）。
func test_apply_block_table_diffs_at_chunk_level() -> void:
	var d := QVoxelSource.new()
	d.grid_size = Vector3i(64, 64, 64)
	var k0 := Vector3i(0, 0, 0)
	var k1 := Vector3i(1, 0, 0)
	var t0 := {k0: _block([Vector3i(1, 1, 1)]), k1: _block([Vector3i(2, 2, 2)])}
	assert_eq(d.apply_block_table(t0), 2, "首次装载 2 块")
	assert_eq(d.get_voxel(Vector3i(1, 1, 1)), MAT, "块 0 的内容就位")
	assert_eq(d.get_voxel(Vector3i(34, 2, 2)), MAT, "块 1 的内容就位")

	assert_eq(d.apply_block_table(t0), 0, "同一份表重装 = 0 改动")

	var t1 := {k0: _block([Vector3i(1, 1, 1)]), k1: _block([Vector3i(3, 3, 3)])}
	assert_eq(d.apply_block_table(t1), 1, "只改 1 块就只装 1 块")
	assert_eq(d.get_voxel(Vector3i(34, 2, 2)), -1, "块 1 的旧体素被清掉")
	assert_eq(d.get_voxel(Vector3i(35, 3, 3)), MAT, "块 1 的新体素就位")

	# 新表里没有的块必须删掉：漏删会让上一帧的残留块永远留在场景里
	assert_eq(d.apply_block_table({k0: t0[k0]}), 1, "删掉 1 块")
	assert_eq(d.get_voxel(Vector3i(35, 3, 3)), -1, "被删块的体素不在了")
	assert_eq(d.get_voxel(Vector3i(1, 1, 1)), MAT, "留下的块不受影响")
	assert_eq(d.get_voxel_count(), 1, "总数对得上")


## 全空缓冲等同"该块没有内容"：不能装进去，否则 `is_empty()` 与"一个体素都没有"脱钩。
func test_apply_block_table_drops_empty_buffers() -> void:
	var d := QVoxelSource.new()
	assert_eq(d.apply_block_table({Vector3i(0, 0, 0): _block([])}), 0, "全空缓冲不算装载")
	assert_true(d.is_empty(), "装完仍是空（不变式没被破坏）")


# ----------------------------------------------------------------------------
# ⑩ 运行时播放器：装配 → 切帧 → 时间推进
# ----------------------------------------------------------------------------

## 播放器端到端：装配后帧 0 立刻就位、seek 换帧、按逐帧时长推进、循环回绕。
## 时间入口就是 `_process`，喂 delta 即可，不必等真实时钟。
func test_animator_plays_frames_into_voxel_data() -> void:
	var path := TEST_DIR + "/anim_play.qvx"
	_write_animated_qvx(path, [
		{"cells": [Vector3i(1, 1, 1)], "duration_ms": 100},
		{"cells": [Vector3i(1, 1, 1), Vector3i(1, 9, 1)], "duration_ms": 200},
	], {}, {"loop": true, "fps": 10, "tags": []})
	var qvx := QVoxelAsset.from_file(path)
	assert_true(qvx != null, "应能解析 FRAM 文件")
	if qvx == null:
		return
	var d := QVoxelSource.from_qvx(qvx, QVoxelSource.OriginMode.WORLD_ORIGIN, 0)
	var animator := VoxelAnimator.new()
	assert_true(animator.setup(qvx, d, 0, false), "有帧动画 → 装配成功")
	assert_eq(animator.frame_count(), 2, "内核拿到 2 帧")
	assert_eq(animator.frame(), 0, "装配后停在第 0 帧")
	# 装配即落帧 0：静态摆在那里显示的也该是第 0 帧，否则"装配了但没播"会是一片空白
	assert_eq(d.get_voxel_count(), 1, "帧 0 内容已就位")
	assert_eq(d.get_voxel(Vector3i(1, 9, 1)), -1, "帧 0 没有 (1,9,1)")

	animator.seek(1)
	assert_eq(animator.frame(), 1, "seek 到第 1 帧")
	assert_eq(d.get_voxel_count(), 2, "帧 1 的内容装进数据")
	assert_eq(d.get_voxel(Vector3i(1, 9, 1)), MAT, "帧 1 新增的体素就位")

	animator.seek(0)
	animator.play()
	assert_true(animator.is_playing(), "2 帧可播")
	animator._process(0.1)
	assert_eq(animator.frame(), 1, "100ms 后到第 1 帧")
	assert_eq(d.get_voxel_count(), 2, "数据跟着换到帧 1")
	animator._process(0.2)
	assert_eq(animator.frame(), 0, "再 200ms 循环回第 0 帧")
	assert_eq(d.get_voxel_count(), 1, "帧 0 的体素已清掉（残留块会永远留在场景里）")
	animator.stop()
	assert_false(animator.is_playing(), "stop 后停播")
	animator.free()


## 静态资产装配失败要**明确返回 false**，而不是悄悄播一个空动画。
func test_animator_rejects_static_asset() -> void:
	var path := TEST_DIR + "/anim_static.qvx"
	_write_static_qvx(path)
	var qvx := QVoxelAsset.from_file(path)
	if qvx == null:
		return
	var d := QVoxelSource.from_qvx(qvx, QVoxelSource.OriginMode.WORLD_ORIGIN, 0)
	var animator := VoxelAnimator.new()
	assert_false(animator.setup(qvx, d, 0, false), "静态模型没有帧 → 装配失败")
	assert_eq(animator.frame_count(), 0, "内核没有帧")
	animator.free()


# ----------------------------------------------------------------------------
# 夹具 / 辅助
# ----------------------------------------------------------------------------

## 播放内核要的是 PackedInt32Array（与 FRAM 逐帧时长同型），字面量数组转一下。
func _durations(ms: Array) -> PackedInt32Array:
	return PackedInt32Array(ms)


## 静态模型夹具（含 2 帧动画）：第 0 帧带 (1,1,1)，第 1 帧为空。
func _animated_model() -> QVoxelModel:
	var obj := QVoxelModel.new()
	obj.grid_size = Vector3i(64, 64, 64)
	obj.set_voxel(1, 1, 1, MAT)   # 静态内容
	obj.make_animated()           # 搬进第 0 帧
	obj.add_frame(QVoxelFrame.new())
	return obj


## 最小可用 QVX 文档骨架：HEAD（单通道 material）+ 材质表（条目 0 空气 + 1 号实体）。
func _new_doc() -> QVoxelFile.QVoxelDocument:
	var doc := QVoxelFile.QVoxelDocument.new()
	doc.head = {
		"qvox": QVoxelSpec.VERSION,
		"channels": [{"name": QVoxelSpec.DOMINANT_CHANNEL, "bpp": QVoxelSpec.CHANNEL_BPP}],
		"block_size": VoxelChunk.CHUNK_SIZE,
		"up_axis": "y",
	}
	doc.materials = [VoxelMaterial.air_mate(),
			VoxelMaterial.to_mate(_solid_material(Color(0.9, 0.2, 0.2)))]
	return doc


## 一块 32³ 缓冲，其中给定局部坐标（Array[Vector3i]）被填上材质。
func _block(cells: Array) -> PackedInt32Array:
	var b := PackedInt32Array()
	b.resize(VoxelChunk.CHUNK_VOLUME)
	for c in cells:
		var p: Vector3i = c
		b[VoxelChunk.buf_index(p.x, p.y, p.z)] = MAT
	return b


## 造一个"只有 FRAM"的 .qvx：单个 model_id=0 的动画 + NODE（可选摆放与 anim 元数据）。
## frame_specs：每项 = { "cells": Array[Vector3i], "duration_ms": int }，块键恒为 (0,0,0)。
## 注意同一 model_id 不能既是 VXEL 又是 FRAM（§12.2），故 doc.models 留空。
func _write_animated_qvx(path: String, frame_specs: Array, transform := {},
		anim := {}) -> void:
	var doc := _new_doc()
	var frames: Array = []
	for spec in frame_specs:
		var s: Dictionary = spec
		frames.append({
			"duration_ms": int(s.get("duration_ms", 0)),
			"blocks": {BLOCK_KEY: _block(s.get("cells", []))},
		})
	doc.frames = {0: frames}
	var node := {"name": "n", "kind": "model", "model_id": 0, "transform": transform}
	if not anim.is_empty():
		node["anim"] = anim
	doc.node = {"nodes": [node]}
	_write_bytes(path, QVoxelFile.serialize(doc))


## 造一个"单模型单体素"的静态 .qvx（块 (0,0,0) 内 (1,1,1)）。
func _write_static_qvx(path: String) -> void:
	var doc := _new_doc()
	doc.models = {0: {BLOCK_KEY: _block([Vector3i(1, 1, 1)])}}
	_write_bytes(path, QVoxelFile.serialize(doc))


## 导入器全套默认选项（含 MeshLibrary 的 mesh_mode / import_meshes）。
## 走静态默认值：`EditorImportPlugin` 在 headless/CI 进程里 new() 会失败，
## 走实例方法会静默拿到空字典（缺键 → 生成器整条链路失败）。
func _mesh_options() -> Dictionary:
	return VoxelMeshLibraryImporter.default_options()


func _solid_material(color: Color) -> VoxelMaterial:
	var mat := VoxelMaterial.new()
	mat.id = MAT
	mat.color = color
	mat.rough = 0.8
	mat.hardness = 6.0
	mat.mass = 2.0
	return mat


func _write_bytes(path: String, bytes: PackedByteArray) -> void:
	var dir := path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()


func _remove_dir(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir():
			DirAccess.remove_absolute(ProjectSettings.globalize_path(dir_path.path_join(name)))
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir_path))

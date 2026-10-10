extends TestCase

## 一期编辑会话（QVoxelEditSession）的契约测试。
## 会话刻意不依赖任何节点，于是"手势 → 命令 → 撤销 → 数据源失效 → 唤醒渲染器"这整条链
## 可以在无头环境里跑完并逐项断言。这里钉死六条承诺：
##   ① 装配：对象 → 显示层（数据层 + 节点 + 调色板）由 create_for 一条路径铺好；
##   ② 拾取的几何判据取自**显示层**（链的产出只在那儿），落笔格 = 命中格 + 法线；
##   ③ 一笔手势 = 一个撤销单位；空手势（没改到任何格）不入栈；
##   ④ 作废（cancel）必须回滚 —— 否则 live 工具拖动中改的东西永远撤不掉；
##   ⑤ 刷新只命中受影响的 chunk（范围外保留缓冲），而不是整对象重算；
##   ⑥ 镜像写入让拖动**当场可见**，且每一次可见改动只唤醒渲染器一次。
## 索引对齐：MAT / OTHER 是材质 ID，值 0 = 空。

const MAT := 1
const OTHER := 2


# 夹具

func _session(grid := Vector3i(128, 128, 128)) -> QVoxelEditSession:
	var w := QVoxelWorld.create_empty()
	# 颜色刻意选 0/1 端点：MATE 是 8 位量化，中间值（如 0.5 → 128/255）取整后回不来，
	# 断言浮点相等会变成在测"取整误差"而不是在测接线。
	w.add_material(Color(1, 0, 0)) # ID 1
	w.add_material(Color(0, 0, 1)) # ID 2
	var obj := w.create_model("m", grid)
	return QVoxelEditSession.create_for(obj, w)


## 射线命中信息（VoxelRay.cast 的形状；这里只填会话读的两个键）。
func _hit(hit: Vector3i, normal: Vector3i) -> Dictionary:
	return {VoxelRay.KEY_HIT: hit, VoxelRay.KEY_NORMAL: normal}


func _dirty_set(s: QVoxelEditSession) -> Dictionary:
	var d := {}
	for ck in s.data.get_dirty_chunks():
		d[ck] = true
	return d


# 装配

func test_create_for_wires_object_data_and_palette() -> void:
	var s := _session()
	assert_ne(s.object, null, "会话要有被编辑的对象")
	assert_ne(s.data, null, "会话要有显示层")
	assert_eq(s.data.node, s.object, "显示层的节点就是被编辑的对象")
	assert_eq(s.data.grid_size, s.object.grid_size, "数据层分辨率必须与对象一致")
	assert_true(s.data.can_generate_chunk(Vector3i(3, 3, 3)),
		"供数范围随数据层自动同步：网格内的块可生成")
	assert_false(s.data.can_generate_chunk(Vector3i(99, 0, 0)),
		"网格外的块不可生成（128³ 只覆盖 chunk 0..3；漏了同步会当自己是无限世界）")


func test_palette_is_copied_from_the_world() -> void:
	var s := _session()
	assert_eq(s.data.materials.size(), 3, "调色板 = 空气占位 + 世界里的两个材质")
	assert_eq(s.data.materials[1].id, 1, "索引 == 材质 ID（体素存的 ID 可直接当数组下标）")
	assert_eq(s.data.materials[2].id, 2, "同上")
	assert_eq(s.data.materials[1].color, Color(1, 0, 0), "颜色按 MATE 条目解释")
	assert_eq(s.data.materials[2].color, Color(0, 0, 1), "同上")


# 拾取

func test_pick_reads_geometry_from_the_display_layer() -> void:
	var s := _session()
	# 这一格只存在于显示层（摸拟"修改器链生成出来的几何"）—— 对象里没有。
	s.data.set_voxel(Vector3i(5, 5, 5), OTHER, false)
	var p := s.pick_from_hit(_hit(Vector3i(5, 5, 5), Vector3i(0, 1, 0)))
	assert_eq(p.place, Vector3i(5, 6, 5), "落笔格 = 命中格 + 法线（往空的那侧长）")
	assert_true(bool(p.solid.call(Vector3i(5, 5, 5))),
		"实心判据取自显示层：拿对象判会让面笔/填充看不见链的产出")
	assert_eq(int(p.material_at.call(Vector3i(5, 5, 5))), OTHER, "材质判据同样取自显示层")
	assert_eq(int(p.material_at.call(Vector3i(9, 9, 9))), 0,
		"空格子的材质必须是 0（数据层的 -1 是「没有」，不是材质）")
	assert_eq(p.grid, s.object.grid_size, "拾取上下文带上网格尺寸（工具据此裁剪产物）")


func test_pick_without_incident_face_cannot_start() -> void:
	var s := _session()
	# 起点就在实心格内 → 没有入射面 → 无处落笔（VoxelRay 给 normal = ZERO）。
	var p := s.pick_from_hit(_hit(Vector3i(1, 1, 1), Vector3i.ZERO))
	assert_false(s.begin(p), "没有入射面的命中不该开始手势")
	assert_false(s.active(), "手势没开始")


# 手势 → 命令 → 撤销栈

func test_one_gesture_is_one_undo_unit_and_writes_both_ledgers() -> void:
	var s := _session()
	var p := s.pick_from_hit(_hit(Vector3i(10, 10, 10), Vector3i(0, 1, 0)))
	assert_true(s.begin(p), "空处落笔应当有效")
	assert_true(s.release(), "改到了东西 → 应当入栈")
	assert_true(s.can_undo(), "一笔手势 = 一个撤销单位")
	assert_false(s.can_redo(), "新操作入栈后 redo 分支被截断")
	assert_eq(s.object.get_voxel(10, 11, 10), MAT, "对象被写入（权威账本）")
	assert_true(s.data.is_chunk_mesh_dirty(Vector3i(0, 0, 0)),
		"收尾让受影响的 chunk 重新取数并等待重建")


func test_gesture_that_changes_nothing_is_not_pushed() -> void:
	var s := _session()
	s.object.set_voxel(8, 9, 8, MAT)  # 目标格已经是这个材质了
	var p := s.pick_from_hit(_hit(Vector3i(8, 8, 8), Vector3i(0, 1, 0)), false, MAT)
	assert_true(s.begin(p), "落笔格合法 → 手势可以开始")
	assert_false(s.release(), "刷了同一种颜色 = 什么都没变 → 不该占一次撤销")
	assert_false(s.can_undo(), "撤销栈保持干净")


func test_release_without_begin_is_a_no_op() -> void:
	var s := _session()
	assert_false(s.release(), "没有手势时松手什么都不做")
	assert_false(s.can_undo(), "撤销栈保持干净")


func test_erase_gesture_removes_the_hit_voxel_and_is_undoable() -> void:
	var s := _session()
	# 稳态：对象与显示层都已有这一格（编辑器里显示层是生成器按对象产出的那一份）。
	# 只喂对象不够 —— 工具的"这一格已经是目标材质了就不写"是拿显示层判的。
	s.object.set_voxel(3, 3, 3, MAT)
	s.data.set_voxel(Vector3i(3, 3, 3), MAT, false)
	# 擦除的落笔格 = 命中格本身（不是 hit + normal）—— 擦掉面前的空格毫无意义。
	var p := s.pick_from_hit(_hit(Vector3i(3, 3, 3), Vector3i(0, 1, 0)), true)
	assert_eq(p.place, Vector3i(3, 3, 3), "擦除的落笔格就是命中格")
	assert_true(s.begin(p), "已经有实心格可擦")
	assert_true(s.release(), "擦除也是一次编辑")
	assert_eq(s.object.get_voxel(3, 3, 3), 0, "右键擦除把目标格清空")
	assert_true(s.undo(), "擦除可以被撤销")
	assert_eq(s.object.get_voxel(3, 3, 3), MAT, "撤销把材质还回来")


func test_cancel_rolls_back_live_writes_and_leaves_no_history() -> void:
	var s := _session()
	var p := s.pick_from_hit(_hit(Vector3i(6, 6, 6), Vector3i(0, 1, 0)))
	s.begin(p)
	assert_true(s.drag(p) > 0, "live 工具拖动就该有产物")
	assert_eq(s.object.get_voxel(6, 7, 6), MAT, "拖动已经改过对象")
	s.cancel()
	assert_eq(s.object.get_voxel(6, 7, 6), 0,
		"作废必须回滚：只丢命令的话，这批改动永远撤不掉")
	assert_false(s.can_undo(), "作废的笔不该留下历史项")
	assert_eq(s.data.get_voxel(Vector3i(6, 7, 6)), -1,
		"显示层也被按权威重新取数（缓冲作废 → 下次取数重新生成）")


func test_cancel_before_any_write_touches_nothing() -> void:
	var s := _session()
	var p := s.pick_from_hit(_hit(Vector3i(2, 2, 2), Vector3i(1, 0, 0)))
	s.begin(p)
	s.cancel()
	assert_false(s.active(), "手势结束")
	assert_eq(s.data.get_dirty_mesh_chunk_count(), 0,
		"没写过任何格 → 连一次「作废」都不该发生（空手势不该引起重建）")


# live / span

func test_live_tool_mirrors_the_stroke_immediately() -> void:
	var s := _session()
	var p := s.pick_from_hit(_hit(Vector3i(4, 4, 4), Vector3i(0, 1, 0)))
	s.begin(p)
	assert_true(s.drag(p) > 0, "体素笔边拖边写")
	assert_eq(s.data.get_voxel(Vector3i(4, 5, 4)), MAT,
		"显示层当场可见（即时反馈靠镜像，而不是每帧全量重求值）")
	assert_false(s.can_undo(), "松手之前不入栈（一次拖动只留一条历史）")


func test_release_hands_the_chunk_back_to_the_authoritative_source() -> void:
	var s := _session()
	var p := s.pick_from_hit(_hit(Vector3i(10, 10, 10), Vector3i(0, 1, 0)))
	s.begin(p)
	s.drag(p)
	assert_eq(s.data.get_voxel(Vector3i(10, 11, 10)), MAT, "拖动中镜像立即可见")
	s.release()
	assert_eq(s.data.get_voxel(Vector3i(10, 11, 10)), -1,
		"收尾把该 chunk 交回权威来源重新取数（镜像只是「这一笔还没结束」时的临时账）")
	assert_true(s.data.is_chunk_mesh_dirty(Vector3i(0, 0, 0)), "并且标脏等待重建")


func test_span_tool_writes_only_at_release() -> void:
	var s := _session()
	s.tool.set_mode(QVoxelBrushTool.Mode.BOX)
	var a := s.pick_from_hit(_hit(Vector3i(2, 0, 3), Vector3i(0, 1, 0)))
	assert_true(s.begin(a), "盒笔从第一个角点按下")
	var b := s.pick_from_hit(_hit(Vector3i(4, 0, 6), Vector3i(0, 1, 0)))
	assert_eq(s.drag(b), 0, "盒笔松手才产出（拖动中写入会留下一串盒子）")
	assert_eq(s.object.get_voxel(2, 1, 3), 0, "拖动期间对象未被触碰")
	assert_eq(s.data.get_voxel(Vector3i(2, 1, 3)), -1, "拖动期间显示层同样未被触碰")
	assert_true(s.release(), "松手封口")
	assert_eq(s.object.get_voxel(2, 1, 3), MAT, "盒子的角点被填上")
	assert_eq(s.object.get_voxel(4, 1, 6), MAT, "另一个角点也在（含端点）")


# 刷新

func test_refresh_only_targets_the_chunks_that_changed() -> void:
	var s := _session()
	# 先备好两个彼此不相邻的 chunk 缓冲，才能区分"只失效受影响的"与"整对象重算"。
	s.data.set_voxel(Vector3i(1, 1, 1), MAT, false)     # chunk (0,0,0)
	s.data.set_voxel(Vector3i(80, 1, 1), MAT, false)    # chunk (2,0,0)
	s.data.get_dirty_chunks()                            # 清空既有脏账
	s.begin(s.pick_from_hit(_hit(Vector3i(10, 10, 10), Vector3i(0, 1, 0))))
	s.release()
	var dirty := _dirty_set(s)
	assert_true(dirty.has(Vector3i(0, 0, 0)), "受影响的 chunk 必须重建")
	assert_false(dirty.has(Vector3i(2, 0, 0)),
		"范围外的 chunk 不重建 —— 它的缓冲内容对未编辑区域仍然正确")


func test_undo_and_redo_restore_object_and_refresh() -> void:
	var s := _session()
	s.begin(s.pick_from_hit(_hit(Vector3i(3, 3, 3), Vector3i(0, 1, 0))))
	s.release()
	assert_eq(s.object.get_voxel(3, 4, 3), MAT, "写完在")
	s.data.get_dirty_chunks()  # 清账，才能断言"撤销自己也触发了刷新"
	assert_true(s.undo(), "撤销可用")
	assert_eq(s.object.get_voxel(3, 4, 3), 0, "撤销后对象回到 before")
	assert_true(_dirty_set(s).has(Vector3i(0, 0, 0)),
		"撤销也要刷新 —— 命令只恢复对象，显示层仍是旧内容")
	assert_true(s.redo(), "重做可用")
	assert_eq(s.object.get_voxel(3, 4, 3), MAT, "重做后写回来")


func test_wake_happens_once_per_visible_change() -> void:
	var s := _session()
	var calls := [0]
	s.request_render_update = func() -> void: calls[0] += 1
	var p := s.pick_from_hit(_hit(Vector3i(1, 1, 1), Vector3i(0, 1, 0)))
	s.begin(p)
	assert_eq(calls[0], 0, "只按下、还没写 → 不唤醒")
	s.drag(p)
	assert_eq(calls[0], 1, "本次拖动真写了格 → 唤醒一次（渲染器走增量重建）")
	s.release()
	assert_eq(calls[0], 2, "收尾的源失效再唤醒一次（一笔一共两次，不多不少）")


func test_session_without_a_renderer_still_works() -> void:
	var s := _session()
	assert_false(s.request_render_update.is_valid(), "默认没有渲染器回调（无头场景）")
	s.begin(s.pick_from_hit(_hit(Vector3i(1, 1, 1), Vector3i(0, 1, 0))))
	assert_true(s.release(), "没有渲染器也能正常编辑（数据源失效是真逻辑，唤醒只是通知）")
	assert_eq(s.object.get_voxel(1, 2, 1), MAT, "对象照常被写")

extends TestCase

## 架构加固的回归测试（编辑器进程即可，无需游戏进程）。
##
## 这里锁定的都是**新建立的不变量**，每条都对应一个已修复的失效模式：
##   · S1 异步批次计数：批次无论派发/取消/空批次，finished **至多且恰好一次**，
##     且结算时只读快照一定被释放 —— 旧实现里结果处理的两条早退路径各减一次计数，
##     计数提前归零 → 快照在 worker 仍读共享缓冲时被释放 → COW 写保护失效。
##   · S5 伤害账归位：伤害随 chunk 生命周期同步清理，体素被移除后其位置伤害归零
##     （否则残留伤害"继承"给后来放上去的新体素，一放上去就被秒杀）。
##   · S6 只读快照句柄：句柄释放后计数归零；泄漏句柄时 clear() 能强制回收
##     （否则 _snapshot_readers 永久 >0 → 之后每次单点写都复制整块 32³）。
##   · S8 bpp：非 16 位的 HEAD 必须被拒绝（旧实现接受 8/32 却按 16 解码 = 接受却读错）。
##
## 注意断言用的是**公开可观测状态**（信号次数、计数器、缓冲内容），而不是内部实现细节，
## 这样即使将来内部结构调整，这些不变量仍然成立。

const CHUNK := VoxelChunk.CHUNK_SIZE
const VOL := VoxelChunk.CHUNK_VOLUME


# ----------------------------------------------------------------------------
# S6：只读快照句柄
# ----------------------------------------------------------------------------

func test_snapshot_handle_releases_counter() -> void:
	var data := VoxelData.new()
	assert_eq(data._snapshot_readers, 0, "初始无快照")
	var h := data.begin_readonly_snapshot()
	assert_eq(data._snapshot_readers, 1, "begin 后计数应为 1")
	h.release()
	assert_eq(data._snapshot_readers, 0, "release 后计数应归零")
	h.release()
	assert_eq(data._snapshot_readers, 0, "重复 release 必须幂等（不得变负/重复减）")


func test_snapshot_handles_are_independent() -> void:
	var data := VoxelData.new()
	var a := data.begin_readonly_snapshot()
	var b := data.begin_readonly_snapshot()
	assert_eq(data._snapshot_readers, 2, "两个快照并发持有")
	a.release()
	assert_eq(data._snapshot_readers, 1, "释放 a 不应影响 b")
	b.release()
	assert_eq(data._snapshot_readers, 0, "全部释放后归零")


func test_clear_force_releases_leaked_snapshot() -> void:
	# 模拟"提前返回漏释放"：句柄被丢弃但从未 release。
	# 若 clear() 不强制回收，_snapshot_readers 会永久 >0，此后每次单点写都复制整块缓冲。
	var data := VoxelData.new()
	data.begin_readonly_snapshot()
	assert_eq(data._snapshot_readers, 1, "泄漏句柄使计数为 1")
	data.clear()
	assert_eq(data._snapshot_readers, 0, "clear() 必须强制回收泄漏快照")


func test_missing_end_release_leaves_counter_stuck_unless_forced() -> void:
	# 反证：不调 clear() 也不 release 时，计数确实停在 1（说明该不变量有意义）。
	var data := VoxelData.new()
	data.begin_readonly_snapshot()
	assert_eq(data._snapshot_readers, 1, "未释放则计数值保持 1")
	data._force_release_snapshots()
	assert_eq(data._snapshot_readers, 0, "_force_release_snapshots 可兜底回收")


# ----------------------------------------------------------------------------
# S1：批次结算唯一（结算点只有 VoxelMeshBatch 内部一处）
# ----------------------------------------------------------------------------

func test_batch_settles_once_for_empty_batch() -> void:
	var b := VoxelMeshBatch.new()
	var fin := [0]
	b.finished.connect(func() -> void: fin[0] += 1)
	b.settle_if_idle()
	assert_eq(fin[0], 1, "空批次应立即结算一次")
	assert_false(b.is_active(), "结算后不再是在途")
	b.settle_if_idle()
	b.cancel()
	assert_eq(fin[0], 1, "重复结算/cancel 必须幂等（finished 只发射一次）")


func test_batch_releases_snapshot_on_settle() -> void:
	var data := VoxelData.new()
	var b := VoxelMeshBatch.new()
	var fin := [0]
	b.finished.connect(func() -> void: fin[0] += 1)
	b.attach_snapshot(data.begin_readonly_snapshot())
	assert_eq(data._snapshot_readers, 1, "批次持有快照")
	b.settle_if_idle()
	assert_eq(fin[0], 1, "空批次结算一次")
	assert_eq(data._snapshot_readers, 0, "结算即释放只读快照")


## 锁定 Godot 4 的 `Callable.bind()` 实参顺序：绑定实参在 **call 实参之后**。
##
## 这正是曾经的真实回归：`_generate_chunk_worker.bind(a, b, ...).call(out)` 的实际调用是
## `_generate_chunk_worker(out, a, b, ...)`，out 落到第 1 个形参上、其余参数整体错位，
## 运行时报 "Cannot convert argument 2 from Dictionary to Array"。
## 旧代码用 `WorkerThreadPool.add_task(f.bind(...))`（无额外实参）时掩盖了这一点，
## 单元测试也测不到（只有真实场景跑起来才会派发 chunk worker）——故在此显式钉住语义。
func test_callable_bind_order_is_after_call_arguments() -> void:
	var f := func(out: Dictionary, a: int, b: int) -> Array:
		return [out.get("k", "?"), a, b]
	var res: Array = f.bind(1, 2).call({"k": "out"})
	assert_eq(res[0], "out", "第 1 个实参应是 call 传入的 out")
	assert_eq(res[1], 1, "bind 的第 1 个实参落在第 2 位")
	assert_eq(res[2], 2, "bind 的第 2 个实参落在第 3 位")


func test_batch_spawn_then_cancel_releases_snapshot_once() -> void:
	# S1 回归核心：worker 可能"不产出任何结果"（被丢弃/空块）。
	# 旧实现里结果处理的早退路径各减一次计数 → 计数提前归零 → 快照提前释放。
	# 现在计数只在批次内部结算一次，故"无产出 worker"绝不能让它失衡。
	var data := VoxelData.new()
	var b := VoxelMeshBatch.new()
	var fin := [0]
	b.finished.connect(func() -> void: fin[0] += 1)
	b.attach_snapshot(data.begin_readonly_snapshot())
	# 两个 worker 都不写 out（等价于"结果被丢弃"）
	for _i in 2:
		b.spawn(func(_out: Dictionary) -> void:
			pass)
	assert_eq(b.pending_count(), 2, "两个任务在途")
	assert_true(b.is_active(), "有在途任务时批次仍活跃")
	b.wait_tasks()          # 任务已结束，但其回填经 call_deferred 尚未回调
	b.cancel()
	assert_eq(fin[0], 1, "取消后 finished 恰好一次（不得因计数失衡重复结算）")
	assert_eq(data._snapshot_readers, 0, "取消必须释放快照")
	assert_false(b.is_active(), "取消后不再在途")
	b.wait_tasks()          # 再次 join 必须安全（幂等）


# ----------------------------------------------------------------------------
# S5：伤害账随 chunk 生命周期同步
# ----------------------------------------------------------------------------

func test_removing_voxel_zeroes_its_damage() -> void:
	var data := VoxelData.new()
	var pos := Vector3i(3, 4, 5)
	data.set_voxel(pos, 7)
	_seed_damage(data, pos, 99.0)
	assert_eq(_damage_at(data, pos), 99.0, "前置：该位置已有累计伤害")
	# 移除体素 → 该位置伤害必须归零，否则会"继承"给新放上去的体素
	data.remove_voxel(pos)
	assert_eq(_damage_at(data, pos), 0.0, "移除体素后其位置伤害应归零")


func test_placing_voxel_on_damaged_spot_resets_damage() -> void:
	var data := VoxelData.new()
	var pos := Vector3i(1, 2, 3)
	data.set_voxel(pos, 7)
	_seed_damage(data, pos, 50.0)
	# 直接覆盖为新材质：同样必须清零（否则新体素继承旧伤害）
	data.set_voxel(pos, 9)
	assert_eq(_damage_at(data, pos), 0.0, "覆盖体素后其位置伤害应归零")


func test_unload_chunk_drops_its_damage() -> void:
	var data := VoxelData.new()
	var stream := VoxelMemoryStream.new()
	data.stream = stream
	var pos := Vector3i(2, 2, 2)
	data.set_voxel(pos, 5)
	_seed_damage(data, pos, 12.0)
	var ck := VoxelChunk.chunk_of(pos)
	assert_true(data.get_damage_buffers().has(ck), "前置：伤害账里有该 chunk")
	data.unload_chunk(ck)
	assert_false(data.get_damage_buffers().has(ck), "卸载 chunk 必须丢弃其伤害账（防无界增长）")


func test_clear_drops_all_damage() -> void:
	var data := VoxelData.new()
	var pos := Vector3i(4, 4, 4)
	data.set_voxel(pos, 5)
	_seed_damage(data, pos, 3.0)
	data.clear()
	assert_eq(data.get_damage_buffers().size(), 0, "clear 必须清空伤害账")


func test_shift_origin_shifts_damage_keys() -> void:
	var data := VoxelData.new()
	var pos := Vector3i(6, 0, 0)
	data.set_voxel(pos, 5)
	_seed_damage(data, pos, 8.0)
	var shift := Vector3i(2, 0, 0)
	data.shift_origin(shift)
	var moved := pos + shift * CHUNK
	assert_eq(_damage_at(data, moved), 8.0, "origin shift 后伤害账应随数据基准一起平移")


## 破坏系统的在途队列存的是**体素坐标**：origin shift 必须把它们一起平移。
## 漏平移 → 在途的破坏/崩塌/掉落体会打到平移后的错位体素（只有"长距离旅行中恰好
## 有在途队列"才暴露，属真跑才现的一类）。
func test_destructible_queues_follow_origin_shift() -> void:
	var r := VoxelDestructible.new()
	r._pending_removed = {Vector3i(5, 5, 5): true}
	r._hardened_buffer = {Vector3i(1, 2, 3): 0.5}
	r._cascade_check_positions = [Vector3i(1, 2, 3)]
	r._cascade_pending_voxels = [Vector3i(4, 5, 6)]
	r._cascade_total = [Vector3i(7, 8, 9)]
	# 掉落物理在途队列已迁往表现层（P2-3）：经宿主 getter 取到该子节点后直接注入
	var presenter: VoxelDestructionPresenter = r._presenter
	presenter._pending_falling_groups = [[Vector3i(2, 0, 0), Vector3i(3, 0, 0)]]
	presenter._pending_falling_materials = [{Vector3i(2, 0, 0): 1, Vector3i(3, 0, 0): 2}]

	var shift := Vector3i(10, -2, 4)
	r.on_origin_shift(shift)

	assert_true(r._pending_removed.has(Vector3i(15, 3, 9)), "待移除队列应随 origin shift 平移")
	assert_false(r._pending_removed.has(Vector3i(5, 5, 5)), "旧键必须消失（不得新旧双份残留）")
	assert_true(r._hardened_buffer.has(Vector3i(11, 0, 7)), "硬化反馈缓冲应平移")
	assert_eq(r._cascade_check_positions[0], Vector3i(11, 0, 7), "级联待检查位置应平移")
	assert_eq(r._cascade_pending_voxels[0], Vector3i(14, 3, 10), "级联待移除体素应平移")
	assert_eq(r._cascade_total[0], Vector3i(17, 6, 13), "级联累积应平移")
	assert_eq(presenter._pending_falling_groups[0][0], Vector3i(12, -2, 4), "待生成掉落体组应平移")
	assert_true(presenter._pending_falling_materials[0].has(Vector3i(12, -2, 4)), "掉落体材质映射应平移")
	assert_eq(presenter._pending_falling_materials[0].get(Vector3i(12, -2, 4)), 1, "平移后材质值应保持不变")
	r.free()


# ----------------------------------------------------------------------------
# 全量悬空检测下沉原生：结果必须与 GDScript flood_fill 判据逐体素一致
# ----------------------------------------------------------------------------

func test_find_unsupported_matches_flood_fill_oracle() -> void:
	var d := VoxelData.new()
	# 一根贴地柱子 + 一块悬空体素（与地面 6 方向不连通）
	for y in 4:
		d.set_voxel(Vector3i(0, y, 0), 1)
	for x in 2:
		for z in 2:
			d.set_voxel(Vector3i(10 + x, 5, 10 + z), 1)
	assert_eq(d.get_voxel_count(), 8, "测试世界应有 8 个体素")

	var got := d.find_unsupported()
	# oracle：种子 = 贴地体素，6 方向 flood fill（与旧 GDScript 实现同一判据）
	var supported := d.flood_fill([Vector3i(0, 0, 0)], {})
	var want := {}
	for pos in d.get_positions():
		if not supported.has(pos):
			want[pos] = true

	assert_eq(got.size(), want.size(), "原生全量检测的悬空体素数应与 flood_fill 判据一致")
	for k in want:
		assert_true(got.has(k), "oracle 判为悬空的体素原生也必须判为悬空: %s" % str(k))
	assert_false(got.has(Vector3i(0, 3, 0)), "与地面连通的体素不得被判悬空")
	assert_true(got.has(Vector3i(10, 5, 10)), "悬空块应被判悬空")
	assert_eq(d.find_unsupported({}).size(), want.size(), "空世界集合参数应走全量路径且结果一致")


# ----------------------------------------------------------------------------
# 集合受限泛洪下沉原生：restrict 分支（原生）必须与判据分支（GDScript oracle）一致
# ----------------------------------------------------------------------------

func test_flood_fill_restrict_branch_matches_predicate_oracle() -> void:
	var d := VoxelData.new()
	# 地面行 + 斜向"台阶"（靠 (3,1,0) 竖直连接地面）+ 负坐标柱 + 悬空 2x2 平面
	for x in 4:
		d.set_voxel(Vector3i(x, 0, 0), 1)
	d.set_voxel(Vector3i(3, 1, 0), 1)
	d.set_voxel(Vector3i(3, 1, 1), 1)
	d.set_voxel(Vector3i(-3, 0, -3), 1)
	d.set_voxel(Vector3i(-3, 1, -3), 1)
	for x in 2:
		for z in 2:
			d.set_voxel(Vector3i(10 + x, 5, 10 + z), 1)

	var restrict := {}
	for pos in d.get_positions():
		restrict[pos] = true

	# oracle：判据分支（restrict 为空 → 逐点回调 has_voxel 的 GDScript BFS）
	var via_pred := d.flood_fill([Vector3i(0, 0, 0)], {})
	# 被测：restrict 分支（restrict = 实体素全集 → 走原生 flood_fill_positions）
	var via_set := d.flood_fill([Vector3i(0, 0, 0)], restrict)

	assert_eq(via_set.size(), via_pred.size(), "restrict 分支（原生）应与判据分支（oracle）结果一致")
	for k in via_pred:
		assert_true(via_set.has(k), "oracle 判为连通的体素 restrict 分支也必须连通: %s" % str(k))
	assert_true(via_set.has(Vector3i(3, 1, 1)), "斜向台阶应经 (3,1,0) 连到地面")
	assert_false(via_set.has(Vector3i(10, 5, 10)), "悬空块不得被泛洪连通")
	assert_false(via_set.has(Vector3i(-3, 0, -3)), "负坐标柱与主分量不连通，不得被纳入")

	# 负坐标分量：从负坐标种子出发应正确标记（哈希键须正确处理负坐标）
	var neg := d.flood_fill([Vector3i(-3, 0, -3)], restrict)
	assert_eq(neg.size(), 2, "负坐标柱应为 2 体素连通块")
	assert_true(neg.has(Vector3i(-3, 1, -3)), "负坐标连通体素应被标记")

	# 从悬空块种子出发：只应连通该 4 体素平面
	var only_hang := d.flood_fill([Vector3i(10, 5, 10)], restrict)
	assert_eq(only_hang.size(), 4, "从悬空块种子出发只应连通该 4 体素平面")
	assert_false(only_hang.has(Vector3i(0, 0, 0)), "与种子不连通的地面柱不得被纳入")

	# 种子不在 restrict 内 → 必须跳过（不得凭空纳入）
	assert_eq(d.flood_fill([Vector3i(50, 50, 50)], restrict).size(), 0, "种子不在 restrict 内时必须被跳过")

	# 子集路径（find_unsupported 的非空集合分支）现在也走原生泛洪
	assert_eq(d.find_unsupported(restrict).size(), 4, "子集路径应把悬空 4 体素判为悬空")


# ----------------------------------------------------------------------------
# S8：bpp 非 16 必须被拒绝（接受却读错 → 改为 fail-fast）
# ----------------------------------------------------------------------------

func test_bpp_other_than_16_is_rejected() -> void:
	for bpp in [8, 32]:
		var doc := QVoxFile.QVoxDocument.new()
		doc.head = {
			"qvox": QVoxSpec.VERSION,
			"channels": [{"name": QVoxSpec.DOMINANT_CHANNEL, "bpp": bpp}],
			"block_size": CHUNK,
			"up_axis": QVoxSpec.DEFAULT_UP_AXIS,
		}
		var rep := QVoxFile.validate(doc)
		assert_false(rep.ok(), "bpp=%d 应被拒绝（本版仅支持 %d 位）" % [bpp, QVoxSpec.CHANNEL_BPP])


func test_bpp_16_is_accepted() -> void:
	var doc := QVoxFile.QVoxDocument.new()
	doc.head = {
		"qvox": QVoxSpec.VERSION,
		"channels": [{"name": QVoxSpec.DOMINANT_CHANNEL, "bpp": QVoxSpec.CHANNEL_BPP}],
		"block_size": CHUNK,
		"up_axis": QVoxSpec.DEFAULT_UP_AXIS,
	}
	var rep := QVoxFile.validate(doc)
	assert_true(rep.ok(), "bpp=16 必须被接受")


# ----------------------------------------------------------------------------
# PCG：同一模型被并发请求多个 chunk 时，只能构建一次
# ----------------------------------------------------------------------------
# 模型覆盖多个 chunk 时，首帧会有多个 worker 线程同时请求不同 chunk，每个都走到
# PcgModelGenerator._ensure_volume()。无锁则各自 build 一遍：L-系统 / 元胞 / WFC 只是
# N× 白算，而 PcgWfcOverlap 的 _learn() 会写实例成员 _patterns/_weights/_allow
# —— 并发即正确性 bug（读者会拿到"新相容表 + 半个图案表"）。
# 32³ 的 demo 只有 1 个 chunk，故这条路径此前从未被走到。

## 并发构建探针：统计 build 次数、检测是否真的发生过重入。
## build 内故意撑住一段时间，把并发窗口放大到必然重叠（无锁时多个线程会同时停在里面）。
class ConcurrentProbeModel:
	extends PcgModel

	const STALL_MS := 30

	var build_calls := 0
	var reentered := false
	var _inside := 0

	func build(grid_size: Vector3i) -> PackedInt32Array:
		build_calls += 1
		_inside += 1
		if _inside > 1:
			reentered = true
		var t0 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < STALL_MS:
			pass
		var v := PcgModel.empty_volume(grid_size)
		PcgModel.set_voxel(v, 3, 3, 3, grid_size, 9)
		_inside -= 1
		return v


func test_pcg_model_builds_once_under_concurrent_chunks() -> void:
	# 64 宽 = 2 个 chunk（x 方向），两个 key 分属不同 chunk → 并发下都会走到 _ensure_volume
	var keys: Array[Vector3i] = [Vector3i(0, 0, 0), Vector3i(1, 0, 0)]
	var probe := ConcurrentProbeModel.new()
	var gen := PcgModelGenerator.new()
	gen.model = probe
	gen.set_grid_size(Vector3i(64, 32, 32))

	# 照 VoxelAsyncLoader.request 的方式派发：每个 chunk 一个后台任务，互不等待。
	# 每个任务写自己那份单元素数组（数组是引用语义，外层容器共享）——两个线程
	# 写同一个外层容器是未定义行为，会让这条回归偶发假红。
	# 内层必须**预置 1 个元素**：空数组上做 `[0] = ...` 是越界写（Invalid access of index
	# '0'），任务会静默失败、后面所有断言都不再执行 → 测试"通过"但什么都没验证。
	var got: Array = [[null], [null]]
	var ids: Array[int] = []
	for i in keys.size():
		var slot := i
		var ck := keys[i]
		ids.append(WorkerThreadPool.add_task(func() -> void:
			got[slot][0] = gen.generate(ck)))
	for id in ids:
		WorkerThreadPool.wait_for_task_completion(id)
	var r0: PackedInt32Array = got[0][0]
	var r1: PackedInt32Array = got[1][0]

	assert_eq(probe.build_calls, 1,
			"并发请求多个 chunk 时模型必须只 build 一次（无锁会等于请求数）")
	assert_false(probe.reentered, "build 绝不能被并发重入")

	# 加锁不得改变产出：逐 chunk 与串行结果比对
	var serial := PcgModelGenerator.new()
	serial.model = ConcurrentProbeModel.new()
	serial.set_grid_size(Vector3i(64, 32, 32))
	assert_eq(r0, serial.generate(keys[0]), "第 1 个 chunk 的切片内容应与串行一致")
	assert_eq(r1, serial.generate(keys[1]), "第 2 个 chunk 的切片内容应与串行一致")
	assert_eq(r0[VoxelChunk.buf_index(3, 3, 3)], 9,
			"体素 (3,3,3) 应落在第 1 个 chunk 的局部同位置")


# ----------------------------------------------------------------------------
# 辅助
# ----------------------------------------------------------------------------

## 在指定位置种入累计伤害（直接写公开的伤害账，避免依赖原生破坏内核）。
func _seed_damage(data: VoxelData, pos: Vector3i, amount: float) -> void:
	var ck := VoxelChunk.chunk_of(pos)
	var buf := PackedFloat32Array()
	buf.resize(VOL)
	buf[VoxelChunk.buf_index(pos.x - ck.x * CHUNK, pos.y - ck.y * CHUNK, pos.z - ck.z * CHUNK)] = amount
	data.get_damage_buffers()[ck] = buf


## 读取指定位置的累计伤害（无该 chunk 视为 0）。
func _damage_at(data: VoxelData, pos: Vector3i) -> float:
	var ck := VoxelChunk.chunk_of(pos)
	var buf := data.get_damage(ck)
	if buf.is_empty():
		return 0.0
	return buf[VoxelChunk.buf_index(pos.x - ck.x * CHUNK, pos.y - ck.y * CHUNK, pos.z - ck.z * CHUNK)]

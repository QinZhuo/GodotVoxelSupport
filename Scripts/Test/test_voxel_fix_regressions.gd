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

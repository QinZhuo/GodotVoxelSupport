extends TestCase

## P0-6 无头回归测试：固定种子生成 → 网格 → 快照哈希（逐字节）。
##
## 【为什么需要它】P1/P2 要把 VoxelRenderer / QVoxelSource 拆开（声明为"纯搬迁、行为等价"），
## 但"搬迁没改变行为"不能靠肉眼 —— 需要一份**逐字节基线**：同 seed 生成同一块体积、
## 切成同样的 chunk、过同一个几何内核，产物字节序列必须与基线完全一致。任一环节漂移
## （生成算法、chunk 存储布局、halo/面生成、实心-透明分桶、索引偏移、材质判定）都会改变哈希。
##
## 【为什么是黄金常量，而不是"跑两次相等"】只比对两次运行的结果只能测"确定性"，
## 测不出"重构把结果改了"——两边一起变照样相等。故把基线钉死成常量：重构后必须逐字节不变；
## 若确实要合法地改结果（内核调优等），必须同期更新常量并说明原因
## （与 test_voxel_mesh_kernel 的黄金三角形数同一约定）。
##
## 【覆盖路径】QVoxelSource(node = PcgTerrain) → _accept_chunk_buffer
##   → get_all_chunk_keys / _chunk_buffers_view → VoxelMeshGenerator.generate_arrays_from_chunks
##   （内部 = build_halo_from_buffers + NativeLoader.generate_chunk_dense，
##    与 VoxelRenderer 逐 chunk 构建用的是同一条内核）。
##
## 【为什么是编辑器侧】纯数据 + 几何内核，不需要场景树；渲染器的异步/GPU 上传路径
## 由 test_voxel_runtime_smoke（游戏进程）覆盖。

## 48³ 跨 2×2×2 = 8 个 chunk —— 必须跨块才能覆盖"块边界面归属 + halo 缝合"这条路径。
const GRID := Vector3i(48, 48, 48)
const SEED := 12345
const VOXEL_SCALE := 0.1

## 基线（2026-10-08，Godot 4.7.2；FNV-1a 32 位，对"排序后的字节流"取哈希）。
## 逐字节口径：体积 = 按 chunk key 排序后各块 PackedInt32Array.to_byte_array() 依次拼接；
## 网格 = 8 条 arrays（solid/trans × verts/normals/uvs/idxs）按固定顺序拼接。
const GOLD_VOLUME_HASH := 1837387656
const GOLD_MESH_HASH := 1739196767
const GOLD_VOXEL_COUNT := 11548
const GOLD_CHUNK_COUNT := 8
const GOLD_TRIANGLE_COUNT := 5790

## 网格 arrays 的固定拼接顺序（同时也是逐字节哈希的输入顺序）。
const MESH_KEYS := [
	"solid_verts", "solid_normals", "solid_uvs", "solid_idxs",
	"trans_verts", "trans_normals", "trans_uvs", "trans_idxs",
]


# ----------------------------------------------------------------------------
# 基线
# ----------------------------------------------------------------------------

## 固定 seed 生成 → 存储 → 网格：体积哈希、网格哈希、体素数、chunk 数、三角数全部钉死。
func test_snapshot_baseline_is_stable() -> void:
	var d := _build_data(SEED)
	assert_eq(d.get_voxel_count(), GOLD_VOXEL_COUNT, "体素数应与基线一致")
	assert_eq(d.get_all_chunk_keys().size(), GOLD_CHUNK_COUNT, "非空 chunk 数应与基线一致")
	assert_eq(_volume_hash(d), GOLD_VOLUME_HASH, "逐字节体积哈希应与基线一致")

	var arrays := _build_arrays(d)
	assert_eq(_triangle_count(arrays), GOLD_TRIANGLE_COUNT, "三角形数应与基线一致")
	assert_eq(_mesh_hash(arrays), GOLD_MESH_HASH, "逐字节网格哈希应与基线一致")


# ----------------------------------------------------------------------------
# 确定性 / 种子敏感（防"基线恒为常量"的假绿）
# ----------------------------------------------------------------------------

## 同 seed 两次生成必须逐字节一致；换 seed 必须改变体积哈希。
## 前者保证基线是确定性的（否则上面的常量会随机飘），后者保证基线不是"恒为某常数"
## 的空壳（比如数据层整块返回空时，任何 seed 都会得到同一个哈希）。
func test_generation_is_deterministic_and_seed_sensitive() -> void:
	var a := _volume_hash(_build_data(SEED))
	var b := _volume_hash(_build_data(SEED))
	assert_eq(a, b, "同 seed 两次生成应逐字节一致")

	var c := _volume_hash(_build_data(SEED + 1))
	assert_ne(c, a, "不同 seed 应得到不同体积（否则哈希测不出任何东西）")


# ----------------------------------------------------------------------------
# 辅助
# ----------------------------------------------------------------------------

## 固定 seed 的程序化地形 → QVoxelSource（逐 chunk 回填，绕过异步加载，纯主线程确定性）。
func _build_data(seed_v: int) -> QVoxelSource:
	var terrain := PcgTerrain.new()
	terrain.seed = seed_v

	var d := QVoxelSource.new()
	d.materials = _materials()
	d.grid_size = GRID
	d.node = QVoxelModel.of_source(terrain, GRID)
	var last := VoxelChunk.chunk_of(GRID - Vector3i.ONE)
	for cz in range(0, last.z + 1):
		for cy in range(0, last.y + 1):
			for cx in range(0, last.x + 1):
				var ck := Vector3i(cx, cy, cz)
				d._accept_chunk_buffer(ck, d.generate(ck, 0))
	return d


## 走与 VoxelRenderer 同一条内核：块缓冲 → halo → 原生 dense 面生成 → 合并 arrays。
func _build_arrays(d: QVoxelSource) -> Dictionary:
	var trans := VoxelMaterial.build_trans_flags(VoxelMaterial.align_by_id(_materials()))
	return VoxelMeshGenerator.generate_arrays_from_chunks(_sorted_chunks(d), trans, VOXEL_SCALE, Vector3.ZERO)


## chunk 键排序后重建的字典：Dictionary 迭代顺序 = 插入顺序，而生成/回填顺序不保证稳定，
## 故必须显式排序，否则哈希会随调用顺序漂移（那是假失败，不是真回归）。
func _sorted_chunks(d: QVoxelSource) -> Dictionary:
	var keys := d.get_all_chunk_keys()
	keys.sort_custom(func(a, b): return _key_rank(a) < _key_rank(b))
	var bufs := d._chunk_buffers_view()
	var out := {}
	for k in keys:
		out[k] = bufs[k]
	return out


## chunk 键的确定性排序基准（x → y → z 字典序）。
func _key_rank(k: Vector3i) -> int:
	return (k.x * 1000000 + k.y * 1000 + k.z)


## 逐字节体积哈希：排序后的各 chunk 缓冲按 int32 小端字节依次拼接。
func _volume_hash(d: QVoxelSource) -> int:
	var bytes := PackedByteArray()
	var bufs := _sorted_chunks(d)
	for k in bufs:
		bytes.append_array((bufs[k] as PackedInt32Array).to_byte_array())
	return _fnv1a(bytes)


## 逐字节网格哈希：8 条 arrays 按固定顺序拼接（顶点是浮点，取原始 IEEE 字节）。
func _mesh_hash(arrays: Dictionary) -> int:
	var bytes := PackedByteArray()
	for key in MESH_KEYS:
		bytes.append_array(arrays[key].to_byte_array())
	return _fnv1a(bytes)


func _triangle_count(arrays: Dictionary) -> int:
	return (arrays["solid_idxs"].size() + arrays["trans_idxs"].size()) / 3


## FNV-1a 32 位：自实现而非用 PackedByteArray.hash()，使基线不随引擎哈希算法变化而飘。
func _fnv1a(bytes: PackedByteArray) -> int:
	var h := 0x811c9dc5
	for b in bytes:
		h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF
	return h


## PcgTerrain 用到的材质 ID 是 1..9（deep/subsoil/rock×3/grass×3/dry）；
## 全不透明 → trans_flags 全 0。材质表覆盖到最大 ID，避免原生侧按索引取标志越界。
func _materials() -> Array[VoxelMaterial]:
	var mats: Array[VoxelMaterial] = []
	for i in range(1, 10):
		var m := VoxelMaterial.new()
		m.id = i
		mats.append(m)
	return mats

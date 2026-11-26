extends TestCase

## 体素 LOD 降采样内核回归测试（编辑器进程即可，无需游戏进程）。

## cell = 2^LOD_SHIFT = 2 体素；block = 32 大格 = 64 体素 = 2×2×2 chunk
const LOD_SHIFT := 1
## 六个面方向（顺序无关，仅遍历用）
const DIRS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]
## 各面的面内两轴（与 C++ 外缘面映射一致）：face=0(x)→(y,z)，face=1(y)→(x,z)，face=2(z)→(x,y)
const FACE_U := [1, 0, 0]
const FACE_V := [2, 2, 1]
## 参与构造数据的 block：自身 + 6 邻居（每个外缘面都要跟邻居的边缘层对拍）
const DATA_BLOCKS: Array[Vector3i] = [
	Vector3i(0, 0, 0),
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]

var _buffers: Dictionary = {}

# 不变式

## 全量脏大格的 patch 与 halo 中心，都必须等于独立参考实现
func test_lod_patch_full_equals_reference() -> void:
	var hs: int = VoxelChunkGenerator.LOD_BLOCK_HALO_SIZE
	var halo := VoxelChunkGenerator.build_lod_block_halo_from_buffers(_get_buffers(), Vector3i.ZERO, LOD_SHIFT)
	assert_eq(halo.size(), hs * hs * hs, "LOD halo 应为 34³（原生库不可用时会返回空）")
	if halo.size() != hs * hs * hs:
		return
	var ref := _ref_coarse(_get_buffers(), Vector3i.ZERO, 1 << LOD_SHIFT, Vector3i.ZERO, _gmax())
	var patched := NativeLoader.patch_lod_block(_get_buffers(), Vector3i.ZERO, LOD_SHIFT,
			PackedInt32Array(), Vector3i.ZERO, _gmax())
	assert_eq(patched.size(), ref.size(), "patch 结果应为 32³")
	assert_true(patched == ref, "全量 patch 应等于参考实现（首个不一致下标 %d）" % _first_diff(patched, ref))
	var center := VoxelChunk.extract_center_from_halo(halo)
	assert_true(center == ref, "halo 中心应等于参考实现（首个不一致下标 %d）" % _first_diff(center, ref))

## 六个外缘面各自 == 参考实现算出的"邻居 block 边缘大格层"。
func test_lod_halo_faces_match_reference() -> void:
	var hs: int = VoxelChunkGenerator.LOD_BLOCK_HALO_SIZE
	var bs: int = VoxelChunkGenerator.LOD_BLOCK_SIZE
	var halo := VoxelChunkGenerator.build_lod_block_halo_from_buffers(_get_buffers(), Vector3i.ZERO, LOD_SHIFT)
	assert_eq(halo.size(), hs * hs * hs, "LOD halo 应为 34³（原生库不可用时会返回空）")
	if halo.size() != hs * hs * hs:
		return
	for d in DIRS:
		var face := 0 if d.x != 0 else (1 if d.y != 0 else 2)
		var fix: int = 0 if d[face] > 0 else bs - 1
		var halo_pos: int = 0 if d[face] < 0 else hs - 1
		# 邻居 block 在此面方向上的边缘大格层（该轴固定为 fix，另两轴全取）
		var gmin := Vector3i.ZERO
		var gmax := _gmax()
		gmin[face] = fix
		gmax[face] = fix
		var ref := _ref_coarse(_get_buffers(), d, 1 << LOD_SHIFT, gmin, gmax)
		var face_vals := PackedInt32Array()
		var ref_vals := PackedInt32Array()
		face_vals.resize(bs * bs)
		ref_vals.resize(bs * bs)
		var ua: int = FACE_U[face]
		var va: int = FACE_V[face]
		for lv in bs:
			for lu in bs:
				var h := Vector3i.ZERO
				h[face] = halo_pos
				h[ua] = 1 + lu
				h[va] = 1 + lv
				face_vals[lu + lv * bs] = halo[h.x + h.y * hs + h.z * hs * hs]
				var g := Vector3i.ZERO
				g[face] = fix
				g[ua] = lu
				g[va] = lv
				ref_vals[lu + lv * bs] = ref[g.x + g.y * bs + g.z * bs * bs]
		assert_true(face_vals == ref_vals,
				"dir=%s 的外缘面应等于参考实现（首个不一致下标 %d）"
						% [str(d), _first_diff(face_vals, ref_vals)])

## 直接拷版 halo（独立 LOD 数据层）：中心 32³ == 自身大格，6 外缘面 == 邻居 block 的边缘大格层。
func test_lod_halo_direct_copy_matches_reference() -> void:
	var hs: int = VoxelChunkGenerator.LOD_BLOCK_HALO_SIZE
	var bs: int = VoxelChunkGenerator.LOD_BLOCK_SIZE
	var src := _make_lod_data_blocks()
	var halo := VoxelChunkGenerator.build_lod_block_halo_from_lod_buffers(src, Vector3i.ZERO)
	assert_eq(halo.size(), hs * hs * hs, "LOD 数据层 halo 应为 34³（原生库不可用时会返回空）")
	if halo.size() != hs * hs * hs:
		return
	# 中心：逐大格等于自身数据
	var self_buf: PackedInt32Array = src[Vector3i.ZERO]
	for lz in bs:
		for ly in bs:
			for lx in bs:
				assert_eq(halo[(1 + lx) + (1 + ly) * hs + (1 + lz) * hs * hs],
						self_buf[lx + ly * bs + lz * bs * bs], "中心大格 (%d,%d,%d) 应等于自身" % [lx, ly, lz])
	# 六个外缘面：逐格等于邻居 block 的贴边大格层
	for d in DIRS:
		var face := 0 if d.x != 0 else (1 if d.y != 0 else 2)
		var fix: int = 0 if d[face] > 0 else bs - 1
		var halo_pos: int = 0 if d[face] < 0 else hs - 1
		var nb_buf: PackedInt32Array = src[d]
		var ua: int = FACE_U[face]
		var va: int = FACE_V[face]
		var face_vals := PackedInt32Array()
		var ref_vals := PackedInt32Array()
		face_vals.resize(bs * bs)
		ref_vals.resize(bs * bs)
		for lv in bs:
			for lu in bs:
				var h := Vector3i.ZERO
				h[face] = halo_pos
				h[ua] = 1 + lu
				h[va] = 1 + lv
				face_vals[lu + lv * bs] = halo[h.x + h.y * hs + h.z * hs * hs]
				var g := Vector3i.ZERO
				g[face] = fix
				g[ua] = lu
				g[va] = lv
				ref_vals[lu + lv * bs] = nb_buf[g.x + g.y * bs + g.z * bs * bs]
		assert_true(face_vals == ref_vals,
				"dir=%s 的外缘面应等于邻居贴边大格（首个不一致下标 %d）"
						% [str(d), _first_diff(face_vals, ref_vals)])

## 逐级上推（L0→LOD1→LOD2）与从 L0 全量重算，都必须等于参考实现算的 LOD2
func test_lod_pyramid_equals_reference() -> void:
	# 只看前 16 个大格：该区域只用到 chunk (0..1)³ 与上一层 block (0,0,0)
	var rmax := Vector3i(15, 15, 15)
	var ref := _ref_coarse(_get_buffers(), Vector3i.ZERO, 4, Vector3i.ZERO, rmax)
	# LOD1 coarse（从 L0 全量）
	var coarse1 := NativeLoader.patch_lod_block(_get_buffers(), Vector3i.ZERO, LOD_SHIFT,
			PackedInt32Array(), Vector3i.ZERO, _gmax())
	var bs: int = VoxelChunkGenerator.LOD_BLOCK_SIZE
	assert_eq(coarse1.size(), bs * bs * bs, "LOD1 coarse 应为 32³")
	if coarse1.size() != bs * bs * bs:
		return
	# LOD2：逐级上推 vs 从 L0 全量
	var from_lod := NativeLoader.patch_lod_block_from_lod(
			{Vector3i.ZERO: coarse1}, Vector3i.ZERO, 2, PackedInt32Array(), Vector3i.ZERO, rmax)
	var full := NativeLoader.patch_lod_block(_get_buffers(), Vector3i.ZERO, 2,
			PackedInt32Array(), Vector3i.ZERO, rmax)
	assert_true(from_lod == ref, "逐级上推应等于参考实现（首个不一致下标 %d）" % _first_diff(from_lod, ref))
	assert_true(full == ref, "L0 全量重算应等于参考实现（首个不一致下标 %d）" % _first_diff(full, ref))

# 辅助

## 独立参考实现（oracle）：在 [gmin, gmax] 大格范围内按 (z, y, x) 序取第一个非空材质。
func _ref_coarse(buffers: Dictionary, block_key: Vector3i, cell: int,
		gmin: Vector3i, gmax: Vector3i) -> PackedInt32Array:
	var bs: int = VoxelChunkGenerator.LOD_BLOCK_SIZE
	var block_voxels := bs * cell
	var out := PackedInt32Array()
	out.resize(bs * bs * bs)
	for gz in range(gmin.z, gmax.z + 1):
		for gy in range(gmin.y, gmax.y + 1):
			for gx in range(gmin.x, gmax.x + 1):
				var bx := block_key.x * block_voxels + gx * cell
				var by := block_key.y * block_voxels + gy * cell
				var bz := block_key.z * block_voxels + gz * cell
				var mat := 0
				for dz in cell:
					for dy in cell:
						for dx in cell:
							var m := _get_voxel(buffers, bx + dx, by + dy, bz + dz)
							if m != 0:
								mat = m
								break
						if mat != 0:
							break
					if mat != 0:
						break
				out[gx + gy * bs + gz * bs * bs] = mat
	return out

## 按世界体素坐标读 LOD0 数据（不存在 = 空）
func _get_voxel(buffers: Dictionary, wx: int, wy: int, wz: int) -> int:
	var cs: int = VoxelChunk.CHUNK_SIZE
	var ck := Vector3i(_floor_div(wx, cs), _floor_div(wy, cs), _floor_div(wz, cs))
	if not buffers.has(ck):
		return 0
	var buf: PackedInt32Array = buffers[ck]
	var lx := wx - ck.x * cs
	var ly := wy - ck.y * cs
	var lz := wz - ck.z * cs
	return buf[lx + ly * cs + lz * cs * cs]

## 向下取整除法（GDScript 的 int / int 向零截断，负坐标会错）
static func _floor_div(v: int, d: int) -> int:
	var q := v / d
	return q - 1 if q * d > v else q

## block 内最后一个大格的坐标
func _gmax() -> Vector3i:
	var bs: int = VoxelChunkGenerator.LOD_BLOCK_SIZE
	return Vector3i(bs - 1, bs - 1, bs - 1)

## 构造覆盖 DATA_BLOCKS 的 LOD0 chunk 缓冲（懒建并缓存，多个用例复用）
func _get_buffers() -> Dictionary:
	if _buffers.is_empty():
		_buffers = _make_buffers()
	return _buffers

func _make_buffers() -> Dictionary:
	var cell := 1 << LOD_SHIFT
	var sub_per_chunk: int = VoxelChunk.CHUNK_SIZE / cell
	var chunks_per_block: int = VoxelChunkGenerator.LOD_BLOCK_SIZE / sub_per_chunk
	var buffers := {}
	for block in DATA_BLOCKS:
		for cz in chunks_per_block:
			for cy in chunks_per_block:
				for cx in chunks_per_block:
					var ck: Vector3i = block * chunks_per_block + Vector3i(cx, cy, cz)
					buffers[ck] = _make_chunk(ck, cell)
	return buffers

## 单个 32³ chunk：材质由体素在 cell 内的相对位置决定，cell 的 (0,0,0) 体素置空。
func _make_chunk(ck: Vector3i, cell: int) -> PackedInt32Array:
	var cs: int = VoxelChunk.CHUNK_SIZE
	var buf := PackedInt32Array()
	buf.resize(cs * cs * cs)
	var n := 0
	for lz in cs:
		for ly in cs:
			for lx in cs:
				var idx := posmod(ck.x * cs + lx, cell) \
						+ posmod(ck.y * cs + ly, cell) * 2 \
						+ posmod(ck.z * cs + lz, cell) * 4
				buf[n] = 0 if idx == 0 else idx + 1
				n += 1
	return buf

## 构造独立 LOD 数据层：自身 + 6 邻居，每块 32³ 大格，值 = (x*3 + y*5 + z*7 + 1)，
func _make_lod_data_blocks() -> Dictionary:
	var bs: int = VoxelChunkGenerator.LOD_BLOCK_SIZE
	var out := {}
	for block in DATA_BLOCKS:
		var buf := PackedInt32Array()
		buf.resize(bs * bs * bs)
		var n := 0
		for lz in bs:
			for ly in bs:
				for lx in bs:
					buf[n] = (block.x + 8) * 1000 + (block.y + 8) * 100 + (block.z + 8) * 10 + (lx + ly + lz) % 10
					n += 1
		out[block] = buf
	return out

## 首个不一致下标（-1 = 完全相同；长度不同则返回较短者长度）
func _first_diff(a: PackedInt32Array, b: PackedInt32Array) -> int:
	var n := mini(a.size(), b.size())
	for i in n:
		if a[i] != b[i]:
			return i
	return -1 if a.size() == b.size() else n

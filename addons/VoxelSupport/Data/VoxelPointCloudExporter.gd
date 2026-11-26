@tool
class_name VoxelPointCloudExporter
extends RefCounted

## 粒子点云导出器：把体素 chunk 缓冲导出成 GPU 可直接消费的点云（定长 float 数组 + 三张纹理）。

# ── 点云布局（**单一真值**在这里；QVoxelSource 上的同名常量是别名，供既有调用方使用）──

## 每个粒子点的 float 数。
const PARTICLE_STRIDE := 12

## 通道偏移（= PARTICLE_STRIDE 布局的下标）
const P_POS := 0      ## +0..2 世界坐标
const P_MAT := 3      ## 材质 ID
const P_COLOR := 4    ## +0..2 sRGB 基色
const P_SEED := 7     ## 稳定随机 0..1
const P_EMIT := 8     ## 自发光 0..1
const P_METAL := 9    ## 金属度 0..1
const P_ROUGH := 10   ## 粗糙度 0..1
const P_TRANS := 11   ## 透明度 0..1（0 = 不透明）

## 默认粒子点上限。
const PARTICLE_DEFAULT_MAX := 200000

## 材质通道表每组（每材质）的 float 数
const MAT_CHANNELS := 5

## 纹理像素字节数：FORMAT_RGBAF = 4 × float32
const _RGBAF_BYTES := 16

## 组装上下文（唯一入口；QVoxelSource 每次调用现取，不缓存）。
static func as_context(buffers: Dictionary, mats: Array, center: Vector3,
		default_scale_value: float) -> Dictionary:
	return {
		"buffers": buffers,
		"materials": mats,
		"center_offset": center,
		"default_scale": default_scale_value,
	}

## 把体素导出成**连续定长**的粒子点数组（GPU 可直接消费）。
func build_particle_points(ctx: Dictionary, scale: float = -1.0,
		max_points: int = PARTICLE_DEFAULT_MAX, surface_only: bool = true) -> PackedFloat32Array:
	var bufs := _buffers_of(ctx)
	if bufs.is_empty():
		return PackedFloat32Array()
	var s := scale if scale > 0.0 else _default_scale_of(ctx)
	var limit := maxi(1, max_points)
	var mats := _materials_of(ctx)
	var tbl := mat_table(mats)
	var cks := _sorted_chunk_keys(bufs)

	var total := _count_candidates(bufs, cks, tbl, surface_only)
	if total <= 0:
		return PackedFloat32Array()
	# stride = 1 → 全取；否则每 stride 个候选取 1 个（点数 = ceil(total / stride) <=…
	var stride := 1 if total <= limit else int(ceil(float(total) / float(limit)))
	return _collect_candidates(ctx, bufs, cks, tbl, mats, s, stride, surface_only)

## 把点数据上传成 GPU 纹理。
func build_particle_textures(ctx: Dictionary, scale: float = -1.0,
		max_points: int = PARTICLE_DEFAULT_MAX, surface_only: bool = true) -> Dictionary:
	return textures_from_points(build_particle_points(ctx, scale, max_points, surface_only))

## 点数组（布局 = PARTICLE_STRIDE）→ 三张点云纹理 + 包围盒。
static func textures_from_points(pts: PackedFloat32Array) -> Dictionary:
	var n := pts.size() / PARTICLE_STRIDE
	if n <= 0:
		return {"points": pts, "count": 0, "grid_width": 1, "stride": PARTICLE_STRIDE,
				"positions": null, "colors": null, "props": null, "bounds": AABB()}
	var w := maxi(1, int(ceil(sqrt(float(n)))))
	var h := maxi(1, int(ceil(float(n) / float(w))))
	var pixels := w * h
	var pos_bytes := PackedByteArray()
	pos_bytes.resize(pixels * _RGBAF_BYTES)
	var col_bytes := PackedByteArray()
	col_bytes.resize(pixels * _RGBAF_BYTES)
	var props_bytes := PackedByteArray()
	props_bytes.resize(pixels * _RGBAF_BYTES)
	var min_v := Vector3(INF, INF, INF)
	var max_v := -min_v
	for i in n:
		var b := i * PARTICLE_STRIDE
		var o := i * _RGBAF_BYTES
		var px := pts[b + P_POS]
		var py := pts[b + P_POS + 1]
		var pz := pts[b + P_POS + 2]
		# 位置：xyz + w=1
		pos_bytes.encode_float(o, px)
		pos_bytes.encode_float(o + 4, py)
		pos_bytes.encode_float(o + 8, pz)
		pos_bytes.encode_float(o + 12, 1.0)
		# 颜色：线性基色 + 不透明度（纹理里存 alpha = 1 - trans）
		var lin := Color(pts[b + P_COLOR], pts[b + P_COLOR + 1], pts[b + P_COLOR + 2]).srgb_to_linear()
		col_bytes.encode_float(o, lin.r)
		col_bytes.encode_float(o + 4, lin.g)
		col_bytes.encode_float(o + 8, lin.b)
		col_bytes.encode_float(o + 12, 1.0 - pts[b + P_TRANS])
		# 材质属性：metal / rough / emission + 占位
		props_bytes.encode_float(o, pts[b + P_METAL])
		props_bytes.encode_float(o + 4, pts[b + P_ROUGH])
		props_bytes.encode_float(o + 8, pts[b + P_EMIT])
		props_bytes.encode_float(o + 12, 1.0)
		min_v = Vector3(minf(min_v.x, px), minf(min_v.y, py), minf(min_v.z, pz))
		max_v = Vector3(maxf(max_v.x, px), maxf(max_v.y, py), maxf(max_v.z, pz))
	return {
		"points": pts,
		"count": n,
		"grid_width": w,
		"stride": PARTICLE_STRIDE,
		"positions": ImageTexture.create_from_image(
				Image.create_from_data(w, h, false, Image.FORMAT_RGBAF, pos_bytes)),
		"colors": ImageTexture.create_from_image(
				Image.create_from_data(w, h, false, Image.FORMAT_RGBAF, col_bytes)),
		"props": ImageTexture.create_from_image(
				Image.create_from_data(w, h, false, Image.FORMAT_RGBAF, props_bytes)),
		"bounds": AABB(min_v, max_v - min_v),
	}

## 材质通道表：扁平数组，每材质 MAT_CHANNELS = 5 个 float：
static func mat_table(mats: Array) -> PackedFloat32Array:
	var n := maxi(mats.size(), 256)
	var tbl := PackedFloat32Array()
	tbl.resize(n * MAT_CHANNELS)
	for i in n:
		var m: Variant = mats[i] if i < mats.size() else null
		var base := i * MAT_CHANNELS
		if m == null:
			tbl[base] = 0.0
			tbl[base + 1] = 0.0
			tbl[base + 2] = 0.0
			tbl[base + 3] = 1.0
			tbl[base + 4] = 0.0
			continue
		var mat: VoxelMaterial = m if m is VoxelMaterial else VoxelMaterial.from_mate(m, i)
		tbl[base] = 1.0 if mat.trans > 0.001 else 0.0
		tbl[base + 1] = clampf(mat.emission, 0.0, 1.0)
		tbl[base + 2] = clampf(mat.metal, 0.0, 1.0)
		tbl[base + 3] = clampf(mat.rough, 0.0, 1.0)
		tbl[base + 4] = clampf(mat.trans, 0.0, 1.0)
	return tbl

## 材质 -> 基色（sRGB）。
static func color_of(mats: Array, mat_id: int) -> Color:
	if mat_id <= 0 or mat_id >= mats.size():
		return Color.WHITE
	var m: Variant = mats[mat_id]
	if m == null:
		return Color.WHITE
	if m is VoxelMaterial:
		return VoxelMaterial.albedo_color(m)
	if m is Dictionary:
		return VoxelMaterial.albedo_color(VoxelMaterial.from_mate(m, mat_id))
	return Color.WHITE

## 稳定随机：由体素坐标决定，同一格永远同值。
static func particle_seed(pos: Vector3i) -> float:
	var h := (pos.x * 73856093) ^ (pos.y * 19349663) ^ (pos.z * 83492791)
	return float(absi(h) % 100000) / 100000.0

# ── 内部实现 ──────────────────────────────────────────────────────────────

static func _buffers_of(ctx: Dictionary) -> Dictionary:
	var b: Variant = ctx.get("buffers")
	return b if b is Dictionary else {}

static func _materials_of(ctx: Dictionary) -> Array:
	var m: Variant = ctx.get("materials")
	return m if m is Array else []

static func _default_scale_of(ctx: Dictionary) -> float:
	return float(ctx.get("default_scale", 1.0))

static func _center_of(ctx: Dictionary) -> Vector3:
	var c: Variant = ctx.get("center_offset")
	return c if c is Vector3 else Vector3.ZERO

## chunk 键的**确定性排序**（内容坐标的函数，与字典插入序无关）。
static func _sorted_chunk_keys(bufs: Dictionary) -> Array:
	var keys: Array = bufs.keys()
	keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x:
			return a.x < b.x
		if a.y != b.y:
			return a.y < b.y
		return a.z < b.z)
	return keys

## 表面过滤判定（两遍扫描共用，保证"数进去的"与"取出来的"完全一致）。
static func _dropped_as_surface(tbl: PackedFloat32Array, tb: int,
		bufs: Dictionary, ck: Vector3i, buf: PackedInt32Array, li: int) -> bool:
	if tb < tbl.size() and tbl[tb] >= 0.5:
		# 透明体素永远保留：玻璃被邻居包住时仍要能看见后面
		return false
	return _is_inside(bufs, ck, buf, li)

## 第一遍：只数候选点数（与 _collect_candidates 完全同一套过滤，保证 stride 语义精确）。
func _count_candidates(bufs: Dictionary, cks: Array, tbl: PackedFloat32Array,
		surface_only: bool) -> int:
	var vol := VoxelChunk.CHUNK_SIZE * VoxelChunk.CHUNK_SIZE * VoxelChunk.CHUNK_SIZE
	var n := 0
	for ck: Vector3i in cks:
		var buf: PackedInt32Array = bufs[ck]
		for i in vol:
			var mat_id := buf[i]
			if mat_id <= 0:
				continue
			if surface_only and _dropped_as_surface(tbl, mat_id * MAT_CHANNELS, bufs, ck, buf, i):
				continue
			n += 1
	return n

## 第二遍：按全局候选序号等步长取样并装箱。
func _collect_candidates(ctx: Dictionary, bufs: Dictionary, cks: Array, tbl: PackedFloat32Array,
		mats: Array, s: float, stride: int, surface_only: bool) -> PackedFloat32Array:
	var center := _center_of(ctx)
	var tbl_size := tbl.size()
	var vol := VoxelChunk.CHUNK_SIZE * VoxelChunk.CHUNK_SIZE * VoxelChunk.CHUNK_SIZE
	var out := PackedFloat32Array()
	var g := 0
	for ck: Vector3i in cks:
		var buf: PackedInt32Array = bufs[ck]
		var origin := VoxelChunk.origin_of(ck)
		for i in vol:
			var mat_id := buf[i]
			if mat_id <= 0:
				continue
			var tb := mat_id * MAT_CHANNELS
			if surface_only and _dropped_as_surface(tbl, tb, bufs, ck, buf, i):
				continue
			# 全局序号（含被跳过的候选）取模 → 均匀、确定、与加载顺序无关
			var phase := g % stride
			g += 1
			if phase != 0:
				continue
			var pos: Vector3i = origin + VoxelChunk.local_from_index(i)
			var world := (Vector3(pos) + center) * s
			var col := color_of(mats, mat_id)
			out.append(world.x)
			out.append(world.y)
			out.append(world.z)
			out.append(float(mat_id))
			out.append(col.r)
			out.append(col.g)
			out.append(col.b)
			out.append(particle_seed(pos))
			if tb + MAT_CHANNELS <= tbl_size:
				out.append(tbl[tb + 1])
				out.append(tbl[tb + 2])
				out.append(tbl[tb + 3])
				out.append(tbl[tb + 4])
			else:
				# 与 mat_table 里"空材质"的取值一致（不透明 / 无金属 / 全粗糙）
				out.append(0.0)
				out.append(0.0)
				out.append(1.0)
				out.append(0.0)
	return out

## 该格是否被 6 邻居完全包住（表面过滤用）。
static func _is_inside(bufs: Dictionary, ck: Vector3i, buf: PackedInt32Array, li: int) -> bool:
	var cs := VoxelChunk.CHUNK_SIZE
	var sl := VoxelChunk.CHUNK_SLICE
	var last := cs - 1
	var cx := li % cs
	var cy := (li % sl) / cs
	var cz := li / sl
	# 块内快路径：6 邻居都在本块里，直接读密集缓冲（无字典查找）
	if cx > 0 and cy > 0 and cz > 0 and cx < last and cy < last and cz < last:
		return buf[li + 1] > 0 and buf[li - 1] > 0 \
				and buf[li + cs] > 0 and buf[li - cs] > 0 \
				and buf[li + sl] > 0 and buf[li - sl] > 0
	# 块边界：逐轴查相邻块（不存在即视为空气 → 不算被包住）
	var origin := VoxelChunk.origin_of(ck)
	var wx: int = origin.x + cx
	var wy: int = origin.y + cy
	var wz: int = origin.z + cz
	if not _solid_at(bufs, wx + 1, wy, wz):
		return false
	if not _solid_at(bufs, wx - 1, wy, wz):
		return false
	if not _solid_at(bufs, wx, wy + 1, wz):
		return false
	if not _solid_at(bufs, wx, wy - 1, wz):
		return false
	if not _solid_at(bufs, wx, wy, wz + 1):
		return false
	if not _solid_at(bufs, wx, wy, wz - 1):
		return false
	return true

## 世界坐标处是否有实体素（只看内存块，不查磁盘流 —— 表面过滤是近似判断，
static func _solid_at(bufs: Dictionary, x: int, y: int, z: int) -> bool:
	var ck := VoxelChunk.chunk_of(Vector3i(x, y, z))
	var b: Variant = bufs.get(ck)
	if b == null:
		return false
	var buf: PackedInt32Array = b
	var o := VoxelChunk.origin_of(ck)
	return buf[VoxelChunk.buf_index(x - o.x, y - o.y, z - o.z)] > 0

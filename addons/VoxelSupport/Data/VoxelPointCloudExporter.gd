@tool
class_name VoxelPointCloudExporter
extends RefCounted

## 粒子点云导出器：把体素 chunk 缓冲导出成 GPU 可直接消费的点云（定长 float 数组 + 三张纹理）。
##
## 【为什么是独立类，而不是数据层的一个方法段】点云导出是**纯派生计算**（输入块表 + 材质表，
##   输出点云），与 QVoxelSource 的存储不变式（计数账 / 脏账 / 快照 / 流式）毫无关系；它此前
##   在 QVoxelSource 里占了约 240 行，是那份"什么角色都干"的清单里最大的一块可搬走内容。
##
## 【为什么不复用 VoxelParticleView】后者是 Node3D（需要场景树、要建 GPUParticles3D）；
##   而烘焙 / MCP 工具 / 无场景上下文的调用（@tool 脚本、命令行烘焙）根本没有树。
##   本类 extends RefCounted：任何地方 new 出来就能用。
##
## 【为什么不持有任何数据（连宿主引用都不存）】持有宿主引用会形成
##   QVoxelSource → exporter → QVoxelSource 的引用环（GDScript 对象互相持有都不释放），
##   而本类是**派生查询**：每次调用现取上下文，天然不会出现"点云是旧的"两套真值问题。
##   上下文用 Dictionary 传入（不反向依赖 QVoxelSource 类型），见 as_context()。
##
## 【上下文契约】as_context() 产出的字典，本类只读、不改、不保存：
##   "buffers"        Dictionary   {Vector3i chunk_key: PackedInt32Array(32³)}，只读
##   "materials"      Array        索引即材质 ID（0 = 空），元素为 VoxelMaterial 或 MATE Dictionary
##   "center_offset"  Vector3      渲染居中偏移（体素单位，见 QVoxelSource.center_offset）
##   "default_scale"  float        每体素世界单位（scale <= 0 时回落到它）

# ── 点云布局（**单一真值**在这里；QVoxelSource 上的同名常量是别名，供既有调用方使用）──

## 每个粒子点的 float 数。布局见 build_particle_points 的说明。
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

## 默认粒子点上限。超过走**确定性均匀下采样**（按全局候选序号等步长取，同输入同输出）。
## 依据：20 万点的三张纹理各约 4 MB；实测 26 万粒子渲染增量仅 2.5 ms。
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
##
## 布局（每点 PARTICLE_STRIDE = 12 float）：
##   [0..2]  世界坐标 = (体素坐标 + center_offset) × scale —— 与网格渲染同一套定位，
##           故粒子与网格**天然重合**，不需要调用方再去对原点
##   [3]     材质 ID（0 = 空气，不产生点）
##   [4..6]  基色（**sRGB 存储值**，上传纹理时才转线性）
##   [7]     稳定随机种子 0..1（由坐标决定，同一格恒同值，供错峰/相位用）
##   [8..11] emission / metal / rough / trans（0..1）
##
## [param scale] 每体素的世界单位；<= 0 时用上下文里的 default_scale。
## [param max_points] **点数上限（硬上限，语义只有这一条）**：总候选数 <= 它时全取；
##   超过时按 `stride = ceil(total / max_points)` 等步长抽样，返回点数 <= max_points。
##   [b]注意不是"前 N 个"[/b]：上限处处等步长丢弃，覆盖整份数据，不偏向先遇到（先加载）的块。
## [param surface_only] 只留表面体素。**透明体素永远保留**（玻璃被包住也能看见后面）。
##
## 【下采样为什么必须两遍扫】旧实现用"边收集边翻倍步长"的近似（reservoir 式），且判定条件
##   `seen < next_take` 里两者同步递增 → **恒假**，退化成"按字典插入序取前 max_points 个点"：
##   超过上限时后加载的 chunk 整块被丢弃（是**截断**，不是降采样），且结果依赖
##   `_chunk_buffers` 的插入序（同一份数据、不同加载顺序 → 不同点云）。
##   均匀降采样需要知道总数，故先数一遍（只扫描、不装箱），再按全局序号取每 stride 个。
##   计数遍比装箱遍便宜得多（不查颜色、不写 12 个 float），代价约为一成到两成。
##
## 【为什么顺序与字典插入序无关】chunk 键按 (x, y, z) 升序编号，块内按线性下标升序编号 ——
##   两者都是内容坐标的函数，不随加载顺序变化 → 同输入必得同输出（回放/烘焙可复现）。
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
	# stride = 1 → 全取；否则每 stride 个候选取 1 个（点数 = ceil(total / stride) <= limit）
	var stride := 1 if total <= limit else int(ceil(float(total) / float(limit)))
	return _collect_candidates(ctx, bufs, cks, tbl, mats, s, stride, surface_only)


## 把点数据上传成 GPU 纹理。返回：
##   points      PackedFloat32Array（同 build_particle_points）
##   positions   ImageTexture RGBAF：xyz + 占位
##   colors      ImageTexture RGBAF：线性基色 + **不透明度**
##   props       ImageTexture RGBAF：metal / rough / emission / 占位
##   count       实际点数
##   grid_width  纹理排布宽度（着色器用它把 INDEX 映射到纹素）
##   bounds      内容包围盒（世界单位）
##   stride      每点 float 数
##
## 【为什么像素先填进 PackedByteArray 再一次 create_from_data】旧实现每点 set_pixel 三次
##   （位置 / 颜色 / 属性各一次），20 万点就是 60 万次逐像素调用 + 每次一次 Color 装箱；
##   直接按 RGBAF 的字节布局写 float（每像素 16 字节）后一次建图，省掉全部逐像素调用。
##
## 【为什么颜色要转线性】FORMAT_RGBAF 是线性纹理，引擎不做 sRGB→linear 转换；
## VoxelMaterial.color 存的是 sRGB 显示值。直接塞进去等于**双重 gamma** ——
## 暗部整体提亮一倍以上（#444444 显示成 #8d8d8d），画面又白又平。
## 网格路径的 albedo 纹理是 RGBA8(sRGB)，引擎会自动转换，所以两条路径必须在此对齐。
func build_particle_textures(ctx: Dictionary, scale: float = -1.0,
		max_points: int = PARTICLE_DEFAULT_MAX, surface_only: bool = true) -> Dictionary:
	return textures_from_points(build_particle_points(ctx, scale, max_points, surface_only))


## 点数组（布局 = PARTICLE_STRIDE）→ 三张点云纹理 + 包围盒。**纹理烘焙的唯一实现**。
##
## 【为什么是独立公开函数而不是 build_particle_textures 的内段】
##   点云有两条入口：从体素现烘焙（build_particle_textures）与**已经排好序/变换过的点数组**
##   （VoxelParticleView 的空间排序、项目自己做的形态变换）。后者若拿不到这条函数，就只能
##   把"顶点 → RGBAF 像素"的字节布局再抄一份，或者退回去搬运整块纹理像素 —— 前者是两份真值，
##   后者在排序后要白搬 3 × 4MB。公开它，两条入口就共用同一份烘焙。
##
## 返回键：points / count / grid_width / stride / positions / colors / props / bounds。
##   points 原样回传（调用方传入什么就拿到什么），故"纹理内容 ↔ points 顺序"天然一致。
##
## 【为什么是 static】它只读常量与入参，不碰上下文、不碰任何成员 —— 调用方（粒子视图做空间
##   排序后重烘焙）不必为了烘焙一个点数组 new 一个对象，也不必持有上下文。
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
##   [i*5 + 0] 是否透明（表面过滤据此放行）
##   [i*5 + 1] emission  0..1
##   [i*5 + 2] metal     0..1
##   [i*5 + 3] rough     0..1
##   [i*5 + 4] trans     0..1
##
## 【为什么要预计算成扁平数组】逐体素去查 materials 数组要几十毫秒（20 万点量级），
## 而且每次都要判断"是 VoxelMaterial 还是磁盘读回的 MATE Dictionary"。
## 一张表**每次导出只算一次**（旧实现里 build_particle_textures 每点还会 new 一个 VoxelMaterial）。
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


## 材质 -> 基色（sRGB）。兼容 VoxelMaterial 与磁盘读回的 MATE Dictionary。
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
## 【为什么不用 randf】重建点云会重跑，随机种子会让每次运行的粒子相位都不同，回放对不上。
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
## 语义：不透明且被 6 邻居包住 → 丢掉。材质表未覆盖该 ID 时按不透明处理（不越界读）。
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
## [param li] 块内线性下标（x + y*CS + z*CS²）。
## 【透明体素不能在调用处被过滤掉】玻璃被包住时仍能看见后面 —— 见 build_particle_points。
## 【性能】这条在 2 万体素上会被调用上万次，任何"每次新建数组/字典"的写法都会把烘焙
## 拖到 100ms 以上（实测未优化时 174ms）。故全部展开成标量判断。
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
## 为了它去加载磁盘块不值得；未加载的块按空气处理会让边界体素被判为"外露"，
## 那只是多画几个点，方向是安全的）。
static func _solid_at(bufs: Dictionary, x: int, y: int, z: int) -> bool:
	var ck := VoxelChunk.chunk_of(Vector3i(x, y, z))
	var b: Variant = bufs.get(ck)
	if b == null:
		return false
	var buf: PackedInt32Array = b
	var o := VoxelChunk.origin_of(ck)
	return buf[VoxelChunk.buf_index(x - o.x, y - o.y, z - o.z)] > 0

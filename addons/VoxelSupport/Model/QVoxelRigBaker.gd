@tool
class_name QVoxelRigBaker
extends RefCounted
## 把"组=骨骼、模型=刚性部件"的摆放动画**烘焙成体素帧**（ANIM）。
## 【为什么不是蒙皮】蒙皮会让同一立方体的顶点被不同骨骼拉扯，方块被拉伸/剪切；
## 体素美术要的是"每一帧都是一张完整的、轴对齐的体素模型"。因此这里只把骨骼当**摆姿势工具**：
## 采样每帧的世界变换 → 逐体素刚体变换 → 重新光栅化回目标网格 → 写成 QVoxelFrame。
## 【输出仍是普通帧动画】运行时继续用 VoxelAnimator / QVoxelSource.apply_block_table，
## 不需要任何 skin/骨架数据；体素、材质、破坏链路全部沿用现有实现。
## 【两个必须的取舍】
##   1) 任意角度旋转后体素中心会离开原网格，只能重新采样；重采样不是无损的，
##      关节处会有体积增减/跳格，用 fill_gaps + on twos + 低分辨率掩盖。
##   2) 目标模型必须有一个**固定网格**；逐帧按包围盒重新居中会让模型抖，所以这里先统计
##      所有采样帧的保守包围盒，再统一分配一次网格，偏移写进目标模型的 local_transform。
##
## options:
##   frame_count:int        0 = 自动（子树里 transform_tracks / frames 的最大值）
##   frame_step:int         1 = 每帧；2 = on twos；3 = on threes
##   source_fps:int         仅用于生成每帧 duration_ms（默认 12）
##   padding:int            自动网格四周留白（默认 1）
##   grid_size:Vector3i     显式目标网格；ZERO = 自动适配
##   fill_gaps:bool         关节补洞（默认 true）
##   gap_min_neighbors:int  6 邻域至少几个实体才补（默认 3）
##   gap_passes:int         补洞迭代次数（默认 1）
##   include_hidden:bool    连隐藏模型一起烘焙（默认 false）
##   exclude_root_motion:bool true = 根节点的轨道不烘进体素（留给节点位移）；默认 false。
##                           **运行时不消费 group 的 transform_tracks**，所以默认要把根运动也烘进去，
##                           否则产物在游戏里会静止。只有确认运行时会自己驱动根节点时才设 true。
##   loop:bool              输出 anim_loop（默认 true）
##   tags:Array             输出 anim_tags
##   name:String            目标模型名（仅 bake() 用）

const _DEFAULTS := {
	"frame_count": 0,
	"frame_step": 1,
	"source_fps": 12,
	"padding": 1,
	"grid_size": Vector3i.ZERO,
	"fill_gaps": true,
	"gap_min_neighbors": 3,
	"gap_passes": 1,
	"include_hidden": false,
	"exclude_root_motion": false,
	"loop": true,
	"tags": [],
	"name": "Baked",
}


## 新建一个目标模型并烘焙。**不自动挂进世界**（调用方决定挂在哪），但仍会分配 model_id，
## 所以拿到后应立刻 attach，避免下一次 bake 复用同一个 id。
static func bake(world: QVoxelWorld, root: QVoxelNode, options: Dictionary = {}) -> QVoxelModel:
	if world == null or root == null:
		return null
	var target := QVoxelModel.new()
	target.model_id = world.next_model_id()
	target.node_name = str(_opt(options, "name"))
	if not bake_into(world, root, target, options):
		return null
	return target


## 把烘焙结果写进已有模型（编辑器"原地重烘"用）。会清空目标的静态体素与旧帧。
static func bake_into(world: QVoxelWorld, root: QVoxelNode, target: QVoxelModel,
		options: Dictionary = {}) -> bool:
	if world == null or root == null or target == null:
		return false
	if _contains_node(root, target):
		push_error("[QVoxelRigBaker] 目标模型不能位于被烘焙的子树里（会边读边写）")
		return false
	var models := _collect_models(root)
	if models.is_empty():
		push_warning("[QVoxelRigBaker] 子树里没有模型，未烘焙")
		return false
	# 目标块边长先对齐世界：后面 _grid_to_blocks 按它分块。
	target.block_size = world.block_size()

	var step := maxi(1, int(_opt(options, "frame_step")))
	var source_fps := maxi(1, int(_opt(options, "source_fps")))
	var exclude_root_motion := bool(_opt(options, "exclude_root_motion"))
	var include_hidden := bool(_opt(options, "include_hidden"))
	var frame_count := maxi(1, int(_opt(options, "frame_count")))
	if int(_opt(options, "frame_count")) <= 0:
		frame_count = _auto_frame_count(root, models, exclude_root_motion)
	var bake_frames: Array[int] = []
	for k in range(0, frame_count, step):
		bake_frames.append(k)
	if bake_frames.is_empty():
		bake_frames.append(0)

	# 1) 保守包围盒：只变换模型 AABB 的 8 个角，避免逐体素跑两遍。
	var lo := Vector3i(2147483647, 2147483647, 2147483647)
	var hi := Vector3i(-2147483648, -2147483648, -2147483648)
	var found := false
	for k in bake_frames:
		for m in models:
			if not include_hidden and not _visible(world, m):
				continue
			var bounds := _blocks_bounds(m.blocks_for(k), m.block_size)
			if bounds.is_empty():
				continue
			var xf := _bake_transform(world, root, m, k, exclude_root_motion)
			var bmin: Vector3i = bounds["min"]
			var bmax: Vector3i = bounds["max"]
			var minp := Vector3(INF, INF, INF)
			var maxp := Vector3(-INF, -INF, -INF)
			for corner in _box_corners(bmin, bmax + Vector3i.ONE):
				var p: Vector3 = xf * corner
				minp = Vector3(minf(minp.x, p.x), minf(minp.y, p.y), minf(minp.z, p.z))
				maxp = Vector3(maxf(maxp.x, p.x), maxf(maxp.y, p.y), maxf(maxp.z, p.z))
			# 格子范围 = floor(min) .. ceil(max)-1：max 正好落在整数边界时不能多算一格。
			# 注意 -0.0：floori(-0.0) 会得到 -1，直接吃掉一格，故先加/减一个极小量。
			var clo := Vector3i(_cell_lo(minp.x), _cell_lo(minp.y), _cell_lo(minp.z))
			var chi := Vector3i(_cell_hi(maxp.x), _cell_hi(maxp.y), _cell_hi(maxp.z))
			lo = Vector3i(mini(lo.x, clo.x), mini(lo.y, clo.y), mini(lo.z, clo.z))
			hi = Vector3i(maxi(hi.x, chi.x), maxi(hi.y, chi.y), maxi(hi.z, chi.z))
			found = true
	if not found:
		push_warning("[QVoxelRigBaker] 所有采样帧都是空的，未烘焙")
		return false

	var padding := maxi(0, int(_opt(options, "padding")))
	var offset := lo - Vector3i.ONE * padding
	var grid_size: Vector3i = _opt(options, "grid_size")
	if grid_size.x <= 0 or grid_size.y <= 0 or grid_size.z <= 0:
		grid_size = hi - lo + Vector3i.ONE + Vector3i.ONE * (padding * 2)
	grid_size = Vector3i(maxi(grid_size.x, 1), maxi(grid_size.y, 1), maxi(grid_size.z, 1))

	# 2) 逐帧光栅化。多个模型压到同一格时"后写的赢"——树序就是优先级（越靠后越靠前）。
	var frames: Array[QVoxelFrame] = []
	var duration := int(round(float(step) * 1000.0 / float(source_fps)))
	for k in bake_frames:
		var grid := PackedInt32Array()
		grid.resize(grid_size.x * grid_size.y * grid_size.z)
		for m in models:
			if not include_hidden and not _visible(world, m):
				continue
			var xf := _bake_transform(world, root, m, k, exclude_root_motion)
			var inv := xf.affine_inverse()
			_rasterize_model(grid, grid_size, offset, m, k, xf, inv)
		if bool(_opt(options, "fill_gaps")):
			var passes := maxi(0, int(_opt(options, "gap_passes")))
			var need := maxi(1, int(_opt(options, "gap_min_neighbors")))
			for _p in passes:
				if not _fill_gaps(grid, grid_size, need):
					break
		var frame := QVoxelFrame.new()
		frame.duration_ms = duration
		frame.blocks = _grid_to_blocks(grid, grid_size, target.block_size)
		frames.append(frame)

	# 3) 写回目标。帧动画与静态体素互斥（一个 model_id 只有一个体素源）。
	target.clear()
	target.block_size = world.block_size()
	target.grid_size = grid_size
	target.active_frame = 0
	target.anim_fps = source_fps
	target.anim_loop = bool(_opt(options, "loop"))
	var tags: Variant = _opt(options, "tags")
	target.anim_tags = (tags as Array).duplicate() if tags is Array else []
	target.frames = frames
	# 烘焙产物是"根局部空间里的一整块体素"，自身不带旋转/缩放；根的姿态由挂载点承载。
	target.local_transform = Transform3D(Basis.IDENTITY, Vector3(offset))
	target.base_revision += 1
	target.content_changed.emit()
	return true


# 采样与变换

static func _auto_frame_count(root: QVoxelNode, models: Array[QVoxelModel],
		exclude_root_motion: bool) -> int:
	var n := 1
	var group_root := root.is_group()
	for node in _collect_nodes(root):
		# 只有"根是组"时，根轨道才被视为可留在节点上的 root motion。
		# 根是单个模型时，它的轨道就是唯一要烘的东西，不能跳过。
		if node == root and group_root and exclude_root_motion:
			continue
		n = maxi(n, node.transform_tracks.size())
	for m in models:
		n = maxi(n, m.frames.size())
	return n


## 模型局部体素坐标 → 烘焙空间。exclude_root_motion 时用根节点当帧参考系，
## 于是根节点的位移不会烘进体素（可以由运行时节点承载）。
static func _bake_transform(world: QVoxelWorld, root: QVoxelNode, model: QVoxelNode,
		frame: int, exclude_root_motion: bool) -> Transform3D:
	var model_xf: Transform3D = world.world_transform_at(model, frame)
	var root_xf: Transform3D
	if exclude_root_motion and root.is_group():
		root_xf = world.world_transform_at(root, frame)
	else:
		root_xf = world.world_transform_rest(root)
	return root_xf.affine_inverse() * model_xf


# 光栅化

## 逐体素把源立方体变到烘焙空间，再回采目标网格。
## 判定 = "目标格子中心反变换回源空间后是否落在源立方体内"（保守、不会因旋转漏格），
## 另外无条件写入源中心所在格，保证再小的部件至少有一个体素。
static func _rasterize_model(grid: PackedInt32Array, grid_size: Vector3i, offset: Vector3i,
		m: QVoxelModel, frame: int, xf: Transform3D, inv: Transform3D) -> void:
	var bs := m.block_size
	var blocks := m.blocks_for(frame)
	for bk: Vector3i in blocks:
		var buf: Variant = blocks[bk]
		if not (buf is PackedInt32Array) or (buf as PackedInt32Array).size() != QVoxelSpec.block_volume(bs):
			continue
		var arr: PackedInt32Array = buf
		var origin := QVoxelSpec.block_origin(bk, bs)
		for lz in bs:
			for ly in bs:
				for lx in bs:
					var mat := arr[QVoxelSpec.local_index(lx, ly, lz, bs)]
					if mat <= 0:
						continue
					_rasterize_voxel(grid, grid_size, offset, origin + Vector3i(lx, ly, lz),
							mat, xf, inv)


static func _rasterize_voxel(grid: PackedInt32Array, grid_size: Vector3i, offset: Vector3i,
		voxel: Vector3i, mat: int, xf: Transform3D, inv: Transform3D) -> void:
	var lo := Vector3(
			float(voxel.x), float(voxel.y), float(voxel.z))
	var hi := lo + Vector3.ONE
	var c0 := xf * lo
	var c1 := xf * Vector3(hi.x, lo.y, lo.z)
	var c2 := xf * Vector3(lo.x, hi.y, lo.z)
	var c3 := xf * Vector3(hi.x, hi.y, lo.z)
	var c4 := xf * Vector3(lo.x, lo.y, hi.z)
	var c5 := xf * Vector3(hi.x, lo.y, hi.z)
	var c6 := xf * Vector3(lo.x, hi.y, hi.z)
	var c7 := xf * hi
	var minp := Vector3(minf(minf(minf(c0.x, c1.x), minf(c2.x, c3.x)),
			minf(minf(c4.x, c5.x), minf(c6.x, c7.x))),
			minf(minf(minf(c0.y, c1.y), minf(c2.y, c3.y)),
			minf(minf(c4.y, c5.y), minf(c6.y, c7.y))),
			minf(minf(minf(c0.z, c1.z), minf(c2.z, c3.z)),
			minf(minf(c4.z, c5.z), minf(c6.z, c7.z))))
	var maxp := Vector3(maxf(maxf(maxf(c0.x, c1.x), maxf(c2.x, c3.x)),
			maxf(maxf(c4.x, c5.x), maxf(c6.x, c7.x))),
			maxf(maxf(maxf(c0.y, c1.y), maxf(c2.y, c3.y)),
			maxf(maxf(c4.y, c5.y), maxf(c6.y, c7.y))),
			maxf(maxf(maxf(c0.z, c1.z), maxf(c2.z, c3.z)),
			maxf(maxf(c4.z, c5.z), maxf(c6.z, c7.z))))
	var cell_lo := Vector3i(_cell_lo(minp.x), _cell_lo(minp.y), _cell_lo(minp.z))
	var cell_hi := Vector3i(_cell_hi(maxp.x), _cell_hi(maxp.y), _cell_hi(maxp.z))
	var center := xf * (lo + Vector3(0.5, 0.5, 0.5))
	_write_cell(grid, grid_size, offset,
			Vector3i(floori(center.x), floori(center.y), floori(center.z)), mat)
	for cz in range(cell_lo.z, cell_hi.z + 1):
		for cy in range(cell_lo.y, cell_hi.y + 1):
			for cx in range(cell_lo.x, cell_hi.x + 1):
				var p := inv * Vector3(float(cx) + 0.5, float(cy) + 0.5, float(cz) + 0.5)
				if p.x < lo.x - 1e-4 or p.y < lo.y - 1e-4 or p.z < lo.z - 1e-4 \
						or p.x > hi.x + 1e-4 or p.y > hi.y + 1e-4 or p.z > hi.z + 1e-4:
					continue
				_write_cell(grid, grid_size, offset, Vector3i(cx, cy, cz), mat)


## 浮点格子边界 → 含端点的整数格范围。极小量用来吸收 -0.0 与旋转后的浮点误差。
static func _cell_lo(v: float) -> int:
	return floori(v + 1e-5)


static func _cell_hi(v: float) -> int:
	return ceili(v - 1e-5) - 1


static func _write_cell(grid: PackedInt32Array, grid_size: Vector3i, offset: Vector3i,
		cell: Vector3i, mat: int) -> void:
	var p := cell - offset
	if p.x < 0 or p.y < 0 or p.z < 0 \
			or p.x >= grid_size.x or p.y >= grid_size.y or p.z >= grid_size.z:
		return
	grid[p.x + p.y * grid_size.x + p.z * grid_size.x * grid_size.y] = mat


static func _grid_to_blocks(grid: PackedInt32Array, grid_size: Vector3i,
		block_size: int) -> Dictionary:
	var blocks := {}
	var n := QVoxelSpec.block_volume(block_size)
	for z in grid_size.z:
		for y in grid_size.y:
			for x in grid_size.x:
				var mat := grid[x + y * grid_size.x + z * grid_size.x * grid_size.y]
				if mat <= 0:
					continue
				var pos := Vector3i(x, y, z)
				var bk := QVoxelSpec.block_of(pos, block_size)
				var buf: PackedInt32Array = blocks.get(bk, PackedInt32Array())
				if buf.size() != n:
					buf = PackedInt32Array()
					buf.resize(n)
				buf[QVoxelSpec.index_in_block(pos, block_size)] = mat
				blocks[bk] = buf
	return blocks


# 关节补洞：空格的 6 邻域实体数达到阈值时，用邻域里出现最多的材质填上。
static func _fill_gaps(grid: PackedInt32Array, grid_size: Vector3i, need: int) -> bool:
	var fill: Array[Vector3i] = []
	var mats: Array[int] = []
	var sx := grid_size.x
	var sy := grid_size.y
	var sz := grid_size.z
	for z in sz:
		for y in sy:
			for x in sx:
				var idx := x + y * sx + z * sx * sy
				if grid[idx] != 0:
					continue
				var counts := {}
				var solid := 0
				_count_neighbor(grid, grid_size, x - 1, y, z, counts)
				_count_neighbor(grid, grid_size, x + 1, y, z, counts)
				_count_neighbor(grid, grid_size, x, y - 1, z, counts)
				_count_neighbor(grid, grid_size, x, y + 1, z, counts)
				_count_neighbor(grid, grid_size, x, y, z - 1, counts)
				_count_neighbor(grid, grid_size, x, y, z + 1, counts)
				for m in counts:
					solid += int(counts[m])
				if solid < need:
					continue
				var best := 0
				var best_n := -1
				for m in counts:
					if int(counts[m]) > best_n:
						best_n = int(counts[m])
						best = int(m)
				fill.append(Vector3i(x, y, z))
				mats.append(best)
	if fill.is_empty():
		return false
	for i in fill.size():
		var p := fill[i]
		grid[p.x + p.y * sx + p.z * sx * sy] = mats[i]
	return true


static func _count_neighbor(grid: PackedInt32Array, grid_size: Vector3i,
		x: int, y: int, z: int, counts: Dictionary) -> void:
	if x < 0 or y < 0 or z < 0 or x >= grid_size.x or y >= grid_size.y or z >= grid_size.z:
		return
	var m := grid[x + y * grid_size.x + z * grid_size.x * grid_size.y]
	if m > 0:
		counts[m] = int(counts.get(m, 0)) + 1


# 查询

static func _collect_models(root: QVoxelNode) -> Array[QVoxelModel]:
	var out: Array[QVoxelModel] = []
	_collect_models_into(root, out)
	return out


static func _collect_models_into(n: QVoxelNode, out: Array[QVoxelModel]) -> void:
	if n == null:
		return
	if n.is_model():
		out.append(n as QVoxelModel)
		return
	for c in (n as QVoxelGroup).child_nodes:
		_collect_models_into(c, out)


static func _collect_nodes(root: QVoxelNode) -> Array[QVoxelNode]:
	var out: Array[QVoxelNode] = []
	_collect_nodes_into(root, out)
	return out


static func _collect_nodes_into(n: QVoxelNode, out: Array[QVoxelNode]) -> void:
	if n == null:
		return
	out.append(n)
	if n.is_group():
		for c in (n as QVoxelGroup).child_nodes:
			_collect_nodes_into(c, out)


static func _contains_node(root: QVoxelNode, target: QVoxelNode) -> bool:
	if root == null:
		return false
	if root == target:
		return true
	if root.is_group():
		for c in (root as QVoxelGroup).child_nodes:
			if _contains_node(c, target):
				return true
	return false


static func _visible(world: QVoxelWorld, node: QVoxelNode) -> bool:
	var n := node
	while n != null:
		if not n.visible:
			return false
		n = world.find_parent(n)
	return true


## 已分配块的实体包围盒（体素坐标，含端点）。空表返回 {}。
static func _blocks_bounds(blocks: Dictionary, bs: int) -> Dictionary:
	var lo := Vector3i(2147483647, 2147483647, 2147483647)
	var hi := Vector3i(-2147483648, -2147483648, -2147483648)
	var found := false
	for bk: Vector3i in blocks:
		var buf: Variant = blocks[bk]
		if not (buf is PackedInt32Array) or (buf as PackedInt32Array).size() != QVoxelSpec.block_volume(bs):
			continue
		var arr: PackedInt32Array = buf
		var origin := QVoxelSpec.block_origin(bk, bs)
		for lz in bs:
			for ly in bs:
				for lx in bs:
					if arr[QVoxelSpec.local_index(lx, ly, lz, bs)] == 0:
						continue
					var p := origin + Vector3i(lx, ly, lz)
					lo = Vector3i(mini(lo.x, p.x), mini(lo.y, p.y), mini(lo.z, p.z))
					hi = Vector3i(maxi(hi.x, p.x), maxi(hi.y, p.y), maxi(hi.z, p.z))
					found = true
	return {"min": lo, "max": hi} if found else {}


static func _box_corners(lo: Vector3i, hi: Vector3i) -> Array[Vector3]:
	return [
		Vector3(lo.x, lo.y, lo.z),
		Vector3(hi.x, lo.y, lo.z),
		Vector3(lo.x, hi.y, lo.z),
		Vector3(hi.x, hi.y, lo.z),
		Vector3(lo.x, lo.y, hi.z),
		Vector3(hi.x, lo.y, hi.z),
		Vector3(lo.x, hi.y, hi.z),
		Vector3(hi.x, hi.y, hi.z),
	]


static func _opt(options: Dictionary, key: String) -> Variant:
	return options.get(key, _DEFAULTS.get(key))

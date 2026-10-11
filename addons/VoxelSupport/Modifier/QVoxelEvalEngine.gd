class_name QVoxelEvalEngine
extends RefCounted

## 求值引擎 —— 把一棵节点树跑成一块体素体积。
## 【去链之后只剩两件事】
##   QVoxelModel: 自己的手绘体素（to_volume）就是结果，盒 = grid_size，摆放 = offset。
##   QVoxelGroup: 把可见子节点按各自 origin（= 子节点 offset）并成**紧致盒**，再整体偏移本组 offset。
## 程序化生成不再是一条随时生效的修改器链，而是"生成工具"一次性烘焙进 blocks（见 QVoxelGenerate）。
## 于是求值不再有域降级 / 检查点 / 增量复用 —— 那些复杂度随链一起消失。
## 【为什么组仍用紧致盒】组不存体素：它的中间体积取子树内容的并集包围盒，内存成本与内容成正比，
## 而不是与"世界画布"成正比（512³ 一次分配就是 537 MB）。


## 单模型求值（对外入口，等价于 evaluate_node；保留给只关心模型的调用方）。
static func evaluate(obj: QVoxelModel, ctx: QVoxelEvalContext,
		previous: QVoxelEvalResult = null) -> QVoxelEvalResult:
	return evaluate_node(obj, ctx, previous)


## 节点求值：模型 → 自身体素；组 → 按偏移合成子树（紧致盒）。
static func evaluate_node(node: QVoxelNode, ctx: QVoxelEvalContext,
		_previous: QVoxelEvalResult = null, _cache = null) -> QVoxelEvalResult:
	var res := QVoxelEvalResult.new()
	if node == null or not node.visible:
		return res
	res.epoch = ctx.epoch if ctx != null else 0
	var frame := ctx.frame if ctx != null else 0
	if node.is_model():
		var m := node as QVoxelModel
		res.volume = m.to_volume()
		res.grid_size = m.grid_size
		_place(res, Vector3i.ZERO, m.transform_at(frame))
		res.input_signature = "%d|%d|%d,%d,%d|%d" % [
				m.get_instance_id(), m.base_revision,
				m.grid_size.x, m.grid_size.y, m.grid_size.z, m.active_frame]
		return res
	var g := node as QVoxelGroup
	var comp := _composite(g.child_nodes, ctx)
	res.volume = comp["volume"]
	res.grid_size = comp["size"]
	_place(res, comp["lo"], g.transform_at(frame))
	res.input_signature = comp["key"]
	return res


## 只取节点**自身局部**的体积（不含本节点及祖先的摆放）。
## 编辑器按"一个模型一个渲染器 + 渲染器承载摆放"的口径渲染时用它；求值 / 导出继续用 evaluate_node。
## 于是体素坐标恒为 [0, grid)，与编辑工具的 object-local 坐标一致（摆放交给渲染器 transform）。
static func evaluate_local(node: QVoxelNode, ctx: QVoxelEvalContext) -> QVoxelEvalResult:
	var res := QVoxelEvalResult.new()
	if node == null or not node.visible:
		return res
	res.epoch = ctx.epoch if ctx != null else 0
	if node.is_model():
		var m := node as QVoxelModel
		res.volume = m.to_volume()
		res.grid_size = m.grid_size
		res.origin = Vector3i.ZERO
		res.input_signature = "%d|%d|%d,%d,%d|%d" % [
				m.get_instance_id(), m.base_revision,
				m.grid_size.x, m.grid_size.y, m.grid_size.z, m.active_frame]
		return res
	var g := node as QVoxelGroup
	var comp := _composite(g.child_nodes, ctx)
	res.volume = comp["volume"]
	res.grid_size = comp["size"]
	res.origin = comp["lo"]
	res.input_signature = comp["key"]
	return res


## 世界级求值：把所有顶层节点按 origin 合成进一个紧致盒。
static func evaluate_world(world: QVoxelWorld, ctx: QVoxelEvalContext,
		_cache = null) -> QVoxelEvalResult:
	var res := QVoxelEvalResult.new()
	if world == null:
		return res
	var comp := _composite(world.nodes, ctx)
	res.volume = comp["volume"]
	res.grid_size = comp["size"]
	res.origin = comp["lo"]
	res.input_signature = comp["key"]
	res.epoch = ctx.epoch if ctx != null else 0
	return res


## 一个节点的输出盒尺寸（模型 = grid_size；组 = 子树内容并集包围盒）。UI / 装配用。
static func output_grid_size(node: QVoxelNode) -> Vector3i:
	if node == null or not node.visible:
		return Vector3i.ZERO
	if node.is_model():
		return _rotated_size((node as QVoxelModel).grid_size, node.local_transform.basis)
	var g := node as QVoxelGroup
	var any := false
	var lo := Vector3i.ZERO
	var hi := Vector3i.ZERO
	for c in g.child_nodes:
		if c == null or not c.visible:
			continue
		var sz := output_grid_size(c)
		if sz.x <= 0 or sz.y <= 0 or sz.z <= 0:
			continue
		var clo := c.offset
		var chi := clo + sz
		if not any:
			lo = clo
			hi = chi
			any = true
		else:
			lo = Vector3i(mini(lo.x, clo.x), mini(lo.y, clo.y), mini(lo.z, clo.z))
			hi = Vector3i(maxi(hi.x, chi.x), maxi(hi.y, chi.y), maxi(hi.z, chi.z))
	if not any:
		return Vector3i.ZERO
	return _rotated_size(hi - lo, g.local_transform.basis)


# 节点摆放（位置 + 旋转）的唯一应用点

## 把一块"位于自身局部盒 [lo, lo+size) 的体积"按节点变换摆进父画布：
## 先绕局部原点做轴对齐旋转，再平移 xf.origin。旋转保整数 ⇒ 结果 origin 仍是整数。
## 非轴对齐旋转 / 缩放（.qvx 世界不支持）按"不旋转"处理并告警 —— 宁可少给，不可给错。
static func _place(res: QVoxelEvalResult, lo: Vector3i, xf: Transform3D) -> void:
	var t := Vector3i(roundi(xf.origin.x), roundi(xf.origin.y), roundi(xf.origin.z))
	var basis := xf.basis.orthonormalized()
	if res.volume.is_empty() or basis.is_equal_approx(Basis.IDENTITY):
		res.origin = t + lo
		return
	if not _is_axis_aligned(basis):
		push_warning("[QVX] 节点摆放含非轴对齐旋转/缩放，求值按不旋转处理（.qvx 世界仅支持 90° 倍数）")
		res.origin = t + lo
		return
	var r := _rotate_box(res.volume, res.grid_size, lo, basis)
	res.volume = r["volume"]
	res.grid_size = r["size"]
	res.origin = t + r["lo"]


## basis 是否为轴对齐 90° 倍数（每列恰是一个 ±单位轴）。
static func _is_axis_aligned(basis: Basis) -> bool:
	for axis: Vector3 in [basis.x, basis.y, basis.z]:
		if absf(absf(axis.x) + absf(axis.y) + absf(axis.z) - 1.0) > 1e-3:
			return false
	return true


## 绕局部原点旋转一块轴对齐体积（basis 为轴对齐 90° 倍数）。返回 {volume, size, lo}。
## 旋转后包围盒重算，逐父坐标反查源坐标取值（basis 正交 ⇒ 逆 = 转置，整数保持）。
## 【为什么角点用 lo+size-1 而不是 lo+size】体素盒是**离散**的 [lo, lo+size)，反射（如 x→−x）下
## 末格落在 −(size−1) 而非 −size；用连续边算包围盒会整体错开一格、把边界那一层丢掉。
static func _rotate_box(vol: PackedInt32Array, size: Vector3i, lo: Vector3i, basis: Basis) -> Dictionary:
	var inv := basis.transposed()
	var hi := lo + size - Vector3i.ONE
	var mn := Vector3i(2147483647, 2147483647, 2147483647)
	var mx := Vector3i(-2147483648, -2147483648, -2147483648)
	for cx in [lo.x, hi.x]:
		for cy in [lo.y, hi.y]:
			for cz in [lo.z, hi.z]:
				var ip := _round3(basis * Vector3(cx, cy, cz))
				mn = Vector3i(mini(mn.x, ip.x), mini(mn.y, ip.y), mini(mn.z, ip.z))
				mx = Vector3i(maxi(mx.x, ip.x), maxi(mx.y, ip.y), maxi(mx.z, ip.z))
	var nsize := mx - mn + Vector3i.ONE
	var out := PackedInt32Array()
	out.resize(nsize.x * nsize.y * nsize.z)
	var dx := nsize.x
	var dxy := dx * nsize.y
	for z in nsize.z:
		for y in nsize.y:
			var row := y * dx + z * dxy
			for x in nsize.x:
				var l := _round3(inv * Vector3(mn.x + x, mn.y + y, mn.z + z))
				if l.x < lo.x or l.y < lo.y or l.z < lo.z \
						or l.x > hi.x or l.y > hi.y or l.z > hi.z:
					continue
				var m := vol[(l.x - lo.x) + (l.y - lo.y) * size.x + (l.z - lo.z) * size.x * size.y]
				if m != 0:
					out[row + x] = m
	return {"volume": out, "size": nsize, "lo": mn}


## 一块尺寸经轴对齐旋转后的包围盒尺寸（非轴对齐或恒等返回原尺寸）。
static func _rotated_size(size: Vector3i, basis: Basis) -> Vector3i:
	if size.x <= 0 or size.y <= 0 or size.z <= 0:
		return size
	var b := basis.orthonormalized()
	if b.is_equal_approx(Basis.IDENTITY) or not _is_axis_aligned(b):
		return size
	var hi := size - Vector3i.ONE
	var mn := Vector3i(2147483647, 2147483647, 2147483647)
	var mx := Vector3i(-2147483648, -2147483648, -2147483648)
	for cx in [0, hi.x]:
		for cy in [0, hi.y]:
			for cz in [0, hi.z]:
				var ip := _round3(b * Vector3(cx, cy, cz))
				mn = Vector3i(mini(mn.x, ip.x), mini(mn.y, ip.y), mini(mn.z, ip.z))
				mx = Vector3i(maxi(mx.x, ip.x), maxi(mx.y, ip.y), maxi(mx.z, ip.z))
	return mx - mn + Vector3i.ONE


static func _round3(v: Vector3) -> Vector3i:
	return Vector3i(roundi(v.x), roundi(v.y), roundi(v.z))


# 树形合成

## 把一组节点按各自 origin 合成成一块**紧致**体积。返回 {"volume","lo","size","key"}。
static func _composite(nodes: Array, ctx: QVoxelEvalContext) -> Dictionary:
	var acc := PackedInt32Array()
	var lo := Vector3i.ZERO
	var size := Vector3i.ZERO
	var parts := PackedStringArray()
	for item in nodes:
		var c := item as QVoxelNode
		if c == null or not c.visible:
			continue
		var cr := evaluate_node(c, ctx)
		parts.append(cr.input_signature)
		if cr.volume.is_empty() or cr.grid_size.x <= 0:
			continue
		var merged := _merge(acc, lo, size, cr.volume, cr.origin, cr.grid_size)
		acc = merged["volume"]
		lo = merged["lo"]
		size = merged["size"]
	return {"volume": acc, "lo": lo, "size": size, "key": "|".join(parts)}


## 把一个子体积**并**进累积盒（盒可能因此扩大）。
## 只写非零格：并集下"对方是空"不该抹掉已有的实心格。
static func _merge(a: PackedInt32Array, a_lo: Vector3i, a_size: Vector3i,
		b: PackedInt32Array, b_lo: Vector3i, b_size: Vector3i) -> Dictionary:
	if b.is_empty() or b_size.x <= 0 or b_size.y <= 0 or b_size.z <= 0:
		return {"volume": a, "lo": a_lo, "size": a_size}
	if a.is_empty() or a_size.x <= 0 or a_size.y <= 0 or a_size.z <= 0:
		return {"volume": b.duplicate(), "lo": b_lo, "size": b_size}
	var lo := Vector3i(mini(a_lo.x, b_lo.x), mini(a_lo.y, b_lo.y), mini(a_lo.z, b_lo.z))
	var hi := Vector3i(maxi(a_lo.x + a_size.x, b_lo.x + b_size.x),
			maxi(a_lo.y + a_size.y, b_lo.y + b_size.y),
			maxi(a_lo.z + a_size.z, b_lo.z + b_size.z))
	var size := hi - lo
	var out := PackedInt32Array()
	out.resize(size.x * size.y * size.z)
	_blit_union(out, size, lo, a, a_lo, a_size)
	_blit_union(out, size, lo, b, b_lo, b_size)
	return {"volume": out, "lo": lo, "size": size}


## 把 src 并进 dst（dst 的 (0,0,0) 对应父画布坐标 dst_lo）。跳过 0 格。
static func _blit_union(dst: PackedInt32Array, dst_size: Vector3i, dst_lo: Vector3i,
		src: PackedInt32Array, src_lo: Vector3i, src_size: Vector3i) -> void:
	var off := src_lo - dst_lo
	for z in src_size.z:
		var dz := off.z + z
		for y in src_size.y:
			var dy := off.y + y
			var srow := y * src_size.x + z * src_size.x * src_size.y
			var drow := dy * dst_size.x + dz * dst_size.x * dst_size.y
			for x in src_size.x:
				var m := src[srow + x]
				if m > 0:
					dst[drow + off.x + x] = m

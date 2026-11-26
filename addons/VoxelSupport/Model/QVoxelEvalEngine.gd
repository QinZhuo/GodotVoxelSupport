class_name QVoxelEvalEngine
extends RefCounted

## 求值引擎 —— 把一棵节点树跑成一块体素体积。

## 节点求值：模型 → 自身体素；组 → 按偏移合成子树（紧致盒）。
static func evaluate_node(node: QVoxelNode, ctx: QVoxelEvalContext) -> QVoxelEvalResult:
	var res := QVoxelEvalResult.new()
	if node == null or not node.visible:
		return res
	res.epoch = ctx.epoch if ctx != null else 0
	if _cancelled(ctx):
		res.cancelled = true
		return res
	if node.is_model():
		var m := node as QVoxelModel
		res.volume = m.to_volume()
		res.grid_size = m.grid_size
		_place(res, Vector3i.ZERO, m.local_transform, ctx)
		res.input_signature = "%d|%d|%d,%d,%d|%d" % [
				m.get_instance_id(), m.base_revision,
				m.grid_size.x, m.grid_size.y, m.grid_size.z, m.active_frame]
		return res
	var g := node as QVoxelGroup
	var comp := _composite(g.child_nodes, ctx)
	if comp.get("cancelled", false):
		res.cancelled = true
		return res
	res.volume = comp["volume"]
	res.grid_size = comp["size"]
	_place(res, comp["lo"], g.local_transform, ctx)
	res.input_signature = comp["key"]
	return res

## 只取节点**自身局部**的体积（不含本节点及祖先的摆放）。
static func evaluate_local(node: QVoxelNode, ctx: QVoxelEvalContext) -> QVoxelEvalResult:
	var res := QVoxelEvalResult.new()
	if node == null or not node.visible:
		return res
	res.epoch = ctx.epoch if ctx != null else 0
	if _cancelled(ctx):
		res.cancelled = true
		return res
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
	if comp.get("cancelled", false):
		res.cancelled = true
		return res
	res.volume = comp["volume"]
	res.grid_size = comp["size"]
	res.origin = comp["lo"]
	res.input_signature = comp["key"]
	return res

## 世界级求值：把所有顶层节点按 origin 合成进一个紧致盒。
static func evaluate_world(world: QVoxelWorld, ctx: QVoxelEvalContext) -> QVoxelEvalResult:
	var res := QVoxelEvalResult.new()
	if world == null:
		return res
	res.epoch = ctx.epoch if ctx != null else 0
	if _cancelled(ctx):
		res.cancelled = true
		return res
	var comp := _composite(world.nodes, ctx)
	if comp.get("cancelled", false):
		res.cancelled = true
		return res
	res.volume = comp["volume"]
	res.grid_size = comp["size"]
	res.origin = comp["lo"]
	res.input_signature = comp["key"]
	return res

## 节点在**自身空间**的内容盒（体素单位）：模型 = [0, grid_size)，组 = 子节点按各自 offset
static func local_box(node: QVoxelNode) -> AABB:
	if node == null or not node.visible:
		return AABB()
	if node.is_model():
		return AABB(Vector3.ZERO, Vector3((node as QVoxelModel).grid_size))
	var box := AABB()
	var any := false
	for c in (node as QVoxelGroup).child_nodes:
		var cb := local_box(c)
		if cb.size.x <= 0.0 or cb.size.y <= 0.0 or cb.size.z <= 0.0:
			continue
		cb.position += Vector3(c.offset)
		box = cb if not any else box.merge(cb)
		any = true
	return box

# 取消 / 进度（热循环里唯一的对外回调点）

## 每隔多少**行**（y 层）查一次取消回调。
const CANCEL_POLL_ROWS := 64

## 该放弃了吗（无回调 / 无 ctx 时恒 false）。
static func _cancelled(ctx: QVoxelEvalContext) -> bool:
	return ctx != null and ctx.cancelled()

## 被取消时的合成结果：`cancelled` 旗标 + 空体积。
static func _empty_comp() -> Dictionary:
	return {"volume": PackedInt32Array(), "lo": Vector3i.ZERO, "size": Vector3i.ZERO,
			"key": "", "cancelled": true}

# 节点摆放（位置 + 旋转）的唯一应用点

## 把一块"位于自身局部盒 [lo, lo+size) 的体积"按节点变换摆进父画布：
static func _place(res: QVoxelEvalResult, lo: Vector3i, xf: Transform3D,
		ctx: QVoxelEvalContext = null) -> void:
	var t := Vector3i(roundi(xf.origin.x), roundi(xf.origin.y), roundi(xf.origin.z))
	var basis := xf.basis.orthonormalized()
	if res.volume.is_empty() or basis.is_equal_approx(Basis.IDENTITY):
		res.origin = t + lo
		return
	if not _is_axis_aligned(basis):
		push_warning("[QVX] 节点摆放含非轴对齐旋转/缩放，求值按不旋转处理（.qvx 世界仅支持 90° 倍数）")
		res.origin = t + lo
		return
	var r := _rotate_box(res.volume, res.grid_size, lo, basis, ctx)
	if r.get("cancelled", false):
		res.volume = PackedInt32Array()
		res.grid_size = Vector3i.ZERO
		res.origin = Vector3i.ZERO
		res.cancelled = true
		return
	res.volume = r["volume"]
	res.grid_size = r["size"]
	res.origin = t + r["lo"]

## basis 是否为轴对齐 90° 倍数（每列恰是一个 ±单位轴）。
static func _is_axis_aligned(basis: Basis) -> bool:
	for axis: Vector3 in [basis.x, basis.y, basis.z]:
		if absf(absf(axis.x) + absf(axis.y) + absf(axis.z) - 1.0) > 1e-3:
			return false
	return true

## 绕局部原点旋转一块轴对齐体积（basis 为轴对齐 90° 倍数）。
static func _rotate_box(vol: PackedInt32Array, size: Vector3i, lo: Vector3i, basis: Basis,
		ctx: QVoxelEvalContext = null) -> Dictionary:
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
		if z % CANCEL_POLL_ROWS == 0 and _cancelled(ctx):
			return {"cancelled": true}
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

static func _round3(v: Vector3) -> Vector3i:
	return Vector3i(roundi(v.x), roundi(v.y), roundi(v.z))

# 树形合成

## 把一组节点按各自 origin 合成成一块**紧致**体积。
static func _composite(nodes: Array, ctx: QVoxelEvalContext) -> Dictionary:
	var acc := PackedInt32Array()
	var lo := Vector3i.ZERO
	var size := Vector3i.ZERO
	var parts := PackedStringArray()
	var total := nodes.size()
	for i in total:
		if _cancelled(ctx):
			return _empty_comp()
		var item: Variant = nodes[i]
		var c := item as QVoxelNode
		if c == null or not c.visible:
			continue
		var cr := evaluate_node(c, ctx)
		if _cancelled(ctx):
			return _empty_comp()
		parts.append(cr.input_signature)
		if cr.volume.is_empty() or cr.grid_size.x <= 0:
			if total > 1:
				ctx.report(float(i + 1) / float(total))
			continue
		var merged := _merge(acc, lo, size, cr.volume, cr.origin, cr.grid_size, ctx)
		if merged.get("cancelled", false):
			return _empty_comp()
		acc = merged["volume"]
		lo = merged["lo"]
		size = merged["size"]
		if total > 1:
			ctx.report(float(i + 1) / float(total))
	return {"volume": acc, "lo": lo, "size": size, "key": "|".join(parts)}

## 把一个子体积**并**进累积盒（盒可能因此扩大）。
static func _merge(a: PackedInt32Array, a_lo: Vector3i, a_size: Vector3i,
		b: PackedInt32Array, b_lo: Vector3i, b_size: Vector3i,
		ctx: QVoxelEvalContext = null) -> Dictionary:
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
	_blit_union(out, size, lo, a, a_lo, a_size, ctx)
	if _cancelled(ctx):
		return {"cancelled": true}
	_blit_union(out, size, lo, b, b_lo, b_size, ctx)
	if _cancelled(ctx):
		return {"cancelled": true}
	return {"volume": out, "lo": lo, "size": size}

## 把 src 并进 dst（dst 的 (0,0,0) 对应父画布坐标 dst_lo）。
static func _blit_union(dst: PackedInt32Array, dst_size: Vector3i, dst_lo: Vector3i,
		src: PackedInt32Array, src_lo: Vector3i, src_size: Vector3i,
		ctx: QVoxelEvalContext = null) -> void:
	var off := src_lo - dst_lo
	for z in src_size.z:
		if z % CANCEL_POLL_ROWS == 0 and _cancelled(ctx):
			return
		var dz := off.z + z
		for y in src_size.y:
			var dy := off.y + y
			var srow := y * src_size.x + z * src_size.x * src_size.y
			var drow := dy * dst_size.x + dz * dst_size.x * dst_size.y
			for x in src_size.x:
				var m := src[srow + x]
				if m > 0:
					dst[drow + off.x + x] = m

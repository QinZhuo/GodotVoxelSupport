@tool
class_name MeshVoxelizer
extends RefCounted
## 网格快照 → 体素栅格参数 + 逐帧密集体积。真正的算法在原生（`NativeLoader.voxelize_mesh`），
## 这里只做编排：合并零件、定网格、复用调色板。
## 【为什么网格参数在这里定，而不是每帧各算一次】体素帧动画的所有帧必须是**同一套网格**
## （`QVoxelModel` 一个 grid_size 服务全部帧）；逐帧各自归一化会让模型在动画里忽大忽小。

const MIN_RESOLUTION := 4
const MAX_RESOLUTION := 256
const DEFAULT_RESOLUTION := 96


## 所有帧的并集包围盒 → 统一栅格。返回 {origin, cell, grid, empty}。
## `resolution` = **最长边**的体素数，其余轴按比例向上取整（保持模型比例）。
static func frame_grid(scene: Dictionary, resolution := DEFAULT_RESOLUTION) -> Dictionary:
	var box := _bounds(scene)
	var size := box.size
	var longest := maxf(size.x, maxf(size.y, size.z))
	if longest <= 0.000001:
		return {"origin": box.position, "cell": 1.0, "grid": Vector3i.ONE, "empty": true}
	var res := clampi(resolution, MIN_RESOLUTION, MAX_RESOLUTION)
	var cell := longest / float(res)
	var grid := Vector3i(
		clampi(int(ceil(size.x / cell - 0.0001)), 1, res),
		clampi(int(ceil(size.y / cell - 0.0001)), 1, res),
		clampi(int(ceil(size.z / cell - 0.0001)), 1, res))
	return {"origin": box.position, "cell": cell, "grid": grid, "empty": false}


## 指定帧 → 原生体素化。`fill` = 实心化（外部泛洪判定内部）；`palette` 非空则复用它
## （多帧共用一套调色板，否则每帧独立量化会让动画帧间颜色跳变）。
static func voxelize_frame(scene: Dictionary, frame_index: int, rast: Dictionary,
		fill := true, palette := PackedByteArray()) -> Dictionary:
	var frames: Array = scene.get("frames", [])
	if frame_index < 0 or frame_index >= frames.size() or rast.get("empty", true):
		return {}
	var parts: Array = (frames[frame_index] as Dictionary).get("parts", [])
	if parts.is_empty():
		return {}
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var tri_slots := PackedInt32Array()
	for part: Dictionary in parts:
		var pv: PackedVector3Array = part["verts"]
		if pv.is_empty():
			continue
		var base := verts.size()
		verts.append_array(pv)
		uvs.append_array(_fit_uv(part["uvs"], pv.size()))
		colors.append_array(_fit_color(part["colors"], pv.size()))
		var pi: PackedInt32Array = part["indices"]
		var shifted := PackedInt32Array()
		shifted.resize(pi.size())
		for k in pi.size():
			shifted[k] = pi[k] + base
		indices.append_array(shifted)
		var tri := PackedInt32Array()
		tri.resize(pi.size() / 3)
		tri.fill(int(part["slot"]))
		tri_slots.append_array(tri)
	if indices.is_empty():
		return {}
	# 原生选项只在这里组装一次（调色板上限固定 255 = 材质表除空气外的容量）。
	var opts := {"fill": fill}
	if not palette.is_empty():
		opts["palette"] = palette
	return NativeLoader.voxelize_mesh(verts, indices, uvs, colors, tri_slots,
			scene.get("slots", []), rast["origin"], rast["cell"], rast["grid"], opts)


# 内部

static func _bounds(scene: Dictionary) -> AABB:
	var box := AABB()
	var first := true
	for frame: Dictionary in scene.get("frames", []):
		for part: Dictionary in frame.get("parts", []):
			var v: PackedVector3Array = part["verts"]
			for p in v:
				if first:
					box = AABB(p, Vector3.ZERO)
					first = false
				else:
					box = box.expand(p)
	return box


## UV 长度必须与顶点一致（原生按长度判断"有没有 UV"）；缺 UV 的零件补 0。
static func _fit_uv(src: Variant, n: int) -> PackedVector2Array:
	var uv: PackedVector2Array = src if src is PackedVector2Array else PackedVector2Array()
	if uv.size() != n:
		uv = PackedVector2Array()
		uv.resize(n)
		uv.fill(Vector2.ZERO)
	return uv


## 同上；缺颜色补**白**（填零会把整块体素染黑）。
static func _fit_color(src: Variant, n: int) -> PackedColorArray:
	var c: PackedColorArray = src if src is PackedColorArray else PackedColorArray()
	if c.size() != n:
		c = PackedColorArray()
		c.resize(n)
		c.fill(Color.WHITE)
	return c

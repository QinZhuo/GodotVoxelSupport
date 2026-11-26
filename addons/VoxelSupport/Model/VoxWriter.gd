@tool
class_name VoxWriter
extends RefCounted
## `QVoxelWorld` → `.vox` 字节。

const VERSION := 150
## 根节点编号：MagicaVoxel 的约定是 nTRN(0) 套 nGRP(1)，所有顶层节点挂在它下面。
const ROOT_TRN := 0
const ROOT_GRP := 1
## 所有节点统一的图层号。
const DEFAULT_LAYER := 0

## 世界 → `.vox` 字节。
static func encode(world: QVoxelWorld, opts := {}) -> PackedByteArray:
	if world == null or not check(world, opts)["ok"]:
		return PackedByteArray()
	var state := {"next_id": ROOT_GRP + 1, "model_of": {}}
	var body := PackedByteArray()
	body.append_array(_model_chunks(world, state))     # SIZE/XYZI 必须先写（nSHP 要引用）
	body.append_array(_scene_chunks(world, state))
	body.append_array(_palette_chunk(world))
	body.append_array(_material_chunks(world))
	var out := "VOX ".to_ascii_buffer()
	out = _put_u32(out, VERSION)
	out.append_array(_chunk("MAIN", PackedByteArray(), body))
	return out

## 保存前预检。
static func check(world: QVoxelWorld, _opts := {}) -> Dictionary:
	var reasons := PackedStringArray()
	var warnings := PackedStringArray()
	if world == null:
		reasons.append("没有可导出的世界")
		return {"ok": false, "reasons": reasons, "warnings": warnings}
	var models := _non_empty_models(world)
	if models.is_empty():
		reasons.append("世界是空的（没有任何体素）")
	for m in models:
		var gs := m.grid_size
		if maxi(gs.x, maxi(gs.y, gs.z)) > VoxSpace.MAX_EDGE:
			reasons.append("「%s」尺寸 %s 超过 .vox 上限 %d" % [m.display_name(), str(gs), VoxSpace.MAX_EDGE])
		if m.is_animated():
			warnings.append("「%s」是体素帧动画，.vox 只保留当前帧（其余 %d 帧不会写入）"
					% [m.display_name(), m.frame_count() - 1])
	for n in world.all_nodes():
		if n is QVoxelModel and not models.has(n):
			continue
		if VoxSpace.encode_rotation(n.local_transform.basis) < 0:
			reasons.append("「%s」的旋转不是 90° 的整数倍，.vox 只有 24 种朝向" % n.display_name())
		if not _is_integral(n.local_transform.origin):
			reasons.append("「%s」的位置 %s 不是整数，.vox 的平移只能是整数"
					% [n.display_name(), str(n.local_transform.origin)])
	if not reasons.is_empty():
		return {"ok": false, "reasons": reasons, "warnings": warnings}
	for id in world.used_materials():
		var mat := VoxelMaterial.from_mate(world.materials[int(id)], int(id))
		if mat != null and (mat.hardness != 1.0 or mat.mass != 1.0):
			warnings.append("硬度 / 质量不会写入 .vox（格式没有对应字段）")
			break
	return {"ok": true, "reasons": reasons, "warnings": warnings}

# ---- 模型（SIZE + XYZI）----

## 每个非空模型一对 SIZE/XYZI，并登记 model_id（供 nSHP 引用）。
static func _model_chunks(world: QVoxelWorld, state: Dictionary) -> PackedByteArray:
	var out := PackedByteArray()
	var model_of: Dictionary = state["model_of"]
	for m in _non_empty_models(world):
		var vox := _voxels_of(m)
		if vox.is_empty():
			continue
		model_of[m] = model_of.size()
		var size_vox := VoxSpace.to_vox_size(m.grid_size)
		var content := PackedByteArray()
		content.resize(12)
		content.encode_u32(0, size_vox.x)
		content.encode_u32(4, size_vox.y)
		content.encode_u32(8, size_vox.z)
		out.append_array(_chunk("SIZE", content))
		out.append_array(_chunk("XYZI", _xyzi_content(vox)))
	return out

## 非空体素的扁平四元组 (x, y, z, material)，坐标已换成 .vox 口径并平移到非负。
static func _voxels_of(m: QVoxelModel) -> PackedInt32Array:
	var raw := PackedInt32Array()
	# 块内布局与本项目其余部分一致时走原生批量（几十万体素也只是一次扫描）；
	if m.block_size == VoxelChunk.CHUNK_SIZE:
		raw = NativeLoader.collect_all_flat(m.source_blocks())
	else:
		raw = _flatten_slow(m)
	var shift := vox_shift(m.grid_size)
	var out := PackedInt32Array()
	for i in range(0, raw.size(), 4):
		var p := VoxSpace.to_vox_pos(Vector3i(raw[i], raw[i + 1], raw[i + 2])) + shift
		out.append(p.x)
		out.append(p.y)
		out.append(p.z)
		out.append(raw[i + 3])
	return out

static func _flatten_slow(m: QVoxelModel) -> PackedInt32Array:
	var out := PackedInt32Array()
	var bs := m.block_size
	var table := m.source_blocks()
	for bk: Vector3i in table:
		var blk: PackedInt32Array = table[bk]
		var base := bk * bs
		for lz in bs:
			for ly in bs:
				for lx in bs:
					var v := blk[QVoxelSpec.local_index(lx, ly, lz, bs)]
					if v > 0:
						out.append(base.x + lx)
						out.append(base.y + ly)
						out.append(base.z + lz)
						out.append(v)
	return out

static func _xyzi_content(flat: PackedInt32Array) -> PackedByteArray:
	var n := flat.size() / 4
	var out := PackedByteArray()
	out.resize(4 + n * 4)
	out.encode_u32(0, n)
	for i in n:
		var o := 4 + i * 4
		out[o] = flat[i * 4]
		out[o + 1] = flat[i * 4 + 1]
		out[o + 2] = flat[i * 4 + 2]
		out[o + 3] = flat[i * 4 + 3]
	return out

## `.vox` 的 XYZI 是 u8：轴换向后 z 会变成负的，故整体平移到非负（`_t` 会把这段再补偿掉）。
static func vox_shift(size_godot: Vector3i) -> Vector3i:
	return Vector3i(0, maxi(0, size_godot.z - 1), 0)

# ---- 场景图（nTRN / nGRP / nSHP / LAYR）----

static func _scene_chunks(world: QVoxelWorld, state: Dictionary) -> PackedByteArray:
	var out := PackedByteArray()
	var root_ids: Array = []
	var body := _emit_list(world.nodes, root_ids, state, _writable_nodes(world, state))
	# 根壳：nTRN(0) → nGRP(1)。
	out.append_array(_ntrn(ROOT_TRN, "", ROOT_GRP, -1, Transform3D.IDENTITY, Vector3i.ZERO))
	out.append_array(_ngrp(ROOT_GRP, root_ids))
	out.append_array(body)
	out.append_array(_layer_chunk())
	return out

## 可写节点集合：有体素的模型 + 子树里含可写模型的组。
static func _writable_nodes(world: QVoxelWorld, state: Dictionary) -> Dictionary:
	var out := {}
	var model_of: Dictionary = state["model_of"]
	for n in world.nodes:
		if n != null:
			_mark_writable(n, model_of, out)
	return out

static func _mark_writable(node: QVoxelNode, model_of: Dictionary, out: Dictionary) -> bool:
	if node is QVoxelModel:
		if model_of.has(node):
			out[node] = true
			return true
		return false
	var any := false
	for c in (node as QVoxelGroup).child_nodes:
		if c != null and _mark_writable(c, model_of, out):
			any = true
	if any:
		out[node] = true
	return any

## 递归一层节点：分配 id、写 nTRN + 自己的 nGRP/nSHP，把 nTRN id 填进 `out_ids`。
static func _emit_list(nodes: Array, out_ids: Array, state: Dictionary,
		writable: Dictionary) -> PackedByteArray:
	var out := PackedByteArray()
	var model_of: Dictionary = state["model_of"]
	for item in nodes:
		var n := item as QVoxelNode
		if n == null or not writable.has(n):
			continue
		var trn_id: int = state["next_id"]
		var body_id := trn_id + 1
		state["next_id"] = trn_id + 2
		out_ids.append(trn_id)
		if n is QVoxelModel:
			out.append_array(_ntrn(trn_id, n.node_name, body_id, DEFAULT_LAYER, n.local_transform,
					(n as QVoxelModel).grid_size, n.visible))
			out.append_array(_nshp(body_id, int(model_of[n])))
		else:
			var kids: Array = []
			var child_chunks := _emit_list((n as QVoxelGroup).child_nodes, kids, state, writable)
			out.append_array(_ntrn(trn_id, n.node_name, body_id, DEFAULT_LAYER, n.local_transform,
					Vector3i.ZERO, n.visible))
			out.append_array(_ngrp(body_id, kids))
			out.append_array(child_chunks)
	return out

## nTRN（**相对父**的局部变换）。
static func _ntrn(id: int, node_name: String, child: int, layer: int, local_xf: Transform3D,
		model_size: Vector3i, visible := true) -> PackedByteArray:
	var fix := _origin_fix(model_size)
	var t_godot := local_xf * fix
	var t_vox := VoxSpace.to_vox_vec3(t_godot)
	var content := PackedByteArray()
	content = _put_u32(content, id)
	var node_attrs := {}
	if not node_name.is_empty():
		node_attrs["_name"] = node_name
	if not visible:
		# 对象级可见性就在这里（`.vox` 的 `_hidden`），不在 LAYR 上 —— 后者是整层开关。
		node_attrs["_hidden"] = "1"
	content.append_array(_dict(node_attrs))
	content = _put_u32(content, child)
	content = _put_u32(content, -1)          # reserved
	content = _put_u32(content, layer)
	content = _put_u32(content, 1)           # frame 数
	var frame_attrs := {}
	var code := VoxSpace.encode_rotation(local_xf.basis)
	if code >= 0:
		frame_attrs["_r"] = str(code)
	if t_vox.length_squared() > 0.0001:
		frame_attrs["_t"] = "%d %d %d" % [roundi(t_vox.x), roundi(t_vox.y), roundi(t_vox.z)]
	content.append_array(_dict(frame_attrs))
	return _chunk("nTRN", content)

## 给 xf 附加的平移：`-(居中偏移 + 坐标平移)`，两者都在 godot 口径下。
static func _origin_fix(model_size: Vector3i) -> Vector3:
	var offset := Vector3(VoxSpace.origin_offset(model_size))
	var shift := Vector3(VoxSpace.to_godot_pos(vox_shift(model_size)))
	return -(offset + shift)

static func _ngrp(id: int, children: Array) -> PackedByteArray:
	var content := PackedByteArray()
	content = _put_u32(content, id)
	content.append_array(_dict({}))
	content = _put_u32(content, children.size())
	for c in children:
		content = _put_u32(content, int(c))
	return _chunk("nGRP", content)

static func _nshp(id: int, model_id: int) -> PackedByteArray:
	var content := PackedByteArray()
	content = _put_u32(content, id)
	content.append_array(_dict({}))
	content = _put_u32(content, 1)
	content = _put_u32(content, model_id)
	content.append_array(_dict({}))
	return _chunk("nSHP", content)

## 唯一的图层块：id 固定、无名字、不隐藏。
static func _layer_chunk() -> PackedByteArray:
	var content := PackedByteArray()
	content = _put_u32(content, DEFAULT_LAYER)
	content.append_array(_dict({}))
	return _chunk("LAYR", content)

# ---- 调色板与材质 ----

static func _palette_chunk(world: QVoxelWorld) -> PackedByteArray:
	# 官方：文件项 0..254 ↔ 调色板 1..255。
	var content := PackedByteArray()
	content.resize(VoxSpace.PALETTE_SLOTS * 4)
	for id in _write_ids(world):
		var c := world.material_color(id)
		var o := VoxSpace.palette_item(id) * 4
		content[o] = int(round(clampf(c.r, 0.0, 1.0) * 255.0))
		content[o + 1] = int(round(clampf(c.g, 0.0, 1.0) * 255.0))
		content[o + 2] = int(round(clampf(c.b, 0.0, 1.0) * 255.0))
		content[o + 3] = int(round(clampf(c.a, 0.0, 1.0) * 255.0))
	return _chunk("RGBA", content)

## 只写"非默认 diffuse"的材质（`.vox` 缺省就是 diffuse，写全量只是徒增体积）。
static func _material_chunks(world: QVoxelWorld) -> PackedByteArray:
	var out := PackedByteArray()
	for mid in _write_ids(world):
		var mat := VoxelMaterial.from_mate(world.materials[mid], mid)
		if mat == null:
			continue
		var attrs := {}
		# 【判据是"有没有非默认值"，不是"metal > 0"】rough 可以独立于类型存在
		var rough_custom := absf(mat.rough - 1.0) > 0.0005
		if mat.trans > 0.0:
			attrs["_type"] = "_blend" if mat.metal > 0.0 else "_glass"
			attrs["_trans"] = _num(mat.trans)
			if mat.metal > 0.0:
				attrs["_metal"] = _num(mat.metal)
			attrs["_rough"] = _num(mat.rough)
		elif mat.emission > 0.0:
			attrs["_type"] = "_emit"
			attrs["_emit"] = _num(mat.emission)
		elif mat.metal > 0.0 or rough_custom:
			# `_metal` 同时也承载"只有粗糙度不同"的材质：读端会照 `_metal` + `_rough`
			attrs["_type"] = "_metal"
			attrs["_metal"] = _num(mat.metal)
			attrs["_rough"] = _num(mat.rough)
		else:
			continue
		var content := PackedByteArray()
		content = _put_u32(content, mid)
		content.append_array(_dict(attrs))
		out.append_array(_chunk("MATL", content))
	return out

## 要落盘的材质 ID：**被体素用到的** + **表里确有内容的**（排序保证字节稳定）。
static func _write_ids(world: QVoxelWorld) -> Array:
	var ids := {}
	for k in world.used_materials():
		var id := int(k)
		if id >= 1 and id < VoxSpace.PALETTE_SLOTS:
			ids[id] = true
	for i in range(1, mini(VoxSpace.PALETTE_SLOTS, world.materials.size())):
		if not _is_air(world.materials[i]):
			ids[i] = true
	var out := ids.keys()
	out.sort()
	return out

## 判"空气"的规则归 `VoxelMaterial` 所有（材质语义），这里只是本地别名。
static func _is_air(entry: Dictionary) -> bool:
	return VoxelMaterial.is_air_entry(entry)

# ---- 字节工具 ----

static func _non_empty_models(world: QVoxelWorld) -> Array[QVoxelModel]:
	var out: Array[QVoxelModel] = []
	for m in world.all_models():
		if m != null and not m.is_empty():
			out.append(m)
	return out

static func _is_integral(v: Vector3) -> bool:
	return absf(v.x - roundf(v.x)) < 0.001 and absf(v.y - roundf(v.y)) < 0.001 \
			and absf(v.z - roundf(v.z)) < 0.001

static func _num(v: float) -> String:
	return "%.3f" % v

static func _chunk(id: String, content: PackedByteArray,
		children := PackedByteArray()) -> PackedByteArray:
	var out := id.to_ascii_buffer()
	out = _put_u32(out, content.size())
	out = _put_u32(out, children.size())
	out.append_array(content)
	out.append_array(children)
	return out

## `.vox` 的字典：`int32 项数` + 每项 `int32 键长 + 键 + int32 值长 + 值`（不含结尾 -1）。
static func _dict(d: Dictionary) -> PackedByteArray:
	var out := PackedByteArray()
	out = _put_u32(out, d.size())
	for k in d:
		var ks := String(k).to_ascii_buffer()
		var vs := String(d[k]).to_ascii_buffer()
		out = _put_u32(out, ks.size())
		out.append_array(ks)
		out = _put_u32(out, vs.size())
		out.append_array(vs)
	return out

## PackedByteArray 是值类型：resize 触发的写时复制不会回写给调用方，故一律返回新数组。
static func _put_u32(b: PackedByteArray, v: int) -> PackedByteArray:
	var o := b.size()
	b.resize(o + 4)
	b.encode_u32(o, v)
	return b

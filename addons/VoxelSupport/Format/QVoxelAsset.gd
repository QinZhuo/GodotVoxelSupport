class_name QVoxelAsset
extends RefCounted

## QVX 资产的**块级**视图：把 QVoxelDocument 直接交给运行时数据层与网格生成器。

const CHUNK_SIZE := VoxelChunk.CHUNK_SIZE
const CHUNK_VOLUME := VoxelChunk.CHUNK_VOLUME

## 材质（**索引 == 材质ID**；索引 0 恒为 null 空气占位，遵循全项目统一材质契约）
var materials: Array[VoxelMaterial] = []

## model_id(int) → { block_key(Vector3i): PackedInt32Array(CHUNK_VOLUME)…
var models: Dictionary = {}

## 帧动画（§12，`FRAM`）：model_id(int) → { "loop": bool, "fps": int, "tags":…
var animations: Dictionary = {}

## 摆放表：每项 { "model_id": int, "transform": Transform3D, "name": String }。
var placements: Array = []

## HEAD 原始元数据（up_axis / bounds / 自定义键原样保留，供调用方按需读取）
var metadata: Dictionary = {}

var up_axis: String = QVoxelSpec.DEFAULT_UP_AXIS

# 惰性缓存。
var _block_buffers_cache: Dictionary = {}
var _fused_cache: Dictionary = {}
var _fused_bounds_cache: Dictionary = {}
var _block_bounds_cache: Dictionary = {}
var _block_count_cache: Dictionary = {}

# 构造

## 该路径是否由本适配器处理。
static func handles(path: String) -> bool:
	return path.get_extension().to_lower() == QVoxelSpec.FILE_EXT

## 读文件并解析（CRC 校验开启）。
static func from_file(path: String) -> QVoxelAsset:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[QVoxelAsset] 无法读取 %s" % path)
		return null
	var bytes := f.get_buffer(f.get_length())
	f.close()
	var rep := QVoxelFile.QVoxelReport.new()
	var doc: QVoxelFile.QVoxelDocument = QVoxelFile.parse(bytes, true, rep, true)
	if doc == null:
		push_error("[QVoxelAsset] %s 解析失败：%s" % [path, rep.summary()])
		return null
	for w in rep.warnings:
		push_warning("[QVoxelAsset] %s: %s" % [path.get_file(), w])
	return from_document(doc)

## 由已解析文档构造（不做任何逐体素展开）。
static func from_document(doc: QVoxelFile.QVoxelDocument) -> QVoxelAsset:
	var out := QVoxelAsset.new()
	out.metadata = doc.head.duplicate(true)
	out.up_axis = str(doc.head.get(QVoxelSpec.HEAD_UP_AXIS_KEY, QVoxelSpec.DEFAULT_UP_AXIS))
	if out.up_axis == "x":
		push_warning("[QVoxelAsset] up_axis='x' 暂不支持轴向修正，按 'y' 处理")
	# 材质：索引 == 材质ID；条目 0（空气）留 null 占位
	out.materials.resize(maxi(doc.materials.size(), 1))
	for i in doc.materials.size():
		if i == 0:
			continue
		out.materials[i] = VoxelMaterial.from_mate(doc.materials[i], i)
	# 模型块（键统一为 int，与 QVoxelDocument 一致）
	for mid in doc.models:
		var blocks: Variant = doc.models[mid]
		if blocks is Dictionary and not (blocks as Dictionary).is_empty():
			out.models[int(mid)] = (blocks as Dictionary).duplicate()
	# 帧动画（§12）：格式层已把块级增量还原成每帧的**完整块表**，这里只需键类型归一 + 补元数据。
	var anim_meta: Dictionary = doc.anim_meta
	for mid in doc.frames:
		var frames: Variant = doc.frames[mid]
		if not (frames is Array) or (frames as Array).is_empty():
			continue
		var id := int(mid)
		var meta: Dictionary = anim_meta.get(id, {})
		var tags: Variant = meta.get("tags")
		out.animations[id] = {
			"loop": bool(meta.get("loop", QVoxelSpec.ANIM_LOOP_DEFAULT)),
			"fps": maxi(1, int(meta.get("fps", QVoxelSpec.ANIM_FPS_DEFAULT))),
			"tags": (tags as Array).duplicate() if tags is Array else [],
			"frames": (frames as Array).duplicate(),
		}
	out.placements = _placements_from_scene(doc, out.all_model_ids())
	return out

## NODE 场景图 → 摆放表（含每个节点累积后的世界变换）。
static func _placements_from_scene(doc: QVoxelFile.QVoxelDocument, model_ids: Array[int]) -> Array:
	var known := {}
	var pending := {}
	for mid in model_ids:
		known[mid] = true
		pending[mid] = true
	var out: Array = []
	var scene := QVoxelFile.scene_of(doc)
	if scene != null:
		_walk_nodes(scene.nodes, Transform3D.IDENTITY, known, pending, out)
	for mid in pending:
		out.append({"model_id": mid, "transform": Transform3D.IDENTITY, "name": ""})
	return out

## 递归一层：按作者书写顺序先序下行（摆放顺序稳定且符合直觉 —— MeshLibrary 的项名/顺序
static func _walk_nodes(nodes: Array, parent_xf: Transform3D, known: Dictionary,
		pending: Dictionary, out: Array) -> void:
	for item in nodes:
		# 防御：scene 已清洗过，这里只是不让一个坏项把整棵树带崩（与 QVoxelFile 的取向一致）
		if not (item is Dictionary):
			continue
		var node: Dictionary = item
		var world := parent_xf * _node_transform(node)
		if String(node.get("kind", "")) == QVoxelSpec.NODE_KIND_MODEL:
			var mid := int(node.get("model_id", -1))
			if known.has(mid):
				out.append({
					"model_id": mid,
					"transform": world,
					"name": String(node.get("name", "")),
				})
				pending.erase(mid)
			continue   # 模型是叶子，不必再看 children
		var kids: Variant = node.get("children")
		if kids is Array:
			_walk_nodes(kids, world, known, pending, out)

## 单个节点的局部变换。
static func _node_transform(node: Dictionary) -> Transform3D:
	return QVoxelTransform.transform_from_json(node.get("transform"))

# 查询

func is_empty() -> bool:
	return models.is_empty() and animations.is_empty()

## up_axis 轴向修正（QVX 体素坐标 → 引擎 Y-up）。
func axis_fix() -> Basis:
	if up_axis == "z":
		return Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0))
	return Basis()

## 能否**零逐体素展开**地导入：无轴向修正、每个模型恰好被摆放一次、且摆放为恒等。
func is_block_importable() -> bool:
	if axis_fix() != Basis():
		return false
	var seen := {}
	for p in placements:
		var mid: int = p["model_id"]
		if seen.has(mid):
			return false
		seen[mid] = true
		var xf: Transform3D = p["transform"]
		if not (xf.basis.is_equal_approx(Basis.IDENTITY) and xf.origin.is_zero_approx()):
			return false
	return seen.size() == all_model_ids().size()

## 指定模型的块表（不拷贝，只读使用）。
func model_blocks(model_id: int) -> Dictionary:
	var blocks: Variant = models.get(model_id)
	return blocks if blocks is Dictionary else {}

## 全部"有体素的" model_id（静态 + 动画），升序。
func all_model_ids() -> Array[int]:
	var ids: Array[int] = []
	for mid in models:
		ids.append(int(mid))
	for mid in animations:
		ids.append(int(mid))
	ids.sort()
	return ids

## 某个 model_id 的动画项（非动画返回空字典）。
func animation_of(model_id: int) -> Dictionary:
	var a: Variant = animations.get(model_id)
	return a if a is Dictionary else {}

## 动画帧数（非动画模型返回 0）。
func frame_count(model_id: int) -> int:
	var anim := animation_of(model_id)
	if anim.is_empty():
		return 0
	return (anim.get("frames", []) as Array).size()

## 整份资产可切的帧数 = 所有动画模型的最大帧数；全静态资产返回 1（"只有一帧"）。
func total_frame_count() -> int:
	var n := 1
	for mid in animations:
		n = maxi(n, frame_count(int(mid)))
	return n

## 第 k 帧的块表。
func frame_blocks(model_id: int, frame: int) -> Dictionary:
	var anim := animation_of(model_id)
	if anim.is_empty():
		return model_blocks(model_id)
	var frames: Array = anim.get("frames", [])
	if frame < 0 or frame >= frames.size():
		return {}
	var f: Variant = frames[frame]
	if not (f is Dictionary):
		return {}
	var b: Variant = (f as Dictionary).get("blocks")
	return b if b is Dictionary else {}

## 该模型是否带帧动画。
func is_animated(model_id: int) -> bool:
	return animations.has(model_id)

## 全部模型的块表合并（块坐标即 chunk 坐标；仅在 is_block_importable() 时有意义）。
func block_buffers(frame: int = 0) -> Dictionary:
	if _block_buffers_cache.has(frame):
		return _block_buffers_cache[frame]
	var out := {}
	for mid in all_model_ids():
		out.merge(frame_blocks(int(mid), frame))
	_block_buffers_cache[frame] = out
	return out

## 逐体素融合（应用轴向修正 + 各模型摆放）。
func fused_voxels(frame: int = 0) -> Dictionary:
	if _fused_cache.has(frame):
		return _fused_cache[frame]
	var out := {}
	if placements.is_empty():
		_fused_cache[frame] = out
		_fused_bounds_cache[frame] = {}
		return out
	var fix := Transform3D(axis_fix())
	for p in placements:
		var mid: int = p["model_id"]
		var blocks := frame_blocks(mid, frame)
		if blocks.is_empty():
			continue
		var full: Transform3D = fix * (p["transform"] as Transform3D)
		for bk in blocks:
			var buf: PackedInt32Array = blocks[bk]
			var origin: Vector3i = (bk as Vector3i) * CHUNK_SIZE
			var i := 0
			for lz in CHUNK_SIZE:
				for ly in CHUNK_SIZE:
					for lx in CHUNK_SIZE:
						var m: int = buf[i]
						i += 1
						if m <= 0:
							continue
						var wp := full * Vector3(origin.x + lx, origin.y + ly, origin.z + lz)
						out[Vector3i(int(round(wp.x)), int(round(wp.y)), int(round(wp.z)))] = m
	_fused_cache[frame] = out
	_fused_bounds_cache[frame] = VoxelWorldUtil.voxel_bounds(out)
	return out

## 输出坐标系下的体素包围盒 {"min": Vector3i, "max": Vector3i}（含端点）；无体素返回 {}。
func voxel_bounds(frame: int = 0) -> Dictionary:
	if is_block_importable():
		if not _block_bounds_cache.has(frame):
			_block_bounds_cache[frame] = bounds_for_blocks(block_buffers(frame))
		return _block_bounds_cache[frame]
	fused_voxels(frame)
	return _fused_bounds_cache.get(frame, {})

func voxel_count(frame: int = 0) -> int:
	if is_block_importable():
		if not _block_count_cache.has(frame):
			var n := 0
			var bufs := block_buffers(frame)
			for ck in bufs:
				var buf: PackedInt32Array = bufs[ck]
				n += buf.size() - buf.count(0)   # 原生计数（PackedInt32Array.count）
			_block_count_cache[frame] = n
		return _block_count_cache[frame]
	return fused_voxels(frame).size()

## 体素网格尺寸（体素个数）。
func grid_size(frame: int = 0) -> Vector3i:
	var b := voxel_bounds(frame)
	if b.is_empty():
		return Vector3i.ZERO
	return (b["max"] as Vector3i) - (b["min"] as Vector3i) + Vector3i.ONE

## 原点偏移（体素单位，叠加到渲染顶点）：按 `origin_mode`（见 VoxelWorldUtil.OriginMode）。
func origin_offset(origin_mode: int = VoxelWorldUtil.OriginMode.WORLD_ORIGIN,
		frame: int = 0) -> Vector3:
	return VoxelWorldUtil.origin_offset(voxel_bounds(frame), origin_mode)

# 内部：包围盒

## 任意块集合的精确体素包围盒（逐体素判空，只取非空体素）。
static func bounds_for_blocks(blocks: Dictionary) -> Dictionary:
	var lo := Vector3i(2147483647, 2147483647, 2147483647)
	var hi := Vector3i(-2147483648, -2147483648, -2147483648)
	var found := false
	for key in blocks:
		var buf: PackedInt32Array = blocks[key]
		if buf.size() != CHUNK_VOLUME:
			continue
		var origin: Vector3i = (key as Vector3i) * CHUNK_SIZE
		var i := 0
		for lz in CHUNK_SIZE:
			for ly in CHUNK_SIZE:
				for lx in CHUNK_SIZE:
					var m: int = buf[i]
					i += 1
					if m <= 0:
						continue
					var p := origin + Vector3i(lx, ly, lz)
					lo = Vector3i(mini(lo.x, p.x), mini(lo.y, p.y), mini(lo.z, p.z))
					hi = Vector3i(maxi(hi.x, p.x), maxi(hi.y, p.y), maxi(hi.z, p.z))
					found = true
	return {"min": lo, "max": hi} if found else {}

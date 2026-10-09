class_name QVoxelAsset
extends RefCounted

## QVX 资产的**块级**视图：把 QVoxelDocument 直接交给运行时数据层与网格生成器。
##
## 【为什么不复用 VoxAsset】VoxAsset 的形状是 MagicaVoxel 专属的：`nTRN/nGRP/nSHP` 场景图、
## `frames` 动画帧、`LAYR` 可见性、Z-up、以及 `VoxelModel.size` 的"按尺寸居中 + Z 翻转"约定。
## QVX 的对应概念完全不同——**一个 `model_id` 就是一个 `VOX0`，摆放由 `NODE` 的 transform 决定**。
## 把 QVX 塞进 VoxAsset 会有三处失真（此前实测）：
##   1. `check_nodes()` 伪造成"每模型一个 frame"，而 `VoxelFrame` 合并分支在 index==0 时短路
##      → **多模型只导入第一个，其余静默丢失**；
##   2. `NODE` 场景图完全不参与 → **各模型的位置/旋转丢失**；
##   3. 体素被摊平成 `Dictionary[Vector3i,int]` 再逐体素重映射回去 → 大模型多趟全量字典操作。
##
## 【为什么本类以"块"为核心】QVX 的 `block_size` 恒等于 `VoxelChunk.CHUNK_SIZE`，
## 块坐标就是 chunk 坐标：因此"导入"在常见情形下只是一次块缓冲搬运（零逐体素重映射）。
## 只有需要融合变换（非恒等摆放 / 非 Y 朝上）时才逐体素展开——见 `is_block_importable()`。
##
## 与 `VoxAsset` 的分工：`.vox` 走 `VoxAsset`，`.qvx` 走本类。两者都由导入器按扩展名分派。

const CHUNK_SIZE := VoxelChunk.CHUNK_SIZE
const CHUNK_VOLUME := VoxelChunk.CHUNK_VOLUME

## 材质（**索引 == 材质ID**；索引 0 恒为 null 空气占位，遵循全项目统一材质契约）
var materials: Array[VoxelMaterial] = []

## model_id(int) → { block_key(Vector3i): PackedInt32Array(CHUNK_VOLUME) }
var models: Dictionary = {}

## 摆放表：每项 { "model_id": int, "transform": Transform3D, "name": String }。
## 来自 NODE 场景图（组的 transform 逐层累积到模型节点）；NODE 缺失或未引用某个模型时，
## 为该模型补一条恒等摆放。
##
## 【为什么没有"帧"这一维】`animations[].frames` 的键是**节点下标**，而 v3 的节点树是嵌套的、
## 没有下标这层身份（见 QVoxelFile 的 NODE 清洗）。于是动画在 v3 里只是"原样透传的遗留键"，
## 不参与摆放 —— 同一个文件无论看哪一帧，摆放都相同。
var placements: Array = []

## HEAD 原始元数据（up_axis / bounds / 自定义键原样保留，供调用方按需读取）
var metadata: Dictionary = {}

var up_axis: String = QVoxelSpec.DEFAULT_UP_AXIS

# 惰性缓存
var _block_buffers: Dictionary = {}
var _fused: Variant = null
var _fused_bounds: Dictionary = {}
var _block_bounds: Dictionary = {}
var _block_count: int = -1


# ----------------------------------------------------------------------------
# 构造
# ----------------------------------------------------------------------------

## 该路径是否由本适配器处理。导入器按扩展名分派：`.qvx` → QVoxelAsset，`.vox` → VoxAsset。
static func handles(path: String) -> bool:
	return path.get_extension().to_lower() == QVoxelSpec.FILE_EXT


## 读文件并解析（CRC 校验开启）。失败返回 null 并报错。
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
	out.up_axis = str(doc.head.get("up_axis", QVoxelSpec.DEFAULT_UP_AXIS))
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
	out.placements = _placements_from_scene(doc, out.models)
	return out


## NODE 场景图 → 摆放表（含每个节点累积后的世界变换）。
## 未出现在场景图中的模型补恒等摆放，保证"文件里有几个 VOX0 就导入几个"。
##
## 【嵌套树直接递归下行】v3 的 nodes[] 每个节点自带 children[]（组）或 model_id（模型），
## "谁是根、谁是子"是结构本身 —— 不再需要"扫一遍 children 反查父表 + 挑出无父者"那一套
## （那套复杂度全部来自"身份即位置"的扁平表示，见 QVoxelFile 的 NODE 清洗）。
static func _placements_from_scene(doc: QVoxelFile.QVoxelDocument, models: Dictionary) -> Array:
	var pending := {}
	for mid in models:
		pending[mid] = true
	var out: Array = []
	var scene: QVoxelFile.QVoxelSceneGraph = doc.scene
	if scene != null:
		_walk_nodes(scene.nodes, Transform3D.IDENTITY, models, pending, out)
	for mid in pending:
		out.append({"model_id": mid, "transform": Transform3D.IDENTITY, "name": ""})
	return out


## 递归一层：按作者书写顺序先序下行（摆放顺序稳定且符合直觉 —— MeshLibrary 的项名/顺序
## 直接来自这里）。`parent_xf` 是父组累积下来的世界变换。
static func _walk_nodes(nodes: Array, parent_xf: Transform3D, models: Dictionary,
		pending: Dictionary, out: Array) -> void:
	for item in nodes:
		# 防御：scene 已清洗过，这里只是不让一个坏项把整棵树带崩（与 QVoxelFile 的取向一致）
		if not (item is Dictionary):
			continue
		var node: Dictionary = item
		var world := parent_xf * _node_transform(node)
		if String(node.get("kind", "")) == "model":
			var mid := int(node.get("model_id", -1))
			if models.has(mid):
				out.append({
					"model_id": mid,
					"transform": world,
					"name": String(node.get("name", "")),
				})
				pending.erase(mid)
			continue   # 模型是叶子，不必再看 children
		var kids: Variant = node.get("children")
		if kids is Array:
			_walk_nodes(kids, world, models, pending, out)


## 单个节点的局部变换。三个字段全部可选，缺省即恒等：
##   `t` 平移 `[x, y, z]`（体素单位）
##   `r` 旋转 **单位四元数** `[x, y, z, w]`（与 glTF 同构）
##   `s` 缩放 `[x, y, z]`
##
## 【为什么旋转不是 0–23 朝向索引】那是 MagicaVoxel 为 `.vox` 的 `nTRN` 发明的省字节
## 编码：只有 24 种轴对齐朝向，还隐含 Z-up 约定。`.qvx` 是通用容器，没有义务继承它——
## 四元数只多一个浮点数就能表达任意旋转，且与 `Quaternion` / `Basis` / `Transform3D`
## 直接对接，读写两端不需要任何查表或位运算（那套解码留在 `VoxAccess` 里，只服务 `.vox`）。
##
## 三者按 T·R·S 组合（与 glTF / 常规场景图层级一致：缩放先于旋转作用于节点自身坐标系）。
## 非单位缩放会破坏"体素坐标是整数"这一前提，因此带缩放的摆放自动落到逐体素融合路径
## （`is_block_importable()` 为假），由 `fused_voxels()` 取整投影。
static func _node_transform(node: Dictionary) -> Transform3D:
	var xf: Variant = node.get("transform")
	var d: Dictionary = xf if xf is Dictionary else {}
	if d.is_empty():
		return Transform3D.IDENTITY
	var basis := Basis(_quaternion(d.get("r")))
	var sv: Variant = d.get("s")
	if sv is Array and (sv as Array).size() >= 3:
		var sa: Array = sv
		basis = basis * Basis.from_scale(Vector3(float(sa[0]), float(sa[1]), float(sa[2])))
	return Transform3D(basis, _vec3(d.get("t")))


## `[x, y, z]` → Vector3。字段缺失或格式非法时取零。
static func _vec3(v: Variant) -> Vector3:
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO


## `[x, y, z, w]` → 单位四元数。字段缺失、格式非法或长度为零时取恒等。
static func _quaternion(v: Variant) -> Quaternion:
	if v is Array and (v as Array).size() >= 4:
		var a: Array = v
		var q := Quaternion(float(a[0]), float(a[1]), float(a[2]), float(a[3]))
		if q.length_squared() > 0.0:
			return q.normalized()
	return Quaternion.IDENTITY


# ----------------------------------------------------------------------------
# 查询
# ----------------------------------------------------------------------------

func is_empty() -> bool:
	return models.is_empty()


## up_axis 轴向修正（QVX 体素坐标 → 引擎 Y-up）。
## 与 `.vox` 侧同一约定：(x,y,z) → (x, z, -y)。
func axis_fix() -> Basis:
	if up_axis == "z":
		return Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0))
	return Basis()


## 能否**零逐体素展开**地导入：无轴向修正、每个模型恰好被摆放一次、且摆放为恒等。
## 成立时导入 = 块缓冲搬运（QVX 块坐标 == chunk 坐标）。
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
	return seen.size() == models.size()


## 指定模型的块表（不拷贝，只读使用）。
func model_blocks(model_id: int) -> Dictionary:
	var blocks: Variant = models.get(model_id)
	return blocks if blocks is Dictionary else {}


## 全部模型的块表合并（块坐标即 chunk 坐标；仅在 is_block_importable() 时有意义）。
func block_buffers() -> Dictionary:
	if _block_buffers.is_empty():
		var out := {}
		for mid in models:
			out.merge(model_blocks(mid))
		_block_buffers = out
	return _block_buffers


## 逐体素融合（应用轴向修正 + 各模型摆放）。仅在需要变换时调用。
func fused_voxels() -> Dictionary:
	if _fused != null:
		return _fused
	var out := {}
	if placements.is_empty():
		_fused = out
		return out
	var fix := Transform3D(axis_fix())
	for p in placements:
		var mid: int = p["model_id"]
		if not models.has(mid):
			continue
		var full: Transform3D = fix * (p["transform"] as Transform3D)
		var blocks: Dictionary = models[mid]
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
	_fused = out
	_fused_bounds = VoxelData.voxel_bounds(out)
	return _fused


## 输出坐标系下的体素包围盒 {"min": Vector3i, "max": Vector3i}（含端点）；无体素返回 {}。
func voxel_bounds() -> Dictionary:
	if is_block_importable():
		if _block_bounds.is_empty():
			_block_bounds = bounds_for_blocks(block_buffers())
		return _block_bounds
	fused_voxels()
	return _fused_bounds


func voxel_count() -> int:
	if is_block_importable():
		if _block_count < 0:
			var n := 0
			for ck in block_buffers():
				var buf: PackedInt32Array = block_buffers()[ck]
				n += buf.size() - buf.count(0)   # 原生计数（PackedInt32Array.count）
			_block_count = n
		return _block_count
	return fused_voxels().size()


## 体素网格尺寸（体素个数）。
func grid_size() -> Vector3i:
	var b := voxel_bounds()
	if b.is_empty():
		return Vector3i.ZERO
	return (b["max"] as Vector3i) - (b["min"] as Vector3i) + Vector3i.ONE


## 原点偏移（体素单位，叠加到渲染顶点）：按 `origin_mode`（见 VoxelData.OriginMode）。
## 与 `.vox` 路径共用 `VoxelData.origin_offset` 这一处实现——"两条路径位置一致"的保证就在这里。
func origin_offset(origin_mode: int = VoxelData.OriginMode.WORLD_ORIGIN) -> Vector3:
	return VoxelData.origin_offset(voxel_bounds(), origin_mode)


# ----------------------------------------------------------------------------
# 内部：包围盒
# ----------------------------------------------------------------------------

## 任意块集合的精确体素包围盒（逐体素判空，只取非空体素）。
## 分项导出（每模型/每节点一份网格）也要各自居中，故做成静态可复用。
## 注：体素字典（{Vector3i: 材质ID}）求界已统一到 `VoxelData.voxel_bounds`，此处只保留
## "块缓冲"这一种输入形状（按 chunk 展开、逐体素判空是它唯一的差别）。
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




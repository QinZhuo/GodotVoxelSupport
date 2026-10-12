@tool
class_name QVoxelBuilder
extends RefCounted

## 程序化建模的**统一入口**：图元（`VoxelPrimitives`，与画笔同一实现）+ 调色板 + 落盘（`QVoxelFile`）。
## 【给谁用】脚本 / AI 生成 `.qvx`：
##     var b := QVoxelBuilder.new()
##     var skin := b.add_material(Color(0.79, 0.54, 0.36))
##     b.box(Vector3i(12, 23, 4), Vector3i(17, 28, 9), skin)
##     b.save("res://demo/samples/foo.qvx")
## 【坐标】对象局部体素坐标（可从负起）；默认单块 `block_size=32`，超出会自动落到更多块。
## 【为什么薄】它只是"图元 + 调色板 + 序列化"的编排；形状算法全在 `VoxelPrimitives`，
## 于是"脚本建的模型"与"编辑器画的"天然一致。

var grid_size: Vector3i
var block_size: int

var _voxels := {}          # Vector3i -> 材质 ID
var _palette: Array = [{"rgba": 0}]   # 索引 0 = 空气（QVX 不变量）


func _init(grid_size := Vector3i(32, 32, 32), block_size := QVoxelSpec.DEFAULT_BLOCK_SIZE) -> void:
	self.grid_size = grid_size
	self.block_size = block_size


# 材质

## 追加一个材质，返回其 ID（从 1 起；0 恒为空气）。
func add_material(color: Color, metal := 0.0, rough := 0.8,
		hardness := 0.5, mass := 0.5, emission := Color.BLACK) -> int:
	var id := _palette.size()
	_palette.append({
		"rgba": (color.r8 << 24) | (color.g8 << 16) | (color.b8 << 8) | color.a8,
		"metal": _byte(metal), "rough": _byte(rough),
		"hardness": _byte(hardness), "mass": _byte(mass),
		"e_r": _byte(emission.r), "e_g": _byte(emission.g), "e_b": _byte(emission.b),
	})
	return id


## 已声明的材质数量（不含空气槽 0）—— 供调用方判断可用材质 ID 上界。
func material_count() -> int:
	return _palette.size() - 1


# 图元（与画笔共用 VoxelPrimitives）

## 单个体素。
func put(pos: Vector3i, material: int) -> void:
	_voxels[pos] = material


## 把任意格子集合盖成同一材质 —— 图元结果的统一落笔入口。
## 【为什么必须有它】`VoxelPrimitives.dilate` / `dilate_plane` / `region` 产出的都是
## `Array[Vector3i]`，没有公开落笔口的话这些结果就只能烂在手上；只留 line/box/ball 三个
## 固定形状不够程序化 / AI 建模用。
func paint(cells: Array[Vector3i], material: int) -> void:
	for p in cells:
		_voxels[p] = material


## 3D 直线（Bresenham，26-连通）。
func line(a: Vector3i, b: Vector3i, material: int) -> void:
	paint(VoxelPrimitives.line(a, b), material)


## 实心长方体（两角点含端点）。
func box(a: Vector3i, b: Vector3i, material: int) -> void:
	paint(VoxelPrimitives.box(a, b), material)


## 欧氏球。
func ball(center: Vector3i, radius: int, material: int) -> void:
	paint(VoxelPrimitives.ball(center, radius), material)


## 已写格子 → 材质表（供只读查询 / 自定义图元）。
func voxels() -> Dictionary:
	return _voxels


# 落盘

## 构建 QVX 文档（单模型 + NODE 摆放 + HEAD.bounds，bounds 按块对齐）。
func to_document() -> QVoxelFile.QVoxelDocument:
	var doc := QVoxelFile.QVoxelDocument.new()
	doc.head = {
		"qvox": QVoxelSpec.VERSION,
		QVoxelSpec.HEAD_CHANNEL_KEY: QVoxelSpec.DOMINANT_CHANNEL,
		QVoxelSpec.HEAD_BPP_KEY: QVoxelSpec.CHANNEL_BPP,
		"block_size": block_size,
		"up_axis": QVoxelSpec.DEFAULT_UP_AXIS,
	}
	if not _voxels.is_empty():
		var b := _block_bounds()
		doc.head["bounds"] = {"min": [b[0].x, b[0].y, b[0].z], "max": [b[1].x, b[1].y, b[1].z]}
	doc.materials = _palette
	if not _voxels.is_empty():
		doc.models[0] = _to_blocks()
		doc.node = {"nodes": [{"kind": "model", "model_id": 0, "name": "model"}]}
	return doc


## 写成 `.qvx`（含 CRC）。返回是否成功。
func save(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("[QVoxelBuilder] 无法写入 %s" % path)
		return false
	f.store_buffer(QVoxelFile.serialize(to_document(), true))
	f.close()
	return true


# 内部

func _byte(v: float) -> int:
	return int(round(clampf(v, 0.0, 1.0) * 255.0))


## 体素字典 → 块表（按块坐标聚合，块内用 QVoxelSpec 的 ZXY 线性下标）。
func _to_blocks() -> Dictionary:
	var n := block_size * block_size * block_size
	var blocks := {}
	for pos in _voxels:
		var p: Vector3i = pos
		var bk := QVoxelSpec.block_of(p, block_size)
		var buf: PackedInt32Array
		if blocks.has(bk):
			buf = blocks[bk]
		else:
			buf = PackedInt32Array()
			buf.resize(n)
		buf[QVoxelSpec.index_in_block(p, block_size)] = int(_voxels[pos])
		blocks[bk] = buf
	return blocks


## HEAD.bounds 约束**块**区间（校验按 k*B..k*B+B 判），故按块对齐。
func _block_bounds() -> Array:
	var lo := Vector3i(1 << 30, 1 << 30, 1 << 30)
	var hi := Vector3i(-(1 << 30), -(1 << 30), -(1 << 30))
	for pos in _voxels:
		var p: Vector3i = pos
		lo = Vector3i(mini(lo.x, p.x), mini(lo.y, p.y), mini(lo.z, p.z))
		hi = Vector3i(maxi(hi.x, p.x), maxi(hi.y, p.y), maxi(hi.z, p.z))
	var blo := Vector3i(floori(lo.x / float(block_size)), floori(lo.y / float(block_size)),
			floori(lo.z / float(block_size))) * block_size
	var bhi := Vector3i(floori(hi.x / float(block_size)) + 1, floori(hi.y / float(block_size)) + 1,
			floori(hi.z / float(block_size)) + 1) * block_size
	return [blo, bhi]

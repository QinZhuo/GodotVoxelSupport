@tool
extends RefCounted

## 用新的 `QVoxelBuilder`（图元 + 调色板 + 落盘）程序化生成一座中世纪半木结构小屋。
## 坐标系：y 上，正面（门窗）朝 +z。

const PATH := "res://demo/samples/cottage.qvx"

const X0 := 0
const X1 := 16
const Z0 := 0
const Z1 := 12
const WY0 := 3
const WY1 := 10
const RIDGE_Z := 6
const RIDGE_Y := 15
const EAVE_Y := 11


static func save() -> void:
	var b := build()
	b.save(PATH)
	var v := b.voxels()
	print("[Cottage] %s  %d voxels" % [PATH, v.size()])


static func build() -> QVoxelBuilder:
	var b := QVoxelBuilder.new()

	var stone := b.add_material(Color8(150, 150, 146), 0.0, 0.9, 0.85, 0.85)
	var stone_dk := b.add_material(Color8(110, 110, 106), 0.0, 0.95, 0.9, 0.9)
	var plaster := b.add_material(Color8(231, 220, 195), 0.0, 0.9, 0.3, 0.3)
	var beam := b.add_material(Color8(74, 54, 38), 0.0, 0.85, 0.6, 0.6)
	var roof := b.add_material(Color8(122, 74, 46), 0.0, 0.9, 0.5, 0.5)
	var roof_dk := b.add_material(Color8(94, 54, 32), 0.0, 0.9, 0.5, 0.5)
	var door := b.add_material(Color8(87, 58, 34), 0.0, 0.8, 0.5, 0.5)
	var iron := b.add_material(Color8(43, 43, 45), 0.6, 0.5, 0.9, 0.9)
	var glass := b.add_material(Color8(176, 202, 224), 0.0, 0.3, 0.2, 0.2, Color8(255, 176, 78))
	var brick := b.add_material(Color8(140, 74, 58), 0.0, 0.9, 0.8, 0.8)

	_foundation(b, stone, stone_dk)
	_walls(b, plaster, beam)
	_timber(b, beam)
	_door(b, beam, door, iron, stone)
	_windows(b, beam, glass)
	_roof(b, roof, roof_dk, plaster, beam)
	_chimney(b, brick, iron)
	_lantern(b, beam, iron, glass)
	return b


## 石砌地基（比墙外扩一圈），顶面掺深色石块。
static func _foundation(b: QVoxelBuilder, stone: int, stone_dk: int) -> void:
	b.box(Vector3i(X0 - 1, 0, Z0 - 1), Vector3i(X1 + 1, 2, Z1 + 1), stone)
	for x in range(X0 - 1, X1 + 2):
		for z in range(Z0 - 1, Z1 + 2):
			if (x * 3 + z * 5) % 4 == 0:
				b.put(Vector3i(x, 2, z), stone_dk)


## 四面灰泥墙（空心壳，一圈一厚）。
static func _walls(b: QVoxelBuilder, plaster: int, beam: int) -> void:
	b.box(Vector3i(X0, WY0, Z0 + 1), Vector3i(X0, WY1, Z1 - 1), plaster)
	b.box(Vector3i(X1, WY0, Z0 + 1), Vector3i(X1, WY1, Z1 - 1), plaster)
	b.box(Vector3i(X0 + 1, WY0, Z0), Vector3i(X1 - 1, WY1, Z0), plaster)
	b.box(Vector3i(X0 + 1, WY0, Z1), Vector3i(X1 - 1, WY1, Z1), plaster)
	# 上下檩条（一整圈）
	for y in [WY0, WY1]:
		b.box(Vector3i(X0, y, Z0), Vector3i(X1, y, Z0), beam)
		b.box(Vector3i(X0, y, Z1), Vector3i(X1, y, Z1), beam)
		b.box(Vector3i(X0, y, Z0), Vector3i(X0, y, Z1), beam)
		b.box(Vector3i(X1, y, Z0), Vector3i(X1, y, Z1), beam)


## 半木结构：四角立柱 + 立枋 + 窗下斜撑。
static func _timber(b: QVoxelBuilder, beam: int) -> void:
	for cx in [X0, X1]:
		for cz in [Z0, Z1]:
			b.line(Vector3i(cx, WY0, cz), Vector3i(cx, WY1, cz), beam)
	# 正面 / 背面立枋
	for x in [4, 8, 12]:
		b.line(Vector3i(x, WY0, Z1), Vector3i(x, WY1, Z1), beam)
		b.line(Vector3i(x, WY0, Z0), Vector3i(x, WY1, Z0), beam)
	# 端墙立枋 + 斜撑
	for z in [4, 8]:
		b.line(Vector3i(X0, WY0, z), Vector3i(X0, WY1, z), beam)
		b.line(Vector3i(X1, WY0, z), Vector3i(X1, WY1, z), beam)
	b.line(Vector3i(X0, WY0, 1), Vector3i(X0, WY0 + 4, 4), beam)
	b.line(Vector3i(X1, WY0, 1), Vector3i(X1, WY0 + 4, 4), beam)
	b.line(Vector3i(X0, WY0, 11), Vector3i(X0, WY0 + 4, 8), beam)
	b.line(Vector3i(X1, WY0, 11), Vector3i(X1, WY0 + 4, 8), beam)


static func _door(b: QVoxelBuilder, beam: int, door: int, iron: int, stone: int) -> void:
	b.box(Vector3i(7, WY0, Z1), Vector3i(9, 7, Z1), door)
	b.line(Vector3i(6, WY0, Z1), Vector3i(6, 8, Z1), beam)
	b.line(Vector3i(10, WY0, Z1), Vector3i(10, 8, Z1), beam)
	b.line(Vector3i(6, 8, Z1), Vector3i(10, 8, Z1), beam)
	for y in [4, 6]:
		b.put(Vector3i(8, y, Z1), iron)
	b.put(Vector3i(9, 5, Z1), iron)
	b.box(Vector3i(6, 2, Z1 + 1), Vector3i(10, 2, Z1 + 2), stone)


static func _windows(b: QVoxelBuilder, beam: int, glass: int) -> void:
	_window_face(b, Vector3i(2, 6, Z1), Vector3i(5, 9, Z1), beam, glass, Vector3i(0, 0, 1))
	_window_face(b, Vector3i(11, 6, Z1), Vector3i(14, 9, Z1), beam, glass, Vector3i(0, 0, 1))
	_window_face(b, Vector3i(X1, 6, 3), Vector3i(X1, 9, 6), beam, glass, Vector3i(1, 0, 0))
	_window_face(b, Vector3i(X1, 6, 7), Vector3i(X1, 9, 10), beam, glass, Vector3i(1, 0, 0))


## 一扇窗：外框 beam + 内部玻璃 + 十字窗棂。normal 为墙面外法线方向（决定面内两轴）。
static func _window_face(b: QVoxelBuilder, a: Vector3i, c: Vector3i, beam: int, glass: int, normal: Vector3i) -> void:
	var lo := Vector3i(mini(a.x, c.x), mini(a.y, c.y), mini(a.z, c.z))
	var hi := Vector3i(maxi(a.x, c.x), maxi(a.y, c.y), maxi(a.z, c.z))
	var x_normal := normal.x != 0
	var my := (lo.y + hi.y) / 2
	var mid := (lo.z + hi.z) / 2 if x_normal else (lo.x + hi.x) / 2
	for cell: Vector3i in VoxelPrimitives.box(a, c):
		var edge := false
		if x_normal:
			edge = cell.z == lo.z or cell.z == hi.z or cell.y == lo.y or cell.y == hi.y
		else:
			edge = cell.x == lo.x or cell.x == hi.x or cell.y == lo.y or cell.y == hi.y
		var mullion := cell.y == my or (cell.x == mid if x_normal else cell.z == mid)
		b.put(cell, beam if (edge or mullion) else glass)


## 人字屋顶（脊沿 x），出檐 + 山墙封闭 + 脊檩。
static func _roof(b: QVoxelBuilder, roof: int, roof_dk: int, plaster: int, beam: int) -> void:
	for z in range(-2, 15):
		var yy := int(round(RIDGE_Y - absi(z - RIDGE_Z) * 0.5))
		var m := roof_dk if z % 2 == 0 else roof
		b.box(Vector3i(X0 - 1, yy, z), Vector3i(X1 + 1, yy, z), m)
		# 山墙填充（屋面以下三角区）
		for y in range(WY1 + 1, yy):
			if z >= Z0 and z <= Z1:
				b.put(Vector3i(X0, y, z), plaster)
				b.put(Vector3i(X1, y, z), plaster)
	# 山墙斜边压条
	b.line(Vector3i(X0, EAVE_Y, -2), Vector3i(X0, RIDGE_Y, RIDGE_Z), beam)
	b.line(Vector3i(X0, EAVE_Y, 14), Vector3i(X0, RIDGE_Y, RIDGE_Z), beam)
	b.line(Vector3i(X1, EAVE_Y, -2), Vector3i(X1, RIDGE_Y, RIDGE_Z), beam)
	b.line(Vector3i(X1, EAVE_Y, 14), Vector3i(X1, RIDGE_Y, RIDGE_Z), beam)
	# 脊檩
	b.box(Vector3i(X0 - 1, RIDGE_Y, RIDGE_Z), Vector3i(X1 + 1, RIDGE_Y, RIDGE_Z), roof_dk)
	# 檐口封檐板
	b.box(Vector3i(X0 - 1, EAVE_Y, -2), Vector3i(X1 + 1, EAVE_Y, -2), beam)
	b.box(Vector3i(X0 - 1, EAVE_Y, 14), Vector3i(X1 + 1, EAVE_Y, 14), beam)


static func _chimney(b: QVoxelBuilder, brick: int, iron: int) -> void:
	b.box(Vector3i(12, WY0, Z0 - 1), Vector3i(13, 18, Z0), brick)
	b.box(Vector3i(11, 18, Z0 - 2), Vector3i(14, 18, Z0 + 1), brick)
	b.box(Vector3i(12, 18, Z0 - 1), Vector3i(13, 18, Z0), iron)


static func _lantern(b: QVoxelBuilder, beam: int, iron: int, glass: int) -> void:
	b.line(Vector3i(10, 7, Z1), Vector3i(11, 8, Z1 + 1), beam)
	b.put(Vector3i(11, 7, Z1 + 1), iron)
	b.put(Vector3i(11, 6, Z1 + 1), glass)

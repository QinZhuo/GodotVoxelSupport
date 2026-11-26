@tool
class_name QVoxelBrushTool
extends RefCounted
## 画笔工具：一次手势（按下 → 拖动 → 松手）的状态机，产出**要写的体素坐标**。

enum Mode {
	VOXEL, ## 体素笔：单格（可加粗），拖拽连续涂抹
	FACE,  ## 面笔：铺满与拾取点连通的一片暴露面
	BOX,   ## 盒笔：两个角点之间的实心长方体
	LINE,  ## 线笔：两个角点之间的直线
	FILL,  ## 填充：与拾取点连通的同材质整块
	SELECT, ## 选择：拖出一个选区盒（不写任何格）
	MOVE,   ## 移动：把选区里的体素搬到拖到的位置
}

## 工具表：界面（热键 / 工具栏 / 提示）与行为（live / 笔刷尺寸）的唯一来源。
const MODES := [
	{"mode": Mode.VOXEL, "id": &"voxel", "label": "点", "hotkey": KEY_1, "icon": "tool_voxel",
		"live": true, "brush": true, "hint": "点：左键画 · 右键擦 · 拖动连续"},
	{"mode": Mode.LINE, "id": &"line", "label": "线", "hotkey": KEY_2, "icon": "tool_line",
		"live": false, "brush": true, "hint": "线：拖出直线，松手落笔"},
	{"mode": Mode.FACE, "id": &"face", "label": "面", "hotkey": KEY_3, "icon": "tool_face",
		"live": false, "brush": false, "hint": "面：铺满一片暴露面（也能铺背景面）"},
	{"mode": Mode.BOX, "id": &"box", "label": "块", "hotkey": KEY_4, "icon": "tool_box",
		"live": false, "brush": true, "hint": "块：拖出一个长方体，松手落笔"},
	{"mode": Mode.FILL, "id": &"fill", "label": "填", "hotkey": KEY_5, "icon": "tool_fill",
		"live": false, "brush": false, "hint": "填：替换连通的同材质整块"},
	{"mode": Mode.SELECT, "id": &"select", "label": "选择", "hotkey": KEY_6, "icon": "tool_select",
		"live": false, "brush": false, "hint": "选择：拖框 / 单击连通一块"},
	{"mode": Mode.MOVE, "id": &"move", "label": "移动", "hotkey": KEY_7, "icon": "tool_move",
		"live": false, "brush": false, "hint": "移动：拖坐标轴"},
]

## 操作意图：这一笔对命中格做**什么**。
enum Op {
	ADD,    ## 添加：在命中面的外侧长出一格（传统"画"）
	REMOVE, ## 移除：挖掉命中格本身（传统"擦"）
	PAINT,  ## 上色：把命中格改成当前材质，不增不减
}

## 操作表：界面（按钮文案 / 图标 / 提示）的唯一来源，与 MODES 同一套路数。
const OPS := [
	{"op": Op.ADD, "text": "添加", "icon": "add", "tip": "添加：在点中的面外侧长出体素"},
	{"op": Op.REMOVE, "text": "移除", "icon": "erase", "tip": "移除：挖掉点中的体素（右键 / Shift+左键同义）"},
	{"op": Op.PAINT, "text": "上色", "icon": "paint", "tip": "上色：把点中的体素改成当前材质，不增不减"},
]

## 笔刷加粗的**截面形态**。
enum Shape {
	BALL,  ## 球：以落笔点为中心各向同性鼓起（圆笔头，原行为）
	PLANE, ## 平面：只在拾取面内摊开，沿法线的厚度不变（在表面上刷宽笔触用）
}

## 形态表：界面（按钮文案 / 提示）的唯一来源，与 MODES 同一套路数。
const SHAPES := [
	{"shape": Shape.BALL, "text": "球", "icon": "shape_ball", "tip": "以落笔点为中心各向同性鼓起（传统圆笔头）"},
	{"shape": Shape.PLANE, "text": "平面", "icon": "shape_plane",
		"tip": "只在拾取面的两个轴向摊开、厚度不变 —— 表面上刷宽笔触不会把一半体积埋进实心里"},
]

## 拾取上下文：一次落笔需要知道的全部外部信息（视口拾取后填好）。
class Pick extends RefCounted:
	var hit := Vector3i.MIN       ## 命中的体素；MIN = 没命中
	var normal := Vector3i.ZERO   ## 入射面法线（朝外，单轴 ±1）
	var place := Vector3i.MIN     ## 落笔格 = hit + normal；移除 / 上色时 = hit
	var op: Op = Op.ADD           ## 这一笔的意图：添加 / 移除 / 上色
	var material_id := 1          ## 当前材质
	var grid := Vector3i.ZERO     ## 对象网格尺寸（ZERO = 不裁剪，测试用）
	var solid := Callable()       ## p → 该格是否实心
	var material_at := Callable() ## p → 该格材质 id（0 = 空）

	## 能不能落笔：没命中或没有入射面（起点在实心格内）都不行 —— 那种命中没有"往哪长"。
	func valid() -> bool:
		return hit != Vector3i.MIN and place != Vector3i.MIN

	## 是否"挖掉命中格"（移除）。
	func erasing() -> bool:
		return op == Op.REMOVE

	## 这一笔写入的材质：移除写 0（内核语义：0 = 空气），添加 / 上色写当前材质。
	func material() -> int:
		return 0 if op == Op.REMOVE else material_id

var mode: Mode = Mode.VOXEL
## 笔头**边长**（格），与 MagicaVoxel 的 size 同义；可取任意正整数（含偶数 2 / 4 / 8）。
var brush_size := 1
## 加粗形态（见 [enum Shape]）。
var brush_shape: Shape = Shape.BALL
## 对称轴掩码：分量为 1 表示该轴镜像（X / Y / Z 各自独立勾选），ZERO = 关。
var symmetry := Vector3i.ZERO

var _pick: Pick = null
var _anchor := Vector3i.MIN
var _current := Vector3i.MIN
var _written := Vector3i.MIN  ## live 工具：已经交出去的产物末端（避免重复交同一段）
var _active := false

# 工具表查询（界面用；不碰手势状态）

static func info(m: Mode) -> Dictionary:
	for row in MODES:
		if row.mode == m:
			return row
	return MODES[0]

static func mode_by_hotkey(key: Key) -> Mode:
	for row in MODES:
		if row.hotkey == key:
			return row.mode
	return Mode.VOXEL

func label() -> String:
	return info(mode).label

func hint() -> String:
	return info(mode).hint

func supports_brush_size() -> bool:
	return info(mode).brush

## 这一笔是"边拖边写"（true）还是"松手才写"（false）。
func live() -> bool:
	return info(mode).live

## 是否是"选区手势"（选择 / 移动）：它们**不产出要写的格**，产物是选区盒 / 位移，
static func is_selection_mode(m: Mode) -> bool:
	return m == Mode.SELECT or m == Mode.MOVE

func selection_mode() -> bool:
	return is_selection_mode(mode)

func set_mode(m: Mode) -> void:
	if mode == m:
		return
	cancel()
	mode = m

## 切加粗形态。
func set_shape(s: Shape) -> void:
	brush_shape = s

# 手势协议（视口调用）

## 按下。
func begin(pick: Pick) -> bool:
	if pick == null or not pick.valid():
		return false
	_pick = pick
	_anchor = _anchor_of(pick)
	_current = _anchor
	_written = Vector3i.MIN
	_active = true
	return true

## 拖动：更新端点。
func drag(pick: Pick) -> Array[Vector3i]:
	if not _active or pick == null or not pick.valid():
		return []
	_pick = pick
	_current = _anchor_of(pick)
	if not live():
		return []
	return _take()

## 松手：交出这一笔剩余的产物（span 工具在这里才第一次产出）。
func release() -> Array[Vector3i]:
	if not _active:
		return []
	if selection_mode():
		cancel()
		return []
	var cells: Array[Vector3i] = []
	if live():
		# 拖动过程中已经交到 _current；只有"只按下没拖动"才还有剩余（点击 = 画一格）
		if _written != _current:
			cells = _take()
	else:
		cells = _finish(_stroke(_anchor, _current, _pick), _pick)
	cancel()
	return cells

## 悬停预览：不改手势状态，只算"如果现在按下（或拖到这里）会画出什么"。
func hover(pick: Pick) -> Array[Vector3i]:
	if selection_mode():
		return []
	# 手势中：盒 / 线笔画出整个拖拽范围；live 笔只画"接下来要写的增量段"（与 _take 同一段，
	if _active:
		var p := pick if pick != null and pick.valid() else _pick
		if p == null:
			return []
		if live():
			if _written == _current:
				return []
			var from := _anchor if _written == Vector3i.MIN else _written
			return _finish(_stroke(from, _current, p), p)
		return _finish(_stroke(_anchor, _current, p), p)
	if pick == null or not pick.valid():
		return []
	var a := _anchor_of(pick)
	return _finish(_stroke(a, a, pick), pick)

## 当前手势的两个角点（锚点 → 当前端点）。
func gesture_corners() -> Array[Vector3i]:
	if not _active or _anchor == Vector3i.MIN or _current == Vector3i.MIN:
		return []
	return [_anchor, _current]

func cancel() -> void:
	_active = false
	_pick = null
	_anchor = Vector3i.MIN
	_current = Vector3i.MIN
	_written = Vector3i.MIN

func active() -> bool:
	return _active

## 当前这一笔要写入的材质（移除 → 0）。
func material() -> int:
	return _pick.material() if _pick != null else 0

# 形状分派

## 锚点：落笔类笔落在"落笔格"（命中格往外一格）；
func _anchor_of(pick: Pick) -> Vector3i:
	if mode == Mode.FACE or mode == Mode.FILL or is_selection_mode(mode):
		return pick.hit
	if mode == Mode.BOX or mode == Mode.LINE:
		# 区域工具：锚点始终取"落笔面外侧那一格"（与操作无关），于是空白区（地板 / 侧墙等背景面）也能起笔。
		return VoxelRay.placement_of(pick.hit, pick.normal)
	return pick.place

func _stroke(a: Vector3i, b: Vector3i, pick: Pick) -> Array[Vector3i]:
	match mode:
		Mode.FACE:
			return _stroke_face(pick)
		Mode.FILL:
			return _stroke_fill(pick)
		Mode.BOX:
			return VoxelPrimitives.box(_clip(a, pick), _clip(b, pick))
		Mode.LINE:
			return VoxelPrimitives.line(_clip(a, pick), _clip(b, pick))
		_:
			# 体素笔：相邻采样点之间补一条线。
			return VoxelPrimitives.line(_clip(a, pick), _clip(b, pick))

## 面笔：铺满与拾取点连通的一片"暴露面"。
func _stroke_face(pick: Pick) -> Array[Vector3i]:
	if not pick.solid.is_valid():
		return []
	var normal := pick.normal
	# 背景面（地板 / 侧墙）：命中格落在网格外 → 铺满整个网格截面的那一层（面笔也要能画背景面）。
	if _is_background_face(pick):
		return _grid_face_plane(pick, normal)
	var offsets := VoxelPrimitives.plane_offsets4(normal)
	var accept := func(p: Vector3i) -> bool:
		return bool(pick.solid.call(p)) and not bool(pick.solid.call(p + normal))
	var step := func(_p: Vector3i) -> Array[Vector3i]:
		return offsets
	var exposed := VoxelPrimitives.region([pick.hit], accept, step)
	if pick.op != Op.ADD:
		return exposed
	# 添加：写在暴露面的外侧（沿法线一格）；移除 / 上色：作用在暴露面本身
	var out: Array[Vector3i] = []
	for c in exposed:
		out.append(c + normal)
	return out

## 命中格是否落在网格外（= 打在了背景面：地板 / 侧墙）。
func _is_background_face(pick: Pick) -> bool:
	var g := pick.grid
	if g == Vector3i.ZERO:
		return false
	var h := pick.hit
	return h.x < 0 or h.y < 0 or h.z < 0 or h.x >= g.x or h.y >= g.y or h.z >= g.z

## 背景面铺满：把与背景面垂直的一整层网格截面作为产物（落笔层 = 命中外侧一格）。
func _grid_face_plane(pick: Pick, normal: Vector3i) -> Array[Vector3i]:
	var g := pick.grid
	var place := VoxelRay.placement_of(pick.hit, normal)
	var out: Array[Vector3i] = []
	if absi(normal.x) == 1:
		for z in g.z:
			for y in g.y:
				out.append(Vector3i(place.x, y, z))
	elif absi(normal.y) == 1:
		for z in g.z:
			for x in g.x:
				out.append(Vector3i(x, place.y, z))
	else:
		for y in g.y:
			for x in g.x:
				out.append(Vector3i(x, y, place.z))
	return out

## 填充：把与拾取点连通的**同材质**整块换成当前材质。
func _stroke_fill(pick: Pick) -> Array[Vector3i]:
	if not pick.solid.is_valid() or not pick.material_at.is_valid():
		return []
	var want: int = pick.material_at.call(pick.hit)
	var accept := func(p: Vector3i) -> bool:
		return bool(pick.solid.call(p)) and int(pick.material_at.call(p)) == want
	var step := func(_p: Vector3i) -> Array[Vector3i]:
		return VoxelPrimitives.neighbors6()
	return VoxelPrimitives.region([pick.hit], accept, step)

## live 工具取"已交出末端 → 当前端点"这一段。
func _take() -> Array[Vector3i]:
	var from := _anchor if _written == Vector3i.MIN else _written
	var cells := _finish(_stroke(from, _current, _pick), _pick)
	_written = _current
	return cells

## 端点裁剪：把角点夹回网格（含外沿一格）—— 注意是**生成形状之前**。
static func _clip(p: Vector3i, pick: Pick) -> Vector3i:
	if pick == null or pick.grid == Vector3i.ZERO:
		return p
	var g := pick.grid
	return Vector3i(clampi(p.x, -1, g.x), clampi(p.y, -1, g.y), clampi(p.z, -1, g.z))

## 收尾：按笔刷尺寸与**形态**加粗 + 裁掉网格外的格子。
func _finish(cells: Array[Vector3i], pick: Pick) -> Array[Vector3i]:
	var size := maxi(brush_size, 1)
	if supports_brush_size() and size > 1:
		if brush_shape == Shape.PLANE:
			# 平面形态要一个"面"来定摊开方向：取拾取面的法线。
			cells = VoxelPrimitives.dilate_plane(cells, size,
					pick.normal if pick != null else Vector3i.ZERO)
		else:
			# 球内切于边长 size 的立方：尺寸 2 = 2×2×2 实心块、3 = 3×3×3 去 8 角、
			cells = VoxelPrimitives.dilate_ball(cells, size)
	if pick == null or pick.grid == Vector3i.ZERO:
		return cells
	if symmetry != Vector3i.ZERO:
		cells = _mirror(cells, pick.grid)
	var g := pick.grid
	var out: Array[Vector3i] = []
	for c in cells:
		if c.x < 0 or c.y < 0 or c.z < 0 or c.x >= g.x or c.y >= g.y or c.z >= g.z:
			continue
		out.append(c)
	return out

## 把一批格按勾选的对称轴展开成"原格 + 各镜像"。
func _mirror(cells: Array[Vector3i], g: Vector3i) -> Array[Vector3i]:
	var seen := {}
	var out: Array[Vector3i] = []
	for c in cells:
		for m in _images(c, g):
			if seen.has(m):
				continue
			seen[m] = true
			out.append(m)
	return out

## 单格的像集：每个勾选轴独立给出"原值 / 镜像值"两档，笛卡尔组合。
func _images(c: Vector3i, g: Vector3i) -> Array[Vector3i]:
	var xs: Array[int] = [c.x]
	if symmetry.x != 0:
		xs.append(g.x - 1 - c.x)
	var ys: Array[int] = [c.y]
	if symmetry.y != 0:
		ys.append(g.y - 1 - c.y)
	var zs: Array[int] = [c.z]
	if symmetry.z != 0:
		zs.append(g.z - 1 - c.z)
	var out: Array[Vector3i] = []
	for x in xs:
		for y in ys:
			for z in zs:
				out.append(Vector3i(x, y, z))
	return out

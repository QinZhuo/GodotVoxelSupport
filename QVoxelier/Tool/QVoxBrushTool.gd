@tool
class_name QVoxBrushTool
extends RefCounted
## 画笔工具：一次手势（按下 → 拖动 → 松手）的状态机，产出**要写的体素坐标**。
##
## 【为什么工具不写数据】写入必须过 QVoxVoxelEditCommand（撤销要改动前后的块快照），
## 而"哪些格要写"是纯几何。分开之后：工具可无头测试（不需要节点 / 输入 / 渲染），
## 预览与落笔调的是同一个函数，命令类也不必知道有几种工具。
##
## 【为什么五种笔是一个类而不是五个子类】它们是**同一次手势的五个形状**：
## 按下取锚点、拖动更新端点、松手交产物 —— 骨架完全一样，只有"端点 → 坐标集合"这一步不同。
## 做成"一个状态机 + 形状分派"后，热键 / 工具栏 / 色板只需要读一张表（MODES），
## 加一种笔 = 加一行表 + 一个 _stroke_* 分支。
##
## 【live 与 span 的区别】体素笔边拖边写（拖拽涂抹是它的语义），盒/线/面/填充松手才写
## （盒笔若边拖边写，拖动过程会在画布上留下一串盒子）。这个区分不是细节，它决定了
## "产物什么时候交给命令"，所以由 MODES 表显式声明而不是靠子类隐式决定。

enum Mode {
	VOXEL, ## 体素笔：单格（可加粗），拖拽连续涂抹
	FACE,  ## 面笔：铺满与拾取点连通的一片暴露面
	BOX,   ## 盒笔：两个角点之间的实心长方体
	LINE,  ## 线笔：两个角点之间的直线
	FILL,  ## 填充：与拾取点连通的同材质整块
}

## 工具表：界面（热键 / 工具栏 / 提示）与行为（live / 笔刷尺寸）的唯一来源。
const MODES := [
	{"mode": Mode.VOXEL, "id": &"voxel", "label": "体素笔", "hotkey": KEY_V,
		"live": true, "brush": true, "hint": "左键画 · 右键擦 · 拖动连续涂抹"},
	{"mode": Mode.FACE, "id": &"face", "label": "面笔", "hotkey": KEY_F,
		"live": false, "brush": false, "hint": "点一下铺满整片同朝向的暴露面"},
	{"mode": Mode.BOX, "id": &"box", "label": "盒笔", "hotkey": KEY_B,
		"live": false, "brush": true, "hint": "按住拖出长方体，松手落笔"},
	{"mode": Mode.LINE, "id": &"line", "label": "线笔", "hotkey": KEY_L,
		"live": false, "brush": true, "hint": "按住拖出直线，松手落笔"},
	{"mode": Mode.FILL, "id": &"fill", "label": "填充", "hotkey": KEY_C,
		"live": false, "brush": false, "hint": "替换与拾取点连通的同材质整块"},
]


## 拾取上下文：一次落笔需要知道的全部外部信息（视口拾取后填好）。
##
## 做成"值对象"而不是让工具去反问视口，是为了工具能脱离场景树测试；
## solid / material_at 两个闭包把"几何判据从哪来"也一并外部化 ——
## 编辑器传的是**显示几何**（VoxelData），测试传的是字典，工具两边都不用改。
class Pick extends RefCounted:
	var hit := Vector3i.MIN       ## 命中的体素；MIN = 没命中
	var normal := Vector3i.ZERO   ## 入射面法线（朝外，单轴 ±1）
	var place := Vector3i.MIN     ## 落笔格 = hit + normal；擦除时 = hit
	var erase := false            ## 右键 = 擦除
	var material_id := 1          ## 当前材质
	var grid := Vector3i.ZERO     ## 对象网格尺寸（ZERO = 不裁剪，测试用）
	var solid := Callable()       ## p → 该格是否实心
	var material_at := Callable() ## p → 该格材质 id（0 = 空）

	## 能不能落笔：没命中或没有入射面（起点在实心格内）都不行 —— 那种命中没有"往哪长"。
	func valid() -> bool:
		return hit != Vector3i.MIN and place != Vector3i.MIN

	## 这一笔写入的材质：擦除写 0（内核语义：0 = 空气）。
	func material() -> int:
		return 0 if erase else material_id


var mode: Mode = Mode.VOXEL
var brush_size := 1

var _pick: Pick = null
var _anchor := Vector3i.MIN
var _current := Vector3i.MIN
var _written := Vector3i.MIN  ## live 工具：已经交出去的产物末端（避免重复交同一段）
var _active := false


# ----------------------------------------------------------------------------
# 工具表查询（界面用；不碰手势状态）
# ----------------------------------------------------------------------------

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


func set_mode(m: Mode) -> void:
	if mode == m:
		return
	cancel()
	mode = m


# ----------------------------------------------------------------------------
# 手势协议（视口调用）
# ----------------------------------------------------------------------------

## 按下。返回 false = 这次无处落笔（视口据此不建命令、不入撤销栈）。
func begin(pick: Pick) -> bool:
	if pick == null or not pick.valid():
		return false
	_pick = pick
	_anchor = _anchor_of(pick)
	_current = _anchor
	_written = Vector3i.MIN
	_active = true
	return true


## 拖动：更新端点。live 工具顺带交出"上一采样点 → 现在"这一段要写的格子，
## 由视口立即写进命令（于是拖拽是连续的，而不是只留下离散的采样点）。
func drag(pick: Pick) -> Array[Vector3i]:
	if not _active or pick == null:
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
	var cells: Array[Vector3i] = []
	if live():
		# 拖动过程中已经交到 _current；只有"只按下没拖动"才还有剩余（点击 = 画一格）
		if _written != _current:
			cells = _take()
	else:
		cells = _finish(_stroke(_anchor, _current, _pick), _pick)
	cancel()
	return cells


## 悬停预览：不改手势状态，只算"如果现在按下会画出什么"。
## 与落笔共用 _stroke 与 _finish —— 所见即所画由构造保证，不靠两处对齐。
func hover(pick: Pick) -> Array[Vector3i]:
	if pick == null or not pick.valid():
		return []
	var a := _anchor_of(pick)
	return _finish(_stroke(a, a, pick), pick)


func cancel() -> void:
	_active = false
	_pick = null
	_anchor = Vector3i.MIN
	_current = Vector3i.MIN
	_written = Vector3i.MIN


func active() -> bool:
	return _active


## 当前这一笔要写入的材质（擦除 → 0）。没有手势时返回 0。
func material() -> int:
	return _pick.material() if _pick != null else 0


# ----------------------------------------------------------------------------
# 形状分派
# ----------------------------------------------------------------------------

## 锚点：绝大多数笔落在"落笔格"（命中格往外一格）；
## 面笔与填充的锚点是**命中格本身** —— 它们的作用域由被点中的那块实体定义，与"往哪长"无关。
func _anchor_of(pick: Pick) -> Vector3i:
	if mode == Mode.FACE or mode == Mode.FILL:
		return pick.hit
	return pick.place


func _stroke(a: Vector3i, b: Vector3i, pick: Pick) -> Array[Vector3i]:
	match mode:
		Mode.FACE:
			return _stroke_face(pick)
		Mode.FILL:
			return _stroke_fill(pick)
		Mode.BOX:
			return QVoxBrushGeometry.box(a, b)
		Mode.LINE:
			return QVoxBrushGeometry.line(a, b)
		_:
			# 体素笔：相邻采样点之间补一条线。鼠标事件是离散的，不补线则快速拖动会断成虚点。
			return QVoxBrushGeometry.line(a, b)


## 面笔：铺满与拾取点连通的一片"暴露面"。
## 两条判据缺一不可：① 该格实心 ② 沿法线那一格是空的（这才是暴露面）。
## 只判 ① 会把模型内部整片实心面也刷上 —— 用户看不见，体积却被撑大。
func _stroke_face(pick: Pick) -> Array[Vector3i]:
	if not pick.solid.is_valid():
		return []
	var normal := pick.normal
	var offsets := QVoxBrushGeometry.plane_offsets4(normal)
	var accept := func(p: Vector3i) -> bool:
		return bool(pick.solid.call(p)) and not bool(pick.solid.call(p + normal))
	var step := func(_p: Vector3i) -> Array[Vector3i]:
		return offsets
	var exposed := QVoxBrushGeometry.region([pick.hit], accept, step)
	if pick.erase:
		return exposed
	# 画：写在暴露面的外侧（沿法线一格）；擦：就擦掉暴露面本身
	var out: Array[Vector3i] = []
	for c in exposed:
		out.append(c + normal)
	return out


## 填充：把与拾取点连通的**同材质**整块换成当前材质。
## 判据是"实心 + 材质相同"，所以填充边界正好落在材质边界上 —— 用户看到的色块就是范围。
func _stroke_fill(pick: Pick) -> Array[Vector3i]:
	if not pick.solid.is_valid() or not pick.material_at.is_valid():
		return []
	var want: int = pick.material_at.call(pick.hit)
	var accept := func(p: Vector3i) -> bool:
		return bool(pick.solid.call(p)) and int(pick.material_at.call(p)) == want
	var step := func(_p: Vector3i) -> Array[Vector3i]:
		return QVoxBrushGeometry.neighbors6()
	return QVoxBrushGeometry.region([pick.hit], accept, step)


## live 工具取"已交出末端 → 当前端点"这一段。
## 还没交过时从**锚点**起算：锚点是按下时那一格，第一次拖动要把它与当前端点连成一条线，
## 否则快速拖动的第一段会只剩一个孤点（按下的位置被丢掉）。
func _take() -> Array[Vector3i]:
	var from := _anchor if _written == Vector3i.MIN else _written
	var cells := _finish(_stroke(from, _current, _pick), _pick)
	_written = _current
	return cells


## 收尾：按笔刷尺寸加粗 + 裁掉网格外的格子。
##
## 【为什么要在这里裁】对象侧的越界处理是"丢弃"，让越界坐标走一趟只会白白记账
## （撤销里出现一堆从未生效的格）。裁剪放在唯一的出口，预览与落笔因此看到同一批格。
func _finish(cells: Array[Vector3i], pick: Pick) -> Array[Vector3i]:
	var radius := brush_size - 1
	if supports_brush_size() and radius > 0:
		cells = QVoxBrushGeometry.dilate(cells, radius)
	if pick == null or pick.grid == Vector3i.ZERO:
		return cells
	var g := pick.grid
	var out: Array[Vector3i] = []
	for c in cells:
		if c.x < 0 or c.y < 0 or c.z < 0 or c.x >= g.x or c.y >= g.y or c.z >= g.z:
			continue
		out.append(c)
	return out

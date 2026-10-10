@tool
class_name QVoxelBrushTool
extends RefCounted
## 画笔工具：一次手势（按下 → 拖动 → 松手）的状态机，产出**要写的体素坐标**。
## 【为什么工具不写数据】写入必须过 QVoxelEditCommand（撤销要改动前后的块快照），
## 而"哪些格要写"是纯几何。分开之后：工具可无头测试（不需要节点 / 输入 / 渲染），
## 预览与落笔调的是同一个函数，命令类也不必知道有几种工具。
## 【为什么五种笔是一个类而不是五个子类】它们是**同一次手势的五个形状**：
## 按下取锚点、拖动更新端点、松手交产物 —— 骨架完全一样，只有"端点 → 坐标集合"这一步不同。
## 做成"一个状态机 + 形状分派"后，热键 / 工具栏 / 色板只需要读一张表（MODES），
## 加一种笔 = 加一行表 + 一个 _stroke_* 分支。
## 【live 与 span 的区别】体素笔边拖边写（拖拽涂抹是它的语义），盒/线/面/填充松手才写
## （盒笔若边拖边写，拖动过程会在画布上留下一串盒子）。这个区分不是细节，它决定了
## "产物什么时候交给命令"，所以由 MODES 表显式声明而不是靠子类隐式决定。
## 【为什么选区 / 移动也在这张表里】它们是**同一次手势的另外两种产物**：按下取锚点、拖动更新
## 端点、松手交结果 —— 骨架一模一样，只是"结果"不是要写的格子，而是"框住了哪一块"（选择）
## 或"搬了多远"（移动）。做成两套状态机等于把"按下 / 拖动 / 松手"抄三遍；放进同一张表后，
## 热键、工具坞按钮、HUD 提示依旧只有一处来源，而**产物分派**（写格子还是改选区）由会话
## 看 `is_selection_mode()` 一处决定。

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
	{"mode": Mode.SELECT, "id": &"select", "label": "选择", "hotkey": KEY_T,
		"live": false, "brush": false, "hint": "拖出选区盒 · 再按 复制 / 剪切 / 粘贴 / 清空"},
	{"mode": Mode.MOVE, "id": &"move", "label": "移动", "hotkey": KEY_M,
		"live": false, "brush": false, "hint": "按住拖动，把选区里的体素搬到新位置"},
]

## 笔刷加粗的**截面形态**。与 Mode 正交：Mode 决定"画哪些格"，Shape 决定"加粗成什么形状"。
## 【为什么不把它做成第八种笔】"画什么"与"加粗成什么"是两件事：体素笔要粗笔头、线笔要粗线、
## 盒笔要厚板 —— 三者都吃尺寸，也都能在球 / 平面之间选。做成模式会让按钮数翻倍，且以后每加
## 一种笔都要把两种形态再抄一遍。正交的一维只该占一维。
enum Shape {
	BALL,  ## 球：以落笔点为中心各向同性鼓起（圆笔头，原行为）
	PLANE, ## 平面：只在拾取面内摊开，沿法线的厚度不变（在表面上刷宽笔触用）
}

## 形态表：界面（按钮文案 / 提示）的唯一来源，与 MODES 同一套路数。
const SHAPES := [
	{"shape": Shape.BALL, "text": "球", "tip": "以落笔点为中心各向同性鼓起（传统圆笔头）"},
	{"shape": Shape.PLANE, "text": "平面",
		"tip": "只在拾取面的两个轴向摊开、厚度不变 —— 表面上刷宽笔触不会把一半体积埋进实心里"},
]


## 拾取上下文：一次落笔需要知道的全部外部信息（视口拾取后填好）。
## 做成"值对象"而不是让工具去反问视口，是为了工具能脱离场景树测试；
## solid / material_at 两个闭包把"几何判据从哪来"也一并外部化 ——
## 编辑器传的是**显示几何**（QVoxelSource），测试传的是字典，工具两边都不用改。
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
## 加粗形态（见 [enum Shape]）。只在 [method supports_brush_size] 且尺寸 > 1 时起作用。
var brush_shape: Shape = Shape.BALL
## 对称轴掩码：分量为 1 表示该轴镜像（X / Y / Z 各自独立勾选），ZERO = 关。
## 【为什么镜像放在 _finish 这一个出口】预览（hover）与落笔（release/drag）都汇到 _finish，
## 镜像接在这里，两边就自动一致 —— 预览里看到的镜像格，落笔时一定也画。这正是本类
## "所见即所画由构造保证"的又一处兑现，而不是在预览与落笔里各写一遍镜像。
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
## 由会话从 [method gesture_corners] 取。会话据此把产物分派到选区而不是命令。
static func is_selection_mode(m: Mode) -> bool:
	return m == Mode.SELECT or m == Mode.MOVE


func selection_mode() -> bool:
	return is_selection_mode(mode)


func set_mode(m: Mode) -> void:
	if mode == m:
		return
	cancel()
	mode = m


## 切加粗形态。与 [method set_mode] 同构，但**不需要 cancel** —— 形态不进手势状态，
## 改它不会让进行中的一笔变成另一笔（尺寸同理，故也没有 setter）。
func set_shape(s: Shape) -> void:
	brush_shape = s


# 手势协议（视口调用）

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
## 【必须挡掉无效 pick —— 这里曾是"画几下整机卡死"的根因】
## 射线既没打到体素、也没打到地板时（鼠标拖出模型外、视角朝天），拾取信息是空字典，
## 而 `placement_of(MIN, ZERO)` 返回的 `Vector3i.MIN` 是**"没有落笔点"的哨兵，不是坐标**。
## 它一旦写进 `_current`，盒 / 线笔就会拿着 -2^31 这个角点去生成格子：`box()` 的
## `range(lo, hi+1)` 变成 21 亿次 `append`，内存耗尽后引擎开始**逐次**报
## `realloc_static: Parameter "mem" is null`（连 GDScript 调用栈一起打）—— 实测刷出 1.27GB
## 日志、游戏彻底卡死、附带的编辑器也被输出缓冲拖死，整台机器一起卡。
## 处置：无效拾取一律**保持上一个有效端点**。语义上也对 —— 把鼠标拖出模型再松手，
## 用户的意思就是"这一笔画到模型边上为止"，而不是"画到无穷远"。
func drag(pick: Pick) -> Array[Vector3i]:
	if not _active or pick == null or not pick.valid():
		return []
	_pick = pick
	_current = _anchor_of(pick)
	if not live():
		return []
	return _take()


## 松手：交出这一笔剩余的产物（span 工具在这里才第一次产出）。
## 选区手势（选择 / 移动）在这里只收摊：它们的产物不是格子，会话会在调用本方法**之前**
## 用 [method gesture_corners] 取走两个角点（本方法一返回，角点就被 cancel 掉了）。
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


## 悬停预览：不改手势状态，只算"如果现在按下会画出什么"。
## 与落笔共用 _stroke 与 _finish —— 所见即所画由构造保证，不靠两处对齐。
func hover(pick: Pick) -> Array[Vector3i]:
	if pick == null or not pick.valid() or selection_mode():
		return []
	var a := _anchor_of(pick)
	return _finish(_stroke(a, a, pick), pick)


## 当前手势的两个角点（锚点 → 当前端点）。选区手势据此造选区盒 / 位移；不在手势中返回空。
## 【为什么返回值而不是 Box】选择只要"框了哪一块"，移动只要"搬了多远"（= 两端点之差）。
## 两者都能从这两个点推出来，于是工具不必知道"选区"或"位移"这两个概念 —— 它只管手势。
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


## 当前这一笔要写入的材质（擦除 → 0）。没有手势时返回 0。
func material() -> int:
	return _pick.material() if _pick != null else 0


# 形状分派

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
			return QVoxelBrushGeometry.box(_clip(a, pick), _clip(b, pick))
		Mode.LINE:
			return QVoxelBrushGeometry.line(_clip(a, pick), _clip(b, pick))
		_:
			# 体素笔：相邻采样点之间补一条线。鼠标事件是离散的，不补线则快速拖动会断成虚点。
			return QVoxelBrushGeometry.line(_clip(a, pick), _clip(b, pick))


## 面笔：铺满与拾取点连通的一片"暴露面"。
## 两条判据缺一不可：① 该格实心 ② 沿法线那一格是空的（这才是暴露面）。
## 只判 ① 会把模型内部整片实心面也刷上 —— 用户看不见，体积却被撑大。
func _stroke_face(pick: Pick) -> Array[Vector3i]:
	if not pick.solid.is_valid():
		return []
	var normal := pick.normal
	var offsets := QVoxelBrushGeometry.plane_offsets4(normal)
	var accept := func(p: Vector3i) -> bool:
		return bool(pick.solid.call(p)) and not bool(pick.solid.call(p + normal))
	var step := func(_p: Vector3i) -> Array[Vector3i]:
		return offsets
	var exposed := QVoxelBrushGeometry.region([pick.hit], accept, step)
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
		return QVoxelBrushGeometry.neighbors6()
	return QVoxelBrushGeometry.region([pick.hit], accept, step)


## live 工具取"已交出末端 → 当前端点"这一段。
## 还没交过时从**锚点**起算：锚点是按下时那一格，第一次拖动要把它与当前端点连成一条线，
## 否则快速拖动的第一段会只剩一个孤点（按下的位置被丢掉）。
func _take() -> Array[Vector3i]:
	var from := _anchor if _written == Vector3i.MIN else _written
	var cells := _finish(_stroke(from, _current, _pick), _pick)
	_written = _current
	return cells


## 端点裁剪：把角点夹回网格（含外沿一格）—— 注意是**生成形状之前**。
## 【为什么必须在生成之前】盒 / 线笔的产物数量由**两个角点的间距**决定：`box()` 遍历
## `range(lo, hi+1)` 的三重循环，`line()` 遍历最大轴跨度。而网格外的产物反正在
## `_finish` 里会被丢掉，等生成完再裁就是"先造再扔"，间距一大就是拿内存换垃圾
## （角点跑到 2^31 那次实测直接把内存打穿，详见 drag() 的注释）。
## 夹在生成之前，代价就被钉在网格体积上。
## 范围取 [-1, 网格尺寸]：这是**合法落笔点**能达到的最外沿 —— 命中边界面 + 法线会落到
## `尺寸` 那一格，地板层的命中格是 y = -1。留出这一格，语义才与 `_finish` 的裁剪一致。
## 无网格上下文（`grid = ZERO`，纯逻辑场合）时原样返回，裁剪责任交给调用方。
static func _clip(p: Vector3i, pick: Pick) -> Vector3i:
	if pick == null or pick.grid == Vector3i.ZERO:
		return p
	var g := pick.grid
	return Vector3i(clampi(p.x, -1, g.x), clampi(p.y, -1, g.y), clampi(p.z, -1, g.z))


## 收尾：按笔刷尺寸与**形态**加粗 + 裁掉网格外的格子。
## 【为什么要在这里裁】对象侧的越界处理是"丢弃"，让越界坐标走一趟只会白白记账
## （撤销里出现一堆从未生效的格）。裁剪放在唯一的出口，预览与落笔因此看到同一批格。
func _finish(cells: Array[Vector3i], pick: Pick) -> Array[Vector3i]:
	var radius := brush_size - 1
	if supports_brush_size() and radius > 0:
		if brush_shape == Shape.PLANE:
			# 平面形态要一个"面"来定摊开方向：取拾取面的法线。没命中（pick 为空）时退化成 XY 平面 ——
			# 那种情况 pick.valid() 本就为假、这一笔不会真的落下，退化值没有副作用。
			cells = QVoxelBrushGeometry.dilate_plane(cells, radius,
					pick.normal if pick != null else Vector3i.ZERO)
		else:
			cells = QVoxelBrushGeometry.dilate(cells, radius)
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
## 【镜像面取在网格正中】x ↔ grid.x-1-x：32 格时 0 ↔ 31，中缝落在 16 与 15 之间。
## 这与 MagicaVoxel 的对称以网格中心为轴一致，也与"边界体素仍落在网格内"一致
## （镜像一个网格内坐标仍是网格内坐标，故镜像不会产生越界格，后面的裁剪只是保险）。
## 【先去重】多轴勾选时组合出的像会互相重合（如格正好在对称面上），
## 交给销毁命令前先去重，撤销里就不会出现同一格被写两次的冗余快照。
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

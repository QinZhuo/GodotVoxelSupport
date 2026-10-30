class_name PointerTool

## 指针状态登记：任何可点的 3D 物体在鼠标进入/离开时登记自己，
## 输入层据此区分「点在交互物上」与「点在空白上」（如点空白返回）。

## 当前压在指针下的可交互对象
static var over: Node3D = null

## 当前正在拖拽的视图（DragView3D），拖拽期间抑制其它视图的悬停
static var dragging: Node3D = null

## 悬停接线：进入/离开转给表现层回调，离开树时兜底注销（回收的视图不残留登记）。
## 表现层自己管 enter/exit，是因为是否算"悬停"由视图状态决定（如拖拽中不点亮）。
static func bind(area: Area3D, on_enter: Callable, on_exit: Callable) -> void:
	if area.mouse_entered.is_connected(on_enter):
		return
	area.mouse_entered.connect(on_enter)
	area.mouse_exited.connect(on_exit)
	area.tree_exiting.connect(func() -> void: PointerTool.exit(area))

static func enter(node: Node3D) -> void:
	over = node

static func exit(node: Node3D) -> void:
	if over == node:
		over = null

## 指针是否落在空白处：没有压在可交互物上（含对象已释放/已隐藏的陈旧登记）
static func is_blank() -> bool:
	return not NodeTreeTool.is_alive(over)

static func begin_drag(node: Node3D) -> void:
	dragging = node

static func end_drag() -> void:
	dragging = null

## 是否有视图正在拖拽（陈旧登记顺手清掉，避免被回收的视图锁死全部悬停）
static func is_dragging() -> bool:
	if not is_instance_valid(dragging):
		dragging = null
		return false
	return true

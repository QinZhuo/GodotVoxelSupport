@tool
class_name QVoxelierResizeHandle
extends Control
## 面板边缘的竖向拖动条：拖它改相邻面板的宽度。
## 【为什么不用 SplitContainer】我们的布局是"锚点 + 按内容算宽度"，不是容器嵌套 ——
## 改成 SplitContainer 会牵动 `_sync_rails` / `_reserve_strip` / 侧栏让位一整套逻辑。
## 一条自绘的细条只改一个数字，其余照旧，才是这个架构下改动最小的一档。
## 【为什么常态不画任何东西】它压在视口边缘上，常驻一条线会在每次看模型时都多一道噪点；
## 悬停才亮起，既是"这里能拖"的提示，也不打扰画面。

## 用户拖动（相对上一点的横向位移，正 = 向右）。
signal dragged(delta: float)
## 松手 —— 调用方据此把宽度写进偏好（拖动过程中写盘太频繁）。
signal released

## 命中区宽度。5 px 足够鼠标抓取，又不至于盖住面板边上的一列按钮。
const WIDTH := 5.0

var _dragging := false
var _hover := false


func _ready() -> void:
	custom_minimum_size.x = WIDTH
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_HSIZE
	mouse_entered.connect(func() -> void:
		_hover = true
		queue_redraw())
	mouse_exited.connect(func() -> void:
		_hover = false
		queue_redraw())


func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
		_dragging = mb.pressed
		queue_redraw()
		if not mb.pressed:
			released.emit()
		accept_event()
		return
	var mm := event as InputEventMouseMotion
	if mm != null and _dragging:
		dragged.emit(mm.relative.x)
		accept_event()


## 只在悬停 / 拖动时画一条竖线：平时完全透明，不打扰画面。
func _draw() -> void:
	if not (_hover or _dragging):
		return
	var x := size.x * 0.5
	var c: Color = QVoxelUi.ACCENT if _dragging else QVoxelUi.BORDER
	draw_line(Vector2(x, 0.0), Vector2(x, size.y), c, 2.0)

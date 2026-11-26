@tool
class_name QVoxelierResizeHandle
extends Control
## 面板边缘的竖向拖动条：拖它改相邻面板的宽度。

## 用户拖动（相对上一点的横向位移，正 = 向右）。
signal dragged(delta: float)
## 松手 —— 调用方据此把宽度写进偏好（拖动过程中写盘太频繁）。
signal released

## 命中区宽度。
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

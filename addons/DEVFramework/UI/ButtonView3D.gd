class_name ButtonView3D extends Area3D

@export var enter_tween: TweenAnimation
@export var press_tween: TweenAnimation

@export var visible_tween: TweenAnimation
@export var tween_visible: bool = true:
	set(value):
		if tween_visible == value:
			return
		tween_visible = value
		_update_visible(false)

@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@export var outline_mesh: MeshInstance3D

## 悬停提示文案 key（tip.csv），留空则不提示；需动态文案或多键提示时重写 get_click_tip()
@export var click_tip: StringName
## 悬停提示优先级：大于常驻流程提示时优先显示
@export var click_tip_priority: int = 0

var is_pressed: bool
var is_enter: bool

signal button_down()
signal button_up()

## 悬停信号在通知阶段连接，子类重写 _ready 时无需 super
func _ready() -> void:
	_update_visible(true)

func _notification(what: int) -> void:
	if what == NOTIFICATION_READY:
		PointerTool.bind(self, _mouse_enter, _mouse_exit)

func _exit_tree():
	_mouse_exit()

func _update_visible(reset: bool):
	TweenViewTool.update_visible(visible_tween, tween_visible, reset)

func _mouse_enter():
	if PointerTool.is_dragging() or is_enter:
		return
	is_enter = true
	PointerTool.enter(self)
	if enter_tween:
		enter_tween.play()
	if outline_mesh:
		OutlineEffect.set_outlined(true, outline_mesh)
	TipTool.show_tip(get_click_tip(), self, click_tip_priority, TipTool.hover_delay)

func _mouse_exit():
	TipTool.hide_tip(self, TipTool.hide_delay)
	if PointerTool.is_dragging() or not is_enter:
		return
	is_enter = false
	PointerTool.exit(self)
	if outline_mesh:
		OutlineEffect.set_outlined(false, outline_mesh)
	if enter_tween:
		enter_tween.playback()
	if press_tween:
		press_tween.playback()

## 返回文案 key，或 [[按键, key], ...] 条目；返回空则不提示。随状态变化时重写这里
func get_click_tip() -> Variant:
	return click_tip

func _mouse_down():
	is_pressed = true
	if press_tween:
		press_tween.play()
	elif enter_tween:
		enter_tween.playback()
	_button_down()

func _mouse_up():
	if not is_pressed:
		return
	is_pressed = false
	if press_tween:
		press_tween.playback()
	elif enter_tween:
		enter_tween.play()
	_button_up()

func _button_down():
	button_down.emit()

func _button_up():
	button_up.emit()

func _input_event(_camera: Camera3D, event: InputEvent, event_position: Vector3, _normal: Vector3, _shape_idx: int):
	_game_input(event, event_position)

## 供手柄焦点导航调用的激活方法，模拟一次完整点击。
func activate() -> void:
	if not visible:
		return
	_mouse_down()
	_mouse_up()

func _game_input(event: InputEvent, _event_position: Vector3):
	if event is InputEventMouseButton:
		var button_event: InputEventMouseButton = event
		if button_event.button_index == MOUSE_BUTTON_LEFT:
			if button_event.is_pressed():
				_mouse_down()
			elif button_event.is_released():
				_mouse_up()
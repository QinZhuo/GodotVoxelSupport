@tool
class_name QVoxelierGestureNav
extends RefCounted
## 触摸 / 触摸板手势 → 相机导航增量。
## 【输入输出】feed() 收 ScreenTouch/ScreenDrag（多指跟踪）与 Magnify/PanGesture（引擎派发的
## 系统手势），把结果累积成 orbit（像素位移）与 zoom（比例）两份量；App 每次 feed 后取走应用。
## 状态解析与相机动作分离 —— 这里不认识相机，也不认识界面。
## 【平台差异】Windows 不派发 Magnify/PanGesture（Godot 仅 Android/macOS/Linux 派发），
## 于是触摸板走"滚轮事件"那条路（App 的滚轮分支：垂直=俯仰、水平=偏航、Ctrl=缩放），
## 触摸屏走多指跟踪这条；macOS/Android 的系统手势直接进 feed。
## 双指语义与主流一致：双指拖动 = 旋转视角，捏合 = 缩放（Blender 触控板同款）。

## 双指中心位移 → 旋转的像素增益（1.0 = 中心挪多少像素转多少像素，与鼠标拖拽同手感）。
const DRAG_GAIN := 1.0
## 捏合起步阈值：指距变化在 ±5% 内不算捏合，防止双指刚落下时的抖动触发缩放。
const PINCH_EPS := 1.05

## 当前是否处于多指手势（>= 2 指）。App 据此打断进行中的笔画。
var active := false
## 累积的旋转位移（App 消费后应调 take() 清零）。
var orbit_pending := Vector2.ZERO
## 累积的缩放比例（同上）。
var zoom_pending := 1.0

var _touches := {}            # finger index → 位置（viewport 坐标）
var _center := Vector2.ZERO   # 手势基线：双指中心
var _span := 0.0              # 手势基线：双指距离


## 把一个输入事件喂给手势层。返回 true = 该事件属于手势（App 不再走笔画 / 其它分支）。
## 单指事件永远不消费 —— 那是绘图指针，emulate_mouse 出来的鼠标事件才是它的归宿。
func feed(e: InputEvent) -> bool:
	if e is InputEventMagnifyGesture:
		zoom_pending *= e.factor
		return true
	if e is InputEventPanGesture:
		# 系统手势的 delta 即"手指滑了多少"，与双指拖同语义 → 旋转。
		orbit_pending += e.delta * DRAG_GAIN
		return true
	if e is InputEventScreenTouch:
		if e.pressed:
			_touches[e.index] = e.position
		else:
			_touches.erase(e.index)
		_sync_baseline()
		return active or _touches.size() >= 2
	if e is InputEventScreenDrag:
		if not _touches.has(e.index):
			_touches[e.index] = e.position
		else:
			_touches[e.index] = e.position
		if not active:
			return false
		# 双指拖：跟手转视角（中心位移）；捏合：指距比例缩放。两者同时发生也各算各的。
		var c := _center_of()
		orbit_pending += (c - _center) * DRAG_GAIN
		var s := _span_of()
		if _span > 0.0 and s > 0.0:
			var ratio := s / _span
			if ratio > PINCH_EPS or ratio < 1.0 / PINCH_EPS:
				zoom_pending *= ratio
		_center = c
		_span = s
		return true
	return false


## 取走累积量并清零（App 每次 feed 后调用）。
func take() -> void:
	orbit_pending = Vector2.ZERO
	zoom_pending = 1.0


## 触点数落到 2 以下 → 手势结束、基线清掉。留下的单指继续被当鼠标（画 / 擦）——
## 但笔画已在手势开始时被 App 取消，必须重新按下才落笔，不会"凭空续上一笔"。
func _sync_baseline() -> void:
	if _touches.size() >= 2:
		if not active:
			active = true
			_center = _center_of()
			_span = _span_of()
	else:
		active = false


func _center_of() -> Vector2:
	var c := Vector2.ZERO
	for p: Vector2 in _touches.values():
		c += p
	return c / float(_touches.size())


func _span_of() -> float:
	var pts := _touches.values()
	if pts.size() < 2:
		return 0.0
	# 最远两指的距离：先取离第 0 指最远的，再取离它最远的 —— 双指（主场景）下即精确指距。
	var far: Vector2 = pts[0]
	for p: Vector2 in pts:
		if p.distance_squared_to(pts[0]) > far.distance_squared_to(pts[0]):
			far = p
	var best := 0.0
	for p: Vector2 in pts:
		best = maxf(best, p.distance_to(far))
	return best

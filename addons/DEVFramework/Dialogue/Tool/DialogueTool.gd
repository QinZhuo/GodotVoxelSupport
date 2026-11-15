## 对话子系统入口。三条命令够用：
##
##     DialogueTool.bind(ui_layer)          # 只需一次（遮罩会自动做）
##     DialogueTool.show("点这里继续", rect) # 一条提示
##     DialogueTool.play(script)            # 一段对话
##
## 表现层默认是 `BubbleView`；想要自己的样子：
##     DialogueTool.view_scene = preload("res://你的气泡.tscn")
##     或 DialogueTool.register(MyDialogueView.new())
class_name DialogueTool

## 项目可替换的表现场景（须继承 DialogueView）
static var view_scene: PackedScene
## 项目主题。气泡通常挂在 CanvasLayer 下，而 CanvasLayer 不参与 Control 的主题链，
## 所以这里显式传一份，view 才能读到项目里的样式/字体。
static var theme: Theme

static var _view: DialogueView
static var _session: DialogueSession


# ------------------------------------------------------------
# 绑定
# ------------------------------------------------------------

## 把表现层挂到某个 UI 父节点（重复调用复用实例）
static func bind(parent: Control, z_index := 0) -> DialogueView:
	if _view != null and is_instance_valid(_view):
		# 已注册的 view 也要套层级: 否则会被遮罩的合成层盖住(看起来"气泡也被压暗了")
		_view.z_as_relative = false
		_view.z_index = z_index
		if theme != null:
			_view.theme = theme
		if parent != null:
			if _view.get_parent() == null:
				parent.add_child(_view)  # 项目先 register() 再 bind: 这里补上入树
			elif _view.get_parent() != parent:
				_view.reparent(parent)
		return _view
	if parent == null:
		return null
	if view_scene != null:
		_view = view_scene.instantiate() as DialogueView
	if _view == null:
		_view = BubbleView.new()
	_view.name = "DialogueView"
	_view.z_as_relative = false
	_view.z_index = z_index
	parent.add_child(_view)
	return _view


## 直接塞一个自己的表现层
static func register(view: DialogueView) -> void:
	_view = view


static func view() -> DialogueView:
	return _view if is_instance_valid(_view) else null


static func is_bound() -> bool:
	return view() != null


# ------------------------------------------------------------
# 一条提示
# ------------------------------------------------------------

## 显示一条提示；anchor 省略 = 屏幕底部（或 view 自己的摆法）
static func show(text: String, anchor := Rect2(), view_size := Vector2.ZERO) -> void:
	var p := view()
	if p == null:
		return
	if _session != null:
		_session.cancel()
		_session = null
	if view_size == Vector2.ZERO:
		view_size = p.get_viewport_rect().size
	p.set_anchor_rect(anchor, view_size)
	p.present(null, text)


## 目标移动时每帧调（只更新锚点，不重设文案）
static func set_anchor(anchor: Rect2, view_size := Vector2.ZERO) -> void:
	var p := view()
	if p == null:
		return
	if view_size == Vector2.ZERO:
		view_size = p.get_viewport_rect().size
	p.set_anchor_rect(anchor, view_size)


static func hide() -> void:
	var p := view()
	if p:
		p.dismiss()




# ------------------------------------------------------------
# 一段对话
# ------------------------------------------------------------

static func play(script: DialogueScriptDef, ctx: Dictionary = {}) -> DialogueSession:
	var p := view()
	if p == null or script == null or script.is_empty():
		return null
	if _session != null:
		_session.cancel()
	_session = DialogueSession.new(script)
	_session.context = ctx
	_session.line_changed.connect(_on_line_changed)
	_session.finished.connect(_on_finished)
	if not _session.start(ctx):
		_session = null
	return _session


static func _on_line_changed(line: DialogueLineDef, _index: int) -> void:
	var p := view()
	if p:
		p.present(line, line.display_text() if line else "")


static func _on_finished() -> void:
	var p := view()
	if p:
		p.dismiss()
	_session = null


## 推进：有对话 → 下一行；没有 → 关闭提示
static func next() -> bool:
	if _session != null:
		return _session.next()
	hide()
	return false


static func stop() -> void:
	if _session != null:
		_session.cancel()
		_session = null
	hide()


## 整体重置(停止播放)。不清掉表现层:
## 项目可能 register 过自己的 view, 清掉后下次 bind 会退回默认外观。
static func reset() -> void:
	stop()


static func is_playing() -> bool:
	return _session != null and _session.running


static func session() -> DialogueSession:
	return _session


## 注: 不提供输入接管。推进由项目自己决定(调 next()),
## 返回/退出等全局按键必须交给项目自己的返回决策点, 框架不吞任何按键。

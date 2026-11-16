@tool
## 焦点遮罩 — 全场变暗, 只有被聚焦的目标"原样显示在最前面".
##
## 实现只有一件事: 一次性屏幕空间合成(读已经画好的整帧), 目标区域内取屏幕原样 × 提亮,
## 区域外压暗。因为读的是"最终画面", 所以:
##   · 不需要挖洞、不修改任何节点的 z_index / modulate / 父子关系
##   · 不需要和 CanvasLayer / SubViewport 比层级 —— 嵌套子视口天然正确
##   · dim_color.a = 1 时目标外就是纯黑(而不是"比别人暗一点")
##
## 描边/发光: 3D 目标用"只渲染目标"那张贴图的 alpha 当轮廓(贴合物体的真实形状),
## 纯 2D 控件没有离屏轮廓, 用控件矩形(圆角 SDF)。
class_name FocusMask extends Control

## 空白处按下(仅 click_to_complete 开启时; 供"点任意处继续")
signal blank_pressed
## 气泡完成一次排版(宿主可在这里对气泡做二次布局: 塞模型/改宽度等)

## 合成层(z_index 上限 4096)
const DIM_Z := 4088
const TIP_Z := 4092
## 一次最多处理多少个目标矩形(与 shader 里的数组长度保持一致)
const MAX_RECTS := 16
const _SPOT_SHADER: Shader = preload("res://addons/DEVFramework/Focus/FocusMaskSpotlight.gdshader")
const _NAV_ACTIONS: Array[StringName] = [&"ui_focus_next", &"ui_focus_prev",
		&"ui_left", &"ui_right", &"ui_up", &"ui_down"]
const _BACK_ACTIONS: Array[StringName] = [&"ui_focus_prev", &"ui_left", &"ui_up"]

## 暗区颜色(alpha = 压暗强度, rgb = 暗色倾向; alpha=1 → 目标外纯黑)
@export var dim_color := Color(0.0, 0.0, 0.0, 0.62)
## 拦截目标外的一切交互(点击/悬停/焦点导航)
@export var block_input := true
## 键盘/手柄的"继续"动作, 空 = 只能点击
@export var advance_action: StringName = &"ui_accept"
## 点/按任意处触发 blank_pressed(展示说明类步骤的"点一下继续")
@export var click_to_complete := false
## 拖拽放行(可选): 返回 true 时放行全部指针事件
var drag_checker: Callable

## 目标自身的提亮倍数(>1 = 比平时更亮, 在暗场里跳出来)
@export var focus_boost := 1.15
## 2D 目标的区域圆角(描边/区域形状; 0 = 直角)
@export var corner_radius := 10.0
## 描边颜色 / 线宽(像素)
@export var outline_color := Color(1.0, 0.86, 0.55, 1.0)
@export var outline_width := 2.5
## 3D 目标是否用"真实轮廓"做区域与发光(需要额外的轮廓渲染通道)
@export var outline_3d := true
## 轮廓渲染用的层(1..20, 需项目未占用)
@export_range(1, 20) var highlight_layer := 20
## 轮廓渲染抗锯齿
@export var highlight_msaa := Viewport.MSAA_4X

## 气泡/对话的表现层完全由 Dialogue 子系统负责(Dialogue/View/*)。
## 遮罩只做两件事: 算命中区、把"锚在哪"喂给 DialogueTool —— 不持有任何气泡控件。
## 项目要换外观: DialogueTool.view_scene = 自己的场景 / DialogueTool.register(...)

var _targets: Array[Node] = []
## 舞台根(收光源用)
var _host: Node
## 目标 → 真正被点亮的节点(子视口里的目标升级为承载它的 SubView3D 面板)
var _promoted := {}
## 可交互区域(屏幕坐标)
var _hit_rects: Array[Rect2] = []
## 与 _hit_rects 一一对应的圆角(取自目标自己的样式盒, 圆形按钮才能画成圆)
var _hit_radii := PackedFloat32Array()
var _screen_size := Vector2.ZERO
var _active := false


## 屏幕空间合成
var _spot: ColorRect
var _spot_mat: ShaderMaterial
## 轮廓(只渲目标的那张贴图: 3D 用层分离重渲, 2D 用离屏快照)
var _sil_target: Node3D
var _sil_view: SubViewport
var _sil_cam: Camera3D
var _sil_rect_index := -1
var _sil_rect := Rect2()
var _sil_layers_backup := {}
## 轮廓贴图是否可用(离屏快照可能渲出空图 → 自动退回矩形描边)
var _sil_ok := true
## 建好后等几帧再验证一次(离屏快照需要先渲一帧)
var _sil_check_frames := 0
## 目标数超上限是否已提示过(避免每帧刷警告)
var _warned_overflow := false
## 2D 目标的离屏快照(duplicate 一份渲染, 拿它的 alpha 当真实轮廓)
var _contour_view: SubViewport


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	visible = false
	set_process_input(true)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)  # 合成层要正好铺满屏幕
	_apply_theme()
	_build_spot()
	_bind_view()


## 主题覆盖(项目可只在 theme 里配 FocusMask/* 而不用逐个实例赋值)
func _apply_theme() -> void:
	if has_theme_color("dim_color", "FocusMask"):
		dim_color = get_theme_color("dim_color", "FocusMask")
	if has_theme_color("outline_color", "FocusMask"):
		outline_color = get_theme_color("outline_color", "FocusMask")


func _exit_tree() -> void:
	_release_presentation()


# ------------------------------------------------------------
# 公开 API
# ------------------------------------------------------------

## 聚焦一组目标(节点)。命中区 = 每个目标自身的屏幕矩形, 不做任何外扩
## opts: dim(Color) / focus_boost(float) / block(bool) / click_to_complete(bool) /
##       advance_action(StringName) / drag_checker(Callable) / tip(String)
## host = 舞台根(收光源/兜底范围用)
func focus(items: Array, opts: Dictionary = {}, host: Node = null) -> void:
	_apply_opts(opts)
	_host = host
	_targets.clear()
	for item in items:
		if item is Node and is_instance_valid(item):
			_targets.append(item)
	_active = true
	visible = true
	_apply_presentation()
	_update_geometry()
	_apply_tip(str(opts.get("tip", "")))
	_grab_target_focus()


## 取消聚焦(暗区消失, 不再拦截任何输入)
func clear() -> void:
	_active = false
	visible = false
	_release_presentation()
	_targets.clear()
	_hit_rects = []
	DialogueTool.hide()


## 配一句提示(空 = 隐藏)。气泡怎么排由 Dialogue 子系统的 view 决定。
## 私有: 外部要改文案请用 DialogueTool.show() / TutorialGuide.set_tip()。
func _apply_tip(text: String) -> void:
	if not DialogueTool.is_bound():
		return
	if text.is_empty() or not _active:
		DialogueTool.hide()
		return
	var view := _screen_size if _screen_size != Vector2.ZERO else get_viewport_rect().size
	DialogueTool.show(text, _merged_rects(), view)


func is_active() -> bool:
	return _active


## 是否处于"锁定目标外输入"状态(供外部禁用快捷键/操作)
func is_blocking() -> bool:
	return _active and block_input


## 当前可交互区域(屏幕坐标)
func get_hit_rects() -> Array[Rect2]:
	return _hit_rects.duplicate()


## 当前目标的包围盒(气泡的锚点)。无目标 = 空矩形 = 纯提示。
func get_focus_rect() -> Rect2:
	return _merged_rects()


# ------------------------------------------------------------
# 表现: 屏幕空间合成 + 可选 3D 轮廓
# ------------------------------------------------------------

func _process(_delta: float) -> void:
	if not _active:
		return
	_update_geometry()
	_sync_silhouette()
	_tick_silhouette()


func _apply_presentation() -> void:
	_release_presentation()
	_promote_targets()
	_setup_silhouette()
	_apply_spot_params()


## 目标 → 真正要显示的节点(子视口里的目标升级为承载它的 SubView3D 面板)
func _promote_targets() -> void:
	for node in _targets:
		_promoted[node] = _promote(node)


static func _promote(node: Node) -> Node:
	var viewport := node.get_viewport()
	if not (viewport is SubViewport):
		return node
	var cursor := viewport.get_parent()
	while cursor:
		if cursor is SubView3D and (cursor as SubView3D).viewport == viewport:
			return cursor
		cursor = cursor.get_parent()
	return node


## 建"只渲染目标"的轮廓通道: 3D 用层分离重渲, 2D 用离屏快照(子视口里的也算)
func _setup_silhouette() -> void:
	if not outline_3d:
		return
	for i in _targets.size():
		var node: Node = _targets[i]
		var promoted: Node = _promoted.get(node)
		if promoted is Node3D and promoted == node:
			# 只有"有可见网格"的 3D 物体才值得渲染轮廓贴图;
			# 纯交互体(Area3D 之类)渲出来是空 alpha, 会让目标区域被判成"区域外"⇒ 看着完全不亮。
			# 多目标时继续往后找: 第一个有网格的物体负责出轮廓。
			if _visible_mesh_aabb(promoted as Node3D).size != Vector3.ZERO:
				_build_3d_silhouette(promoted as Node3D, i)
				return
			continue
		# 2D 目标不建轮廓快照: 控件样式盒经常只画边框/贴图未设置, 快照里"控件内部"是空的,
		# 于是目标内部会被当成区域外(遮罩不透明时只剩一圈框、本体全黑)。
		# 2D 直接用"矩形 + 样式盒圆角"的 SDF, 形状与区域都可靠。
		return


## 2D 目标的真实轮廓: 把控件自己的样式盒画进离屏视口。
## 不走 duplicate —— 复制体脱离主题上下文后经常画不出东西(全透明),
## 直接取"实际生效的 StyleBox"来画, 圆角/胶囊/带缺口都能贴合。
func _build_2d_contour(node: CanvasItem, index: int) -> bool:
	if not (node is Control):
		return false
	var control := node as Control
	var box := _style_box_of(control)
	if box == null:
		return false
	var rect := screen_rect(node)
	if rect.size == Vector2.ZERO:
		return false
	var size := Vector2i(maxi(int(ceil(rect.size.x)), 8), maxi(int(ceil(rect.size.y)), 8))
	_contour_view = SubViewport.new()
	_contour_view.name = "FocusContour"
	_contour_view.transparent_bg = true
	_contour_view.disable_3d = true
	_contour_view.size = size
	_contour_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_contour_view.gui_disable_input = true
	add_child(_contour_view)
	var painter := ContourPainter.new()
	painter.name = "ContourPainter"
	painter.box = box
	painter.size = Vector2(size)
	_contour_view.add_child(painter)
	_sil_view = _contour_view
	_sil_rect = rect
	_sil_rect_index = index
	_sil_ok = true
	_sil_check_frames = 2  # 离屏快照要先渲一帧, 2 帧后再验证是否有内容
	return true


## 目标自己的圆角(取样式盒四角最大值; 不是 StyleBoxFlat 就是 0 = 用全局默认)
static func _corner_radius_of(node: Node) -> float:
	var control := node as Control
	if control == null:
		return 0.0
	var box := _style_box_of(control)
	if box is StyleBoxFlat:
		var flat := box as StyleBoxFlat
		return float(maxi(maxi(flat.corner_radius_top_left, flat.corner_radius_top_right),
				maxi(flat.corner_radius_bottom_left, flat.corner_radius_bottom_right)))
	return 0.0


## 取控件"实际生效"的样式盒(用来还原它的形状)
static func _style_box_of(control: Control) -> StyleBox:
	if control is Button:
		var btn := control as Button
		for name in ["normal", "pressed", "hover"]:
			var box := btn.get_theme_stylebox(name)
			if box:
				return box
	elif control is Panel:
		var panel_box := (control as Panel).get_theme_stylebox("panel")
		if panel_box:
			return panel_box
	var fallback := control.get_theme_stylebox("panel")
	return fallback


## 把样式盒画出来的最小画布(只用来生成轮廓 alpha)
class ContourPainter extends Control:
	var box: StyleBox

	func _draw() -> void:
		if box == null:
			return
		# 有些按钮样式只画边框(draw_center = false)。这种样式画出来的 alpha 只有一圈,
		# 轮廓里"控件内部"就是空的 → 目标内部会被当成区域外而保持压暗
		# (表现出来就是: 遮罩不透明时只剩一个描边框、按钮本体看不见)。
		# 这种情况补一层实心底, 形状就是整块控件区域。
		if box is StyleBoxFlat and not (box as StyleBoxFlat).draw_center:
			draw_rect(Rect2(Vector2.ZERO, size), Color.WHITE)
		draw_style_box(box, Rect2(Vector2.ZERO, size))


## 每帧维护轮廓: 验证离屏快照是否真的渲出了内容, 并让轮廓跟随目标移动/缩放
func _tick_silhouette() -> void:
	if _sil_view == null or not is_instance_valid(_sil_view) or _sil_rect_index < 0:
		return
	if _sil_check_frames > 0:
		_sil_check_frames -= 1
		if _sil_check_frames == 0 and not _silhouette_has_content():
			_drop_silhouette()
			return
	# 只有 2D 离屏快照需要跟随目标矩形;
	# 3D 轮廓是"整屏坐标系"渲染出来的, 绝不能改成目标矩形(否则轮廓整个错位)
	if _sil_view != _contour_view:
		return
	if _sil_rect_index >= _targets.size():
		return
	var node: Node = _targets[_sil_rect_index]
	if not is_instance_valid(node):
		return
	var rect := screen_rect(node)
	if rect.size == Vector2.ZERO or rect == _sil_rect:
		return
	if rect.size != _sil_rect.size and _sil_view == _contour_view:
		# 尺寸变了: 快照要按新尺寸重建
		var index := _sil_rect_index
		_drop_silhouette()
		if node is CanvasItem:
			_build_2d_contour(node as CanvasItem, index)
		_apply_spot_params()
		return
	_sil_rect = rect
	if _spot_mat:
		_spot_mat.set_shader_parameter("sil_rect", rect)


## 轮廓贴图里是否有实际内容(抽样即可, 只在建立后验证一次)
func _silhouette_has_content() -> bool:
	var tex := _sil_view.get_texture()
	if tex == null:
		return false
	var img := tex.get_image()
	if img == null:
		return false
	for y in range(0, img.get_height(), 3):
		for x in range(0, img.get_width(), 3):
			if img.get_pixel(x, y).a > 0.1:
				return true
	return false


## 轮廓不可用: 释放并退回矩形描边(不能因为拿不到轮廓就什么都不画)
func _drop_silhouette() -> void:
	if is_instance_valid(_sil_view):
		_sil_view.queue_free()
	_sil_view = null
	_sil_cam = null
	_sil_target = null
	_contour_view = null
	_sil_rect_index = -1
	_sil_rect = Rect2()
	_sil_ok = false
	_sil_check_frames = 0
	_apply_spot_params()


## 3D 目标: 层分离 + 同相机重渲, 整屏对齐
func _build_3d_silhouette(target: Node3D, index: int) -> void:
	_sil_target = target
	_sil_rect_index = index
	_sil_rect = Rect2(Vector2.ZERO, _screen_size if _screen_size != Vector2.ZERO else get_viewport_rect().size)
	_sil_ok = true
	_sil_check_frames = 0  # 3D 重渲是稳定的, 不需要验证
	var layer_bit := 1 << (highlight_layer - 1)
	for visual in _visuals_of(_sil_target):
		if not _sil_layers_backup.has(visual):
			_sil_layers_backup[visual] = visual.layers
		visual.layers = layer_bit
	# 相机的 cull_mask 同样筛光源, 光源不进这一层物体就全黑
	for light_node in _collect_lights(_sil_target.get_viewport()):
		if not _sil_layers_backup.has(light_node):
			_sil_layers_backup[light_node] = light_node.layers
		light_node.layers = light_node.layers | layer_bit

	var size := Vector2i(_screen_size if _screen_size != Vector2.ZERO else get_viewport_rect().size)
	_sil_view = SubViewport.new()
	_sil_view.name = "FocusSilhouette"
	_sil_view.transparent_bg = true
	_sil_view.size = size
	_sil_view.msaa_3d = highlight_msaa
	_sil_view.gui_disable_input = true
	_sil_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# 挂在目标下面 → 和它在同一个 3D 世界里(相机才看得到它)
	_sil_target.add_child(_sil_view)
	_sil_cam = Camera3D.new()
	_sil_cam.name = "SilhouetteCamera"
	_sil_cam.cull_mask = layer_bit
	_sil_view.add_child(_sil_cam)
	_sil_cam.current = true
	_sync_silhouette()


## 轮廓相机与"目标所在世界的相机"逐项同步(变换 + 投影)
func _sync_silhouette() -> void:
	if _sil_cam == null or _sil_target == null or not is_instance_valid(_sil_target):
		return
	var world_cam := _sil_target.get_viewport().get_camera_3d()
	if world_cam == null:
		return
	_sil_cam.global_transform = world_cam.global_transform
	_sil_cam.projection = world_cam.projection
	_sil_cam.fov = world_cam.fov
	_sil_cam.size = world_cam.size
	_sil_cam.near = world_cam.near
	_sil_cam.far = world_cam.far
	_sil_cam.keep_aspect = world_cam.keep_aspect
	_sil_cam.frustum_offset = world_cam.frustum_offset
	_sil_cam.h_offset = world_cam.h_offset
	_sil_cam.v_offset = world_cam.v_offset


func _build_spot() -> void:
	if _spot:
		return
	_spot = ColorRect.new()
	_spot.name = "FocusSpotlight"
	_spot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_spot.color = Color.WHITE
	_spot.z_as_relative = false
	_spot.z_index = DIM_Z
	_spot_mat = ShaderMaterial.new()
	_spot_mat.shader = _SPOT_SHADER
	_spot.material = _spot_mat
	# 画面渲染到 SubViewport(3D 世界在子视口里)时, hint_screen_texture 需要显式拷贝一次 backbuffer,
	# 否则采样到的是空的 → 整屏变黑
	var back := BackBufferCopy.new()
	back.name = "FocusBackBuffer"
	back.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	back.z_as_relative = false
	back.z_index = DIM_Z - 1
	add_child(back)
	add_child(_spot)
	_spot.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)



func _apply_spot_params() -> void:
	if _spot_mat == null:
		return
	var view := _screen_size if _screen_size != Vector2.ZERO else get_viewport_rect().size
	_spot_mat.set_shader_parameter("screen_size", view)
	_spot_mat.set_shader_parameter("dim_color", dim_color)
	_spot_mat.set_shader_parameter("focus_boost", focus_boost)
	_spot_mat.set_shader_parameter("corner_radius", corner_radius)
	_spot_mat.set_shader_parameter("outline_color", outline_color)
	_spot_mat.set_shader_parameter("outline_width", outline_width)
	var use_sil := _sil_ok and _sil_view != null and is_instance_valid(_sil_view)
	_spot_mat.set_shader_parameter("use_silhouette", use_sil)
	_spot_mat.set_shader_parameter("sil_index", _sil_rect_index)
	if use_sil:
		_spot_mat.set_shader_parameter("silhouette", _sil_view.get_texture())
		var rect := _sil_rect
		if rect.size == Vector2.ZERO:
			rect = Rect2(Vector2.ZERO, view)
		_spot_mat.set_shader_parameter("sil_rect", rect)
	_push_rects()


## 把当前可交互区域写进着色器(最多 8 个)
func _push_rects() -> void:
	if _spot == null or _spot_mat == null:
		return
	var view := _screen_size if _screen_size != Vector2.ZERO else get_viewport_rect().size
	_spot_mat.set_shader_parameter("screen_size", view)
	# 传归一化坐标(0..1): 着色器用 SCREEN_UV 比较,
	# 这样与"渲染分辨率是否等于逻辑分辨率"无关(3D 渲染到 3x 尺寸的 SubViewport 时也不会错位)
	var view_size := view if view.x > 0.0 and view.y > 0.0 else Vector2.ONE
	var packed := PackedVector4Array()
	var radii := PackedFloat32Array()
	for i in mini(_hit_rects.size(), MAX_RECTS):
		var rect := _hit_rects[i]
		packed.append(Vector4(rect.position.x / view_size.x, rect.position.y / view_size.y,
				rect.size.x / view_size.x, rect.size.y / view_size.y))
		radii.append(_hit_radii[i] if i < _hit_radii.size() else 0.0)
	_spot_mat.set_shader_parameter("rects", packed)
	_spot_mat.set_shader_parameter("radii", radii)
	_spot_mat.set_shader_parameter("rect_count", packed.size())
	# 有目标却一个都定位不到(还没排版/被裁没): 宁可不压暗, 也不要给玩家一片黑
	_spot.visible = _active and (not _targets.is_empty() and packed.size() > 0 or _targets.is_empty())


func _release_presentation() -> void:
	for visual in _sil_layers_backup:
		if is_instance_valid(visual):
			visual.layers = _sil_layers_backup[visual]
	_sil_layers_backup.clear()
	if is_instance_valid(_sil_view):
		_sil_view.queue_free()
	_sil_view = null
	_sil_cam = null
	_sil_target = null
	_sil_rect_index = -1
	_sil_rect = Rect2()
	_contour_view = null
	_promoted.clear()
	if _spot:
		_spot.visible = false


# ------------------------------------------------------------
# 输入
# ------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if not _active or not block_input:
		return
	if drag_checker.is_valid() and drag_checker.call() and _is_release_or_move(event):
		## 拖拽期间只放行"移动/松手/右键取消"(拖出挖孔才不会被截断);
		## 左键按下仍按目标区域拦 —— 否则拖拽窗口里点摇杆等流程入口也会一起放行
		return
	if click_to_complete and (_is_primary_press(event) or _is_advance(event)):
		blank_pressed.emit()
		get_viewport().set_input_as_handled()
		return
	var pos := _pointer_position(event)
	if pos == Vector2.INF:
		if _contain_focus(event):
			get_viewport().set_input_as_handled()
		return
	if not _contains(pos):
		get_viewport().set_input_as_handled()


## 键盘/手柄: 把焦点导航限制在目标内, 防止焦点逃到背后的 UI。
## 注意: **不拦 ui_cancel(返回/ESC)** —— 那是全局语义, 由项目的统一返回决策点处理;
## 遮罩在这里吞掉它, 会让"教程中按 ESC 退出"之类的功能彻底失效。
func _contain_focus(event: InputEvent) -> bool:
	var focusables := _focusables()
	if focusables.is_empty():
		if _is_nav(event):
			return true
		## 确认键: 3D 导航下会直接激活"焦点所在的可交互物"(摇杆等流程入口),
		## 焦点不在目标上时必须一并吞掉, 否则等于绕过了目标外拦截
		return _is_advance(event) and not _focus_in_targets()
	if _is_nav(event):
		_cycle_focus(-1 if _is_back_nav(event) else 1, focusables)
		return true
	return false


## 3D 导航焦点是否落在某个目标上(是则放行确认键, 让玩家照常操作目标)
func _focus_in_targets() -> bool:
	var focus := InputTool.get_3d_focus()
	if focus == null:
		return false
	for node in _targets:
		if is_instance_valid(node) and (node == focus or node.is_ancestor_of(focus) or focus.is_ancestor_of(node)):
			return true
	return false


func _cycle_focus(step: int, focusables: Array[Control]) -> void:
	var current := get_viewport().gui_get_focus_owner()
	var idx := focusables.find(current)
	var next: Control = focusables[0] if idx < 0 else focusables[(idx + step + focusables.size()) % focusables.size()]
	if next and not next.has_focus():
		next.grab_focus()


## 目标自身及子级里所有可聚焦 Control
func _focusables() -> Array[Control]:
	var result: Array[Control] = []
	for node in _targets:
		if is_instance_valid(node):
			_collect_focusables(node, result)
	return result


static func _collect_focusables(node: Node, result: Array[Control]) -> void:
	if node is Control:
		var control := node as Control
		if control.is_visible_in_tree() and control.focus_mode != Control.FOCUS_NONE:
			result.append(control)
	for child in node.get_children():
		_collect_focusables(child, result)


func _grab_target_focus() -> void:
	var focusables := _focusables()
	if focusables.is_empty():
		# 目标没有可聚焦控件(如 3D 物体): 释放残留焦点, 免得继续键激活背后被压暗的按钮
		var owner := get_viewport().gui_get_focus_owner()
		if owner:
			owner.release_focus()
		return
	if not focusables[0].has_focus():
		focusables[0].grab_focus()


static func _is_primary_press(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		return button.pressed and button.button_index == MOUSE_BUTTON_LEFT
	if event is InputEventScreenTouch:
		return (event as InputEventScreenTouch).pressed
	return false


func _is_advance(event: InputEvent) -> bool:
	return advance_action != &"" and event.is_action_pressed(advance_action)


static func _is_nav(event: InputEvent) -> bool:
	for action in _NAV_ACTIONS:
		if event.is_action_pressed(action):
			return true
	return false


static func _is_back_nav(event: InputEvent) -> bool:
	for action in _BACK_ACTIONS:
		if event.is_action_pressed(action):
			return true
	return false


## 指针类事件的屏幕坐标; 非指针事件返回 INF
static func _pointer_position(event: InputEvent) -> Vector2:
	if event is InputEventMouseButton:
		return (event as InputEventMouseButton).position
	if event is InputEventMouseMotion:
		return (event as InputEventMouseMotion).position
	if event is InputEventScreenTouch:
		return (event as InputEventScreenTouch).position
	if event is InputEventScreenDrag:
		return (event as InputEventScreenDrag).position
	return Vector2.INF


## 拖拽期间需要放行的事件: 移动(拖拽本体)、松手(收尾)、右键(取消拖拽)。
## 左键按下不算 —— 它可能是"再点一下别的东西", 该照常按目标区域拦。
static func _is_release_or_move(event: InputEvent) -> bool:
	if event is InputEventMouseMotion or event is InputEventScreenDrag:
		return true
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		return not button.pressed or button.button_index == MOUSE_BUTTON_RIGHT
	if event is InputEventScreenTouch:
		return not (event as InputEventScreenTouch).pressed
	return false


func _contains(pos: Vector2) -> bool:
	for rect in _hit_rects:
		if rect.has_point(pos):
			return true
	return false


# ------------------------------------------------------------
# 几何
# ------------------------------------------------------------

func _update_geometry() -> void:
	var view := get_viewport_rect().size
	var hit_rects: Array[Rect2] = []
	var radii := PackedFloat32Array()
	if view.x > 0.0 and view.y > 0.0:
		var screen := Rect2(Vector2.ZERO, view)
		for i in _targets.size():
			var node := _targets[i]
			if not is_instance_valid(node) or not node.is_inside_tree():
				continue
			var rect := screen_rect(node)
			if rect.size == Vector2.ZERO:
				# 目标被裁剪/还没排版好: 退到承载它的那块面板(子视口目标), 不能一片黑
				rect = _panel_rect(node)
			if rect.size == Vector2.ZERO:
				continue
			rect = rect.intersection(screen)
			if rect.size == Vector2.ZERO:
				rect = _panel_rect(node).intersection(screen)
			if rect.size == Vector2.ZERO:
				continue
			# 兜底退化成"整屏"等于没定位到: 宁可当作没目标, 也别整屏压暗
			if rect.size.x * rect.size.y > screen.size.x * screen.size.y * 0.9:
				continue
			if hit_rects.size() >= MAX_RECTS:
				# 静默截断会表现成"少亮了一个目标", 很难查: 至少报一次
				if not _warned_overflow:
					_warned_overflow = true
					push_warning("FocusMask: 目标超过 %d 个, 超出的不会被点亮/描边" % MAX_RECTS)
				break
			hit_rects.append(rect)
			radii.append(_corner_radius_of(node))
	if hit_rects == _hit_rects and radii == _hit_radii and view == _screen_size:
		return
	_hit_rects = hit_rects
	_hit_radii = radii
	_screen_size = view
	_push_rects()
	_sync_bubble()


## 目标自己算不出矩形时, 用它所在的 SubView3D 面板(屏幕区域)兜底
func _panel_rect(node: Node) -> Rect2:
	var promoted: Node = _promoted.get(node)
	if promoted == null or promoted == node:
		return Rect2()
	return screen_rect(promoted)


func _merged_rects() -> Rect2:
	var merged := Rect2()
	for i in _hit_rects.size():
		merged = _hit_rects[i] if i == 0 else merged.merge(_hit_rects[i])
	return merged


func _apply_opts(opts: Dictionary) -> void:
	if opts.has("dim"):
		dim_color = opts.dim
	if opts.has("focus_boost"):
		focus_boost = opts.focus_boost
	if opts.has("block"):
		block_input = opts.block
	if opts.has("click_to_complete"):
		click_to_complete = opts.click_to_complete
	if opts.has("advance_action"):
		advance_action = opts.advance_action
	if opts.has("drag_checker"):
		drag_checker = opts.drag_checker


# ------------------------------------------------------------
# 提示气泡
# ------------------------------------------------------------

## 把对话子系统的表现层挂到自己这一层(遮罩只提供挂载点与 z)
func _bind_view() -> void:
	var view := DialogueTool.bind(self, TIP_Z)



## 把当前几何交给气泡: 锚点 = 目标包围盒(空 = 纯提示)
func _sync_bubble() -> void:
	if not DialogueTool.is_bound():
		return
	var view := _screen_size if _screen_size != Vector2.ZERO else get_viewport_rect().size
	DialogueTool.set_anchor(_merged_rects(), view)


# ------------------------------------------------------------
# 目标 → 屏幕矩形(2D 控件 / Node2D 精灵 / 3D 模型 / 子视口贴面通用)
# ------------------------------------------------------------

## 节点在屏幕上的可见矩形(失败返回空 Rect2)
static func screen_rect(node: Node) -> Rect2:
	if node == null or not node.is_inside_tree():
		return Rect2()
	var rect := Rect2()
	if node is Node3D:
		rect = _rect_3d(node as Node3D)
	elif node is CanvasItem:
		rect = _rect_2d(node as CanvasItem)
	if rect.size == Vector2.ZERO:
		return Rect2()
	# UI 或 3D 画在子视口里(贴图面渲染到 3D 屏幕等)时, 换回主视口坐标
	return _sub_view_screen_rect(node.get_viewport(), rect)


## CanvasItem → 画布矩形: 合并自身与可见子级(父节点可作为"多目标同框"的目标)
static func _rect_2d(item: CanvasItem) -> Rect2:
	var rects: Array[Rect2] = []
	_collect_canvas_rects(item, rects)
	if rects.is_empty():
		var origin := item.get_global_transform_with_canvas().origin
		return Rect2(origin - Vector2.ONE * 0.5, Vector2.ONE)
	var rect := rects[0]
	for i in range(1, rects.size()):
		rect = rect.merge(rects[i])
	return rect


## 子视口内的矩形 → 屏幕矩形。
## 逐层往上映射: 子视口 → 承载它的 SubView3D → 该面板所在视口 → … → 主视口。
## (嵌套子视口只映射一层会得到"外层视口坐标"而不是屏幕坐标, 高亮就会跑到左上角)
static func _sub_view_screen_rect(viewport: Viewport, rect: Rect2) -> Rect2:
	var current := rect
	var vp: Viewport = viewport
	var guard := 0
	while vp is SubViewport and guard < 8:
		var panel := _find_panel(vp)
		if panel == null:
			break
		current = panel.viewport_rect_to_screen(current)
		vp = panel.get_viewport()
		guard += 1
	return current


## 找到承载某个子视口的 SubView3D(沿祖先链)
static func _find_panel(viewport: Viewport) -> SubView3D:
	var node := viewport.get_parent()
	while node:
		if node is SubView3D and (node as SubView3D).viewport == viewport:
			return node as SubView3D
		node = node.get_parent()
	return null


## Node3D → 屏幕矩形。统一用"可见 mesh 世界 AABB 合并投影"而非顶点投影
static func _rect_3d(node: Node3D) -> Rect2:
	var cam := node.get_viewport().get_camera_3d()
	if cam == null:
		return Rect2()
	var aabb := _visible_mesh_aabb(node)
	if aabb.size == Vector3.ZERO:
		aabb = _global_aabb(node)  # 无可见网格 → 退回整体 AABB
	if aabb.size == Vector3.ZERO:
		aabb = _collision_aabb(node)  # 只有碰撞盒的交互体(Area3D 之类): 用碰撞形状估矩形
	if cam.is_position_behind(aabb.get_center()):
		return Rect2()
	var rect := Rect2()
	for i in 8:
		var p := cam.unproject_position(aabb.get_endpoint(i))
		rect = rect.expand(p) if i > 0 else Rect2(p, Vector2.ZERO)
	if rect.size == Vector2.ZERO:
		# 所有角投影重叠(目标极小/极远): 以中心投影点为单位矩形兜底
		var c := cam.unproject_position(aabb.get_center())
		return Rect2(c - Vector2.ONE * 0.5, Vector2.ONE)
	return rect


## 汇总"真实显示中"的网格世界 AABB(合并), 收所有可见 MeshInstance3D 与 Label3D
static func _visible_mesh_aabb(node: Node3D) -> AABB:
	if not node.is_visible_in_tree():
		return AABB()
	var result := AABB()
	var found := false
	if node is MeshInstance3D and (node as MeshInstance3D).mesh:
		result = (node as MeshInstance3D).global_transform * (node as MeshInstance3D).mesh.get_aabb()
		found = true
	elif node is Label3D and (node as VisualInstance3D).get_aabb().size != Vector3.ZERO:
		result = (node as Node3D).global_transform * (node as VisualInstance3D).get_aabb()
		found = true
	for child in node.get_children():
		if child is Node3D:
			var aabb := _visible_mesh_aabb(child)
			if aabb.size != Vector3.ZERO:
				result = result.merge(aabb) if found else aabb
				found = true
	return result


## 只有碰撞盒、没有可见网格的交互体(Area3D/StaticBody3D 之类):
## 用它子级 CollisionShape3D 的形状拼出世界 AABB, 否则目标会退化成 1x1 ⇒ 看起来"没高亮"
static func _collision_aabb(node: Node3D) -> AABB:
	var result := AABB()
	var found := false
	for child in node.find_children("*", "CollisionShape3D", true, false):
		var box := _shape_aabb(child as CollisionShape3D)
		if box.size == Vector3.ZERO:
			continue
		result = result.merge(box) if found else box
		found = true
	return result


## 单个 CollisionShape3D 的世界 AABB(按形状尺寸取 8 角投影)
static func _shape_aabb(shape_node: CollisionShape3D) -> AABB:
	var shape := shape_node.shape
	if shape == null:
		return AABB()
	var size := Vector3.ZERO
	if shape is BoxShape3D:
		size = (shape as BoxShape3D).size
	elif shape is SphereShape3D:
		size = Vector3.ONE * (shape as SphereShape3D).radius * 2.0
	elif shape is CapsuleShape3D:
		var capsule := shape as CapsuleShape3D
		size = Vector3(capsule.radius * 2.0, capsule.height, capsule.radius * 2.0)
	elif shape is CylinderShape3D:
		var cylinder := shape as CylinderShape3D
		size = Vector3(cylinder.radius * 2.0, cylinder.height, cylinder.radius * 2.0)
	if size == Vector3.ZERO:
		return AABB()
	var xform := shape_node.global_transform
	var local := AABB(-size * 0.5, size)
	var result := AABB(xform * local.position, Vector3.ZERO)
	for i in 8:
		result = result.expand(xform * local.get_endpoint(i))
	return result


## 汇总节点(含子级)的全局 AABB
static func _global_aabb(node: Node3D) -> AABB:
	if node is VisualInstance3D:
		return (node as VisualInstance3D).global_transform * (node as VisualInstance3D).get_aabb()
	var result := AABB()
	var found := false
	for child in node.get_children():
		if child is Node3D:
			var aabb := _global_aabb(child)
			if aabb.size == Vector3.ZERO and not found:
				continue
			result = result.merge(aabb) if found else aabb
			found = true
	if not found:
		return AABB(node.global_position, Vector3.ZERO)
	return result


## 收集 CanvasItem(含子级, 仅可见)的画布坐标矩形
static func _collect_canvas_rects(item: CanvasItem, result: Array[Rect2]) -> void:
	if not item.visible:
		return
	if item is Control:
		result.append((item as Control).get_global_rect())
	elif item is Sprite2D:
		var local := (item as Sprite2D).get_rect()
		if local.size != Vector2.ZERO:
			result.append(_canvas_rect(item, local))
	for child in item.get_children():
		if child is CanvasItem:
			_collect_canvas_rects(child, result)


## 局部矩形 → 画布坐标包围矩形(Node2D 经 global_transform_with_canvas 投影)
static func _canvas_rect(item: Node2D, local_rect: Rect2) -> Rect2:
	var t := item.get_global_transform_with_canvas()
	var p1 := t * local_rect.position
	var p2 := t * (local_rect.position + local_rect.size)
	return Rect2(
		Vector2(minf(p1.x, p2.x), minf(p1.y, p2.y)),
		Vector2(absf(p2.x - p1.x), absf(p2.y - p1.y)))


# ------------------------------------------------------------
# 辅助
# ------------------------------------------------------------

static func _collect_lights(node: Node) -> Array[Light3D]:
	var result: Array[Light3D] = []
	if node is Light3D:
		result.append(node)
	for child in node.get_children():
		result.append_array(_collect_lights(child))
	return result


## 目标自身及子级里所有真实参与绘制的实例(Area3D 本身不画, 画的是它的 mesh 子节点)
static func _visuals_of(node: Node) -> Array[VisualInstance3D]:
	var result: Array[VisualInstance3D] = []
	if node is VisualInstance3D:
		result.append(node)
	for child in node.get_children():
		result.append_array(_visuals_of(child))
	return result

@tool
## 机位取景器(编辑器底部面板): 实时预览某个 VirtualCamera3D 看到的画面。
##
## 做法: 用一个 SubViewport 共享编辑器 3D 视口的 World3D, 内部放一台预览相机并对齐到目标机位。
## 因此不需要复制场景、不改动场景树, 看到的就是编辑中的真实场景。
## 画面按 项目实际游戏分辨率比例 letterbox 显示, 取景范围与运行时一致。
## 由 DEVFramework 插件挂载到底部面板(无 class_name, 仅编辑器加载)。
extends Control

## 项目分辨率设置项
const SETTING_WIDTH := "display/window/size/viewport_width"
const SETTING_HEIGHT := "display/window/size/viewport_height"
## 读不到项目设置时的回退比例
const FALLBACK_ASPECT := 16.0 / 9.0
## 预览相机的默认视场角(机位与 Brain 都没指定 fov 时)
const DEFAULT_FOV := 60.0
## 画面区域的最小高度(避免面板过扁时渲染目标退化)
const MIN_HEIGHT := 180.0
## 机位列表的重扫间隔(秒): 扫全场景树有开销, 不必每帧做
const RESCAN_INTERVAL := 0.5

var _aspect: AspectRatioContainer
var _container: SubViewportContainer
var _viewport: SubViewport
var _camera: Camera3D
var _overlay: Control
var _tip: Label
var _info: Label
var _picker: OptionButton
var _follow: CheckBox
var _guides: CheckBox
var _solo: Button
var _target: VirtualCamera3D = null
## 下拉列表当前列出的机位(与 OptionButton 的 item 一一对应)
var _cameras: Array[VirtualCamera3D] = []
## 列表签名: 仅在机位增删改名时才重建下拉, 避免每帧重建导致无法点选
var _list_signature: String = ""
var _rescan_timer: float = 0.0
## 当前生效的画面比例(宽/高)
var _ratio: float = FALLBACK_ASPECT


func _ready() -> void:
	name = "CameraViewfinder"
	_build_ui()
	# 编辑器中 _process 不会自动启用, 必须显式打开, 否则取景器永远不刷新
	set_process(true)


func _process(delta: float) -> void:
	if _viewport == null:
		return
	_update(delta)


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var bar := HBoxContainer.new()
	root.add_child(bar)

	_picker = OptionButton.new()
	_picker.tooltip_text = "在场景中的机位之间快速切换预览"
	_picker.custom_minimum_size = Vector2(160, 0)
	_picker.item_selected.connect(_on_camera_selected)
	bar.add_child(_picker)

	_info = Label.new()
	_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info.clip_text = true
	bar.add_child(_info)

	_follow = CheckBox.new()
	_follow.text = "跟随选中"
	_follow.button_pressed = true
	_follow.tooltip_text = "在场景中选中机位时自动切换预览; 关闭则只由左侧下拉决定"
	bar.add_child(_follow)
	_guides = CheckBox.new()
	_guides.text = "构图线"
	_guides.button_pressed = true
	_guides.toggled.connect(_on_guides_toggled)
	bar.add_child(_guides)
	_solo = Button.new()
	_solo.text = "Solo"
	_solo.tooltip_text = "让该机位立即生效(激活并置顶), 运行时可用; 编辑器中只改变竞争关系"
	_solo.pressed.connect(_on_solo_pressed)
	bar.add_child(_solo)

	# 按游戏分辨率比例 letterbox: AspectRatioContainer 会把每个 Control 子节点
	# 摆到同一个按比例居中的矩形, 因此画面与构图线叠层能精确对齐。
	_aspect = AspectRatioContainer.new()
	_aspect.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_aspect.ratio = _ratio
	_aspect.custom_minimum_size = Vector2(0, MIN_HEIGHT)
	root.add_child(_aspect)

	_container = SubViewportContainer.new()
	_container.stretch = true
	_aspect.add_child(_container)

	_viewport = SubViewport.new()
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.handle_input_locally = false
	_container.add_child(_viewport)

	_camera = Camera3D.new()
	_camera.current = true
	_camera.near = 0.05
	_camera.far = 1000.0
	_viewport.add_child(_camera)

	# 叠层与画面同为 AspectRatioContainer 的子节点 => 两者矩形完全一致。
	# 注意: 不能把叠层塞进 SubViewportContainer 里靠 anchors 撑满,
	# 那是 Container, 会覆盖子节点 anchors, 叠层拿不到画面的完整尺寸(构图线会错位)。
	_overlay = Control.new()
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_guides)
	# 尺寸变化不会自动重绘, 否则拖动面板高度后构图线会停留在旧尺寸
	_overlay.resized.connect(_overlay.queue_redraw)
	_aspect.add_child(_overlay)

	# 提示文字挂在最外层(self 不是 Container, anchors 才生效), 覆盖整个面板居中显示
	_tip = Label.new()
	_tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tip.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_tip)
	_tip.set_anchors_preset(Control.PRESET_FULL_RECT)


func _update(delta: float) -> void:
	# 面板不可见时完全停止渲染: 共享编辑器世界开销不低, 也避免后台空转
	if not is_visible_in_tree():
		_set_render_enabled(false)
		return
	_set_render_enabled(true)
	_sync_ratio()
	# 编辑器接口走动态调用(见 _editor_interface 注释), 故用无类型变量
	var ei = _editor_interface()
	if ei == null:
		_show_tip("无法访问编辑器接口")
		return
	_rescan_timer += delta
	if _rescan_timer >= RESCAN_INTERVAL:
		_rescan_timer = 0.0
		_refresh_camera_list(ei)
	var vcam: VirtualCamera3D = _pick_target(ei)
	if vcam == null:
		_target = null
		_info.text = ""
		_show_tip("场景中没有 VirtualCamera3D, 或尚未选择机位")
		return
	_target = vcam
	_sync_picker_selection()
	var view = ei.get_editor_viewport_3d(0)
	if view == null:
		_show_tip("无法访问编辑器 3D 视口, 取景器不可用")
		return
	# 关键: 要用 find_world_3d() 而不是 world_3d 属性。
	# 编辑器视口从不显式设置 world_3d(读出来恒为 null), 实际用的是它内部自动创建的 world;
	# find_world_3d() 才能拿到那个 world。共享它 = 共享 scenario, 于是能渲染到同一份场景内容。
	var world = view.find_world_3d() if view.has_method("find_world_3d") else null
	if world == null:
		# 主屏幕不在 3D 视图时编辑器视口尚未建立 world, 切到 3D 页即可恢复
		_show_tip("取景器需要编辑器 3D 视口, 请先把主屏幕切到 3D 视图")
		return
	if _viewport.world_3d != world:
		_viewport.world_3d = world
	if _tip.visible:
		_tip.visible = false
		_tip.text = ""
	_camera.global_transform = vcam.get_pose()
	_camera.fov = _resolve_fov(vcam)
	# 与 Brain 保持同样的取景基准轴, 否则宽高比不同时取景范围会有偏差
	var brain := CameraTool.get_brain()
	_camera.keep_aspect = brain.keep_aspect if brain != null else Camera3D.KEEP_HEIGHT
	_info.text = "%dx%d  fov %.1f  优先级 %d%s" % [
		_viewport.size.x, _viewport.size.y, _camera.fov, vcam.priority,
		"  (生效中)" if vcam.is_current else "",
	]


## 画面比例跟随项目分辨率设置(改了设置无需重启插件)
func _sync_ratio() -> void:
	var w := float(ProjectSettings.get_setting(SETTING_WIDTH, 0))
	var h := float(ProjectSettings.get_setting(SETTING_HEIGHT, 0))
	var ratio := w / h if w > 0.0 and h > 0.0 else FALLBACK_ASPECT
	if is_equal_approx(ratio, _ratio):
		return
	_ratio = ratio
	_aspect.ratio = ratio


# ── 机位列表 ──

## 扫描当前编辑场景中的全部机位; 仅在列表确有变化时重建下拉, 避免打断用户点选
func _refresh_camera_list(ei) -> void:
	# 下拉展开时重建会立刻关闭弹窗, 用户就永远选不中
	if _picker.get_popup().visible:
		return
	var root: Node = ei.get_edited_scene_root()
	var found: Array[VirtualCamera3D] = []
	if root != null:
		if root is VirtualCamera3D:
			found.append(root)
		for node: Node in root.find_children("*", "VirtualCamera3D", true, false):
			found.append(node)
	var signature := ""
	for cam: VirtualCamera3D in found:
		signature += "%d:%s;" % [cam.get_instance_id(), cam.name]
	if signature == _list_signature:
		return
	_list_signature = signature
	_cameras = found
	_picker.clear()
	for cam: VirtualCamera3D in found:
		_picker.add_item(String(cam.name))
		_picker.set_item_tooltip(_picker.item_count - 1, String(root.get_path_to(cam)) if root != null else "")
	_picker.disabled = found.is_empty()


## 下拉选中: 同时同步编辑器选中, 让 3D 视图 gizmo 一起高亮, 也避免与"跟随选中"互相打架
func _on_camera_selected(index: int) -> void:
	if index < 0 or index >= _cameras.size():
		return
	var cam := _cameras[index]
	if cam == null or not is_instance_valid(cam):
		return
	_target = cam
	var ei = _editor_interface()
	if ei == null:
		return
	var selection = ei.get_selection()
	selection.clear()
	selection.add_node(cam)


## 让下拉高亮项跟随当前预览的机位(在场景树里选机位时下拉也同步)
func _sync_picker_selection() -> void:
	var index := _cameras.find(_target)
	if index >= 0 and _picker.selected != index:
		_picker.selected = index


## 目标机位: 跟随选中优先; 选中项里没有机位时保持上一台(避免点别的节点就丢失预览)
func _pick_target(ei) -> VirtualCamera3D:
	if _follow.button_pressed:
		var nodes: Array[Node] = ei.get_selection().get_selected_nodes()
		for node: Node in nodes:
			if node is VirtualCamera3D:
				return node
		for node: Node in nodes:
			for child: Node in node.find_children("*", "VirtualCamera3D", true, false):
				return child
	if _target != null and is_instance_valid(_target) and _target.is_inside_tree():
		return _target
	# 没有历史目标时退回列表首项, 打开面板即有画面
	for cam: VirtualCamera3D in _cameras:
		if is_instance_valid(cam):
			return cam
	return null


func _resolve_fov(vcam: VirtualCamera3D) -> float:
	if vcam.lens_fov > 0.0:
		return vcam.lens_fov
	var brain := CameraTool.get_brain()
	if brain != null:
		return brain.fov
	return DEFAULT_FOV


func _show_tip(text: String) -> void:
	_tip.visible = true
	_tip.text = text


func _set_render_enabled(enabled: bool) -> void:
	var mode := SubViewport.UPDATE_ALWAYS if enabled else SubViewport.UPDATE_DISABLED
	if _viewport.render_target_update_mode != mode:
		_viewport.render_target_update_mode = mode


func _on_guides_toggled(enabled: bool) -> void:
	_overlay.visible = enabled


func _on_solo_pressed() -> void:
	if _target == null or not is_instance_valid(_target):
		return
	_target.activate(0.0)


## 三分线 + 中心十字 + 安全框; 坐标一律基于叠层本地矩形(0,0 起), 与画面区域严格重合
func _draw_guides() -> void:
	var size := _overlay.size
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var line := Color(1, 1, 1, 0.25)
	var third := size / 3.0
	for i in [1, 2]:
		_overlay.draw_line(Vector2(third.x * i, 0.0), Vector2(third.x * i, size.y), line)
		_overlay.draw_line(Vector2(0.0, third.y * i), Vector2(size.x, third.y * i), line)
	var center := size * 0.5
	var cross := minf(size.x, size.y) * 0.03
	var strong := Color(1, 0.9, 0.4, 0.5)
	_overlay.draw_line(center - Vector2(cross, 0.0), center + Vector2(cross, 0.0), strong)
	_overlay.draw_line(center - Vector2(0.0, cross), center + Vector2(0.0, cross), strong)
	# 安全框: 四边各内缩 5%, 按各自轴长计算(用同一像素值会导致横竖不等比)
	var inset := size * 0.05
	_overlay.draw_rect(Rect2(inset, size - inset * 2.0), Color(1, 1, 1, 0.15), false, 1.0)


## 注意: 不要给返回值/变量标注 EditorInterface 类型。
## 对 Engine.get_singleton() 的返回值做 EditorInterface 类型化的 return / as,
## 会触发 GDScript VM 内部错误(OPCODE_RETURN: Condition "!nc" is true), 每帧刷屏。
## 因此这里一律走无类型(Variant)返回 + 动态调用。
func _editor_interface():
	if not Engine.has_singleton(&"EditorInterface"):
		return null
	return Engine.get_singleton(&"EditorInterface")

@tool
class_name QVoxelierSnapshotSection
extends QVoxelierSection
## 快照分组：把当前世界按所选参数**离屏**渲成一张 PNG（不带网格地板、选中框与别的浮层）。
## 【为什么要离屏，而不是抓主视口】主视口里有网格地板、选区线框、朝向指示器、Gizmo ——
## 抓它就会把它们一起拍进去；而且主视口的相机是用户**当前正在用**的角度，而快照要的是
## **指定**角度。离屏 SubViewport 自带一套世界（own_world_3d）、自己的相机与灯光，
## "拍什么"与"视口现在什么样"由此彻底解耦。
## 【为什么数据要自己求值，而不是复用视口里的渲染器】视口里的渲染器是"每个模型一个"、
## 挂在编辑会话下、数据源按相机距离惰性生成 chunk 的（见 QVoxelSource._ensure_volume）。
## 快照要的是**确定性**：一次求值出整块体积、一次渲完。于是这里自备一份私有数据源
## （QVoxelSource.from_eval_result），与 `.vox` 导出吃**同一份**求值结果 —— 于是"快照里的模型"
## 与"导出写出的模型"必然一致，不会出现"导出的和截图的不一样"。
## 【为什么角度 / 尺寸 / 镜头是开关组而不是下拉】与批量导出的范围、笔刷形态同一套
## （见 QVoxelUi 密度档）：触摸没有下拉，选项一眼全在。
## 【为什么按下渲染不经过应用层】离屏舞台是本分组自己的私有状态，渲染是它自己的活 ——
## 让 App 收到信号再回调 render_now() 只是白绕一圈。**只有落盘要问应用层**：文件对话框的
## 公共装配（主题 / 默认目录 / 中文按钮）在应用层一处，见 save_requested。
## 【本分组只读世界】它不改世界、不记撤销、不参与编辑链 —— 参数与预览图都是自己的状态，
## 故不需要会话，只需要 App 把当前世界推给它（见 set_world）。

## 用户点了「保存…」：应用层负责弹对话框并把选中的路径交回 save_png()。
signal save_requested

## 等网格的上限帧数。渲染器的网格生成走 worker + 每帧限量上传（见 VoxelRenderer），
## 模型越大等得越久；但不能没有上限 —— 卡住时"永远停在渲染中"比"渲得慢"更糟。
const MESH_WAIT_FRAMES := 600

## 快照背景色（不透明时）。取一档深蓝灰：快照多半是拿去当素材，深底比浅底耐看，
## 也不会与常见的浅色模型糊在一起。
const BACKGROUND := Color(0.0706, 0.0863, 0.1137, 1.0)

var _world: QVoxelWorld = null
var _view: int = QVoxelViewCamera.View.ISO
var _size: int = QVoxelSnapshot.DEFAULT_SIZE
var _lens: int = QVoxelViewCamera.Lens.PERSPECTIVE
var _transparent := false

## 当前预览图（已是 RGBA8 显示值，见 render_now 的取色说明）。null = 还没渲过。
var _image: Image = null
## 当前预览图是按哪一组参数渲的。用来在参数改动后提醒"预览是旧的" ——
## 否则用户改了角度、看着旧图、按了保存，会以为存下的是新角度。
var _preview_key := ""
## 当前预览图的一句话描述（状态行显示的是它，而不是"当前参数"）。
var _preview_desc := ""
var _busy := false
var _mesh_signal_seen := false

var _render_button: Button
var _save_button: Button
var _preview: TextureRect
var _status: Label

## 离屏舞台。全部是本分组的私有状态，与主视口不共享任何节点。
var _viewport: SubViewport
var _stage: Node3D
var _camera: QVoxelViewCamera
var _renderer: VoxelRenderer
var _env: WorldEnvironment


func section_title() -> String:
	return "快照"


# ---------------------------------------------------------------- 对外接口

## 由 App 推入当前世界（本分组只读它）。世界换了就把旧预览作废 ——
## 留着一张"上一个世界的图"比什么都不留更容易误判。
func set_world(w: QVoxelWorld) -> void:
	if w == _world:
		return
	_world = w
	_drop_preview()
	_refresh_status()


## 保存对话框的默认文件名（应用层在弹窗前问它）。
func suggested_file_name() -> String:
	var world_name := _world.world_name() if _world != null else ""
	return "%s.png" % QVoxelSnapshot.file_stem(world_name, _view)


## 是否已有可保存的图。
func has_image() -> bool:
	return _image != null


## 渲染一次（异步）。渲染中重复调用被忽略。
func render_now() -> void:
	if _busy:
		return
	var reason := QVoxelSnapshot.blocker(_world)
	if not reason.is_empty():
		_set_status(reason)
		return
	_busy = true
	_render_button.disabled = true
	_save_button.disabled = true
	_set_status("渲染中…")

	# ① 求值：与 .vox 导出吃同一份结果（QVoxelEvalEngine.evaluate_world）。
	var res := QVoxelEvalEngine.evaluate_world(_world, QVoxelEvalContext.new())
	if res == null or res.volume.is_empty():
		_end_render()
		_set_status("世界里没有体素")
		return

	# ② 摆舞台：数据源、取景、背景。
	_sync_stage(res)

	# ③ 等网格建完再按快门。
	await _await_meshes()

	# ④ 抓图。取色交给框架的 ScreenshotTool —— 它按 Image 的**数据格式**判定要不要做 sRGB
	#    编码（8 位格式读回来已是显示值，再编码一次会蒙一层灰白，见其类文档）。
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_image = await ScreenshotTool.grab(_viewport)
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_end_render()

	if _image == null:
		_set_status("抓图失败：视口没有产出图像")
		return
	# 抓回来的可能是线性 HDR 浮点图，统一归一到 RGBA8 显示值：预览与落盘用的是**同一张**，
	# 于是"面板里看到的"就是"存下去的那张"。
	ScreenshotTool.normalize(_image)
	_preview.texture = ImageTexture.create_from_image(_image)
	_preview_key = _params_key()
	_preview_desc = QVoxelSnapshot.describe(_size, _view, _lens)
	_save_button.disabled = false
	_refresh_status()


## 把当前预览图写到 path，返回给用户看的一句话（应用层负责把它弹出来）。
func save_png(path: String) -> String:
	if _image == null:
		return "还没有可保存的图，先点「渲染」"
	# 落盘走框架的统一入口：它建目录、按格式判定取色、再写盘。
	# max_width 必须显式给 0 —— 它的默认值是 1280，会把 2048 的快照悄悄缩到 1280
	# （"存下去的不是我选的那一档"，而且不报错）。
	var report := ScreenshotTool.save_image(_image, {"path": path, "max_width": 0})
	if not report.get("ok", false):
		return "保存失败：%s" % report.get("error", "未知原因")
	return QVoxelSnapshot.summary(path, _size)


# ---------------------------------------------------------------- 构建

func _build_body(body: VBoxContainer) -> void:
	body.add_child(QVoxelUi.heading("视图"))
	body.add_child(_build_options(QVoxelSnapshot.views(), 3, _view, _on_view_toggled))
	body.add_child(QVoxelUi.heading("尺寸"))
	body.add_child(_build_options(QVoxelSnapshot.sizes(), 3, _size, _on_size_toggled))
	body.add_child(QVoxelUi.heading("镜头"))
	body.add_child(_build_options(QVoxelSnapshot.lenses(), 2, _lens, _on_lens_toggled))

	var transparent_button := QVoxelUi.toggle_button("背景透明：PNG 带 alpha 通道，方便叠到别的底上")
	transparent_button.text = "透明背景"
	transparent_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	transparent_button.toggled.connect(_on_transparent_toggled)
	body.add_child(transparent_button)

	body.add_child(_build_actions())
	body.add_child(_build_preview())

	_status = QVoxelUi.label("", QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(_status)

	_build_stage()
	_refresh_status()


## 一组互斥开关。**ButtonGroup + toggled** 而不是"按下即动作"（对比视图栏）：
## 这里的选项是**参数**，选中的要一直亮着 —— 用户得看得见"现在选的是哪个"。
func _build_options(specs: Array[Dictionary], columns: int, current: int,
		handler: Callable) -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = columns
	var group := ButtonGroup.new()
	group.allow_unpress = false
	for spec in specs:
		var b := QVoxelUi.toggle_button(spec.tip)
		b.text = spec.text
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.button_group = group
		b.toggled.connect(handler.bind(spec.value))
		if spec.value == current:
			b.set_pressed_no_signal(true)
		grid.add_child(b)
	return grid


func _build_actions() -> HBoxContainer:
	var row := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	_render_button = QVoxelUi.button("渲染", "按当前视图 / 尺寸 / 镜头渲一次；结果只在下面预览，不落盘",
		QVoxelUi.VARIATION_ACCENT)
	_render_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_render_button.pressed.connect(render_now)
	row.add_child(_render_button)

	_save_button = QVoxelUi.button("保存…", "把下面这张预览图另存为 PNG")
	_save_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_save_button.disabled = true
	_save_button.pressed.connect(func(): save_requested.emit())
	row.add_child(_save_button)
	return row


func _build_preview() -> PanelContainer:
	var frame := QVoxelUi.panel(QVoxelUi.space_s(), QVoxelUi.BAR)
	_preview = TextureRect.new()
	# 高度按命中区算：快照是方形，宽度受右列约束（约 116 逻辑像素），故这里给个近方的框，
	# 图片按 KEEP_ASPECT_CENTERED 居中铺满，不会变形。
	_preview.custom_minimum_size = Vector2(0, QVoxelUi.hit_size() * 3)
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	# 预览是"一张图"，不该吃鼠标：面板空白处一律让给视口（见基类的输入姿态约定）。
	_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(_preview)
	return frame


## 离屏舞台。own_world_3d 是关键：它自带一套世界，于是主视口里的网格地板、选区线框、
## 朝向指示器都不会跟进来 —— 这正是快照要的"干净"。
func _build_stage() -> void:
	_viewport = SubViewport.new()
	_viewport.name = "SnapshotStage"
	_viewport.own_world_3d = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	# 常态 DISABLED：这个视口只在按快门那一瞬需要出图，平时不该占 GPU。
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)

	_stage = Node3D.new()
	_viewport.add_child(_stage)

	_env = WorldEnvironment.new()
	_env.environment = Environment.new()
	_stage.add_child(_env)

	# 打光与 QVoxelier.tscn 的 KeyLight / FillLight 同一套变换与能量 —— 快照与视口里看到的
	# 明暗关系一致，用户不必为了"截图好看"重新调光。抄数字比凭感觉写角度可靠。
	# ⚠️ 写法是 `Transform3D(x_axis, y_axis, z_axis, origin)`（**列**为轴）：本版本的 GDScript
	# 没有 12 参的 `Transform3D`，也没有 9 参的 `Basis`，故 .tscn 里那种按**行**铺开的写法
	# 不能照抄 —— 下面的三个 Vector3 是同一矩阵的列（已按 .tscn 的 KeyLight / FillLight 核对）。
	var key := DirectionalLight3D.new()
	key.transform = Transform3D(Vector3(-0.5, 0.35, -0.75), Vector3(0.0, 0.866, 0.5),
			Vector3(0.866, 0.35, 0.433), Vector3(0.0, 6.0, 0.0))
	key.light_energy = 1.7
	key.shadow_enabled = true
	_stage.add_child(key)

	var fill := DirectionalLight3D.new()
	fill.transform = Transform3D(Vector3(-0.70711, -0.31879, 0.63117), Vector3(0.0, 0.89262, 0.45084),
			Vector3(-0.70711, 0.31879, -0.63117), Vector3(0.0, 6.0, 0.0))
	fill.light_energy = 0.9
	fill.light_color = Color(0.76, 0.82, 0.98)
	_stage.add_child(fill)

	_camera = QVoxelViewCamera.new()
	_camera.name = "SnapshotCamera"
	_camera.current = true
	_stage.add_child(_camera)
	# QVoxelViewCamera._ready 只在**运行时**设裁剪面（它按"无限世界"给足远端），编辑器里保持
	# 引擎默认；而快照的取景距离由模型大小决定、可能很远，故这里显式给一组够用的。
	_camera.near = 0.01
	_camera.far = 40000.0

	_renderer = VoxelRenderer.new()
	_renderer.name = "SnapshotModel"
	# FULL：不按相机距离筛 chunk。快照要的是"整块体积都渲出来"，取景由我们自己算好
	# （见 QVoxelSnapshot.frame_aabb），不该再让渲染器按距离筛一遍 —— 筛漏的块会静默消失。
	_renderer.visibility_mode = VoxelRenderer.VisibilityMode.FULL
	_renderer.lod_count = 1
	_stage.add_child(_renderer)


# ---------------------------------------------------------------- 参数联动

func _on_view_toggled(on: bool, value: int) -> void:
	# ButtonGroup 里被换下的那颗也会发 toggled(false)，故只认"选中"那一次。
	if not on:
		return
	_view = value
	_refresh_status()


func _on_size_toggled(on: bool, value: int) -> void:
	if not on:
		return
	_size = value
	_refresh_status()


func _on_lens_toggled(on: bool, value: int) -> void:
	if not on:
		return
	_lens = value
	_refresh_status()


func _on_transparent_toggled(on: bool) -> void:
	_transparent = on
	_refresh_status()


# ---------------------------------------------------------------- 渲染实现

## 按当前参数摆好离屏舞台（数据、取景、背景、视口尺寸）。
func _sync_stage(res: QVoxelEvalResult) -> void:
	_viewport.size = Vector2i(_size, _size)
	_viewport.transparent_bg = _transparent

	var env := _env.environment
	# 透明走 CLEAR_COLOR，不透明走纯色 —— 两者都不需要天空，故环境光 / 反射都取自**颜色**：
	# 透明那张没有天空可借，若两种背景走两条取光路径，明暗会差一档。
	env.background_mode = Environment.BG_CLEAR_COLOR if _transparent \
		else Environment.BG_COLOR
	env.background_color = BACKGROUND
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.3608, 0.4078, 0.4941)
	env.ambient_light_energy = 1.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_BG
	# 与视口同款色调映射：不然快照的明暗关系会和视口里看到的不一样。
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	# 接触阴影让体素之间的凹角有层次；但透明背景下它会在模型边缘留一圈暗晕，故只在不透明时开。
	env.ssao_enabled = not _transparent
	env.ssao_radius = 0.6
	env.ssao_intensity = 1.4

	var src := QVoxelSource.from_eval_result(_world, res)
	_renderer.voxel_scale = _world.voxel_size()
	_renderer.data = src

	# 先摆角度再框盒：frame_aabb 会同时算好透视距离与正交可见高度（两者都写，切换镜头即对齐）。
	_camera.set_lens(_lens)
	_camera.apply_view(_view)
	_camera.frame_aabb(QVoxelSnapshot.frame_aabb(res, _world.voxel_size()))


## 等离屏渲染器把网格建完。
## 【为什么要等】渲染器的重建是**跨帧**的：worker 生成网格 → 批次结算（mesh_updated）→
## 上传队列每帧限量挂载（见 VoxelRenderer._mesh_build_per_frame）。喂完数据就抓图，
## 只会抓到一张空场景。
## 【为什么判据是"信号到了 + 队列空了"】只等信号会抓到半张（批次结算时还有大半块排在
## 上传队列里）；只等固定帧数则在小模型上白等、在大模型上等不够。两个条件一起用才是
## "该挂的都挂上了"。
## 【为什么有上限】worker 或帧循环任何一环卡住，按钮就会永远停在"渲染中…"。
## 宁可超时渲一张不完整的图并说明，也不要无限转圈。
func _await_meshes() -> void:
	_mesh_signal_seen = false
	var seen := func(): _mesh_signal_seen = true
	_renderer.mesh_updated.connect(seen)
	for i in MESH_WAIT_FRAMES:
		await get_tree().process_frame
		if _mesh_signal_seen and not _has_queued_mesh():
			break
	if _renderer.mesh_updated.is_connected(seen):
		_renderer.mesh_updated.disconnect(seen)


## 上传队列里还有没有本源的块（有 = 网格还没全挂上，此刻抓图会缺块）。
func _has_queued_mesh() -> bool:
	var src: QVoxelSource = _renderer.data
	if src == null:
		return false
	for ck in src.get_all_chunk_keys():
		if _renderer.is_mesh_build_queued(ck):
			return true
	return false


func _end_render() -> void:
	_busy = false
	_render_button.disabled = false


func _drop_preview() -> void:
	_image = null
	_preview_key = ""
	_preview_desc = ""
	if _preview != null:
		_preview.texture = null
	if _save_button != null:
		_save_button.disabled = true


# ---------------------------------------------------------------- 状态行

## 参数指纹：用来判断"预览图是不是当前参数渲的"。
func _params_key() -> String:
	return "%d|%d|%d|%s" % [_view, _size, _lens, str(_transparent)]


func _refresh_status() -> void:
	if _image == null:
		var reason := QVoxelSnapshot.blocker(_world)
		_set_status(reason if not reason.is_empty() else "点「渲染」按当前参数出图")
		return
	var text := "预览：%s" % _preview_desc
	if _preview_key != _params_key():
		# 提醒而不是自动重渲：重渲要等网格、要几秒，用户改参数时未必想立刻重来。
		text += "；参数已改，需重新渲染"
	_set_status(text)


func _set_status(text: String) -> void:
	if _status != null:
		_status.text = text

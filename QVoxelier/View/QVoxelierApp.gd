@tool
class_name QVoxelierApp
extends Node3D
## 建模视口的应用壳：**装配 + 输入翻译 + 快捷键**，不含任何算法。
## 【它只做三件事】
##   ① 装配：新建世界/对象 → 建会话 → 把显示层交给渲染器、把网格交给地板、把会话交给状态栏；
##   ② 翻译：鼠标事件 → 相机射线 → 网格拾取 → `QVoxelEditSession` 的手势（begin/drag/release）；
##   ③ 快捷键：工具表里的热键切笔、[ ] 改笔刷、Ctrl+Z / Ctrl+Shift+Z 撤销重做、Esc 取消、Home 取景；
##      工程文件 Ctrl+S / Ctrl+Shift+S / Ctrl+O（`.qvx` 也能直接拖进窗口）。
## 【快捷键是加速器，不是入口】本应用要同时跑在平板（无键盘 / 无中键 / 无滚轮 / 无右键）与桌面，
## 于是每个动作都先在界面上有一个按钮，键盘只让熟练用户少点两下 —— 按钮与快捷键改的是**同一份状态**
## （工具 / 笔刷 / 材质 / 导航模式），不存在"只有键盘才够得着"的功能。
## 触摸屏上必须由界面补位的三处：中键转视角 →「导航 / 平移」开关，滚轮缩放 →「− / +」，右键擦除 →「擦除」开关。
## 本类因此也是这些状态的**唯一持有者**（`_install` / `_set_*` 都往界面上回写），界面自己不留副本。
## 【为什么"翻译"值得单独一层】会话刻意不认识鼠标：它要的是"这一次落笔打在哪"（Pick）。
## 视口是唯一知道屏幕坐标、相机与渲染节点的地方 —— 于是换算只在这里发生一次，
## 会话与工具因此都能无头测试（换成 Dock 内嵌视口时，本类只换相机与渲染节点两行）。
## 【坐标换算】渲染器的局部空间是"体素单位 × voxel_scale"（网格顶点按 voxel_scale 放大），
## 故世界射线先 to_local、再除一次 voxel_scale，才落进 QVoxelSource 的体素坐标里。
## 这条换算只此一处 —— 拾取、地板、网格尺寸三处用的都是同一套单位。

## 新建模型的网格尺寸（MagicaVoxel 的默认有界网格就是 32³）。
@export var grid_size := Vector3i(32, 32, 32)

## 新建模型时预置的调色板（ID 从 1 开始；0 是空气）。
## 不给颜色就没法验证"画上去的是什么颜色"，所以新建即带一套可用色板。
@export var default_palette: Array[Color] = [
	Color(0.87, 0.27, 0.25), Color(0.95, 0.64, 0.19), Color(0.94, 0.89, 0.35),
	Color(0.36, 0.78, 0.40), Color(0.26, 0.64, 0.94), Color(0.61, 0.42, 0.90),
	Color(0.90, 0.90, 0.90), Color(0.34, 0.35, 0.38),
]

## 笔刷上限（体素笔/盒笔/线笔的加粗半径）。
@export var max_brush_size := 16

@onready var model: VoxelRenderer = $Model
@onready var camera: QVoxelViewCamera = $Camera
@onready var grid_floor: QVoxelGridFloor = $Model/Floor
@onready var hud: QVoxelierHud = $Hud

## 应用栏 / 工具坞 / 调色板：**在代码里建**而不是摆进 .tscn —— 它们的内容完全由运行时数据决定
## （工具表、世界的材质表），在场景里预摆只会得到一份立刻被推翻的空壳；
## 状态栏（Hud）留在场景里，因为它是静态骨架、且视口脚本要按路径引用它。
var _toolbar: QVoxelierToolbar
var _tools: QVoxelierTools
var _palette: QVoxelierPalette
var _view_bar: QVoxelierViewBar
var _gizmo: QVoxelierGizmo
var _dock: QVoxelierDock
var _color_section: QVoxelierColorSection
var _tree_section: QVoxelierTreeSection
var _inspector_section: QVoxelierInspectorSection
var _timeline_section: QVoxelierTimelineSection
## 快照分组（F5）：离屏渲一张 PNG。它只读世界，故本类只把世界推给它、再管一次落盘对话框
## （参数与预览是分组自己的状态，见 QVoxelierSnapshotSection）。
var _snapshot_section: QVoxelierSnapshotSection
var _confirm: ConfirmationDialog

## 参数面板当前绑定的修改器（选中树上某条修改器时置入，用于撤销 / 重做后重绑）。
var _modifier: QVoxelModifier
## 该修改器的宿主节点（改参数的命令要挂在它的 content_changed 上标脏）。
var _modifier_owner: QVoxelNode

## 非活动对象的渲染节点容器：多对象世界里只有"当前对象"用 model，其余挂在这里。
## （见 _rebuild_view —— 切换活动对象只换 model.data，其余渲染器复用。）
var _extra_root: Node3D

## 选区线框（挂在 model 下，与体素网格同一套坐标换算）。看不见的选区等于没有选区 ——
## 用户按了"复制"却不知道复制了什么，故它随 _refresh_hud 一起重画。
var _selection_box: QVoxelSelectionBox
## 笔刷悬停预览（虚线框标出"按下 / 拖到这里会改哪些格"）。与选区框同挂 model 下 ——
## 同一套坐标换算，两者天然对齐；线色 = 待写材质色（擦除 = 警示红），一眼看出会改成什么。
var _ghost: QVoxelSelectionBox
## 光标处最近一次的落笔点。粘贴要落在"用户正指着的地方"，而光标只在移动事件里出现 ——
## 于是把它记下来，按钮 / 快捷键按下时才有得用（没有它，粘贴只能贴回原地）。
var _hover_pick: QVoxelBrushTool.Pick
## 非活动对象的渲染器：model_id → VoxelRenderer。
var _display: Dictionary = {}

## 应用会话：世界 + 每对象一条编辑会话 + 工程状态 + 应用能力（见 QVoxelierSession）。
## 视口脚本只做装配 / 翻译 / 刷新，故这里**只读**地投影出最常用的两份数据。
var _sess: QVoxelierSession

## 当前世界与当前活动编辑会话 —— 是 `_sess` 的**只读投影**，不是第二份真相。
## 【为什么是只读属性而不是各自的字段】换世界与切对象必须走 install / activate 两条路径
## （它们才会把显示层一起换掉）；只读属性把"绕过会话直接赋值"这件事变成编译期错误。
var world: QVoxelWorld:
	get:
		return _sess.world if _sess != null else null

var session: QVoxelEditSession:
	get:
		return _sess.session if _sess != null else null

var _material_id := 1
var _stroke := false
var _erase := false
## 对称轴掩码。是**App 级设置**而非笔刷级：每个对象各有自己的笔刷实例，
## 若把它存在笔刷里，切一次对象就会被新笔刷的默认值抹掉（见 _apply_symmetry）。
var _symmetry := Vector3i.ZERO
var _orbit := false
var _pan := false
## 导航 / 平移模式：拖动改的是视角而不是体素。桌面上的中键与 Shift+中键，在触摸屏上
## 没有对应物，故提升为常驻开关 —— 它与 `_orbit` / `_pan` 这类"某一帧正在发生的拖动"不同，
## 是**跨手势的粘性模式**，所以排在状态区而不是手势区。
var _nav := false
var _pan_mode := false
## 修饰键 / 粘性模式的导航拖拽由谁启动（&"" / &"left" / &"middle"）—— 释放时只关自己启动的
## 那一路，免得左键松开把还按着的中键视角拖拽一并关掉。
var _nav_key := &""
## 触摸 / 触摸板手势解析（双指拖 = 旋转、捏合 = 缩放）。解析与相机动作分离，见 QVoxelierGestureNav。
var _gesture := QVoxelierGestureNav.new()
## 左右两条侧栏占掉的宽度（可见区 = 窗口减这两块）。取景按它把模型对齐可见中心，见 frame_view。
var _left_inset := 0.0
var _right_inset := 0.0
## 待执行的"取景对齐可见中心" —— 放 _process 做：那时 inset 已由 sync 算出、相机也完成布局。
var _pending_center := false
## 已经补过的侧栏像素量。补偿按**差值**做：inset 结算晚于首帧时（布局未稳），
## 后续 sync 只补差额 —— 重复调用不会叠加，也不会吃掉用户自己的平移。
var _center_done_px := 0.0
## 左右侧栏的背景条（把漂浮面板连成整条侧栏）。
var _left_rail: Panel
var _right_rail: Panel

## 取色器：开启后下一次左键点击改为"吸取该处体素的材质"，而不落笔。
var _eyedropper := false
## 正在进行的"改材质"手势（颜色或 PBR）对应的属性命令（松手时封口入栈；见 QVoxelierColorSection 的"手势即命令"）。
var _material_cmd: QVoxelPropertyCommand
## 正在进行的"改修改器参数"手势对应的属性命令（同上，只是目标换成链上的某条条目）。
var _prop_cmd: QVoxelPropertyCommand
## 正在进行的"改帧时长"手势对应的属性命令（同上，目标是那一帧 QVoxelFrame 的 duration_ms）。
var _frame_dur_cmd: QVoxelPropertyCommand

var _open_dialog: FileDialog
var _save_dialog: FileDialog
var _export_dialog: FileDialog
var _palette_import_dialog: FileDialog
var _palette_export_dialog: FileDialog
## 快照落盘对话框（*.png）。与调色板导出同走自绘那套 —— 默认文件名由分组按视图名给出。
var _snapshot_dialog: FileDialog
## 批量导出的目标目录对话框：范围开关与命名前缀就挂在它自己的 vbox 里（见 _build_batch_options）。
var _batch_dialog: FileDialog
## 批量导出的范围（取值见 QVoxelBake.Scope）。选在对话框里，烘的时候才读。
var _batch_scope := QVoxelBake.Scope.WORLD
var _batch_prefix: LineEdit

const ACTION_UNDO := &"qvoxelier_undo"
const ACTION_REDO := &"qvoxelier_redo"
const ACTION_BRUSH_UP := &"qvoxelier_brush_up"
const ACTION_BRUSH_DOWN := &"qvoxelier_brush_down"
const ACTION_SAVE := &"qvoxelier_save"
const ACTION_SAVE_AS := &"qvoxelier_save_as"
const ACTION_OPEN := &"qvoxelier_open"
const ACTION_EXPORT := &"qvoxelier_export"
const ACTION_SELECT_ALL := &"qvoxelier_select_all"
const ACTION_COPY := &"qvoxelier_copy"
const ACTION_CUT := &"qvoxelier_cut"
const ACTION_PASTE := &"qvoxelier_paste"
const ACTION_CLEAR := &"qvoxelier_clear"


# 装配

func _ready() -> void:
	_sess = QVoxelierSession.new()
	# 会话不认识渲染器：唤醒回调与三条对外信号都在这里接上（见 QVoxelierSession 类文档）。
	_sess.render_update = model.request_update
	_sess.hint.connect(hud.flash)
	_sess.changed.connect(_on_session_changed)
	_sess.dirty_changed.connect(_on_dirty_changed)
	_bind_actions()
	_build_dialogs()
	_build_ui()
	new_model()
	# 编辑器里只装配外观（网格地板与取景），输入留给编辑器自己 —— @tool 脚本不该抢编辑器的键。
	if Engine.is_editor_hint():
		return
	get_window().files_dropped.connect(_on_files_dropped)


## 装配三个界面面板并接线。面板只发"用户想干什么"的信号，**不收会话**：
## 于是界面层永远不碰编辑逻辑，换视口（独立窗口 → Dock 内嵌）时面板一行都不用改。
## （状态栏是例外：它要读会话才能显示工具与撤销栈，所以在 _install 里注入 session。）
func _build_ui() -> void:
	_toolbar = QVoxelierToolbar.new()
	_toolbar.name = "Toolbar"
	add_child(_toolbar)

	# 左右整栏背景：把工具坞 / 视图栏 / 抽屉这些浮板连成两条完整的侧栏（Blender 式），
	# 3D 不再从面板缝隙里漏出来。先入树压在所有面板之下，只作背景不吃事件。
	_left_rail = _make_rail(false)
	add_child(_left_rail)
	_right_rail = _make_rail(true)
	add_child(_right_rail)
	_toolbar.new_requested.connect(request_new)
	_toolbar.open_requested.connect(request_open)
	_toolbar.save_requested.connect(save_project)
	_toolbar.save_as_requested.connect(save_project_as)
	_toolbar.export_requested.connect(export_vox)
	_toolbar.export_batch_requested.connect(export_vox_batch)
	_toolbar.undo_requested.connect(_undo)
	_toolbar.redo_requested.connect(_redo)
	_toolbar.frame_requested.connect(func(): frame_view(); hud.flash("已取景"))
	_toolbar.zoom_requested.connect(func(steps: float): camera.zoom_by_steps(steps))
	_toolbar.view_mode_changed.connect(_set_view_mode)
	# 两块浮层都锚在右上角，开一块就关另一块 —— 互斥与按钮回弹都收在 _set_*_visible 里，
	# 免得"界面开着日志、按钮却显示说明"这类不一致散落在两个 connect 里。
	_toolbar.help_toggled.connect(_set_legend_visible)
	_toolbar.log_toggled.connect(_set_log_visible)

	_tools = QVoxelierTools.new()
	_tools.name = "Tools"
	add_child(_tools)
	_tools.tool_selected.connect(_set_tool)
	_tools.brush_step.connect(_step_brush)
	_tools.brush_scale_requested.connect(_scale_brush)
	_tools.brush_shape_selected.connect(_set_brush_shape)
	_tools.erase_toggled.connect(func(on: bool): hud.flash("擦除模式：%s" % ("开" if on else "关")))
	_tools.symmetry_toggled.connect(_set_symmetry_axis)
	# 选区面板的五个按钮共用一条信号（带动作 id）—— 面板不必为每个动作各开一条连接。
	_tools.selection_action.connect(_on_selection_action)

	_palette = QVoxelierPalette.new()
	_palette.name = "Palette"
	add_child(_palette)
	_palette.material_selected.connect(_set_material)

	_view_bar = QVoxelierViewBar.new()
	_view_bar.name = "ViewBar"
	add_child(_view_bar)
	_view_bar.lens_selected.connect(_set_lens)
	_view_bar.view_selected.connect(_apply_view)
	_view_bar.grid_lines_toggled.connect(_set_grid_lines)

	# 朝向指示器要读相机基，故注入相机实例（它不持有相机，只是借来看一眼 —— see 类文档）。
	_gizmo = QVoxelierGizmo.new()
	_gizmo.name = "Gizmo"
	add_child(_gizmo)
	_gizmo.camera = camera
	_gizmo.view_requested.connect(_apply_view)
	# 盘上拖拽 = 自由旋转（点击轴尖仍是切视图，见 QVoxelierGizmo._gui_input 的判型时机）。
	_gizmo.orbit_requested.connect(func(rel: Vector2) -> void:
		camera.orbit_by_pixels(rel)
		_view_bar.set_view(camera.view))

	# 右侧抽屉：颜色 / 对象 / 参数 / 时间轴 / 快照五组。分组各自只发"用户想干什么"，写世界与记撤销都在本类一处完成。
	_dock = QVoxelierDock.new()
	_dock.name = "Dock"
	add_child(_dock)

	_color_section = QVoxelierColorSection.new()
	_color_section.edit_began.connect(_begin_material_edit)
	_color_section.color_changed.connect(_live_color)
	_color_section.pbr_changed.connect(_live_pbr)
	_color_section.edit_ended.connect(_end_material_edit)
	_color_section.eyedropper_toggled.connect(_set_eyedropper)
	_color_section.add_material_requested.connect(_add_material)
	_color_section.import_requested.connect(func(): _palette_import_dialog.popup_centered_ratio(0.7))
	_color_section.export_requested.connect(func(): _palette_export_dialog.popup_centered_ratio(0.7))
	# 颜色分组**默认收起**：多数时候只是拿笔刷画，材质编辑是"想改才点开"的事 ——
	# 让它默认摊开等于给每个会画画的人看一屏他没在改的参数。
	_dock.add_section(_color_section, true)

	_tree_section = QVoxelierTreeSection.new()
	_tree_section.node_selected.connect(_on_tree_selected)
	_tree_section.model_add_requested.connect(_sess.add_model)
	_tree_section.group_add_requested.connect(_sess.add_group)
	_tree_section.node_remove_requested.connect(_sess.remove_node)
	_tree_section.node_visible_changed.connect(_sess.set_node_visible)
	_tree_section.node_locked_changed.connect(_sess.set_node_locked)
	_tree_section.node_rename_requested.connect(_sess.rename_node)
	_tree_section.node_move_requested.connect(_sess.move_node)
	_tree_section.modifier_add_requested.connect(_add_modifier)
	_tree_section.modifier_remove_requested.connect(_remove_modifier)
	_tree_section.modifier_enabled_changed.connect(_set_modifier_enabled)
	_tree_section.modifier_selected.connect(_on_modifier_selected)
	# 装配时只摊开「颜色」一组，其余四组收成抬头（点一下才展开）：右列全展开实测约 1400px，
	# 在 648 高的默认窗口里等于"一进来就满屏 + 下面还够不着"。收起来之后五组抬头一眼看全，
	# 需要哪组展哪组 —— Dock 本身可滚动，展开多少都不丢东西。
	_dock.add_section(_tree_section, true)

	# 参数分组：链上选中哪条修改器，就反射生成它的参数控件（含"变换"的参数，故不再需要独立变换面板）。
	_inspector_section = QVoxelierInspectorSection.new()
	_inspector_section.edit_began.connect(_begin_prop_edit)
	_inspector_section.value_changed.connect(_live_prop)
	_inspector_section.edit_ended.connect(_end_prop_edit)
	_dock.add_section(_inspector_section, true)

	# 时间轴分组（§12）：帧条 / 播放头 / 逐帧时长 / 标签 / 播放预览。与其余分组同一约定 ——
	# 面板只说"用户想干什么"，改哪个属性、记成哪条命令全在本类一处完成（见文件末的"时间轴"段）。
	_timeline_section = QVoxelierTimelineSection.new()
	_timeline_section.frame_selected.connect(_select_frame)
	_timeline_section.insert_requested.connect(_insert_frame)
	_timeline_section.remove_requested.connect(_remove_frame)
	_timeline_section.move_requested.connect(_move_frame)
	_timeline_section.duration_edit_began.connect(_begin_frame_duration)
	_timeline_section.duration_changed.connect(_live_frame_duration)
	_timeline_section.duration_edit_ended.connect(_end_frame_duration)
	_timeline_section.fps_changed.connect(func(fps: int): _set_anim_meta(&"anim_fps", fps, "改帧率"))
	_timeline_section.loop_toggled.connect(func(on: bool): _set_anim_meta(&"anim_loop", on, "改循环"))
	_timeline_section.tags_changed.connect(func(tags: Array): _set_anim_meta(&"anim_tags", tags, "改标签"))
	_dock.add_section(_timeline_section, true)

	# 快照分组（F5）：它自己摆离屏舞台、自己按快门（见 QVoxelierSnapshotSection 的"为什么按下渲染
	# 不经过应用层"）。本类只做它做不了的两件事：把当前世界推给它（见 _refresh_panels）、
	# 以及弹落盘对话框 —— 文件对话框的公共装配在应用层一处（见 _build_dialogs）。
	_snapshot_section = QVoxelierSnapshotSection.new()
	_snapshot_section.save_requested.connect(_request_snapshot_save)
	_dock.add_section(_snapshot_section, true)

	# 选区线框：与网格地板同挂 model 下（同一套"体素单位 × voxel_scale"换算），故两者天然对齐。
	# 它是纯显示物，不参与拾取（拾取只看体素与地板），故没有碰撞体。
	_selection_box = QVoxelSelectionBox.new()
	_selection_box.name = "Selection"
	model.add_child(_selection_box)

	_ghost = QVoxelSelectionBox.new()
	_ghost.name = "HoverGhost"
	model.add_child(_ghost)

	# 状态栏与两块浮层都归 Hud 所有，而 Hud 是场景里预摆的（排在子节点最前 = 画在最底下），
	# 后建的右列抽屉会整条压住浮层 —— 实测「操作说明」右半边被「颜色」面板盖掉。
	# 把它挪到最后一个子节点位置，浮层与提示才浮得住（左右两条侧栏的高度都已避开状态栏，
	# 不会反过来被它遮住）。
	move_child(hud, -1)

	# 两处"邻居的边界会动，故要互相让位"的布线。都放在装配处说清：面板之间不互相认识
	# （工具坞不认识视图栏、HUD 不认识抽屉），只有本类同时看得见它们。
	# 1) 左列：视图栏贴在工具坞正下方（实测 189px 高），工具坞的高度上限要让出它。
	# 2) 右列：抽屉宽度随内容变，视口里的浮层（HUD 的说明 / 日志、朝向指示器）都要让出它。
	# 两边的目标值都是**布局算出来的**（不是常量），故挂信号 + 装配末尾补一次初值：
	# 邻面板的矩形一般要到下一帧最小尺寸结算完才定下来。
	var sync_left := func() -> void:
		_tools.set_bottom_reserved(_view_bar.size.y + QVoxelUi.space_s())
		_sync_rails()
	var sync_right := func() -> void:
		_sync_rails()
		# 三者共用一个宽度而不是各算各的 —— 状态栏"避开右列"与坐标轴"避开状态栏"从此是一个数。
		hud.set_right_inset(_right_inset)
		_gizmo.right_inset = _right_inset
	_view_bar.resized.connect(sync_left)
	_tools.resized.connect(_sync_rails)   # 工具坞按内容变宽时，左栏背景也要跟
	_dock.resized.connect(sync_right)
	sync_left.call_deferred()
	sync_right.call_deferred()


## 新建一个空模型（grid 为 ZERO 时用导出的 grid_size）：建世界 → 建对象 → 装配。
## 尺寸与色板是视口的 @export（场景里可调），故由这里喂给会话 —— 会话只认"多大、哪些色"。
func new_model(grid := Vector3i.ZERO) -> void:
	_reset_edit_state()
	_sess.new_model(grid, grid_size, default_palette)
	frame_view()


## 装配：世界 + 待编辑对象 → 会话 / 渲染器 / 地板 / 状态栏。
## **新建与打开共用这一条路径** —— 两套初始化迟早会分叉出"新建能画、打开画不了"这类怪病。
## 【分工】世界与"每对象一条会话"由 `_sess` 装配（应用层）；这里只做显示层那一半。
## 刷新时机也不在这里：会话装完会发 `changed`，_on_session_changed 会把显示层重挂一遍。
func _install(w: QVoxelWorld, obj: QVoxelModel) -> void:
	_reset_edit_state()
	_sess.install(w, obj)
	frame_view()


## 换世界后作废的"手势 / 工具"级界面状态。新建与打开两个入口共用这一份 ——
## 【为什么必须共用】新建若漏掉它，新工程一进来材质还指着旧编号；启动首屏也是这条路径，
## 于是"打开工程取过景、新建 / 首屏却停在默认机位"这种分叉就会一直存在。
func _reset_edit_state() -> void:
	_material_id = 1
	_stroke = false
	_erase = false
	_eyedropper = false
	_material_cmd = null
	model.visibility_mode = VoxelRenderer.VisibilityMode.FULL
	# 调色板不必在这里喂：它挂在唯一刷新路径上，install 发出的 changed 会把世界带过去
	# （色板取的是**世界的材质表**而不是 default_palette，打开别人的 256 色工程也照显）。


## 切换"当前编辑对象"。三条入口共用这一条路径：对象列表点击、新建对象、打开工程挑初始对象。
## 【为什么不重建会话】非活动对象也早就有一条展示会话（见 _install），切换只是把活动引用换掉。
## 于是撤销栈按对象各自保留 —— 切走再切回来，那一个对象的撤销历史还在，
## 不会因为"看了一眼别的对象"就清空。
## 【为什么刷新的活不在这里】换活动对象是"数据变了"的一种，由会话发 `changed` 带出刷新；
## 这里只处理两件**界面专有**的事：停播放预览、收掉正按着的那一笔。
func _activate(model_id: int, flash := true) -> void:
	if world == null:
		return
	var o := world.find_model(model_id)
	if o == null:
		return
	# 换对象前先停预览：时间轴马上要绑到另一个模型上，让计时器继续跑就成了"播着 A、突然跳去播 B"。
	_timeline_section.stop_playback()
	if session != null and session.object == o:
		return
	if _stroke and session != null:
		session.cancel()
		_stroke = false
	if not _sess.activate(model_id):
		return
	if flash:
		hud.flash("已切换到 %s" % o.node_name)


## 把"当前活动对象"附着到显示层：model 渲染活动对象，地板与线框跟着它的输出盒。
## 【为什么每条都要比一遍再赋】本函数在**每次数据变化**时都会被调到（改名、拖层级也算），
## 而这几个 setter 都是**无条件重建网格**的：`VoxelRenderer.data` 会断开重连信号、清掉 LOD
## 并排一次更新；`QVoxelGridFloor` 的 grid_size / voxel_scale 会重建整块地板网格。
## 不比一遍就等于"改个名字重铺一次场景"，白白吃掉一帧。
## （线框的 voxel_scale 只改 scale、HUD 的 session 是普通字段，都无需比。）
func _attach_active() -> void:
	if session == null or world == null:
		return
	var vs := world.voxel_size()
	if model.data != session.data:
		model.data = session.data
	if not is_equal_approx(model.voxel_scale, vs):
		model.voxel_scale = vs
	# 地面网格框按**输出盒**画：链里一旦有重排（镜像 / 旋转 / 平铺），它就与手绘种子不同尺寸。
	var out := session.output_size()
	if grid_floor.grid_size != out:
		grid_floor.grid_size = out
	if not is_equal_approx(grid_floor.voxel_scale, model.voxel_scale):
		grid_floor.voxel_scale = model.voxel_scale
	_selection_box.voxel_scale = model.voxel_scale
	_ghost.voxel_scale = model.voxel_scale
	hud.session = session


## 会话数据变了 → 重挂显示层 + 重建视口 + 一处刷新界面。
## 【为什么这是唯一的刷新出口】改世界、切对象、撤销 / 重做、改材质、改帧都会发这条信号。
## 分散写"谁该刷什么"迟早漏一处 —— 表现为"按钮高亮着、提示还写着上一个工具"。
## `_refresh_hud` 自己会带上右列三组（见 _refresh_panels），故这里不再逐个面板点名。
func _on_session_changed() -> void:
	_attach_active()
	_rebuild_view()
	_refresh_hud()
	# 参数组要重看一眼数据：撤销 / 重做会把数据退回到"面板控件被建出来时"之外的状态。
	_rebind_inspector()


func _on_dirty_changed(_on: bool) -> void:
	_update_title()


## 让"世界的全部对象"都显示出来：活动对象用 model，其余各挂一个渲染器到 _extra_root。
## 【幂等 + 复用】本函数在切对象、图层可见性变化、撤销图层命令后都会被调到，所以它必须
## "算出现状"，而不是"推倒重来"：已有且仍该显示的渲染器原地复用（只改 visible），
## 该消失的回收，该新增的才建。若每次都重建，多对象场景每落一笔就重建一遍网格，会闪。
## 【为什么活动对象固定用 model】视口脚本按场景路径 $Model 引着它，重指代价大；
## 于是约定"model 永远渲染当前活动对象"，其余对象才走 _extra_root。切换只是换 model.data。
func _rebuild_view() -> void:
	if world == null or session == null:
		return
	if _extra_root == null:
		_extra_root = Node3D.new()
		_extra_root.name = "Objects"
		add_child(_extra_root)

	var active_id: int = session.object.model_id

	# 回收：不再属于世界、或已变成活动对象（该由 model 渲染）的旧渲染器。
	for id in _display.keys():
		var keep: bool = id != active_id and world.find_model(id) != null
		if keep:
			continue
		var old: VoxelRenderer = _display[id]
		if is_instance_valid(old):
			old.queue_free()
		_display.erase(id)

	# 非活动对象：一条会话一个渲染器。数据源是那条会话自己的 QVoxelSource（它自己会重建），
	# 唤醒回调改指向**它对应的渲染器** —— 会话不认识渲染器，只认这个 Callable（见类文档）。
	for s in _sess.all_sessions():
		var id: int = s.object.model_id
		if world.find_model(id) == null or id == active_id:
			continue
		var r: VoxelRenderer = _display.get(id)
		if r == null or not is_instance_valid(r):
			r = VoxelRenderer.new()
			r.name = "Model_%d" % id
			_extra_root.add_child(r)
			r.voxel_scale = model.voxel_scale
			r.visibility_mode = VoxelRenderer.VisibilityMode.FULL
			r.data = s.data
			s.request_render_update = r.request_update
			_display[id] = r
		r.visible = _sess.node_visible(s.object)

	model.visible = _sess.node_visible(session.object)


## 取景：把"有东西可落笔"的范围落进画面（新建 / 打开 / Home 键）。
## 空图时唯一能落笔的是网格底面（`QVoxelGridPick` 的落笔面），所以对准底面 —— 若照搬"框住整块
## 32³ 网格"，默认 25° 视角下屏幕上半尽是空体积，点正中只会换来一句"这儿落不了笔"。
func frame_view() -> void:
	if session == null:
		return
	var g := Vector3(session.output_size()) * model.voxel_scale
	var extent := g if not session.object.is_empty() else Vector3(g.x, 0.0, g.z)
	camera.frame_aabb(model.global_transform * AABB(Vector3.ZERO, extent), true)
	# 取景对齐的是窗口中心，但可见区被左右侧栏裁掉的宽度不等（右栏通常更宽）——
	# 模型因此视觉偏右。这里只打标记：inset 是布局的产物（要等 sync 算出来），补偿放 _apply_view_center。
	_center_done_px = 0.0
	_pending_center = true


## 把取景中心拉回可见区正中（左右侧栏不对称的补偿）。
## 【为什么按差值补】首帧 sync 拿到的还是布局结算前的宽度，此后 `_dock.resized` 才把 inset
## 更新到终值；一次性消费会在旧值上补完就作废（表现为"启动时模型仍偏右、按 Home 才正"）。
## 差值式让每次 sync 都只补"还欠多少"：何时算准何时到位，重复调用也不会叠加。
func _apply_view_center() -> void:
	if session == null or _left_inset <= 0.0 or _right_inset <= 0.0:
		return
	# 相机没进树 / 视口还没尺寸时先不补：pan 按像素换世界距离，无尺寸可换算。
	if not camera.is_inside_tree() or camera.get_viewport().get_visible_rect().size.y <= 0.0:
		return
	var want := (_left_inset - _right_inset) * 0.5
	var delta := want - _center_done_px
	if not is_zero_approx(delta):
		camera.pan_by_pixels(Vector2(delta, 0.0))
		_center_done_px = want
	_pending_center = false


func _process(_delta: float) -> void:
	# 条件不满足就不清标记 —— 下一帧重试，直到 inset 与视口都就绪。
	if _pending_center:
		_apply_view_center()


## 侧栏背景条：宽 = 内容 + 两侧缝，高 = 顶栏下缘到状态栏上缘。只作背景，不吃鼠标事件。
func _make_rail(right: bool) -> Panel:
	var p := Panel.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 纵向贴满（顶栏下缘 → 状态栏上缘），横向各自锚定到所属侧；宽度由 _sync_rails 按内容更新。
	p.anchor_top = 0.0
	p.anchor_bottom = 1.0
	p.offset_top = QVoxelUi.bar_height()
	p.offset_bottom = -QVoxelUi.status_height()
	if right:
		p.anchor_left = 1.0
		p.anchor_right = 1.0
		p.offset_right = 0.0
		p.offset_left = -QVoxelUi.dock_width() - QVoxelUi.space_m() * 2.0
	else:
		p.anchor_left = 0.0
		p.anchor_right = 0.0
		p.offset_left = 0.0
		p.offset_right = QVoxelUi.dock_width() + QVoxelUi.space_m() * 2.0
	p.add_theme_stylebox_override("panel",
			QVoxelUi.box(QVoxelUi.SURFACE_SOLID, QVoxelUi.BORDER, 1, 0, 0, 0))
	return p


## 两条侧栏的宽度与"可见区裁切量"随邻居实际宽度更新 —— rail 背景、状态栏让位、
## 坐标轴让位、取景补偿从此共用同一组数。
func _sync_rails() -> void:
	# 左栏以"工具坞 / 视图栏中更宽的那个"为准 —— 视图栏比工具坞宽时会凸出背景条。
	_left_inset = maxf(_tools.size.x, _view_bar.size.x) + QVoxelUi.space_m() * 2.0
	_right_inset = _dock.size.x + QVoxelUi.space_m() + QVoxelUi.space_s()
	_left_rail.offset_right = _left_inset
	_right_rail.offset_left = -_right_inset
	# 宽度变了 = 可见区中心也变了。补差额（只在取过景之后有欠账，别的场景 delta 为 0）。
	_apply_view_center()


# 输入翻译

func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or session == null:
		return
	# 触摸 / 触摸板手势（双指旋转、捏合缩放）在最前面分流：手势期间指针归导航，不进笔画。
	if event is InputEventScreenTouch or event is InputEventScreenDrag \
			or event is InputEventMagnifyGesture or event is InputEventPanGesture:
		if _gesture.feed(event):
			_flush_gesture()
		return
	if event is InputEventMouseButton:
		_on_mouse_button(event)
	elif event is InputEventMouseMotion:
		_on_mouse_motion(event)
	elif event is InputEventKey and event.pressed and not event.echo:
		_on_key(event)


func _on_mouse_button(e: InputEventMouseButton) -> void:
	match e.button_index:
		MOUSE_BUTTON_LEFT:
			# 取色器优先于一切：开启时左键点击用来"吸取"，不该顺带落一笔。
			# 拖拽（含导航 / 平移）时若不放开手会一直吸，故只在**按下那一拍**取一次。
			if _eyedropper and e.pressed:
				_pick_material_at(e.position)
				return
			# 触摸屏没有中键，故「导航 / 平移」模式把左键借给视角：单手即可转 / 移模型。
			# 平板上的单指拖动经过 emulate_mouse_from_touch 就是这里的 LEFT，不需要另写一套触摸分支。
			if e.pressed:
				if _nav or _pan_mode:
					_nav_key = &"mode"
					_orbit = _nav
					_pan = _pan_mode
				elif e.alt_pressed or e.shift_pressed:
					# Alt+拖 = 旋转、Shift+拖 = 平移（Maya / Blender 系惯例）——
					# 鼠标用户不必摸中键，与触摸板"双指拖 = 旋转"同一套肌肉记忆。
					_nav_key = &"left"
					_orbit = e.alt_pressed
					_pan = e.shift_pressed and not e.alt_pressed
				else:
					_begin_stroke(e.position, _erasing())
			elif _nav_key == &"left" or _nav_key == &"mode":
				_nav_key = &""
				_orbit = false
				_pan = false
			else:
				_end_stroke()
		MOUSE_BUTTON_RIGHT:
			# 导航 / 平移模式下右键不参与擦除 —— 否则"想转个视角却擦掉一片"。
			if _nav or _pan_mode:
				return
			if e.pressed:
				_begin_stroke(e.position, true)
			else:
				_end_stroke()
		MOUSE_BUTTON_MIDDLE:
			# 中键转视角、Shift / Alt+中键平移：与左右键（画 / 擦）互不干扰，
			# 于是"边画边转着看"不需要先切模式 —— 建模里这一步每天都在用。
			if e.pressed:
				_nav_key = &"middle"
				_orbit = not (e.shift_pressed or e.alt_pressed)
				_pan = e.shift_pressed or e.alt_pressed
			elif _nav_key == &"middle":
				_nav_key = &""
				_orbit = false
				_pan = false
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
			# 裸滚轮不再缩放（整屏一滚就放大缩小，误操作太容易）：
			#   裸滚轮 = 俯仰；触摸板双指上下滑就是滚轮事件，"双指拖 = 旋转"由此闭环；
			#   Ctrl+滚轮 = 缩放（Windows 精确触摸板的捏合也走这条 Ctrl+滚轮）；
			#   Alt+滚轮 = 偏航，与 Alt+拖旋转同一修饰语义。
			var up := e.button_index == MOUSE_BUTTON_WHEEL_UP
			if e.ctrl_pressed:
				camera.zoom_by_steps(1.0 if up else -1.0)
			elif e.alt_pressed:
				camera.yaw_by_degrees(4.0 if up else -4.0)
			else:
				camera.pitch_by_degrees(-4.0 if up else 4.0)
			_view_bar.set_view(camera.view)
		MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT:
			# 水平滚轮 = 触摸板双指左右滑 → 偏航，补齐"双指拖 = 旋转"的水平分量。
			camera.yaw_by_degrees(-4.0 if e.button_index == MOUSE_BUTTON_WHEEL_LEFT else 4.0)
			_view_bar.set_view(camera.view)


## 把手势层累积的导航量接到相机上（每喂完一个手势事件调用一次）。
func _flush_gesture() -> void:
	# 第二指落下即打断进行中的笔画 —— 双指是导航，不该顺带画一笔。
	# 只在笔画中途取消；非笔画时不动 _cancel，它还有"退出选区"的语义。
	if _gesture.active and _stroke:
		_cancel()
	if _gesture.orbit_pending != Vector2.ZERO:
		camera.orbit_by_pixels(_gesture.orbit_pending)
		_view_bar.set_view(camera.view)
	if not is_equal_approx(_gesture.zoom_pending, 1.0):
		camera.zoom_by_ratio(_gesture.zoom_pending)
	_gesture.take()


func _on_mouse_motion(e: InputEventMouseMotion) -> void:
	if _stroke:
		session.drag(_pick_at(e.position))
		_refresh_cursor(e.position)
	elif _orbit:
		camera.orbit_by_pixels(e.relative)
		# 转完就不再对齐任何预设了：视图栏要如实回显这一点，否则"前视图"还亮着 ——
		# 用户会以为视角没动。
		_view_bar.set_view(camera.view)
	elif _pan:
		camera.pan_by_pixels(e.relative)
	else:
		_refresh_cursor(e.position)


func _on_key(e: InputEventKey) -> void:
	# 撤销 / 重做 / 存开走框架 InputTool（key_event 管修饰键，动作名可被重映射）。
	# 模式热键直接查工具表 —— 表即配置，不需要修饰键语义，也就没必要再声明一遍动作名。
	if _pressed(e, ACTION_UNDO):
		_undo()
	elif _pressed(e, ACTION_REDO):
		_redo()
	elif _pressed(e, ACTION_SAVE_AS):
		save_project_as()
	elif _pressed(e, ACTION_SAVE):
		save_project()
	elif _pressed(e, ACTION_OPEN):
		request_open()
	elif _pressed(e, ACTION_EXPORT):
		export_vox()
	elif _pressed(e, ACTION_SELECT_ALL):
		_select_all()
	elif _pressed(e, ACTION_COPY):
		_copy_selection()
	elif _pressed(e, ACTION_CUT):
		_cut_selection()
	elif _pressed(e, ACTION_PASTE):
		_paste_clipboard()
	elif _pressed(e, ACTION_CLEAR):
		_clear_selection()
	elif _pressed(e, ACTION_BRUSH_UP):
		_step_brush(1)
	elif _pressed(e, ACTION_BRUSH_DOWN):
		_step_brush(-1)
	elif e.keycode == KEY_ESCAPE:
		_cancel()
	elif e.keycode == KEY_HOME:
		frame_view()
		hud.flash("已取景")
	elif e.keycode == KEY_E:
		# 擦除开关的热键：平板用户点左侧「擦除」，桌面用户按 E —— 改的是同一份状态。
		_toggle_erase()
	elif e.keycode >= KEY_1 and e.keycode <= KEY_8:
		_set_material(e.keycode - KEY_0)
	elif _numpad_view(e.keycode):
		pass
	else:
		_switch_by_hotkey(e.keycode)


## 动作命中判定：**必须精确比对修饰键**（第 3 个参数 exact_match）。
## `is_action_pressed` 默认只比键码、不比修饰键 —— 于是 Ctrl+Shift+Z 会连"撤销"一起命中、
## Ctrl+Shift+S 会连"保存"一起命中，谁先判谁赢、另一个永远轮不到（"重做"就是这么坏的）。
func _pressed(e: InputEventKey, action: StringName) -> bool:
	return e.is_action_pressed(action, false, true)


## 热键切笔：与点工具坞走同一条 `_set_tool`，于是按钮高亮与提示文案不可能与实况不一致。
func _switch_by_hotkey(key: Key) -> void:
	for row in QVoxelBrushTool.MODES:
		if row.hotkey == key:
			_set_tool(row.mode)
			return


## 把屏幕坐标解成"这一次落笔打在哪"：相机射线 → 体素空间 → 网格拾取（含空图落在地板上）。
func _pick_at(screen: Vector2) -> QVoxelBrushTool.Pick:
	var scale := model.voxel_scale
	var origin: Vector3 = model.to_local(camera.project_ray_origin(screen)) / scale
	var dir: Vector3 = model.global_transform.basis.inverse() * camera.project_ray_normal(screen)
	var info := QVoxelGridPick.hit(session.data, origin, dir, session.output_size())
	return session.pick_from_hit(info, _erasing(), _material_id)


## 这一笔是擦还是画。两个来源取或：右键按下时的**一次性** `_erase`，与左侧「擦除」开关的
## **粘性**模式（平板上没有右键，全靠它）。取或而不是二选一，是为了让"开着擦除模式时按右键"
## 仍然擦 —— 用户不会因为多按了一个键反而改回画。
func _erasing() -> bool:
	return _erase or (_tools != null and _tools.erase_mode())


# 手势

func _begin_stroke(screen: Vector2, erase: bool) -> void:
	if _sess.node_locked(session.object):
		hud.flash("这一层已锁定：先在右侧「图层」里解锁")
		return
	# 预览中落笔 = 这一笔会画在"播放头正好停住的那一帧"上，而播放头还在动 —— 用户根本
	# 说不清自己画到了第几帧。先停下播放再落笔（停在哪一帧就是哪一帧，看得见）。
	_timeline_section.stop_playback()
	_erase = erase
	if not session.begin(_pick_at(screen)):
		hud.flash("这儿落不了笔：把光标放到网格上，或已经画出来的体素上")
		return
	_stroke = true
	_refresh_cursor(screen)


func _end_stroke() -> void:
	if not _stroke:
		return
	_stroke = false
	var picking := session.tool.selection_mode()
	if not session.release():
		hud.flash(_no_change_hint(picking))
	_erase = false
	_refresh_hud()


## "这一笔没改动"的原因随工具而不同：画笔是网格外 / 同色覆盖，选区是"没框到网格内的格子"。
## 提示词照抄画笔那套会让用户以为选区坏了（其实只是原地没动）。
func _no_change_hint(picking: bool) -> String:
	if picking:
		return "选区没变（没框到网格内的格子）"
	return "这一笔没有改动（网格外 / 同色覆盖 / 没东西可擦）"


func _cancel() -> void:
	if _stroke:
		session.cancel()
		_stroke = false
		_erase = false
		hud.flash("已取消这一笔")
		return
	# 不在手势中时，Esc 退掉选区：选区是"模式之外的临时状态"，用户需要一个不碰数据的退出键。
	# 退选区**不记撤销** —— 它没改任何体素，进撤销栈只会让 Ctrl+Z 多按一次才回到真正的改动。
	if session != null and session.deselect():
		hud.flash("已取消选区")
		_refresh_hud()
	elif hud.legend_visible() or hud.log_visible():
		# 浮层挡着视口，Esc 应先关它 —— 与"Esc 先关最上面那层"的普遍习惯一致。
		_set_legend_visible(false)
		_set_log_visible(false)
	else:
		hud.flash("没有进行中的手势")


## 失焦时作废手势：否则"切出去松手"的那一拍会把笔卡在按下状态。
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT and _stroke and session != null:
		session.cancel()
		_stroke = false
		_erase = false


func _undo() -> void:
	if _stroke:
		return
	var label := session.history.undo_label()
	if session.undo():
		hud.flash("已撤销：" + label)
	else:
		hud.flash("没有可撤销的")


func _redo() -> void:
	if _stroke:
		return
	var label := session.history.redo_label()
	if session.redo():
		hud.flash("已重做：" + label)
	else:
		hud.flash("没有可重做的")


## 说明浮层（应用栏「?」）。两块浮层同锚右上角，同时开会叠在一起 —— 开一块就顺手关另一块，
## 并把两个按钮的按下态一起校准：按钮是浮层的投影，不能各自为政。
func _set_legend_visible(on: bool) -> void:
	hud.set_legend_visible(on)
	_toolbar.set_help(on)
	if on:
		hud.set_log_visible(false)
		_toolbar.set_log(false)


## 日志浮层（应用栏「日志」）。与 _set_legend_visible 对称。
func _set_log_visible(on: bool) -> void:
	hud.set_log_visible(on)
	_toolbar.set_log(on)
	if on:
		hud.set_legend_visible(false)
		_toolbar.set_help(false)


## 切笔：工具坞的按钮与热键共用这一处 —— 于是"按钮高亮"永远是实况的投影，而不是第二份状态。
func _set_tool(mode: int) -> void:
	session.tool.set_mode(mode)
	hud.flash("工具：" + session.tool.label())
	_refresh_hud()


## 笔刷加减（工具坞的 [−]/[+] 与 [ ] 键共用）。面板只报"想加还是想减"（相对量），
## 钳制与语义留在这一层 —— 界面不必知道上限，也就不可能在两处写出不同的上限。
func _step_brush(delta: int) -> void:
	_set_brush(session.tool.brush_size + delta)


## 笔刷乘除（工具坞的 2X / 1÷2）。÷2 向下取整并兜底到 1 —— 与细调同一条底线：
## 笔刷永远至少一格，界面不必认识"上限"（clamp 仍在 _set_brush 一处）。
func _scale_brush(up: bool) -> void:
	var s: int = session.tool.brush_size
	_set_brush(s * 2 if up else maxi(1, s >> 1))


## 切笔刷形态。与 _set_tool 同构：只改一处状态 + 刷新，按钮高亮由 _refresh_hud 投影出来
## （面板自己 set_pressed_no_signal，故不存在"界面又通知 App"的回环）。
func _set_brush_shape(shape: int) -> void:
	session.tool.set_shape(shape)
	hud.flash("笔刷形态：%s" % QVoxelBrushTool.SHAPES[shape].text)
	_refresh_hud()


func _set_brush(size: int) -> void:
	var n := clampi(size, 1, max_brush_size)
	if n == session.tool.brush_size:
		hud.flash("笔刷已到 %s" % ("上限" if n == max_brush_size else "下限"))
		return
	session.tool.brush_size = n
	hud.flash("笔刷 %d" % n)
	_refresh_hud()


func _set_material(id: int) -> void:
	if id >= world.materials.size():
		hud.flash("没有 %d 号材质（当前色板 %d 色）" % [id, world.materials.size() - 1])
		return
	_material_id = id
	hud.flash("材质 %d" % id)
	_refresh_hud()


## 擦除开关（工具坞的「擦除」按钮与 E 键共用）：平板上没有右键，这是唯一的擦除入口。
func _toggle_erase() -> void:
	var on := not _tools.erase_mode()
	_tools.set_erase(on)
	hud.flash("擦除模式：%s" % ("开（画的时候挖掉体素）" if on else "关"))


## 对称轴开关（左侧「对称」三个按钮共用）。状态留在 App 这一层，再压进当前笔刷。
func _set_symmetry_axis(axis: int, on: bool) -> void:
	var axes := [_symmetry.x, _symmetry.y, _symmetry.z]
	axes[axis] = 1 if on else 0
	_symmetry = Vector3i(axes[0], axes[1], axes[2])
	_apply_symmetry()
	hud.flash("对称：X%s Y%s Z%s" % [_axis_mark(_symmetry.x), _axis_mark(_symmetry.y), _axis_mark(_symmetry.z)])


func _axis_mark(on: int) -> String:
	return "●" if on != 0 else "○"


## 把 App 级的笔刷设置压进**当前活动对象**的笔刷实例。切对象后必须再调一次 ——
## 新活动对象有它自己的工具实例，不压就退回默认（对称"莫名其妙自己关了"的根因）。
func _apply_symmetry() -> void:
	if session != null and session.tool != null:
		session.tool.symmetry = _symmetry


# 修改器链（右侧抽屉·层级组挂链 + 参数组改参数）
# 旋转 / 镜像 / 平铺不再是"一次性重写整片网格"的动作，而是链上一条 QVoxelTransformModifier。
# 于是本段只剩三件事：把面板报告的用户意图翻译成"改哪个属性 + 记成哪条命令"，
# 并在动手前用 PcgTransform.within_budget 拦一次（那条命令本身在 QVoxelPropertyCommand）。


## 往 node 的链上追加一条修改器（一条可撤销的属性命令）。
## 【为什么先造条目再追加，而不是把"算子 + 合成方式"传进来】条目自带开关与合成方式，
## 而这些属于修改器而不属于算子（同一棵 Sdf 树既能被并进去、也能被减掉），
## 故由 QVoxelModifierSerializer.new_modifier 造空条目、本处填好默认核，见 QVoxelNode.add_modifier。
## 【为什么默认核是"镜像 X"而不是空】空条目求值为恒等 —— 挂上去画面纹丝不动，
## 用户会以为按钮坏了。镜像既是重排（看得出效果），又不改盒尺寸（不会突然撑大网格）。
func _add_modifier(node: QVoxelNode, kind: String) -> void:
	if world == null or session == null or node == null:
		return
	var m := QVoxelModifierSerializer.new_modifier(kind)
	if m == null:
		return
	if kind == QVoxelModifier.KIND_TRANSFORM:
		(m as QVoxelTransformModifier).transform = PcgTransform.mirror(0)
	var too_big := _over_budget(node, m)
	if too_big != Vector3i.ZERO:
		hud.flash("挂上「%s」会把网格撑到 %d×%d×%d，超过 %d 格的上限，未执行"
				% [m.display_name(), too_big.x, too_big.y, too_big.z,
						PcgTransform.MAX_OUTPUT_VOXELS])
		return
	var cmd := QVoxelPropertyCommand.begin(node, &"modifiers", node, "挂修改器 %s" % m.display_name())
	node.add_modifier(m)
	if not cmd.commit():
		return
	session.history.push(cmd)
	_select_modifier(node, m)
	_chain_changed()
	hud.flash("已挂 %s" % m.display_name())


## 从链上移除第 index 条（同样只记一条属性命令 —— modifiers 就是一个 @export 数组）。
func _remove_modifier(node: QVoxelNode, index: int) -> void:
	if world == null or session == null or node == null:
		return
	if index < 0 or index >= node.modifiers.size():
		return
	var m: QVoxelModifier = node.modifiers[index]
	var cmd := QVoxelPropertyCommand.begin(node, &"modifiers", node, "移除修改器 %s" % m.display_name())
	node.remove_modifier(index)
	if not cmd.commit():
		return
	session.history.push(cmd)
	if _modifier == m:
		_select_modifier(node, null)
	_chain_changed()
	hud.flash("已移除 %s" % m.display_name())


## 旁通 / 启用链上第 index 条。**不删条目** —— 与 Blender 的修改器眼睛同义：
## 试比较两种参数配置时不必反复删了重加。
func _set_modifier_enabled(node: QVoxelNode, index: int, on: bool) -> void:
	if world == null or session == null or node == null:
		return
	if index < 0 or index >= node.modifiers.size():
		return
	var m: QVoxelModifier = node.modifiers[index]
	if m.enabled == on:
		return
	var cmd := QVoxelPropertyCommand.apply(m, &"enabled", on, node,
			"%s修改器 %s" % ["启用" if on else "旁通", m.display_name()])
	if cmd != null:
		session.history.push(cmd)
	_chain_changed()


## 选中链上某条修改器 → 参数组显示它的参数。
func _on_modifier_selected(node: QVoxelNode, index: int) -> void:
	if node == null or index < 0 or index >= node.modifiers.size():
		return
	_select_modifier(node, node.modifiers[index])


## 把参数组绑到 m（null = 清空）。宿主节点一并记下 —— 改参数的命令要挂在它的 content_changed 上。
func _select_modifier(node: QVoxelNode, m: QVoxelModifier) -> void:
	_modifier = m
	_modifier_owner = node if m != null else null
	_inspector_section.bind(m)


## 改参数的手势三段：开始（抓改前值）→ 连续写（不入栈，实时预览）→ 结束（封口入栈）。
## 与改色 / 体素笔同一时间线（见 QVoxelPropertyCommand 的"手势即命令"）。
func _begin_prop_edit(target: Object, prop: StringName) -> void:
	if session == null or _modifier_owner == null or target == null:
		return
	_prop_cmd = QVoxelPropertyCommand.begin(target, prop, _modifier_owner, "修改器参数")


func _live_prop(target: Object, prop: StringName, value: Variant) -> void:
	if _prop_cmd == null or target == null:
		return
	target.set(prop, value)
	# 实时预览：只重建渲染，**不重建树** —— 重建会把正在拖的那根滑条销毁，手势当场断掉。
	# 与改色同理（见 QVoxelierColorSection），差异只在"链改了要连输出盒一起同步"。
	if session != null:
		session.rebuild()


func _end_prop_edit(_target: Object, _prop: StringName) -> void:
	if _prop_cmd == null:
		return
	if _prop_cmd.commit() and session != null:
		session.history.push(_prop_cmd)
	_prop_cmd = null
	_chain_changed()


## 链变了之后的四件事：标脏、重建显示、刷新层级（行上的显示名与超限提示跟着变）、重绑参数组。
## 【为什么统一走这里，而不是各入口各刷一遍】"链变了"的入口有四个（挂 / 删 / 旁通 / 改参数），
## 它们要刷的东西一模一样；分散写迟早漏一处 —— 表现为"撤销回去树上是旧名字"。
func _chain_changed() -> void:
	_sess.mark_dirty()
	_rebuild_view()
	_refresh_hud()
	_tree_section.refresh()
	_rebind_inspector()


## 让参数组重看一眼数据。**两个出口共用**：链变了（_chain_changed）与撤销 / 重做（_on_session_changed）
## —— 两者都会把数据改到"面板控件被建出来时"之外的状态：
##   · 选中算子会顺带校正合成方式（见 QVoxelVolumeModifier.detail），而下拉框还停在旧值；
##   · 撤销一次改参数会把值退回去，滑条却还停在拖完的位置；
##   · 撤销掉"挂修改器"会让绑着的那条**不在链上**了 —— 再改它就是写进孤儿，还白占一次撤销。
## 故这里一并做"清理 + 重绑"：绑着的那条已不在链上就清空，否则重绑。
## 【为什么按 is_editing() 让开】重绑会重建控件、把正在拖的滑条销毁。手势中的实时预览本就不重建
## （见 _live_prop），而撤销栈的信号是在手势收尾（commit）之后才发的，故走到这里手势已经结束。
func _rebind_inspector() -> void:
	if _inspector_section == null or _inspector_section.is_editing():
		return
	if _modifier != null and not _owns_modifier(_modifier_owner, _modifier):
		_select_modifier(null, null)
	else:
		_inspector_section.bind(_modifier)


## 挂上 candidate 之后，node 的输出盒会变成多大。**超限则返回那个超限的尺寸**（供报错文案用），
## 没超限返回 ZERO。
## 【为什么问核的 raw_output_size 而不是引擎的 output_grid_size】后者会经过核的上限判定，
## 超限时"静静地原样返回"——于是 UI 看到的尺寸与没挂时一样，压根发现不了超限。
## 而界面上先拦一次只是为了给一句人话；真正生效的那道闸在 PcgTransform（撤销 / 读盘也过它），
## 判据共用 within_budget，故"提示"与"实际生效"不会说两套话。
func _over_budget(node: QVoxelNode, candidate: QVoxelModifier) -> Vector3i:
	var t := candidate.op() as PcgTransform
	if t == null:
		return Vector3i.ZERO
	var size := t.raw_output_size(_node_output_size(node))
	return Vector3i.ZERO if PcgTransform.within_budget(size) else size


## node 当前的输出盒尺寸。模型问会话（与显示层同源，且那份结果本来就算过）；
## 组要问引擎 —— 组的输入盒是"子树并集包围盒"，那是求值的产物，没有更便宜的来源。
func _node_output_size(node: QVoxelNode) -> Vector3i:
	if node == null:
		return Vector3i.ZERO
	if node.is_model():
		var s := _sess.session_for((node as QVoxelModel).model_id)
		return s.output_size() if s != null else (node as QVoxelModel).grid_size
	# ctx 的 grid_size 随便给 —— 组求值第一件事就是把它换成"子树并集包围盒"（见 QVoxelEvalEngine）。
	var ctx := QVoxelEvalContext.make(Vector3i.ONE, 0)
	return QVoxelEvalEngine.evaluate_node(node, ctx, null, null).grid_size


## 视图模式：绘制 / 转视角 / 平移。触摸屏上没有中键，故左键会被借去当视角键，
## 切模式时若正按着笔，必须先收笔 —— 否则那一笔会以"松手"的形式留下半截改动。
func _set_view_mode(mode: int) -> void:
	_nav = mode == QVoxelierToolbar.VIEW_ORBIT
	_pan_mode = mode == QVoxelierToolbar.VIEW_PAN
	_orbit = false
	_pan = false
	if mode != QVoxelierToolbar.VIEW_PAINT and _stroke:
		session.cancel()
		_stroke = false
	match mode:
		QVoxelierToolbar.VIEW_ORBIT:
			hud.flash("导航模式：单指 / 左键拖动 = 转视角")
		QVoxelierToolbar.VIEW_PAN:
			hud.flash("平移模式：单指 / 左键拖动 = 平移画面")
		_:
			hud.flash("回到绘制：拖动 = 画")


# 视图（镜头 / 标准视角 / 网格线）

## 切镜头（视图栏「透视 / 正交」与小键盘 5 共用）。正交不是"另一种画风"：
## 没有近大远小才量得准比例、才对得齐体素 —— 体素建模里它是刚需而不是可选项。
func _set_lens(mode: int) -> void:
	camera.set_lens(mode)
	_view_bar.set_lens(mode)
	hud.flash("镜头：%s" % QVoxelViewCamera.LENS_NAMES[mode])


## 切标准视角。**三个入口共用这一条路径**：视图栏七个预设、朝向指示器点轴、小键盘 ——
## 于是三处的回显与提示永远一致（不存在"点了指示器但视图栏还亮着别的"）。
func _apply_view(view: int) -> void:
	camera.apply_view(view)
	_view_bar.set_view(view)
	hud.flash("%s视图" % QVoxelViewCamera.VIEW_NAMES[view])


## 网格线显隐（视图栏开关）。只摘格线、保留外框 —— 外框是"合法范围"的告知，见 QVoxelGridFloor。
func _set_grid_lines(on: bool) -> void:
	grid_floor.set_grid_lines_visible(on)
	_view_bar.set_grid_lines(on)
	hud.flash("网格线：%s" % ("开" if on else "关"))


## 小键盘切视角 —— 沿用 Blender 的约定（1 前 / 3 右 / 7 顶 / 5 切投影）。
## 【为什么照抄这套】建模用户的视角肌肉记忆大多来自 Blender，白捡的学习成本不捡白不捡。
## 小键盘在本应用没有任何既有用途，不会与工具热键（字母）或材质键（主键盘 1..8）相撞。
## 返回是否命中，供 _on_key 的 elif 链判断。
func _numpad_view(key: Key) -> bool:
	match key:
		KEY_KP_1: _apply_view(QVoxelViewCamera.View.FRONT)
		KEY_KP_2: _apply_view(QVoxelViewCamera.View.BACK)
		KEY_KP_3: _apply_view(QVoxelViewCamera.View.RIGHT)
		KEY_KP_4: _apply_view(QVoxelViewCamera.View.LEFT)
		KEY_KP_7: _apply_view(QVoxelViewCamera.View.TOP)
		KEY_KP_8: _apply_view(QVoxelViewCamera.View.BOTTOM)
		KEY_KP_0: _apply_view(QVoxelViewCamera.View.ISO)
		KEY_KP_5: _set_lens(QVoxelViewCamera.Lens.ORTHO
				if camera.lens == QVoxelViewCamera.Lens.PERSPECTIVE
				else QVoxelViewCamera.Lens.PERSPECTIVE)
		_:
			return false
	return true


# 工程文件（.qvx）

## 新建 / 打开都会**整体换掉**当前世界，故先过一道"未保存的改动"确认。
## 这层保护是必须的：平板上没有 Ctrl+S 的肌肉记忆，误触一次「新建」丢掉一下午是常事。
func request_new() -> void:
	_confirm_discard("新建", new_model)


## 打开工程（path 为空 = 弹文件对话框让用户选）。
func request_open(path := "") -> void:
	_confirm_discard("打开工程", _open_now.bind(path))


func _open_now(path: String) -> void:
	if path.is_empty():
		_open_dialog.popup_centered_ratio(0.7)
	else:
		open_project(path)


## 有未落盘改动时先问一句；没有就直接执行 —— 绝大多数情况下不该多出这一步。
func _confirm_discard(action: String, cb: Callable) -> void:
	if not _sess.dirty:
		cb.call()
		return
	_confirm.dialog_text = "当前工程有未保存的改动。\n继续「%s」会丢掉这些改动。" % action
	_confirm.get_ok_button().text = "放弃改动并继续"
	_confirm.get_cancel_button().text = "返回"
	# 取消不触发 confirmed，于是连接会留着；下一次再来同一个动作就会重复连接而报错。
	# 这里先断再连，把它变成"最近一次请求说了算"。
	if _confirm.confirmed.is_connected(cb):
		_confirm.confirmed.disconnect(cb)
	_confirm.confirmed.connect(cb, CONNECT_ONE_SHOT)
	_confirm.popup_centered()


## 打开工程：读盘 → 接管世界 → 重建会话。**失败时视口保持原样**（绝不半途换掉用户正编辑的东西）。
func open_project(path: String) -> bool:
	if _stroke:
		session.cancel()
		_stroke = false
	var loaded := QVoxelProject.load_world(path)
	if loaded == null:
		hud.flash("打不开这个工程（缺失或已损坏）：%s" % path.get_file())
		return false
	var obj := QVoxelierSession.pick_editable(loaded)
	if obj == null:
		hud.flash("这个工程里没有可编辑的对象：%s" % path.get_file())
		return false
	_install(loaded, obj)
	_sess.project_path = path
	_sess.clear_dirty()
	_update_title()
	var total := loaded.all_models().size()
	hud.flash("已打开 %s%s" % [path.get_file(),
			"（共 %d 个模型，可在右侧「层级」里切换）" % total if total > 1 else ""])
	return true


## 保存到当前工程文件；还没存过盘就转"另存为"。
func save_project() -> void:
	if _stroke:
		session.cancel()
		_stroke = false
	if _sess.project_path.is_empty():
		save_project_as()
		return
	_write_project(_sess.project_path)


## 另存为：弹文件对话框，默认文件名取世界名。
func save_project_as() -> void:
	_save_dialog.current_file = "%s.%s" % [world.world_name(), QVoxelProject.EXTENSION]
	_save_dialog.popup_centered_ratio(0.7)


func _write_project(path: String) -> bool:
	var err := QVoxelProject.save(world, path)
	if err != OK:
		hud.flash("保存失败（错误码 %d）：%s" % [err, path.get_file()])
		return false
	_sess.project_path = path
	_sess.clear_dirty()
	_update_title()
	hud.flash("已保存 %s" % path.get_file())
	return true


func _on_save_path_selected(path: String) -> void:
	_write_project(QVoxelProject.ensure_extension(path))


## 导出成 `.vox`：**与"保存"是两件事**，别合并。保存（.qvx）留的是"下次还能接着编辑"的全套
## （修改器链 / 材质 PBR / 相机 / 帧）；导出只留**烘出来的体素与调色板**，给别的工具用。
## 两者的产物与失败原因都不同，所以按钮、对话框、提示都分开。
## 【为什么不要求"先存盘"】导出读的是内存里的世界（`VoxAsset.from_world` 现算），与工程文件
## 在哪、存没存过都无关 —— 一个刚新建、从没存过的世界照样能导出。少一条前置条件就少一处
## "为什么按钮是灰的"的疑问。
func export_vox() -> void:
	_export_dialog.current_file = "%s.vox" % world.world_name()
	_export_dialog.popup_centered_ratio(0.7)


## 批量导出：**先挑目标目录**，范围与命名前缀就在同一个对话框里选（见 `_build_batch_options`）。
## 之所以是"目录对话框"而不是"先弹一个参数框、再弹目录框"：这两件事本来是同一次决定，
## 拆成两个弹窗只是让用户多点一次、还要在两个窗口之间来回看。
func export_vox_batch() -> void:
	_batch_dialog.popup_centered_ratio(0.7)


func _on_export_path_selected(path: String) -> void:
	var asset := VoxAsset.from_world(world)
	# 【为什么先查尺寸、再落盘】MagicaVoxel 的模型上限是 256³（`VoxAccess.MODEL_LIMIT`），超了
	# 它**不报错、直接截断**；而 XYZI 的坐标是单字节，写口会把 256 以外的体素丢掉。那对用户就是
	# "导出成功了，可我的模型少了一层壳"。宁可在这里明确拒绝，也不产出悄悄少一块的文件。
	# 判据只有一处（`VoxAsset.fits_magica`）—— 批量导出问的是同一句。
	if not asset.fits_magica():
		var box := asset.box()
		hud.flash("未导出：世界盒 %d×%d×%d 超过 MagicaVoxel 的 %d 上限（超出部分会被它截掉）"
				% [box.x, box.y, box.z, VoxAccess.MODEL_LIMIT])
		return
	var err := VoxAccess.Save(path, asset)
	if err != OK:
		hud.flash("导出失败（错误码 %d）：%s" % [err, path.get_file()])
		return
	hud.flash("已导出 %s（%d 体素）" % [path.get_file(), asset.voxel_count()])


## 目录已定：范围与前缀**当场读**（用户可能刚在同一个对话框里改过），
## 烘完把"写了几个、跳了哪几个"一句话报回去。切分与落盘都在 QVoxelBake 里。
func _on_batch_dir_selected(dir: String) -> void:
	var batches := QVoxelBake.plan(world, _batch_scope, _batch_prefix.text.strip_edges())
	hud.flash(QVoxelBake.summary(QVoxelBake.write(dir, batches), dir))


## 文件对话框：一个"打开"、一个"另存为"。走系统文件系统 —— `res://` 是只读的导入资源，
## 工程文件本就该落在用户自己的目录里（导出打包后 `res://` 更是读不到的）。
func _build_dialogs() -> void:
	_open_dialog = _make_dialog(FileDialog.FILE_MODE_OPEN_FILE)
	_open_dialog.file_selected.connect(open_project)
	_save_dialog = _make_dialog(FileDialog.FILE_MODE_SAVE_FILE)
	_save_dialog.file_selected.connect(_on_save_path_selected)
	_export_dialog = _make_format_dialog(FileDialog.FILE_MODE_SAVE_FILE, "*.vox",
			"MagicaVoxel 体素", "导出 .vox")
	_export_dialog.file_selected.connect(_on_export_path_selected)

	_palette_import_dialog = _make_format_dialog(FileDialog.FILE_MODE_OPEN_FILE, "*.png",
			"调色板 PNG（256×1）", "导入调色板")
	_palette_import_dialog.file_selected.connect(_import_palette)
	_palette_export_dialog = _make_format_dialog(FileDialog.FILE_MODE_SAVE_FILE, "*.png",
			"调色板 PNG（256×1）", "导出调色板")
	_palette_export_dialog.file_selected.connect(_export_palette)

	# 快照落盘：与调色板导出同是 "*.png" 另存，但默认文件名由分组按当前视图给出（见
	# _request_snapshot_save）—— 于是"同一个世界出七个角度"不会七张互相覆盖。
	_snapshot_dialog = _make_format_dialog(FileDialog.FILE_MODE_SAVE_FILE, "*.png",
			"PNG 图片", "保存快照")
	_snapshot_dialog.file_selected.connect(_on_snapshot_path_selected)

	# 批量导出挑的是**目录**（一个文件一个名字，不由用户逐个起名），故走 OPEN_DIR + dir_selected。
	# 不能挂 native：范围与前缀要画进它自己的 vbox 里（见 _build_batch_options）。
	_batch_dialog = _make_fs_dialog(FileDialog.FILE_MODE_OPEN_DIR, "批量导出 .vox（选目标目录）", false)
	_batch_dialog.ok_button_text = "导出到此目录"
	_batch_dialog.dir_selected.connect(_on_batch_dir_selected)
	_build_batch_options()

	_confirm = ConfirmationDialog.new()
	_confirm.title = "未保存的改动"
	_confirm.cancel_button_text = "返回"
	# 对话框是独立的 Window，不会从 Node3D 父链上继承主题，得手挂一份 —— 否则它会顶着一套
	# 与全应用无关的默认皮，风格统一在这里破功。
	_confirm.theme = QVoxelUi.theme()
	# AcceptDialog 弹出时会把键盘焦点给"确认"那颗 —— 也就是这里最危险的一颗（"放弃改动并继续"）。
	# 主题里 focus 框是强调色描边，于是它一弹出来就被画成主操作（实测 has_focus = true），
	# 回车 / 空格还会当场把它按下去。把焦点交给安全项（"返回"）：强调色回到"当前该按的那个"，
	# 回车落到安全项上，Esc 照旧关闭（Esc 走 Window 的取消路径，与焦点无关）。
	_confirm.visibility_changed.connect(func():
		if _confirm.visible:
			_confirm.get_cancel_button().grab_focus())
	add_child(_confirm)


## 系统文件对话框的公共装配：**"选什么、叫什么、筛什么"是唯一随用途变的东西**，其余
##（系统文件系统、主题、首路径、按钮文案的中文化）四种用途一字不差 —— 复制成四份，
## 迟早有一份忘了改。
## 【为什么 native 是参数，而不是一律关掉】`.qvx` 的打开 / 另存走系统原生对话框 —— 桌面端体验
## 更好（记住上次目录、能直接跳系统盘符）。而调色板与批量导出要往对话框里挂自定义内容
##（格式过滤 / 范围开关 / 前缀输入），原生对话框不渲染自绘 UI，那两处只能
## `use_native_dialog = false` 走引擎自绘的那套。
func _make_fs_dialog(mode: FileDialog.FileMode, title: String, native := true) -> FileDialog:
	var d := FileDialog.new()
	d.file_mode = mode
	d.access = FileDialog.ACCESS_FILESYSTEM
	d.current_dir = _default_dir()
	# 与 _confirm 同因：对话框的父链是 Node3D，主题传不下来，不挂就是一套 Godot 默认皮
	#（本应用是内嵌子窗口样式，所以这层皮是看得见的）。 Theme 是**叠加**而不是替换：
	# 本主题没定义的条目（Tree / LineEdit / OptionButton）继续走引擎默认值，不会把对话框弄坏。
	d.theme = QVoxelUi.theme()
	d.title = title
	# 引擎自建文案在游戏进程里没有内置翻译，会显示成 "Save" / "Cancel"。
	# 其余（Path: / 列头 / 新建文件夹）同样来自引擎，改不动；但这两个是每次操作都要读、
	# 要按的，必须跟界面同一种语言。
	d.ok_button_text = "打开" if mode == FileDialog.FILE_MODE_OPEN_FILE else "保存"
	d.cancel_button_text = "取消"
	d.use_native_dialog = native
	add_child(d)
	return d


func _make_dialog(mode: FileDialog.FileMode) -> FileDialog:
	var d := _make_fs_dialog(mode,
			"打开工程" if mode == FileDialog.FILE_MODE_OPEN_FILE else "保存工程")
	d.add_filter("*.%s" % QVoxelProject.EXTENSION, "QVoxelier 工程")
	return d


## 调色板 / 导出用的文件对话框（带格式过滤，且必须自绘 —— 理由见 `_make_fs_dialog` 的 native）。
## 为什么调色板走 PNG 而不是自定义格式：MagicaVoxel 的调色板就是 256×1 的 PNG，沿用它就能与
## 其它体素工具互相倒色板，也不用再定义一套只有本程序认得的格式。
func _make_format_dialog(mode: FileDialog.FileMode, filter: String, filter_name: String,
		title: String) -> FileDialog:
	var d := _make_fs_dialog(mode, title, false)
	d.add_filter(filter, filter_name)
	return d


## 批量导出的范围与前缀：挂在目录对话框**自己的 vbox** 里（`FileDialog.get_vbox()` 是引擎留给
## 自绘控件的口子），于是"选目录 + 选范围 + 填前缀"是**一次**交互，不用弹第二个对话框。
## 【为什么范围是一排开关而不是下拉】与工具面板的 球/平面、导航/平移 同一套（QVoxelUi 的
## 开关组）：触摸屏上没有下拉，而且四个选项一眼全在，不必点开才知道有些什么。
func _build_batch_options() -> void:
	var row := QVoxelUi.hbox(QVoxelUi.SPACE_XS)
	row.add_child(QVoxelUi.label("范围", QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM))

	var group := ButtonGroup.new()
	# 同组按钮永远有一个是"当前"，不允许点第二下变成"什么都没选"（与笔刷形态同一套）。
	group.allow_unpress = false
	for i in QVoxelBake.SCOPES.size():
		var spec: Dictionary = QVoxelBake.SCOPES[i]
		var b := QVoxelUi.toggle_button(spec.tip)
		b.text = spec.text
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.button_group = group
		# bind 而不是闭包捕获：与笔刷形态同一条理由 —— 每个按钮各钉各的值，不会一起变成最后一个。
		b.toggled.connect(_on_batch_scope_toggled.bind(i))
		if i == _batch_scope:
			b.set_pressed_no_signal(true)
		row.add_child(b)

	row.add_child(QVoxelUi.label("前缀", QVoxelUi.FONT_S, QVoxelUi.TEXT_DIM))
	_batch_prefix = QVoxelUi.text_field("", "如 rock_（可留空）", "接在每份文件名之前，用来区分批次")
	_batch_prefix.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_batch_prefix)

	_batch_dialog.get_vbox().add_child(row)


func _on_batch_scope_toggled(on: bool, scope: int) -> void:
	# 同组切换是"旧的先弹起、新的再按下"两次信号：只听按下那一次，否则会被弹起那一下
	# 覆盖回旧值（与 QVoxelierTools._on_shape_toggled 同一条）。
	if on:
		_batch_scope = scope


## 文件对话框的首选落地目录。**两个平台的"用户自己的目录"不是同一个地方**：
##   桌面：系统的「文档」—— 存完还能在资源管理器/访达里找回来（`user://` 在桌面上是
##         隐藏的 AppData/Godot/app_userdata/<项目>，用户绝不会去那儿翻自己的模型）。
##   移动 / Web：`user://` —— 那是唯一保证可写的沙箱，Android 的分区存储下写系统目录会被拒。
## 取不到系统目录（精简系统 / 权限受限）时一律退回 `user://`，绝不留下一个点不进去的首路径。
static func _default_dir() -> String:
	if OS.has_feature("pc"):
		var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
		if not docs.is_empty() and DirAccess.dir_exists_absolute(docs):
			return docs
	return ProjectSettings.globalize_path("user://")


## 把 `.qvx` 拖进窗口即打开（建模时最顺手的一步）；非工程文件一律忽略。
func _on_files_dropped(files: PackedStringArray) -> void:
	for f in files:
		if QVoxelProject.is_project_path(f):
			# 拖进来同样是"整体换掉当前世界"，走 request_open 才有那道未保存确认。
			request_open(f)
			return
	hud.flash("只认得 .%s 工程文件" % QVoxelProject.EXTENSION)


func _update_title() -> void:
	var name := _sess.project_path.get_file() if not _sess.project_path.is_empty() else "未命名"
	_toolbar.set_project(name, _sess.dirty)
	if not Engine.is_editor_hint() and get_window() != null:
		get_window().title = "QVoxelier — %s%s" % [name, " *" if _sess.dirty else ""]


# 状态栏

# 撤销 / 重做、结构增删、材质与帧的改动都不在这里逐个接管了：它们统一由应用会话发 `changed`，
# 由 _on_session_changed 一处处理（其中"链上重排改了分辨率 → 地面网格框要跟着换"那条，
# 落在 _attach_active 里，因为它是"按输出盒画地板"这件事的一部分）。


## 界面刷新的**唯一入口**：一处改状态（工具 / 笔刷 / 材质 / 撤销栈），所有界面跟着走。
## 不做增量 diff —— 状态栏与工具坞加起来不过几十个 Label，而"每个状态变更是谁负责刷新哪块"
## 才是真会出错的地方（漏一处就出现"按钮高亮着、提示还写着上一个工具"）。
func _refresh_hud() -> void:
	if hud.session == session:
		hud.refresh()
	if session == null:
		return
	_toolbar.set_history(session.history.can_undo(), session.history.can_redo())
	_tools.set_tool(session.tool.mode)
	_tools.set_brush(session.tool.brush_size, session.tool.supports_brush_size())
	_tools.set_brush_shape(session.tool.brush_shape, session.tool.supports_brush_size())
	# 对称是 App 级设置 → 每次刷新都把它压回当前对象的笔刷，并回写三个按钮的按下态。
	_apply_symmetry()
	_tools.set_symmetry(_symmetry)
	# 选区 / 剪贴板：线框、按钮可用性、状态栏读数三处都跟着同一份数据走（一处刷新，三处跟上）。
	_tools.set_selection_state(not session.selection.is_empty(), not session.clipboard.is_empty())
	_selection_box.set_box(session.selection.lo(), session.selection.size())
	# 状态栏里的选区 / 剪贴板读数由 HUD 自己按会话算（见 QVoxelierHud._selection_readout），
	# 不在这里再喂一份字符串 —— 同一事实两处拼装迟早会各说各话。
	# 色板取世界的材质表（增删材质 / 导入 / 改色都可能换掉它）。挂在这条唯一刷新路径上，
	# set_palette 自己按指纹判重 —— 状态变更就不再需要各自记得去喂色板了（此前只有"打开工程"
	# 那条路喂过，于是新建之后整条色板是空的，只剩一个"材质 1"的标签）。
	if world != null:
		_palette.set_palette(_material_colors(world))
	_palette.set_current(_material_id)
	hud.set_material_id(_material_id)
	_refresh_panels()


## 右列三组的刷新。与 _refresh_hud 同一入口，于是"改状态 → 全界面跟上"仍只有一条路径。
func _refresh_panels() -> void:
	if _color_section == null or world == null or session == null:
		return
	var has := _material_id > 0 and _material_id < world.materials.size()
	var pbr := {}
	for key in QVoxelierColorSection.pbr_keys():
		pbr[key] = world.material_scalar(_material_id, StringName(key))
	_color_section.bind(_material_id, world.material_color(_material_id) if has else Color(0, 0, 0, 0), pbr)
	_tree_section.set_world(world, session.object.model_id)
	# 时间轴绑的是**当前对象**（帧是模型自己的属性，不像材质那样属于世界）。
	# 它内部只在帧数变了时才重建帧条（见 QVoxelierTimelineSection.bind），播放期间不重建控件。
	_timeline_section.bind(session.object)
	# 快照只读世界，且 set_world 幂等（同一个世界直接返回），故挂在这条唯一刷新路径上 ——
	# 新建 / 打开换世界时它自然会收到新世界并把旧预览作废（见 QVoxelierSnapshotSection.set_world）。
	_snapshot_section.set_world(world)


## 世界的材质表 → 调色板用的颜色数组：**下标即材质 ID**，0 位留空气占位。
## 不直接用 default_palette，是因为打开别人的工程时色板得跟着工程走。
func _material_colors(w: QVoxelWorld) -> Array[Color]:
	var colors: Array[Color] = [Color(0, 0, 0, 0)]
	for id in range(1, w.materials.size()):
		colors.append(w.material_color(id))
	return colors


## 光标格：画的时候看"要写哪一格"，擦的时候看"要擦哪一格"（Pick 已按擦除算好 place）。
## 屏幕坐标由调用方传入（鼠标事件里有，不必再问视口要一次 —— 内嵌视口时那个答案还是错的）。
func _refresh_cursor(screen: Vector2) -> void:
	var pick := _pick_at(screen)
	_hover_pick = pick if pick.valid() else null
	if not pick.valid():
		hud.set_cursor(Vector3i.MIN)
	else:
		# 擦除显示将被挖掉的那格，否则显示将落笔的那格 —— 与 ghost 预览同一个 pick，不会各说各话。
		hud.set_cursor(pick.hit if pick.erase else pick.place)
	_refresh_ghost(pick)


## 悬停预览：格子来自会话的 hover()（与真正落笔同一条形状分派，所见即所画）。
## 颜色告诉用户"会改成什么"：擦除 = 警示红，画 = 当前材质色。
func _refresh_ghost(pick: QVoxelBrushTool.Pick) -> void:
	# 手势中射线落到模型外仍要预览 —— hover() 内部用起点 pick 兜底，盒子不闪没。
	if not pick.valid() and not _stroke:
		_ghost.set_cells([])
		return
	_ghost.line_color = QVoxelUi.WARN if _erasing() else Color(world.material_color(_material_id), 0.9)
	_ghost.set_cells(session.hover(pick))


func _bind_actions() -> void:
	InputTool.register_action(ACTION_UNDO, [InputTool.key_event(KEY_Z, true)])
	InputTool.register_action(ACTION_REDO, [
		InputTool.key_event(KEY_Z, true, true), InputTool.key_event(KEY_Y, true),
	])
	InputTool.register_action(ACTION_BRUSH_UP, [
		InputTool.key_event(KEY_BRACKETRIGHT), InputTool.key_event(KEY_EQUAL),
	])
	InputTool.register_action(ACTION_BRUSH_DOWN, [
		InputTool.key_event(KEY_BRACKETLEFT), InputTool.key_event(KEY_MINUS),
	])
	InputTool.register_action(ACTION_SAVE, [InputTool.key_event(KEY_S, true)])
	InputTool.register_action(ACTION_SAVE_AS, [InputTool.key_event(KEY_S, true, true)])
	InputTool.register_action(ACTION_OPEN, [InputTool.key_event(KEY_O, true)])
	InputTool.register_action(ACTION_EXPORT, [InputTool.key_event(KEY_E, true)])
	# 选区 / 剪贴板：与"存 / 开"同属"带修饰键的操作"，故一律走 InputTool 注册的动作，
	# 而不是在 _on_key 里手写 ctrl 判断 —— 键位因此能在项目设置里改。
	InputTool.register_action(ACTION_SELECT_ALL, [InputTool.key_event(KEY_A, true)])
	InputTool.register_action(ACTION_COPY, [InputTool.key_event(KEY_C, true)])
	InputTool.register_action(ACTION_CUT, [InputTool.key_event(KEY_X, true)])
	InputTool.register_action(ACTION_PASTE, [InputTool.key_event(KEY_V, true)])
	InputTool.register_action(ACTION_CLEAR, [
		InputTool.key_event(KEY_DELETE), InputTool.key_event(KEY_BACKSPACE),
	])


# 选区与剪贴板
# 本段只做三件事：把界面意图翻成会话调用、把结果说给用户听（flash）、刷新界面。
# 选区盒与剪贴板**住在会话里**（它们是"编辑操作的输入"），本类不持有第二份真相 ——
# 否则线框、按钮可用性、状态栏读数会各读各的，迟早对不上。

## 选区面板的五个按钮共用这一条入口（面板发 id，这里分派）：加动作时只改这一处。
func _on_selection_action(action: StringName) -> void:
	match action:
		&"all":
			_select_all()
		&"copy":
			_copy_selection()
		&"cut":
			_cut_selection()
		&"paste":
			_paste_clipboard()
		&"clear":
			_clear_selection()


func _select_all() -> void:
	if session == null or session.object == null:
		return
	if session.select_all():
		hud.flash("已全选：%s" % session.selection.describe())
		_refresh_hud()
	else:
		hud.flash("已经是全选了")


func _copy_selection() -> void:
	if session == null:
		return
	if session.selection.is_empty():
		hud.flash("先框一块再复制")
		return
	_report_edit(session.copy_selection(), "已复制 %d 个体素", "选区里没有体素")


func _cut_selection() -> void:
	if session == null:
		return
	if session.selection.is_empty():
		hud.flash("先框一块再剪切")
		return
	_report_edit(session.cut_selection(), "已剪切 %d 个体素", "选区里没有体素")


func _clear_selection() -> void:
	if session == null:
		return
	if session.selection.is_empty():
		hud.flash("先框一块再清空")
		return
	_report_edit(session.clear_selection(), "已清空 %d 个体素", "选区里没有体素")


## 粘贴落点：优先落在**光标指着的地方**（所见即所得），光标不在网格上时退回选区下角，
## 再不行才退回原点。
## 【为什么不一律贴回选区原处】"复制一块、贴到另一处"是这套功能的全部意义；贴回原处等于什么
## 都没做，用户还得再按一次「移动」把它挪走 —— 那一步本来可以省掉。
func _paste_clipboard() -> void:
	if session == null:
		return
	if session.clipboard.is_empty():
		hud.flash("剪贴板是空的：先框一块并复制")
		return
	var at := Vector3i.ZERO
	if _hover_pick != null:
		at = _hover_pick.place
	elif not session.selection.is_empty():
		at = session.selection.lo()
	_report_edit(session.paste(at), "已粘贴 %d 个体素", "这儿贴不下（越界或已被同色占满）")


## 一次性选区操作的统一收尾：报数 + 刷新界面。五个动作的差异只在"调谁、说什么"。
## 【为什么成功与失败要分开措辞】"已复制 0 个体素"读起来像成功了但没东西，用户会以为复制坏了；
## 明说"选区里没有体素"才能把他指向真正的原因（框了一片空气）。
func _report_edit(n: int, ok_text: String, empty_text: String) -> void:
	if n > 0:
		hud.flash(ok_text % n)
	else:
		hud.flash(empty_text)
	_refresh_hud()


# 层级树（右侧抽屉·层级组）
# 本段只做一件事：把面板报告的用户意图翻译成"改哪个属性 + 记成哪条命令"。
# 树视图本身是 QVoxelWorld.nodes 的**纯投影**（见 QVoxelierTreeSection）。

## 点树上的行：模型就切过去编辑；组只是容器，不改变当前编辑对象。
## 【为什么要顺手清掉参数组】选中的是"节点"，而参数组显示的是"链上某一条修改器"。
## 换了节点还留着上一条的参数，滑一下就把改动写进了另一个对象的链里（且看不出来）。
func _on_tree_selected(node: QVoxelNode) -> void:
	if _modifier != null and (_modifier_owner != node or not _owns_modifier(node, _modifier)):
		_select_modifier(null, null)
	if node != null and node.is_model():
		_activate((node as QVoxelModel).model_id)


## m 是否还在 node 的链上（撤销 / 重做会换掉整个数组，条目可能已经不在了）。
func _owns_modifier(node: QVoxelNode, m: QVoxelModifier) -> bool:
	return node != null and m != null and node.modifiers.has(m)


# 层级的增 / 删 / 移 / 改字段全在 QVoxelierSession（应用能力），本层只做两件事：
# 把面板信号接过去（见 _build_ui），以及"点了树上的行就切过去编辑"这一个界面动作。



# 材质（右侧抽屉·颜色组）

## 改材质的手势三段：开始（抓改前值）→ 连续写（不入栈）→ 结束（封口入栈）。
## 颜色与 PBR 共用同一条时间线与同一条命令（目标都是 `world.materials`）。
## 与体素笔同一时间线（见 QVoxelierColorSection 的"手势即命令"注释）。
func _begin_material_edit() -> void:
	if world == null or _material_id <= 0 or _material_id >= world.materials.size():
		return
	_material_cmd = QVoxelPropertyCommand.begin(world, &"materials", null, "修改材质")


func _live_color(c: Color) -> void:
	if world == null or _material_id <= 0:
		return
	world.set_material_color(_material_id, c)
	# 底部色块就地跟着变色：它就是"这个材质长什么样"，拖滑块时不变等于读数滞后一格。
	_palette.set_color(_material_id, c)
	_sync_material(_material_id)


func _live_pbr(field: StringName, value: float) -> void:
	if world == null or _material_id <= 0:
		return
	world.set_material_scalar(_material_id, field, value)
	_sync_material(_material_id)


func _end_material_edit() -> void:
	if _material_cmd != null and _material_cmd.commit():
		session.history.push(_material_cmd)
	_material_cmd = null
	_refresh_hud()


## 把世界上某个材质刷进所有会话的 QVoxelSource（渲染器读的是那份），再重生成材质纹理。
## 【为什么每个会话都要刷】非活动对象也显示着，各自的 QVoxelSource 里也存着一份材质 ——
## 只刷活动对象的话，换个色会看到"当前对象变了、旁边的对象还是旧色"。
func _sync_material(id: int) -> void:
	if world == null or id <= 0 or id >= world.materials.size():
		return
	var mat := VoxelMaterial.from_mate(world.materials[id], id)
	for s in _sess.all_sessions():
		s.data.add_material(mat)
	_rerender_materials()


func _rerender_materials() -> void:
	if model != null:
		model.regenerate_materials()
	for r in _display.values():
		if is_instance_valid(r):
			r.regenerate_materials()


func _add_material() -> void:
	if world == null or session == null:
		return
	var cmd := QVoxelPropertyCommand.begin(world, &"materials", null, "新增材质")
	var id := world.add_material(Color(0.8, 0.8, 0.8))
	if cmd.commit():
		session.history.push(cmd)
	_sync_material(id)
	# 色板由 _set_material 里的 _refresh_hud 一并跟上（世界多了个材质，指纹自然不同）。
	_set_material(id)
	hud.flash("已新增材质 %d" % id)


# 取色器

func _set_eyedropper(on: bool) -> void:
	_eyedropper = on
	_color_section.set_eyedropper(on)
	hud.flash("取色器：%s" % ("开 —— 点视口里的体素吸取其材质色" if on else "关"))


## 吸取某屏幕位置下体素的材质，并把当前材质切过去。
func _pick_material_at(screen: Vector2) -> void:
	if session == null:
		return
	var pick := _pick_at(screen)
	if not pick.valid():
		hud.flash("这儿没有体素可吸取")
		return
	var id := session.data.get_voxel(pick.hit)
	if id <= 0:
		hud.flash("这儿是空的，没有材质可吸")
		return
	_set_material(id)
	hud.flash("已吸取材质 %d" % id)


# 调色板导入 / 导出（256×1 的 PNG，索引即材质 ID —— 与 MagicaVoxel 互通）

func _import_palette(path: String) -> void:
	if world == null or session == null:
		return
	var img := Image.load_from_file(path)
	if img == null:
		hud.flash("读不了这个 PNG：%s" % path.get_file())
		return
	img.convert(Image.FORMAT_RGBA8)
	var width := img.get_width()
	if width < 2:
		hud.flash("调色板 PNG 太窄（应是 256×1）")
		return
	var cmd := QVoxelPropertyCommand.begin(world, &"materials", null, "导入调色板")
	for i in range(1, mini(width, 256)):
		world.set_material_color(i, img.get_pixel(i, 0))
	if cmd.commit():
		session.history.push(cmd)
	_push_palette_into_all()
	_refresh_hud()
	hud.flash("已导入调色板（%d 色）" % (mini(width, 256) - 1))


func _export_palette(path: String) -> void:
	if world == null:
		return
	path = _ensure_png_ext(path)
	var img := Image.create(256, 1, false, Image.FORMAT_RGBA8)
	for i in 256:
		var c := Color(0, 0, 0, 0)
		if i > 0 and i < world.materials.size():
			c = world.material_color(i)
		img.set_pixel(i, 0, c)
	var err := img.save_png(path)
	if err != OK:
		hud.flash("导出失败（错误码 %d）" % err)
		return
	hud.flash("已导出调色板：%s" % path.get_file())


## 把整张材质表刷进每一条会话的 QVoxelSource（导入后一次性对齐，比逐色 _sync_material 省事）。
func _push_palette_into_all() -> void:
	if world == null:
		return
	for s in _sess.all_sessions():
		var data: QVoxelSource = s.data
		for id in range(1, world.materials.size()):
			data.add_material(VoxelMaterial.from_mate(world.materials[id], id))
	_rerender_materials()


# 快照（右侧抽屉·快照组，F5）
# 分组自己摆离屏舞台、自己按快门（见 QVoxelierSnapshotSection 的"为什么按下渲染不经过应用层"）。
# 本段只做两件分组做不了的事：弹落盘对话框（对话框的公共装配在 _build_dialogs 一处），
# 以及把落盘结果说给用户听。世界的推送见 _refresh_panels。

## 分组点了「保存…」：用它的默认名（带视图名）弹对话框 —— 覆盖是可预期的，
## 而不是"七张角度悄悄互相覆盖、用户以为存了七张"。
func _request_snapshot_save() -> void:
	_snapshot_dialog.current_file = _snapshot_section.suggested_file_name()
	_snapshot_dialog.popup_centered_ratio(0.7)


func _on_snapshot_path_selected(path: String) -> void:
	hud.flash(_snapshot_section.save_png(_ensure_png_ext(path)))


## 补上 .png 扩展名（两个 PNG 出口共用：调色板导出与快照落盘）。
## 用 to_lower 判：Windows 上 "X.PNG" 同样是 PNG，不认它就会存出一个 "X.PNG.png"。
func _ensure_png_ext(path: String) -> String:
	return path if path.to_lower().ends_with(".png") else path + ".png"


# 时间轴（右侧抽屉·时间轴组，QVoxelSpec §12.6）
# 与层级树那一段同构：本段只做一件事 —— 把面板报告的用户意图翻译成"改哪个属性 + 记成哪条命令"。
# 帧的结构改动走 QVoxelPropertyCommand（`frames` 就是属性），而切帧 / 播放**不入栈**：
# active_frame 是"正在看第几帧"，是游标不是数据（§12.6）。

## 切帧：改游标 → 重算 → 刷界面。**不标脏、不入栈**。
## 【为什么不记进历史】"我看了第 3 帧"不是一次内容改动。若它也占一格，用户画一笔再翻十帧，
## 想撤掉那一笔就得连按十一次 —— 撤销栈会被浏览动作灌满，而里面 90% 是空操作。
func _select_frame(index: int) -> void:
	if session == null or not session.object.is_animated():
		return
	session.set_active_frame(index)
	_after_frame_change()


## 帧结构 / 元数据改动后的统一收尾：重算 + 刷界面（标脏由撤销栈的 changed 信号带出来，
## 见 QVoxelierSession._on_history_changed —— 帧操作都入栈，故不在这里重复标）。
func _after_frame_change() -> void:
	if session == null:
		return
	session.rebuild()
	_refresh_hud()


## 把一次"帧结构编辑"夹成一条属性命令：`mutate` 里做真正的改动（begin 之后、commit 之前）。
## 【为什么是"传一个闭包"而不是每种操作各写一遍】§12.6 的增 / 删 / 重排走的是同一条包裹：
## begin（抓旧值）→ 改 → commit → push → 刷界面，差异只有中间那两行。复制三遍就等着某一遍
## 忘了 also_write(blocks) —— 而漏掉它的那次撤销会把模型的体素源整个丢掉（见下）。
func _run_frame_edit(label: String, mutate: Callable) -> void:
	if session == null or world == null:
		return
	var m := session.object
	var cmd := QVoxelPropertyCommand.begin(m, &"frames", m, label)
	# §12.2：动画生效即静态源让位。`blocks` 因此必须进**同一条**命令的撤销范围 ——
	# 否则撤销"做成动画"会只把 frames 清空，而 blocks 早在转换时就被搬进第 0 帧了，内容凭空消失。
	# 对已经是动画的模型，blocks 恒为空字典、前后相同，这一行等于零开销（commit 会忽略未变项）。
	cmd.also_write(m, &"blocks")
	mutate.call(m)
	if cmd.commit():
		session.history.push(cmd)
	_after_frame_change()


## 在当前帧之后插入一帧（`duplicate` = 复制当前帧，否则空帧）。
## 【静态模型上插入为什么要先 make_animated】静态模型的体素住在 `blocks` 里，而帧动画的
## 体素住在 `frames[i].blocks`（§12.2 一个 model_id 只能有一个源）。做成动画不是"多一个空帧"，
## 而是把现有内容搬进第 0 帧 —— 否则用户点一下「＋」就会看见模型整个消失。
func _insert_frame(duplicate: bool) -> void:
	_run_frame_edit("复制帧" if duplicate else "新增帧", func(m: QVoxelModel) -> void:
		if not m.is_animated():
			m.make_animated()
		var at := m.active_frame + 1
		var f: QVoxelFrame = m.frame_at(m.active_frame).clone() if duplicate else QVoxelFrame.new()
		m.add_frame(f, at)
		m.active_frame = at   # 新帧就是接下来要画的那一帧（否则用户得再点一下帧条）
	)


func _remove_frame(index: int) -> void:
	_run_frame_edit("删除帧", func(m: QVoxelModel) -> void:
		m.remove_frame(index)
	)


func _move_frame(from: int, to: int) -> void:
	_run_frame_edit("移动帧", func(m: QVoxelModel) -> void:
		if m.move_frame(from, to):
			# 游标跟帧走：用户按「◀」想继续编辑的是**同一帧**，不是同一个序号
			m.active_frame = to
	)


## 改帧时长的三段手势（与改色 / 改参数同一时间线：见 QVoxelPropertyCommand 的"手势即命令"）。
## 目标是**那一帧对象本身**的 duration_ms，而不是模型的 frames 数组 —— 后者是"整数组替换"的
## 属性命令，就地改一帧的时长不会让数组前后不同（元素是同一个 QVoxelFrame），commit 会当成没改。
func _begin_frame_duration(index: int) -> void:
	if session == null or index < 0 or index >= session.object.frame_count():
		return
	_frame_dur_cmd = QVoxelPropertyCommand.begin(session.object.frame_at(index), &"duration_ms",
			session.object, "改帧时长")


func _live_frame_duration(index: int, ms: int) -> void:
	if _frame_dur_cmd == null or session == null:
		return
	var m := session.object
	if index < 0 or index >= m.frame_count():
		return
	m.frame_at(index).duration_ms = ms
	# 实时预览只重刷面板（播放头读数要跟着变），**不重建渲染** —— 时长不改变任何体素，
	# 而且重建会把正在拖的那根滑条销毁、手势当场断掉（与改色同理）。


func _end_frame_duration(_index: int) -> void:
	var cmd := _frame_dur_cmd
	_frame_dur_cmd = null
	if cmd != null and cmd.commit():
		session.history.push(cmd)
	_after_frame_change()


## 时间轴元数据（loop / fps / tags，落进 NODE 条目的 `anim` 键 —— §12.3）。
func _set_anim_meta(prop: StringName, value: Variant, label: String) -> void:
	if session == null or not session.object.is_animated():
		return
	var m := session.object
	var cmd := QVoxelPropertyCommand.begin(m, prop, m, label)
	m.set(prop, value)
	if cmd.commit():
		session.history.push(cmd)
	_after_frame_change()

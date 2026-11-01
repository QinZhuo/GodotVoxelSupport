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
## 触摸屏上必须由界面补位的两处：滚轮缩放 →「− / +」，右键擦除 → 顶部选项条的「添加 / 移除 / 上色」三态（E 键同义）。
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

## 导入模型时的体素分辨率 = 模型最长边的体素数（其余轴按比例）。越大越精细、也越吃内存。
@export var import_resolution := 96

@onready var model: VoxelRenderer = $Model
@onready var camera: QVoxelViewCamera = $Camera
@onready var grid_floor: QVoxelGridFloor = $Model/Floor
@onready var hud: QVoxelierHud = $Hud
@onready var _key_light: DirectionalLight3D = $KeyLight
@onready var _env_node: WorldEnvironment = $WorldEnvironment

## 应用栏 / 工具坞 / 调色板：**在代码里建**而不是摆进 .tscn —— 它们的内容完全由运行时数据决定
## （工具表、世界的材质表），在场景里预摆只会得到一份立刻被推翻的空壳；
## 状态栏（Hud）留在场景里，因为它是静态骨架、且视口脚本要按路径引用它。
var _toolbar: QVoxelierToolbar
var _tools: QVoxelierTools
var _context: QVoxelierContextBar
var _palette: QVoxelierPalette
var _gizmo: QVoxelierGizmo
var _dock: QVoxelierDock
var _color_section: QVoxelierColorSection
var _tree_section: QVoxelierTreeSection
var _object_section: QVoxelierObjectSection
## 底部动画帧条（常驻一行，只显示当前模型的帧）。
var _timeline: QVoxelierTimeline
## 快照分组（F5）：离屏渲一张 PNG。它只读世界，故本类只把世界推给它、再管一次落盘对话框
## （参数与预览是分组自己的状态，见 QVoxelierSnapshotSection）。
var _snapshot_section: QVoxelierSnapshotSection
var _snapshot_popup: PopupPanel
var _confirm: ConfirmationDialog

## 工具类别：笔刷 / 自定义笔刷（拿一个模型当图章盖）。与 QVoxelierContextBar.KIND_* 对应。
enum ToolKind { BRUSH, CUSTOM }
var _tool_kind := ToolKind.BRUSH
## 层级里当前选中的节点（对象属性页据此显示"它是什么"）。
var _selected_node: QVoxelNode

## 非活动对象的渲染节点容器：多对象世界里只有"当前对象"用 model，其余挂在这里。
## （见 _rebuild_view —— 切换活动对象只换 model.data，其余渲染器复用。）
var _extra_root: Node3D
## 布局模式的叠加层：每个模型的不透明包围盒线框 + 世界中心十字（仅布局模式可见）。
var _layout_overlay: Node3D
## 选区线框（挂在 model 下，与体素网格同一套坐标换算）。看不见的选区等于没有选区 ——
## 用户按了"复制"却不知道复制了什么，故它随 _refresh_hud 一起重画。
var _selection_box: QVoxelSelectionBox
## 移动坐标轴 gizmo（选区中心，点轴端挪一格）。
var _move_gizmo: QVoxelierMoveGizmo
## 笔刷悬停预览（半透明实体标出"按下 / 拖到这里会改成什么"）。与选区框同挂 model 下 ——
## 同一套坐标换算，两者天然对齐；色与线框形态按操作三态（添加 = 实体材质色，移除 = 红线框，上色 = 材质色线框）。
var _ghost: QVoxelPreviewMesh
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
## 当前操作模式（添加 / 移除 / 上色）。顶部选项条与 E 键改的是这一份。
var _op: QVoxelBrushTool.Op = QVoxelBrushTool.Op.ADD
## 进行中手势的模式：落笔那一刻定死，拖动与预览都按它走（与 _op 可不同，右键 / Shift 会临时覆盖）。
var _stroke_op: QVoxelBrushTool.Op = QVoxelBrushTool.Op.ADD
## 悬停预览用的模式：按 Shift 时临时切到移除，于是**松手前**的预览就能反映"这一下是移除"。
var _hover_op: QVoxelBrushTool.Op = QVoxelBrushTool.Op.ADD
## 对称轴掩码。是**App 级设置**而非笔刷级：每个对象各有自己的笔刷实例，
## 若把它存在笔刷里，切一次对象就会被新笔刷的默认值抹掉（见 _apply_symmetry）。
var _symmetry := Vector3i.ZERO
## 快速选区判据（App 级设置，切对象时压回当前会话）：true = 同色相连。
var _select_by_color := true
var _orbit := false
var _pan := false
## 坐标轴拖拽移动的进行态。
var _gizmo_active := false
var _gizmo_axis := -1
## gizmo 拖拽模式：0 = 移动选区（坐标轴），1 = 旋转选区（旋转环），
## 2 = 布局模式移动节点，3 = 布局模式旋转节点。
var _gizmo_mode := 0
var _gizmo_rot_angle := 0.0
## 旋转预览当前吸附到的 90° 倍数（避免每移动一像素都重画 ghost）。
var _gizmo_rot_quarters := 0
var _gizmo_t0 := 0.0
## 编辑层级：0 = 模型内部（编辑体素），1 = 布局（编辑模型整体变换）。Tab 切换（类似 Blender）。
var _edit_mode := 0
## 布局拖拽的**固定参考**（拖拽期间模型会动，参考必须钉在按下那一刻，否则参数自漂移）。
var _layout_center := Vector3.ZERO
var _layout_axis_u := Vector3.ZERO
## 布局多选：选中的 model_id 集合；拖拽时逐模型记下改前值，松手一次性提交。
var _layout_sel: Dictionary = {}
var _layout_base_offsets: Dictionary = {}
var _layout_base_xfs: Dictionary = {}
## 布局旋转的**共同中心**（世界体素坐标），按下时按改前变换算一次并钉住。
var _layout_pivot := Vector3.ZERO
## 布局旋转的**固定参考系**（gizmo 随模型转，必须钉住按下那一刻的基/中心，否则夹角乱跳）。
var _layout_rot_basis := Basis.IDENTITY
var _layout_rot_center := Vector3.ZERO
## 布局框选（屏幕矩形）。
var _box_select := false
var _box_start := Vector2.ZERO
var _box_end := Vector2.ZERO
var _box_panel: Panel
var _gizmo_per_voxel := 1.0
var _gizmo_delta := 0
## 拖动移动时的实时预览素材：拖动开始时抓取的选区体素 + 选区下角。
var _gizmo_clip: QVoxelClipboard = null
var _gizmo_base_lo := Vector3i.ZERO
## 导航拖拽由谁启动（&"" / &"left" / &"middle"）—— 释放时只关自己启动的那一路，
## 免得左键松开把还按着的中键视角拖拽一并关掉。
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
## 右侧栏的背景条（把右列的浮板连成整条侧栏）。左列工具是独立图标按钮、不带统一底色，故无左条。
var _right_rail: Panel

## 取色器：开启后下一次左键点击改为"吸取该处体素的材质"，而不落笔。
var _eyedropper := false
## 正在进行的"改材质"手势（颜色或 PBR）对应的属性命令（松手时封口入栈；见 QVoxelierColorSection 的"手势即命令"）。
var _material_cmd: QVoxelPropertyCommand
## 正在进行的"改帧时长"手势对应的属性命令（同上，目标是那一帧 QVoxelFrame 的 duration_ms）。
var _frame_dur_cmd: QVoxelPropertyCommand

var _open_dialog: FileDialog
var _save_dialog: FileDialog
## 导出网格对话框（glTF 2.0：*.glb / *.gltf）。
var _mesh_dialog: FileDialog
## 选模型文件的对话框（过滤项由 MeshAccess.filter_specs() 生成）。
var _model_dialog: FileDialog
## 导入参数对话框（分辨率 / 追加 / 实心）：**先定参数、再选文件**。
var _import_dialog: QVoxelierImportDialog
## 拖放进来的模型路径：有值时跳过文件选择，确认参数即导入。
var _pending_import_path := ""
## 本次导入参数（参数框确认时写入，文件选完/拖放确认后取用）。
var _import_opts: Dictionary = {}
var _palette_import_dialog: FileDialog
var _palette_export_dialog: FileDialog
## 快照落盘对话框（*.png）。与调色板导出同走自绘那套 —— 默认文件名由分组按视图名给出。
var _snapshot_dialog: FileDialog

## 滚轮 / 双指滑一格对应的平移像素量。
const WHEEL_PAN_STEP := 48.0

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
	_disable_focus(self)
	# 天空里的"太阳盘"调小：材质 metallic=1 会把天空的太阳反射成一个大光球（用户不想要）。
	_setup_sky()
	_apply_render_mode()
	# 按钮/控件的悬停提示统一送到状态栏显示（本应用不用悬浮气泡）。
	QVoxelUi.hint_sink = hud.show_hover_hint
	new_model()
	# 编辑器里只装配外观（网格地板与取景），输入留给编辑器自己 —— @tool 脚本不该抢编辑器的键。
	if Engine.is_editor_hint():
		return
	get_window().files_dropped.connect(_on_files_dropped)
	# 帧条贴在状态栏上方占底部一条：等布局稳一帧再让左列 / 右列 / 坐标系让位。
	_reserve_strip.call_deferred()


## 关闭界面控件的**焦点导航**：Tab / 方向键不再在控件之间跳焦点（Tab 留给"模型 / 布局"切换）。
## 文本框（LineEdit / TextEdit / SpinBox）除外 —— 它们要能聚焦输入；对话框窗口整棵跳过（自带焦点）。
func _disable_focus(node: Node) -> void:
	if node is Window:
		return
	if node is Control:
		var c := node as Control
		if not (c is LineEdit or c is TextEdit or c is SpinBox):
			c.focus_mode = Control.FOCUS_NONE
	for ch in node.get_children():
		_disable_focus(ch)


## 装配三个界面面板并接线。面板只发"用户想干什么"的信号，**不收会话**：
## 于是界面层永远不碰编辑逻辑，换视口（独立窗口 → Dock 内嵌）时面板一行都不用改。
## （状态栏是例外：它要读会话才能显示工具与撤销栈，所以在 _install 里注入 session。）
func _build_ui() -> void:
	_toolbar = QVoxelierToolbar.new()
	_toolbar.name = "Toolbar"
	add_child(_toolbar)

	# 右侧整栏背景：把抽屉里的浮板连成一条完整侧栏，3D 不从面板缝隙里漏出来。
	# 先入树压在所有面板之下，只作背景不吃事件。（左列是独立图标按钮，不需要这条。）
	_right_rail = _make_rail(true)
	add_child(_right_rail)
	_toolbar.new_requested.connect(request_new)
	_toolbar.open_requested.connect(request_open)
	_toolbar.save_requested.connect(save_project)
	_toolbar.save_as_requested.connect(save_project_as)
	_toolbar.export_mesh_requested.connect(export_mesh)
	_toolbar.import_model_requested.connect(request_import_model)
	_toolbar.render_requested.connect(_toggle_render_popup)
	_toolbar.undo_requested.connect(_undo)
	_toolbar.redo_requested.connect(_redo)
	_toolbar.frame_requested.connect(func(): frame_view(); hud.flash("已取景"))
	_toolbar.zoom_requested.connect(func(steps: float): camera.zoom_by_steps(steps))
	# 镜头 / 网格线原在视口左下的「视图栏」，随该栏一并移除后并进顶栏；标准视角交给右下坐标系。
	_toolbar.lens_toggled.connect(func(ortho: bool):
		_set_lens(QVoxelViewCamera.Lens.ORTHO if ortho else QVoxelViewCamera.Lens.PERSPECTIVE))
	_toolbar.grid_lines_toggled.connect(_set_grid_lines)
	# 两块浮层都锚在右上角，开一块就关另一块 —— 互斥与按钮回弹都收在 _set_*_visible 里，
	# 免得"界面开着日志、按钮却显示说明"这类不一致散落在两个 connect 里。
	_toolbar.help_toggled.connect(_set_legend_visible)
	_toolbar.log_toggled.connect(_set_log_visible)

	_tools = QVoxelierTools.new()
	_tools.name = "Tools"
	add_child(_tools)
	# 工具列排在调色板列的右边（最左一列是调色板）。
	_tools.position.x = QVoxelUi.space_m() + QVoxelUi.palette_width() + QVoxelUi.space_m()
	_tools.tool_selected.connect(_set_tool)

	# 上下文选项条：只显示当前工具用得到的选项（笔刷 / 形态 / 对称 / 选区动作）。
	# 与左列工具条分工 —— 左列选工具，本条随工具给出操作三态与参数。
	_context = QVoxelierContextBar.new()
	_context.name = "ContextBar"
	add_child(_context)
	_context.op_selected.connect(_set_op)
	_context.brush_step.connect(_step_brush)
	_context.brush_scale_requested.connect(_scale_brush)
	_context.brush_shape_selected.connect(_set_brush_shape)
	_context.symmetry_toggled.connect(_set_symmetry_axis)
	# 选区面板的五个按钮共用一条信号（带动作 id）—— 面板不必为每个动作各开一条连接。
	_context.selection_action.connect(_on_selection_action)
	_context.select_criterion_changed.connect(_set_select_criterion)

	_palette = QVoxelierPalette.new()
	_palette.name = "Palette"
	add_child(_palette)
	_palette.material_selected.connect(_set_material)
	_palette.add_material_requested.connect(_add_material)

	# 朝向指示器要读相机基，故注入相机实例（它不持有相机，只是借来看一眼 —— see 类文档）。
	_gizmo = QVoxelierGizmo.new()
	_gizmo.name = "Gizmo"
	add_child(_gizmo)
	_gizmo.camera = camera
	# 网格背景面要知道相机朝哪，才能把"当前作为背景的那几个面"画成格线。
	grid_floor.camera = camera
	_gizmo.view_requested.connect(_apply_view)
	# 盘上拖拽 = 自由旋转（点击轴尖仍是切视图，见 QVoxelierGizmo._gui_input 的判型时机）。
	_gizmo.orbit_requested.connect(func(rel: Vector2) -> void:
		camera.orbit_by_pixels(rel))

	# 右侧抽屉：上「层级」+ 下「属性」。
	_dock = QVoxelierDock.new()
	_dock.name = "Dock"
	add_child(_dock)

	# 层级树：唯一的层级入口，固定在右列**上方**。
	_tree_section = QVoxelierTreeSection.new()
	_tree_section.node_selected.connect(_on_tree_selected)
	_tree_section.model_add_requested.connect(_sess.add_model)
	_tree_section.group_add_requested.connect(_sess.add_group)
	_tree_section.node_remove_requested.connect(_sess.remove_node)
	_tree_section.node_visible_changed.connect(_sess.set_node_visible)
	_tree_section.node_locked_changed.connect(_sess.set_node_locked)
	_tree_section.node_rename_requested.connect(_sess.rename_node)
	_tree_section.rename_begin_requested.connect(_begin_rename)
	_tree_section.node_move_requested.connect(_sess.move_node)
	_dock.add_outliner(_tree_section)

	# ── 属性页签 ── 顺序即页签顺序；App 按当前选择自动切到对应那一页。
	_color_section = QVoxelierColorSection.new()
	_color_section.edit_began.connect(_begin_material_edit)
	_color_section.color_changed.connect(_live_color)
	_color_section.pbr_changed.connect(_live_pbr)
	_color_section.edit_ended.connect(_end_material_edit)
	_color_section.eyedropper_toggled.connect(_set_eyedropper)
	_color_section.add_material_requested.connect(_add_material)
	_color_section.import_requested.connect(func(): _palette_import_dialog.popup_centered_ratio(0.7))
	_color_section.export_requested.connect(func(): _palette_export_dialog.popup_centered_ratio(0.7))
	_dock.add_property(_color_section)

	# 对象：显示当前在层级里选中的节点的数据；改名 / 可见 / 锁定走与树同一条会话入口。
	_object_section = QVoxelierObjectSection.new()
	_object_section.rename_requested.connect(_sess.rename_node)
	_object_section.visible_changed.connect(_sess.set_node_visible)
	_object_section.locked_changed.connect(_sess.set_node_locked)
	_object_section.offset_changed.connect(_set_node_offset)
	_object_section.resize_requested.connect(_resize_model)
	_object_section.rotation_changed.connect(_set_node_rotation)
	_dock.add_property(_object_section)

	# 生成：选程序化算子 + 参数 + 合并方式，一次性烘焙进当前模型。

	# 底部时间轴：常驻一行，显示当前模型的帧并驱动播放。
	_timeline = QVoxelierTimeline.new()
	_timeline.name = "Timeline"
	add_child(_timeline)
	_timeline.frame_selected.connect(_select_frame)
	_timeline.append_frame_requested.connect(_append_frame)
	_timeline.insert_frame_requested.connect(_insert_frame)
	_timeline.remove_frame_requested.connect(func():
		if session != null and session.object != null and session.object.is_animated():
			_remove_frame(session.object.active_frame))
	_timeline.move_frame_requested.connect(_move_frame)
	_timeline.loop_toggled.connect(func(on: bool): _set_anim_meta(&"anim_loop", on, "改循环"))
	_timeline.duration_edit_began.connect(_begin_frame_duration)
	_timeline.duration_changed.connect(_live_frame_duration)
	_timeline.duration_edit_ended.connect(_end_frame_duration)
	_timeline.fps_changed.connect(func(fps: int): _set_anim_meta(&"anim_fps", fps, "改帧率"))
	_timeline.tags_changed.connect(func(tags: Array): _set_anim_meta(&"anim_tags", tags, "改标签"))
	# 渲染（原「快照」）：离屏出图，做成顶栏一个按钮弹出的浮层（不再是右列的一页）。
	_snapshot_section = QVoxelierSnapshotSection.new()
	_snapshot_section.save_requested.connect(_request_snapshot_save)
	_snapshot_popup = PopupPanel.new()
	_snapshot_popup.name = "RenderPopup"
	_snapshot_popup.theme = QVoxelUi.theme()
	add_child(_snapshot_popup)
	_snapshot_popup.add_child(_snapshot_section)

	# 选区线框：与网格地板同挂 model 下（同一套"体素单位 × voxel_scale"换算），故两者天然对齐。
	# 它是纯显示物，不参与拾取（拾取只看体素与地板），故没有碰撞体。
	_selection_box = QVoxelSelectionBox.new()
	_selection_box.name = "Selection"
	model.add_child(_selection_box)

	_move_gizmo = QVoxelierMoveGizmo.new()
	_move_gizmo.name = "MoveGizmo"
	model.add_child(_move_gizmo)

	_ghost = QVoxelPreviewMesh.new()
	_ghost.name = "HoverPreview"
	model.add_child(_ghost)

	# 状态栏与两块浮层都归 Hud 所有，而 Hud 是场景里预摆的（排在子节点最前 = 画在最底下），
	# 后建的右列抽屉会整条压住浮层 —— 实测「操作说明」右半边被「颜色」面板盖掉。
	# 把它挪到最后一个子节点位置，浮层与提示才浮得住（左右两条侧栏的高度都已避开状态栏，
	# 不会反过来被它遮住）。
	move_child(hud, -1)

	# 右列：抽屉宽度随内容变，视口里的浮层（HUD 的说明 / 日志、朝向指示器）都要让出它。
	# 目标值都是**布局算出来的**（不是常量），故挂信号 + 装配末尾补一次初值：
	# 邻面板的矩形一般要到下一帧最小尺寸结算完才定下来。
	var sync_right := func() -> void:
		_sync_rails()
		# 三者共用一个宽度而不是各算各的 —— 状态栏"避开右列"与坐标轴"避开状态栏"从此是一个数。
		hud.set_right_inset(_right_inset)
		_gizmo.right_inset = _right_inset
	_tools.resized.connect(_sync_rails)   # 工具坞按内容变宽时，左栏背景也要跟
	_dock.resized.connect(sync_right)
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
	if _timeline != null:
		_timeline.stop_playback()
	_material_id = 1
	_stroke = false
	_gizmo_active = false
	_op = QVoxelBrushTool.Op.ADD
	_stroke_op = QVoxelBrushTool.Op.ADD
	_hover_op = QVoxelBrushTool.Op.ADD
	_tool_kind = ToolKind.BRUSH
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
	_timeline.stop_playback()
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
	_move_gizmo.voxel_scale = model.voxel_scale
	_move_gizmo.origin = session.data.center_offset if session.data != null else Vector3.ZERO
	# 预览与显示层同一份偏移（导入资产的 center_offset）：否则预览与体素错开。
	_ghost.origin = session.data.center_offset if session.data != null else Vector3.ZERO
	# 摆放：体素在数据层是**本地**坐标，节点变换（含祖先）由渲染器承载。model 的子树（地板 /
	# 选区 / gizmo / 预览）都跟着它走，故只在 model 上设一次变换即可整体归位。
	var xf := _display_transform(session.object, model.voxel_scale)
	if not model.transform.is_equal_approx(xf):
		model.transform = xf
	_rebuild_layout_overlay()
	hud.session = session


## 节点的世界摆放 → 渲染器变换：位置换算到世界单位（× voxel_scale），旋转直接沿用。
## 体素几何本身已按 voxel_scale 生成，故这里只承载"平移到哪、转到什么朝向"。
func _display_transform(node: QVoxelNode, scale: float) -> Transform3D:
	if world == null or node == null:
		return Transform3D.IDENTITY
	var xf := world.world_transform(node)
	return Transform3D(xf.basis, xf.origin * scale)


## 会话数据变了 → 重挂显示层 + 重建视口 + 一处刷新界面。
## 【为什么这是唯一的刷新出口】改世界、切对象、撤销 / 重做、改材质、改帧都会发这条信号。
## 分散写"谁该刷什么"迟早漏一处 —— 表现为"按钮高亮着、提示还写着上一个工具"。
## `_refresh_hud` 自己会带上右列三组（见 _refresh_panels），故这里不再逐个面板点名。
func _on_session_changed() -> void:
	_attach_active()
	_rebuild_view()
	_refresh_hud()


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
	# 活动对象由 model 渲染，其唤醒回调必须指回 model.request_update。
	# 【曾经的 bug】对象先当非活动（回调指向它的临时渲染器）、再切回活动时，回调仍指向那个
	# 已释放的临时渲染器 → 撤销后 _wake_renderer 打到野对象 → 网格不重建（画面看着没撤销）。
	session.request_render_update = model.request_update

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
			r.visibility_mode = VoxelRenderer.VisibilityMode.FULL
			r.data = s.data
			s.request_render_update = r.request_update
			_display[id] = r
		# 摆放由渲染器承载（数据层是本地坐标）：每次刷新都同步一次（改名 / 移动 / 换尺寸都会进来）。
		r.voxel_scale = model.voxel_scale
		r.transform = _display_transform(s.object, model.voxel_scale)
		r.visible = _sess.node_visible(s.object)

	model.visible = _sess.node_visible(session.object)


## 取景：把"有东西可落笔"的范围落进画面（新建 / 打开 / Home 键）。
## 空图时唯一能落笔的是网格底面（`QVoxelGridPick` 的落笔面），所以对准底面 —— 若照搬"框住整块
## 32³ 网格"，默认 25° 视角下屏幕上半尽是空体积，点正中只会换来一句"这儿落不了笔"。
func frame_view() -> void:
	if session == null:
		return
	var g := Vector3(session.output_size()) * model.voxel_scale
	# 取景对准**整块网格盒的中心**（而不是地板中心）—— 背景面有地板也有侧墙，盒子中心才是视觉中心。
	camera.frame_aabb(model.global_transform * AABB(Vector3.ZERO, g), true)
	_pending_center = false


## 居中补偿：已停用（见 frame_view 的说明）。保留空实现以兼容调用点。
func _apply_view_center() -> void:
	_pending_center = false


## 取景整个世界：所有模型（按各自摆放）联合包围盒的中心。布局模式的聚焦用。
func frame_world() -> void:
	if world == null:
		return
	var vs := world.voxel_size()
	var any := false
	var lo := Vector3.ZERO
	var hi := Vector3.ZERO
	for m in world.all_models():
		var sz := QVoxelEvalEngine.output_grid_size(m)
		if sz.x <= 0 or sz.y <= 0 or sz.z <= 0:
			continue
		var bb := _world_aabb(world.world_transform(m), Vector3.ZERO, Vector3(sz))
		if not any:
			lo = bb.position
			hi = bb.end
			any = true
		else:
			lo = Vector3(minf(lo.x, bb.position.x), minf(lo.y, bb.position.y), minf(lo.z, bb.position.z))
			hi = Vector3(maxf(hi.x, bb.end.x), maxf(hi.y, bb.end.y), maxf(hi.z, bb.end.z))
	if not any:
		frame_view()
		return
	camera.frame_aabb(AABB(lo * vs, (hi - lo) * vs), true)


## 把一块"局部盒 [lo, lo+size)"按变换 xf 摆进世界后的轴对齐包围盒（体素单位）。
func _world_aabb(xf: Transform3D, lo: Vector3, size: Vector3) -> AABB:
	var mn := Vector3(INF, INF, INF)
	var mx := Vector3(-INF, -INF, -INF)
	for cx in [lo.x, lo.x + size.x]:
		for cy in [lo.y, lo.y + size.y]:
			for cz in [lo.z, lo.z + size.z]:
				var p := xf * Vector3(cx, cy, cz)
				mn = Vector3(minf(mn.x, p.x), minf(mn.y, p.y), minf(mn.z, p.z))
				mx = Vector3(maxf(mx.x, p.x), maxf(mx.y, p.y), maxf(mx.z, p.z))
	return AABB(mn, mx - mn)


## 布局叠加层：每个模型的不透明包围盒线框 + 世界中心十字。仅布局模式可见，随数据变化重画。
func _rebuild_layout_overlay() -> void:
	if _layout_overlay == null:
		_layout_overlay = Node3D.new()
		_layout_overlay.name = "LayoutOverlay"
		add_child(_layout_overlay)
	for c in _layout_overlay.get_children():
		_layout_overlay.remove_child(c)
		c.queue_free()
	var on := _edit_mode == 1 and world != null
	_layout_overlay.visible = on
	if not on:
		return
	var vs := world.voxel_size()
	for m in world.all_models():
		var sz := QVoxelEvalEngine.output_grid_size(m)
		if sz.x <= 0 or sz.y <= 0 or sz.z <= 0:
			continue
		var bb := _world_aabb(world.world_transform(m), Vector3.ZERO, Vector3(sz))
		# 未选中：透明灰；选中 / 活动：与编辑模式选区线框同色（强调色）。
		var col := Color(0.65, 0.65, 0.70, 0.35)
		if _layout_sel.has(m.model_id) or (session != null and m == session.object):
			col = Color(QVoxelUi.ACCENT, 0.95)
		_layout_overlay.add_child(_line_box(AABB(bb.position * vs, bb.size * vs), col))
	# 世界中心十字（表示原点位置）。
	_layout_overlay.add_child(_cross_lines(maxf(vs * 4.0, 0.4), Color(0.95, 0.8, 0.3)))


## 布局模式：射线点选模型（对每个模型的包围盒做射线求交，取最近的）。无命中返回 null。
func _pick_layout_model(screen: Vector2) -> QVoxelModel:
	if world == null:
		return null
	var ro := camera.project_ray_origin(screen)
	var rd := camera.project_ray_normal(screen)
	var vs := world.voxel_size()
	var best: QVoxelModel = null
	var best_t := INF
	for m in world.all_models():
		var sz := QVoxelEvalEngine.output_grid_size(m)
		if sz.x <= 0 or sz.y <= 0 or sz.z <= 0:
			continue
		var bb := _world_aabb(world.world_transform(m), Vector3.ZERO, Vector3(sz))
		var t := _ray_aabb(ro, rd, AABB(bb.position * vs, bb.size * vs))
		if t >= 0.0 and t < best_t:
			best_t = t
			best = m
	return best


## 射线 × 轴对齐盒（slab 法）：返回进入参数 t（>=0），无交返回 -1。
func _ray_aabb(ro: Vector3, rd: Vector3, bb: AABB) -> float:
	var tmin := 0.0
	var tmax := INF
	for a in 3:
		var o := ro[a]
		var d := rd[a]
		if absf(d) < 1e-8:
			if o < bb.position[a] or o > bb.end[a]:
				return -1.0
		else:
			var t1 := (bb.position[a] - o) / d
			var t2 := (bb.end[a] - o) / d
			if t1 > t2:
				var tmp := t1
				t1 = t2
				t2 = tmp
			tmin = maxf(tmin, t1)
			tmax = minf(tmax, t2)
			if tmin > tmax:
				return -1.0
	return tmin


## 一个轴对齐盒的 12 条棱（线段，与编辑模式的选区线框同一套观感）。
func _line_box(bb: AABB, col: Color) -> MeshInstance3D:
	var c := []
	for i in 8:
		c.append(bb.position + Vector3(
				bb.size.x if (i & 1) else 0.0,
				bb.size.y if (i & 2) else 0.0,
				bb.size.z if (i & 4) else 0.0))
	var edges := [[0, 1], [2, 3], [4, 5], [6, 7], [0, 2], [1, 3], [4, 6], [5, 7],
			[0, 4], [1, 5], [2, 6], [3, 7]]
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for e in edges:
		im.surface_add_vertex(c[e[0]])
		im.surface_add_vertex(c[e[1]])
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	mi.material_override = _line_material(col)
	return mi


## 世界中心十字：三根过原点的短轴（线段）。
func _cross_lines(r: float, col: Color) -> MeshInstance3D:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for axis in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
		im.surface_add_vertex(-axis * r)
		im.surface_add_vertex(axis * r)
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	mi.material_override = _line_material(col)
	return mi


## 线材质：不受光、可透明、不裁剪、不做深度测试 —— 与编辑模式选区线框同一套。
func _line_material(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = col
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = true
	return m


# 布局多选 / 框选

## 当前布局选中的模型（空选区时退化为"当前对象"，与移动默认整体一致）。
func _layout_models() -> Array[QVoxelModel]:
	var out: Array[QVoxelModel] = []
	if world == null:
		return out
	if _layout_sel.is_empty():
		if session != null and session.object != null:
			out.append(session.object)
		return out
	for m in world.all_models():
		if _layout_sel.has(m.model_id):
			out.append(m)
	return out


func _layout_capture_offsets() -> Dictionary:
	var d := {}
	for m in _layout_models():
		d[m.model_id] = m.offset
	return d


func _layout_capture_xfs() -> Dictionary:
	var d := {}
	for m in _layout_models():
		d[m.model_id] = m.local_transform
	return d


## 模型父组的**世界变换**（顶层模型的父为世界 → 恒等）。
func _parent_world(m: QVoxelModel) -> Transform3D:
	if world == null:
		return Transform3D.IDENTITY
	var p := world.find_parent(m)
	return world.world_transform(p) if p != null else Transform3D.IDENTITY


## 布局选区的**共同中心**（世界体素坐标）—— 按给定的改前变换算，旋转绕它整体转。
func _layout_pivot_from(xfs: Dictionary) -> Vector3:
	var sum := Vector3.ZERO
	var n := 0
	for m in _layout_models():
		var base: Transform3D = xfs.get(m.model_id, m.local_transform)
		sum += (_parent_world(m) * base) * _node_center_voxel(m)
		n += 1
	return sum / float(maxi(n, 1))


func _layout_pivot_world() -> Vector3:
	return _layout_pivot_from(_layout_capture_xfs())


## 共同中心在**活动模型本地**体素坐标（gizmo 是 model 的子节点，位置要用这个）。
func _layout_gizmo_center() -> Vector3:
	if world == null or session == null:
		return Vector3.ZERO
	var p := _layout_pivot_world() * model.voxel_scale
	var local := model.global_transform.affine_inverse() * p
	return local / maxf(model.voxel_scale, 1e-6)


## 布局拖拽期间实时更新被选中模型的渲染器变换（活动对象用 model，其余用 _display）。
func _update_layout_renderers() -> void:
	for m in _layout_models():
		var r: VoxelRenderer = null
		if session != null and m == session.object:
			r = model
		else:
			r = _display.get(m.model_id)
		if r != null:
			r.transform = _display_transform(m, model.voxel_scale)
	_rebuild_layout_overlay()


## 布局点选：replace / Shift 加选 / Ctrl 减选。
func _layout_select(m: QVoxelModel, add: bool, remove: bool) -> void:
	if remove:
		_layout_sel.erase(m.model_id)
	elif add:
		_layout_sel[m.model_id] = true
	else:
		_layout_sel.clear()
		_layout_sel[m.model_id] = true
	_activate(m.model_id)
	_on_tree_selected(m)
	_rebuild_layout_overlay()
	_refresh_hud()


func _box_panel_node() -> Panel:
	if _box_panel == null:
		_box_panel = Panel.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(1.0, 0.55, 0.2, 0.12)
		sb.border_color = Color(1.0, 0.55, 0.2, 0.9)
		sb.set_border_width_all(1)
		_box_panel.add_theme_stylebox_override("panel", sb)
		_box_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_box_panel)
	return _box_panel


func _show_box_rect() -> void:
	_box_panel_node().visible = true
	_update_box_rect()


func _update_box_rect() -> void:
	var p := _box_panel_node()
	var r := Rect2(_box_start, _box_end - _box_start).abs()
	p.position = r.position
	p.size = r.size


func _hide_box_rect() -> void:
	if _box_panel != null:
		_box_panel.visible = false


## 结束框选：把投影中心落在矩形内的模型纳入选区（`add` = Shift 加选，否则替换）。
func _end_box_select(add := false) -> void:
	_box_select = false
	_hide_box_rect()
	var r := Rect2(_box_start, _box_end - _box_start).abs()
	if r.size.x < 4.0 or r.size.y < 4.0 or world == null:
		return
	var vs := world.voxel_size()
	if not add:
		_layout_sel.clear()
	for m in world.all_models():
		var sz := QVoxelEvalEngine.output_grid_size(m)
		if sz.x <= 0 or sz.y <= 0 or sz.z <= 0:
			continue
		var bb := _world_aabb(world.world_transform(m), Vector3.ZERO, Vector3(sz))
		var c := (bb.position + bb.end) * 0.5 * vs
		if r.has_point(camera.unproject_position(c)):
			_layout_sel[m.model_id] = true
	_rebuild_layout_overlay()
	_refresh_hud()


func _process(_delta: float) -> void:
	# 条件不满足就不清标记 —— 下一帧重试，直到 inset 与视口都就绪。
	if _pending_center:
		_apply_view_center()
	_update_gizmo_size()


## gizmo 手柄**屏幕大小恒定**：几何缩放系数按相机到 gizmo 中心的距离设定（世界尺寸 ∝ 距离）。
func _update_gizmo_size() -> void:
	if _move_gizmo == null or not _move_gizmo.visible or session == null:
		return
	var vs := maxf(model.voxel_scale, 1e-4)
	var d := camera.global_position.distance_to(_move_gizmo.center_global())
	_move_gizmo.set_size_factor(clampf(d * 0.06 / vs, 0.15, 40.0))


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
	# 左列 = 最左的调色板列 + 工具列。inset 要含两者，可见区才让得对。
	_left_inset = (QVoxelUi.space_m() + QVoxelUi.palette_width() + QVoxelUi.space_m()
			+ _tools.size.x + QVoxelUi.space_m())
	_right_inset = _dock.size.x + QVoxelUi.space_m() + QVoxelUi.space_s()
	_right_rail.offset_left = -_right_inset
	# 上下文选项条横跨可见区（两侧让开左右栏），故也吃同一组 inset。
	if _context != null:
		_context.set_insets(_left_inset, _right_inset)
	# 宽度变了 = 可见区中心也变了。补差额（只在取过景之后有欠账，别的场景 delta 为 0）。
	_apply_view_center()


# 输入翻译

## 在 GUI 之前截获 Tab：**先于**控件的焦点导航（`ui_focus_next`）消费掉它，
## 于是 Tab 只用于"模型编辑 / 布局"层级切换，不会在界面控件之间乱跳焦点。
func _input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or session == null:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_TAB:
		_set_edit_mode(1 - _edit_mode)
		get_viewport().set_input_as_handled()


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
			# 触摸屏没有中键：单指拖动画/擦，单指拖动**空白处**即转视角，双指拖动即平移。
			# 平板上的单指拖动经过 emulate_mouse_from_touch 就是这里的 LEFT，不需要另写触摸分支。
			if e.pressed:
				if e.alt_pressed:
					# Alt+拖 = 旋转：老肌肉记忆的一条加速器，与空白处拖动同一条路径。
					_nav_key = &"left"
					_orbit = true
				else:
					# 移动**只经坐标轴**：先试着按住轴拖拽；没点中轴就转视角（不会误移）。
					# 其余工具：命中可落笔处 → 落笔；落在空白处 → 拖动即旋转视角。
					# 自定义笔刷是"点一下"的工具（不拖拽），走 _stamp_at 而不是笔画手势。
					if _edit_mode == 1:
						# 布局：先试 gizmo；否则**点中模型即选中**（任何工具下都行，Shift 加 / Ctrl 减）；
						# 空处：只有「选择」工具才框选，其它工具（默认「移动」）拖动即转视角。
						if _gizmo_begin(e.position):
							pass
						else:
							var lm := _pick_layout_model(e.position)
							if lm != null:
								_layout_select(lm, e.shift_pressed, e.ctrl_pressed)
							elif session.tool.mode == QVoxelBrushTool.Mode.SELECT:
								_box_select = true
								_box_start = e.position
								_box_end = e.position
								_show_box_rect()
							else:
								_nav_key = &"left"
								_orbit = true
					elif _tool_kind == ToolKind.BRUSH and session.tool.mode == QVoxelBrushTool.Mode.MOVE:
						if not _gizmo_begin(e.position):
							_nav_key = &"left"
							_orbit = true
					elif not _pick_at(e.position, _op).valid():
						_nav_key = &"left"
						_orbit = true
					elif _tool_kind != ToolKind.BRUSH:
						_stamp_at(e.position)
					else:
						# 选区手势：Shift 加选 / Ctrl 减选（在按下那一刻定死）。
						if session.tool.selection_mode():
							session.selection_combine = 2 if e.ctrl_pressed else (1 if e.shift_pressed else 0)
						_begin_stroke(e.position, QVoxelBrushTool.Op.REMOVE if e.shift_pressed else _op)
			elif _box_select:
				_end_box_select(e.shift_pressed)
			elif _gizmo_active:
				_gizmo_end()
			elif _nav_key == &"left":
				_nav_key = &""
				_orbit = false
				_pan = false
			else:
				_end_stroke()
		MOUSE_BUTTON_RIGHT:
			# 右键 = 临时移除，只对笔刷有意义（生成 / 风化是单击工具；布局模式不落笔）。
			if _edit_mode == 1 or _tool_kind != ToolKind.BRUSH:
				return
			if e.pressed:
				_begin_stroke(e.position, QVoxelBrushTool.Op.REMOVE)
			else:
				_end_stroke()
		MOUSE_BUTTON_MIDDLE:
			# 中键拖动 = 任意位置旋转；Shift+中键 = 平移。与左右键（画 / 擦 / 空白处旋转）
			# 互不干扰，于是"边画边转着看"不需要先切模式 —— 建模里这一步每天都在用。
			if e.pressed:
				_nav_key = &"middle"
				_pan = e.shift_pressed
				_orbit = not e.shift_pressed
			elif _nav_key == &"middle":
				_nav_key = &""
				_orbit = false
				_pan = false
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
			# 裸滚轮**什么都不做** —— 触摸板双指滑动就是滚轮事件，之前映射成平移/俯仰都太容易
			# 误触（随手一滑视角就动）。缩放一律走 Ctrl+滚轮；俯仰留给 Alt+滚轮与中键/空白拖拽。
			var up := e.button_index == MOUSE_BUTTON_WHEEL_UP
			if e.ctrl_pressed:
				camera.zoom_by_steps(1.0 if up else -1.0)
			elif e.alt_pressed:
				camera.pitch_by_degrees(-4.0 if up else 4.0)
		MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT:
			# 水平滚轮同样忽略（触摸板双指左右滑）。
			pass


## 把手势层累积的导航量接到相机上（每喂完一个手势事件调用一次）。
func _flush_gesture() -> void:
	# 第二指落下即打断进行中的笔画 —— 双指是导航，不该顺带画一笔。
	# 只在笔画中途取消；非笔画时不动 _cancel，它还有"退出选区"的语义。
	if _gesture.active and _stroke:
		_cancel()
	if _gesture.pan_pending != Vector2.ZERO:
		camera.pan_by_pixels(_gesture.pan_pending)
	if not is_equal_approx(_gesture.zoom_pending, 1.0):
		camera.zoom_by_ratio(_gesture.zoom_pending)
	_gesture.take()


func _on_mouse_motion(e: InputEventMouseMotion) -> void:
	if _box_select:
		_box_end = e.position
		_update_box_rect()
		return
	if _gizmo_active:
		_gizmo_update(e.position)
		return
	if _stroke:
		session.drag(_pick_at(e.position, _stroke_op))
		_refresh_cursor(e.position)
	elif _orbit:
		camera.orbit_by_pixels(e.relative)
	elif _pan:
		camera.pan_by_pixels(e.relative)
	else:
		_hover_op = QVoxelBrushTool.Op.REMOVE if e.shift_pressed else _op
		_update_gizmo_hover(e.position)
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
		export_mesh()
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
		# E = 在「添加 / 移除」之间切换操作模式（平板点顶部选项条，桌面按 E，同一份状态）。
		_set_op(QVoxelBrushTool.Op.ADD if _op == QVoxelBrushTool.Op.REMOVE else QVoxelBrushTool.Op.REMOVE)
	elif _numpad_view(e.keycode):
		pass
	else:
		# 数字键 1..7 切工具（调色板不再占用数字键）。
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
func _pick_at(screen: Vector2, op: int) -> QVoxelBrushTool.Pick:
	var scale := model.voxel_scale
	var origin: Vector3 = model.to_local(camera.project_ray_origin(screen)) / scale
	var dir: Vector3 = model.global_transform.basis.inverse() * camera.project_ray_normal(screen)
	# 只允许落在"当前可见的背景面"上（与边框显示一致：有边框的面才作画笔地面）。
	var info := QVoxelGridPick.hit(session.data, origin, dir, session.output_size(), 100.0,
			grid_floor.visible_faces())
	return session.pick_from_hit(info, op, _material_id)


# 手势

func _begin_stroke(screen: Vector2, op: int) -> void:
	if _sess.node_locked(session.object):
		hud.flash("这一层已锁定：先在右侧「图层」里解锁")
		return
	# 预览中落笔 = 这一笔会画在"播放头正好停住的那一帧"上，而播放头还在动 —— 用户根本
	# 说不清自己画到了第几帧。先停下播放再落笔（停在哪一帧就是哪一帧，看得见）。
	_timeline.stop_playback()
	_stroke_op = op
	if not session.begin(_pick_at(screen, op)):
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
	_refresh_hud()


## "这一笔没改动"的原因随工具而不同：画笔是网格外 / 同色覆盖，选区是"没框到网格内的格子"。
## 提示词照抄画笔那套会让用户以为选区坏了（其实只是原地没动）。
func _no_change_hint(picking: bool) -> String:
	if picking:
		return "选区没变（没框到网格内的格子）"
	return "这一笔没有改动（网格外 / 同色覆盖 / 没东西可擦）"


func _cancel() -> void:
	_gizmo_active = false
	if _stroke:
		session.cancel()
		_stroke = false
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


## 切工具：工具坞的按钮与热键共用这一处 —— 于是"按钮高亮"永远是实况的投影，而不是第二份状态。
## 自定义笔刷是"工具"而非笔刷模式，故只切 _tool_kind（笔刷模式才写回 session.tool）。
func _set_tool(mode: int) -> void:
	if mode == QVoxelierTools.TOOL_CUSTOM:
		_tool_kind = ToolKind.CUSTOM
		hud.flash("工具：自定义笔刷（把复制出的体素当笔刷，点击盖章）")
		_refresh_hud()
		return
	_tool_kind = ToolKind.BRUSH
	session.tool.set_mode(mode)
	hud.flash("工具：" + session.tool.label())
	_refresh_hud()


## 当前工具的 id（供工具坞高亮）：笔刷模式或其枚举值，自定义笔刷用 TOOL_CUSTOM。
func _current_tool_id() -> int:
	return QVoxelierTools.TOOL_CUSTOM if _tool_kind == ToolKind.CUSTOM else session.tool.mode


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
	# 选中材质 → 属性区自动切到「颜色」（"选了什么就看什么"）。
	if _dock != null:
		_dock.show_property_by_title("颜色")
	_refresh_hud()


## 切换操作三态（顶部选项条与 E 键共用）。按钮高亮由 _refresh_hud 投影，界面不留副本。
func _set_op(op: int) -> void:
	if _op == op:
		return
	_op = op
	_hover_op = op
	hud.flash("操作：%s" % QVoxelBrushTool.OPS[op].text)
	_refresh_hud()


## 切快速选区判据（顶部选项条：同色 / 相连）。
func _set_select_criterion(by_color: bool) -> void:
	_select_by_color = by_color
	if session != null:
		session.select_by_color = by_color
	hud.flash("快速选区：%s" % ("同色相连" if by_color else "几何相连"))


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


# 自定义笔刷（右侧抽屉·「笔刷」面板）
# 拿一个做好的模型当图章：抓成图案 → 在视口里**点哪盖哪**，一次点击 = 一条可撤销命令。
# 合并方式由操作三态（添加 / 移除 / 上色）决定。

## 在点击处盖一次自定义笔刷（图章），图案取自剪贴板。center = 命中格（无入射面时退回落笔格）。
func _stamp_at(screen: Vector2) -> void:
	if world == null or session == null:
		return
	if _sess.node_locked(session.object):
		hud.flash("这一层已锁定：先在右侧「层级」里解锁")
		return
	# 自定义笔刷 = 剪贴板里的体素（复制 = 把它做成笔刷）。不需要额外的"抓取"操作。
	var clip := session.clipboard
	if clip.is_empty():
		hud.flash("先框选并复制一块体素（复制出来的那块就是笔刷）")
		return
	var pick := _pick_at(screen, _op)
	if not pick.valid():
		hud.flash("这儿落不了：把光标放到网格或已有体素上")
		return
	_timeline.stop_playback()
	var center := pick.hit if pick.hit != Vector3i.MIN else pick.place
	var obj := session.object
	var cmd := QVoxelEditCommand.begin(obj, session.edit_frame())
	cmd.label_override = "盖笔刷"
	var pat := {"cells": clip.cells(), "mats": clip.materials(), "size": clip.size()}
	var n := QVoxelStamp.stamp(cmd, obj, pat, center, _op, _material_id)
	if not cmd.commit() or n <= 0:
		hud.flash("这一下没有改动（空白 / 越界 / 同色）")
		return
	session.history.push(cmd)
	session.rebuild()
	_sess.mark_dirty()
	_rebuild_view()
	_refresh_hud()
	hud.flash("已盖 %d 个体素" % n)


# 视图（镜头 / 标准视角 / 网格线）

## 切镜头（视图栏「透视 / 正交」与小键盘 5 共用）。正交不是"另一种画风"：
## 没有近大远小才量得准比例、才对得齐体素 —— 体素建模里它是刚需而不是可选项。
func _set_lens(mode: int) -> void:
	camera.set_lens(mode)
	_toolbar.set_lens(mode == QVoxelViewCamera.Lens.ORTHO)
	hud.flash("镜头：%s" % QVoxelViewCamera.LENS_NAMES[mode])


## 切标准视角。**三个入口共用这一条路径**：朝向指示器点轴、小键盘、视图模式 ——
## 回显由坐标系自身按相机基呈现，故这里不必再维护一处"当前预设"。
func _apply_view(view: int) -> void:
	camera.apply_view(view)
	hud.flash("%s视图" % QVoxelViewCamera.VIEW_NAMES[view])


## 网格线显隐（顶栏开关）。只摘格线、保留外框 —— 外框是"合法范围"的告知，见 QVoxelGridFloor。
func _set_grid_lines(on: bool) -> void:
	grid_floor.set_grid_lines_visible(on)
	_toolbar.set_grid_lines(on)
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
	var loaded := QVoxelProject.load_world(path)
	if loaded == null:
		hud.flash("打不开这个工程（缺失或已损坏）：%s" % path.get_file())
		return false
	if _adopt_world(loaded, path, false) == null:
		hud.flash("这个工程里没有可编辑的对象：%s" % path.get_file())
		return false
	var total := loaded.all_models().size()
	hud.flash("已打开 %s%s" % [path.get_file(),
			"（共 %d 个模型，可在右侧「层级」里切换）" % total if total > 1 else ""])
	return true


## 接管一份世界：取消进行中的手势 → 选可编辑对象 → 装配 → 记工程状态。返回活动对象（失败 null）。
## 【为什么只留一条】打开工程 / 导入模型 / 将来的合并都会换掉整个世界，尾部这几步必须完全一致 ——
## 各抄一份迟早漏掉"取消手势"或"标脏"。提示文案归调用方：三种来源各有各的说法。
func _adopt_world(w: QVoxelWorld, path: String, dirty: bool) -> QVoxelModel:
	if w == null:
		return null
	var obj := QVoxelierSession.pick_editable(w)
	if obj == null:
		return null
	if _stroke and session != null:
		session.cancel()
	_stroke = false
	_install(w, obj)
	_sess.project_path = path
	if dirty:
		_sess.mark_dirty()
	else:
		_sess.clear_dirty()
	_update_title()
	return obj


## 保存到当前文件：`.qvx` 工程或 `.vox` 模型，由**当前路径的扩展名**决定格式；
## 还没存过盘就转"另存为"。
func save_project() -> void:
	if _stroke:
		session.cancel()
		_stroke = false
	if _sess.project_path.is_empty():
		save_project_as()
		return
	_write_project(_sess.project_path)


## 另存为：弹文件对话框，默认扩展名跟随当前文件类型（打开的是 .vox 就默认存回 .vox）。
func save_project_as() -> void:
	var ext := VoxAsset.VOX_EXTENSION if QVoxelProject.is_vox_path(_sess.project_path) \
			else QVoxelProject.EXTENSION
	_save_dialog.current_file = "%s.%s" % [world.world_name(), ext]
	_save_dialog.popup_centered_ratio(0.7)


func _write_project(path: String) -> bool:
	# `.vox` 有几条绕不过去的硬约束（≤256、24 种朝向、整数平移）：先在写盘前把原因说清楚，
	# 而不是产出一个 MagicaVoxel 打不开、或"看着对了其实整体偏移"的文件。
	var warnings := PackedStringArray()
	if QVoxelProject.is_vox_path(path):
		var report := VoxWriter.check(world)
		if not report["ok"]:
			hud.flash("存不了 .vox：%s" % "；".join(report["reasons"]))
			return false
		warnings = report["warnings"]
	var err := QVoxelProject.save(world, path)
	if err != OK:
		hud.flash("保存失败（错误码 %d）：%s" % [err, path.get_file()])
		return false
	_sess.project_path = path
	_sess.clear_dirty()
	_update_title()
	var note := "" if warnings.is_empty() else "（注意：%s）" % "；".join(warnings)
	hud.flash("已保存 %s%s" % [path.get_file(), note])
	return true


func _on_save_path_selected(path: String) -> void:
	_write_project(QVoxelProject.ensure_extension(path))


# ======= 外部程序化生成接口(脚本 / 运行时 MCP) =======
##
## 供外部以**字符串方法名**调用(`scene.call("script_xxx", ...)`), 于是调用方(QVoxelMCPTools)
## 在编译期**不需要认识 QVoxelierApp**。
## 只放**程序化生成模型**所需: 材质 / 写格(见 QVoxelEditSession.apply_cells) / 存盘 / 统计。
## 编辑类操作(撤销 / 选区 / 剪贴板 / 帧)是给人按界面的, 不是脚本生成所需, 故不放这里。
## 每个入口都复用应用内部同一条时间线/落盘路径, 不新开第二条写入通道。

## 新增材质(颜色 + PBR), 返回材质 ID。与色板"新增材质"按钮同一条命令(可撤销) + 同一次纹理刷新。
func script_add_material(color: Color, metal := 0.0, rough := 0.8) -> int:
	if world == null or session == null:
		return -1
	var cmd := QVoxelPropertyCommand.begin(world, &"materials", null, "新增材质")
	var id := world.add_material(color)
	if cmd.commit():
		session.history.push(cmd)
	world.set_material_scalar(id, &"metal", metal)
	world.set_material_scalar(id, &"rough", rough)
	_sync_material(id)
	_set_material(id)
	return id


## 存到指定路径(.qvx)。复用 _write_project(脏标记/标题/flash 一致), 并在存盘前收尾进行中的笔画。
func script_save(path: String) -> bool:
	if world == null:
		return false
	if _stroke and session != null:
		session.cancel()
		_stroke = false
	return _write_project(QVoxelProject.ensure_extension(path))


## 当前模型统计。
func script_stats() -> Dictionary:
	if world == null or session == null:
		return {}
	var gs := session.output_size()
	return {
		"grid_size": [gs.x, gs.y, gs.z],
		"voxel_count": session.object.count_solid() if session.object != null else 0,
		"material_count": world.materials.size() - 1,
		"objects": _sess.all_sessions().size(),
	}


## 新建空模型(MCP / 脚本入口)：**整体替换**当前世界（网格 grid；ZERO 用场景默认）。
## 与界面"新建"同一条 `new_model` 路径，只是省掉了未保存确认对话框（脚本调用）。
func script_new(grid := Vector3i.ZERO) -> bool:
	new_model(grid)
	return session != null


## 改当前活动模型的分辨率(输出盒尺寸)。保留新旧尺寸交集内的体素, 超出部分丢弃 —— 与对象属性
## 面板的"尺寸"走同一条可撤销命令(_resize_model → QVoxelResizeCommand)。尺寸非法 / 未变返回 false。
func script_resize(size: Vector3i) -> bool:
	if session == null or session.object == null:
		return false
	if size.x <= 0 or size.y <= 0 or size.z <= 0 or size == session.object.grid_size:
		return false
	_resize_model(session.object, size)
	return true


## 导出网格：把当前世界烘成三角网格，写成 glTF 2.0（`.glb`/`.gltf` 由扩展名决定）。
## 与"保存（.qvx）"分开：保存留的是"下次还能接着编辑"的全套，导出只留**烘出来的几何与颜色**。
func export_mesh() -> void:
	_mesh_dialog.current_file = "%s.glb" % world.world_name()
	_mesh_dialog.popup_centered_ratio(0.7)


func _on_mesh_path_selected(path: String) -> void:
	path = _ensure_mesh_ext(path)
	var err := QVoxelMeshExport.export(world, path)
	if err != OK:
		hud.flash("导出失败（错误码 %d）：%s" % [err, path.get_file()])
		return
	hud.flash("已导出网格 %s" % path.get_file())


## 导入模型（path 为空 = 先问参数再选文件；非空 = 拖放进来的，只问参数）。
## 【为什么先参数后文件】分辨率决定内存（256³ 是 67MB），追加还是替换决定当前工程存亡 ——
## 两者都必须在动手前定，选完文件再问等于让人重来。
func request_import_model(path := "") -> void:
	_pending_import_path = path
	_import_opts = {}
	_import_dialog.set_defaults(import_resolution, false, true, path.is_empty())
	_import_dialog.popup_centered()


## 参数框确认：还有文件要选就弹选择框；拖放进来的直接进未保存确认。
func _on_import_options() -> void:
	_import_opts = _import_dialog.options()
	var path := _pending_import_path
	_pending_import_path = ""
	if path.is_empty():
		_model_dialog.popup_centered_ratio(0.7)
	else:
		_confirm_discard("导入模型", _import_now.bind(path))


func _on_model_path_selected(path: String) -> void:
	_confirm_discard("导入模型", _import_now.bind(path))


func _import_now(path: String) -> void:
	import_model(path, _import_opts)


## 外部网格 → 体素 → **替换**当前工程（与打开 .vox 同一条装配路径）。失败时视口保持原样。
## 【协程】加载与逐帧体素化都会让出帧，界面不冻。`opts`：{resolution, append, fill}。
func import_model(path: String, opts := {}) -> bool:
	var resolution := int(opts.get("resolution", import_resolution))
	var scene: Dictionary = await MeshAccess.load_scene(path, self)
	if scene.is_empty():
		hud.flash("打不开这个模型：%s（只支持 %s）" % [path.get_file(), MeshAccess.describe()])
		return false
	var imported: QVoxelWorld = await MeshVoxelWorld.to_world(scene, resolution,
			bool(opts.get("fill", true)))
	if imported == null:
		hud.flash("体素化失败（模型里没有可用三角面）：%s" % path.get_file())
		return false
	if bool(opts.get("append", false)) and world != null:
		return _append_import(imported, path, resolution)
	var obj := _adopt_world(imported, "", true)
	if obj == null:
		hud.flash("体素化结果为空：%s" % path.get_file())
		return false
	var anim := ("，%d 帧体素动画" % obj.frame_count()) if obj.is_animated() else ""
	hud.flash("已导入 %s → %s（最长边 %d）%s" % [path.get_file(), str(obj.grid_size),
			resolution, anim])
	return true


## 追加：把导入结果的模型与材质并进**当前世界**（不换掉它）。工程路径保持不变。
func _append_import(imported: QVoxelWorld, path: String, resolution: int) -> bool:
	var added: Array[QVoxelModel] = world.merge_from(imported)
	if added.is_empty():
		hud.flash("这个模型里没有可用的体素：%s" % path.get_file())
		return false
	_install(world, added[0])
	_sess.mark_dirty()
	_update_title()
	var anim := ("，%d 帧体素动画" % added[0].frame_count()) if added[0].is_animated() else ""
	hud.flash("已追加 %s → %s（最长边 %d）%s" % [path.get_file(), str(added[0].grid_size),
			resolution, anim])
	return true


## 文件对话框：一个"打开"、一个"另存为"。走系统文件系统 —— `res://` 是只读的导入资源，
## 工程文件本就该落在用户自己的目录里（导出打包后 `res://` 更是读不到的）。
func _build_dialogs() -> void:
	_open_dialog = _make_dialog(FileDialog.FILE_MODE_OPEN_FILE)
	_open_dialog.file_selected.connect(open_project)
	_save_dialog = _make_dialog(FileDialog.FILE_MODE_SAVE_FILE)
	_save_dialog.file_selected.connect(_on_save_path_selected)

	# 导出网格：glTF 2.0。两个扩展名各一个过滤器（*.glb 二进制 / *.gltf 文本），
	# 写出格式随扩展名（见 QVoxelMeshExport）。
	_mesh_dialog = _make_format_dialog(FileDialog.FILE_MODE_SAVE_FILE, "*.glb",
			"glTF 二进制（.glb）", "导出网格")
	_mesh_dialog.add_filter("*.gltf", "glTF 文本（.gltf）")
	_mesh_dialog.file_selected.connect(_on_mesh_path_selected)

	# 导入模型：过滤项由 MeshAccess 生成（格式事实只有一处），先过参数框再选文件。
	_model_dialog = _make_fs_dialog(FileDialog.FILE_MODE_OPEN_FILE, "导入模型")
	for spec: Array in MeshAccess.filter_specs():
		_model_dialog.add_filter(spec[0], spec[1])
	_model_dialog.file_selected.connect(_on_model_path_selected)
	_import_dialog = QVoxelierImportDialog.new()
	add_child(_import_dialog)
	_import_dialog.confirmed.connect(_on_import_options)

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
##（系统文件系统、主题、首路径、按钮文案）各处一字不差 —— 复制成几份，迟早有一份忘了改。
## 【一律走系统原生对话框】`use_native_dialog = true`：每个平台都用**它自己的**文件对话框
##（Windows 用系统对话框、macOS / Linux 同理；没有原生实现的平台 Godot 自动回退到自绘那套）。
## 于是"打开 / 另存 / 导入 / 导出"四处行为一致 —— 不会一会儿弹系统框、一会儿弹引擎自绘框。
## 【过滤与扩展名】原生对话框同样吃 `add_filter`（Windows 只认扩展名，macOS/Linux 还认 MIME），
## 但它**不替你补扩展名**，所以每个保存出口都要自己补（见 _ensure_png_ext / _ensure_mesh_ext）。
func _make_fs_dialog(mode: FileDialog.FileMode, title: String) -> FileDialog:
	var d := FileDialog.new()
	d.file_mode = mode
	d.access = FileDialog.ACCESS_FILESYSTEM
	d.current_dir = _default_dir()
	# 原生对话框忽略 theme / ok_button_text 等自绘属性（系统自己那套更地道）；这里仍设一遍，
	# 是为了**没有原生实现的平台**回退到自绘那套时，外观与文案不至于跟界面脱节。
	d.theme = QVoxelUi.theme()
	d.title = title
	d.ok_button_text = "打开" if mode == FileDialog.FILE_MODE_OPEN_FILE else "保存"
	d.cancel_button_text = "取消"
	d.use_native_dialog = true
	add_child(d)
	return d


func _make_dialog(mode: FileDialog.FileMode) -> FileDialog:
	var d := _make_fs_dialog(mode,
			"打开工程" if mode == FileDialog.FILE_MODE_OPEN_FILE else "保存工程")
	d.add_filter("*.%s" % QVoxelProject.EXTENSION, "QVoxelier 工程")
	# `.vox` 两种模式都支持：打开是导入，保存是写回（MagicaVoxel 能直接打开）。
	d.add_filter("*.%s" % VoxAsset.VOX_EXTENSION, "MagicaVoxel 体素")
	return d


## 带格式过滤的文件对话框（调色板 / 快照 / 导出网格共用）。
## 为什么调色板走 PNG 而不是自定义格式：MagicaVoxel 的调色板就是 256×1 的 PNG，沿用它就能与
## 其它体素工具互相倒色板，也不用再定义一套只有本程序认得的格式。
func _make_format_dialog(mode: FileDialog.FileMode, filter: String, filter_name: String,
		title: String) -> FileDialog:
	var d := _make_fs_dialog(mode, title)
	d.add_filter(filter, filter_name)
	return d


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


## 把 `.qvx` / `.vox` / 外部模型拖进窗口即打开（建模时最顺手的一步）；其它文件一律忽略。
func _on_files_dropped(files: PackedStringArray) -> void:
	for f in files:
		# 拖进来同样是"整体换掉当前世界"，走 request_* 才有那道未保存确认。
		if QVoxelProject.is_openable(f):
			request_open(f)
			return
		if MeshAccess.handles(f):
			request_import_model(f)
			return
	hud.flash("只认得 .%s 工程 / .%s 体素文件，以及 %s 模型"
			% [QVoxelProject.EXTENSION, VoxAsset.VOX_EXTENSION, MeshAccess.describe()])


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
	_tools.set_tool(_current_tool_id())
	# 上下文选项条：先按工具类别决定显示哪一组（操作三态 / 笔刷参数 / 选区动作），再回填值。
	var brush := session.tool.supports_brush_size()
	_context.set_tool(_tool_kind, brush, session.tool.selection_mode())
	_context.set_op(_op)
	_context.set_brush(session.tool.brush_size, brush)
	_context.set_brush_shape(session.tool.brush_shape, brush)
	# 对称是 App 级设置 → 每次刷新都把它压回当前对象的笔刷，并回写三个按钮的按下态。
	_apply_symmetry()
	_context.set_symmetry(_symmetry)
	# 快速选区判据同样是 App 级设置（切对象后新会话要重新压一次）。
	session.select_by_color = _select_by_color
	# 选区 / 剪贴板：线框、按钮可用性、状态栏读数三处都跟着同一份数据走（一处刷新，三处跟上）。
	_context.set_selection_state(not session.selection.is_empty(), not session.clipboard.is_empty())
	# 选区线框：集合形态逐格高亮（不规则形状），盒形态画一个框。
	if session.selection.is_precise():
		_selection_box.set_cells(session.selection.cells())
	else:
		_selection_box.set_box(session.selection.lo(), session.selection.size())
	# 移动坐标轴 / 旋转环：
	#   布局模式 → 摆在**节点原点**，拖动改模型整体变换；
	#   模型内部 + 「移动」工具 → 摆在选区中心（没有选区时按"整体"摆在网格中心）。
	if _move_gizmo != null:
		if _edit_mode == 1:
			# 布局：gizmo 摆在**选区共同中心**（多选时绕它整体旋转）。
			_move_gizmo.set_center(_layout_gizmo_center())
		elif _tool_kind == ToolKind.BRUSH and session.tool.mode == QVoxelBrushTool.Mode.MOVE:
			if session.selection.is_empty():
				_move_gizmo.set_selection(Vector3i.ZERO, session.object.grid_size)
			else:
				_move_gizmo.set_selection(session.selection.lo(), session.selection.size())
		else:
			_move_gizmo.visible = false
	# 状态栏里的选区 / 剪贴板读数由 HUD 自己按会话算（见 QVoxelierHud._selection_readout），
	# 不在这里再喂一份字符串 —— 同一事实两处拼装迟早会各说各话。
	# 色板取世界的材质表（增删材质 / 导入 / 改色都可能换掉它）。挂在这条唯一刷新路径上，
	# set_palette 自己按指纹判重 —— 状态变更就不再需要各自记得去喂色板了（此前只有"打开工程"
	# 那条路喂过，于是新建之后整条色板是空的，只剩一个"材质 1"的标签）。
	if world != null:
		_palette.set_palette(_material_colors(world))
	_palette.set_current(_material_id)
	_refresh_panels()
	# 面板会动态新建控件（色板 / 层级 / 帧条…），刷新收尾再关一遍焦点，杜绝 Tab/方向键乱跳。
	_disable_focus(self)


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
	# 底部时间轴绑到当前编辑对象（帧是模型自己的属性）。
	if _timeline != null:
		_timeline.bind(session.object)
	# 对象属性页跟着当前选中的节点（撤销 / 重做后重看一眼数据）。
	if _object_section != null:
		_object_section.bind(_selected_node)
	# 时间轴绑的是**当前对象**（帧是模型自己的属性，不像材质那样属于世界）。
	# 它内部只在帧数变了时才重建帧条（见 QVoxelierTimeline.bind），播放期间不重建控件。
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


## 光标格：按 Pick 已经算好的 place 显示（添加 = 外侧那格，移除 / 上色 = 命中格本身）。
## 屏幕坐标由调用方传入（鼠标事件里有，不必再问视口要一次 —— 内嵌视口时那个答案还是错的）。
func _refresh_cursor(screen: Vector2) -> void:
	var pick := _pick_at(screen, _stroke_op if _stroke else _hover_op)
	_hover_pick = pick if pick.valid() else null
	if not pick.valid():
		hud.set_cursor(Vector3i.MIN)
	else:
		hud.set_cursor(pick.place)
	_refresh_ghost(pick)
	_refresh_selection_preview()


## 悬停预览：格子来自会话的 hover()（与真正落笔同一条形状分派，所见即所画）。
## 三态各有一种读法：添加 = 材质色半透明实体；移除 = 警示红线框；上色 = 材质色线框
## （线框表示"改的是已有体素"，色调表示"改成什么色"）。
func _refresh_ghost(pick: QVoxelBrushTool.Pick) -> void:
	# 自定义笔刷：预览"贴上去的整块图案"（与真正盖章同一套定位，所见即所盖）。
	if _tool_kind == ToolKind.CUSTOM:
		_refresh_brush_ghost(pick)
		return
	# 手势中射线落到模型外仍要预览 —— hover() 内部用起点 pick 兜底，预览不闪没。
	if not pick.valid() and not _stroke:
		_ghost.clear()
		return
	var remove := pick.op == QVoxelBrushTool.Op.REMOVE
	_ghost.set_cells(session.preview_cells(pick),
			QVoxelUi.WARN if remove else _material_color(), pick.op != QVoxelBrushTool.Op.ADD)


## 自定义笔刷的悬停预览：把剪贴板图案按盖章位置铺出来。
## 与真正盖章**共用同一定位公式**、同样夹进网格 —— 否则预览会多出越界的那半块，看着"盖歪了"。
func _refresh_brush_ghost(pick: QVoxelBrushTool.Pick) -> void:
	var clip := session.clipboard if session != null else null
	if clip == null or clip.is_empty() or not pick.valid():
		_ghost.clear()
		return
	if session.object == null:
		_ghost.clear()
		return
	var center := pick.hit if pick.hit != Vector3i.MIN else pick.place
	var size: Vector3i = clip.size()
	var anchor := center - Vector3i(size.x >> 1, size.y >> 1, size.z >> 1)
	var top := session.object.grid_size - Vector3i.ONE
	var cells: Array[Vector3i] = []
	for c in clip.cells():
		var p: Vector3i = anchor + c
		if p.x < 0 or p.y < 0 or p.z < 0 or p.x > top.x or p.y > top.y or p.z > top.z:
			continue
		cells.append(p)
	var remove := pick.op == QVoxelBrushTool.Op.REMOVE
	_ghost.set_cells(cells, QVoxelUi.WARN if remove else _material_color(), pick.op != QVoxelBrushTool.Op.ADD)


## 选择 / 移动手势中的**实时线框预览**（松手前就看得见框多大 / 会挪到哪）。
## 【为什么必须预览】选区是纯数据，拖动中不给反馈就是"盲拖"；而松手才显示太晚，用户不知道
## 自己框到了什么 / 搬去了哪。生成最终选区的是会话（release），这里只画"如果现在松手会怎样"。
func _refresh_selection_preview() -> void:
	if session == null or not session.tool.selection_mode() or not session.tool.active():
		return
	var corners := session.tool.gesture_corners()
	if corners.size() < 2:
		return
	if session.tool.mode == QVoxelBrushTool.Mode.MOVE:
		if session.selection.is_empty():
			return
		_set_preview_box(session.selection.offset_by(corners[1] - corners[0]))
	else:
		_set_preview_box(QVoxelSelection.from_corners(corners[0], corners[1]))


## 把预览框夹进网格后画出来（与 QVoxelEditSession._set_box_selection 的夹取一致）。
func _set_preview_box(sel: QVoxelSelection) -> void:
	if sel.is_empty() or session == null or session.object == null:
		return
	var top := session.object.grid_size - Vector3i.ONE
	var lo := sel.lo().clamp(Vector3i.ZERO, top)
	var hi := sel.hi().clamp(Vector3i.ZERO, top)
	if hi.x < lo.x or hi.y < lo.y or hi.z < lo.z:
		return
	_selection_box.set_box(lo, hi - lo + Vector3i.ONE)


## 天空里的"太阳盘"**完全隐藏**：材质 metallic=1 会把天空的太阳反射成一个大光球（用户不想看到）。
func _setup_sky() -> void:
	if _env_node == null or _env_node.environment == null:
		return
	var sky := _env_node.environment.sky
	if sky != null and sky.sky_material is ProceduralSkyMaterial:
		var mat := sky.sky_material as ProceduralSkyMaterial
		mat.sun_angle_max = 0.0
		mat.sun_curve = 1.0


## 按编辑层级套渲染设置：
##   模型编辑 → 关阴影 / SSAO / SSIL / SSR / 辉光（这些会干扰"看体素判断形状"）；
##   布局（世界）→ 全开并精调（高质阴影 + SSAO + SSIL + SSR + 适度辉光 + ACES），逼近渲染图。
func _apply_render_mode() -> void:
	var best := _edit_mode == 1
	if _key_light != null:
		_key_light.shadow_enabled = best
		# 阴影质量拉高：4 段 PSSM + 混合分割 + 软阴影 + 更细的偏置。
		_key_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
		_key_light.directional_shadow_blend_splits = true
		_key_light.directional_shadow_max_distance = 120.0
		_key_light.directional_shadow_fade_start = 0.8
		_key_light.shadow_blur = 1.5
		_key_light.shadow_bias = 0.03
		_key_light.shadow_normal_bias = 1.5
		_key_light.shadow_opacity = 0.9
		_key_light.light_angular_distance = 0.6
	var env := _env_node.environment if _env_node != null else null
	if env == null:
		return
	env.ssao_enabled = best
	env.ssil_enabled = best
	env.ssr_enabled = best
	env.glow_enabled = best
	if best:
		# 环境光遮蔽：稍强、稍大半径 → 凹处层次更明显。
		env.ssao_intensity = 2.0
		env.ssao_radius = 0.8
		# 屏幕空间间接光：让缝隙 / 背光面得到更自然的补光。
		env.ssil_intensity = 1.0
		env.ssil_radius = 5.0
		env.ssil_sharpness = 0.98
		env.ssil_normal_rejection = 1.0
		# 屏幕空间反射：金属/光滑面能映出周围体素与地面。
		env.ssr_max_steps = 64
		env.ssr_fade_in = 0.15
		env.ssr_fade_out = 2.0
		env.ssr_depth_tolerance = 0.2
		# 辉光调低（此前偏强）：阈值抬高，只有真发光才溢出。
		env.glow_intensity = 0.5
		env.glow_bloom = 0.02
		env.glow_hdr_threshold = 1.2
		# 环境光：更亮的间接照明 + 更多天空贡献。
		env.ambient_light_energy = 1.3
		env.ambient_light_sky_contribution = 0.6
		# 色调映射：ACES（更接近渲染图）。
		env.tonemap_mode = Environment.TONE_MAPPER_ACES
		env.tonemap_white = 6.0
		env.tonemap_exposure = 1.0
	else:
		env.ambient_light_energy = 1.0
		env.ambient_light_sky_contribution = 0.3
		env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
		env.tonemap_exposure = 1.0


## 切换编辑层级（Tab）：模型内部 ⇄ 布局（类似 Blender 的模式切换）。
## 布局下：只留「移动」工具可用、隐藏上下文条（绘制参数无关）、gizmo 改**模型整体变换**。
func _set_edit_mode(m: int) -> void:
	m = clampi(m, 0, 1)
	if m == _edit_mode:
		return
	_edit_mode = m
	_gizmo_active = false
	_apply_render_mode()
	if m == 1:
		_layout_sel.clear()
	if _move_gizmo != null:
		_move_gizmo.set_hover(-1, -1)
	if _tools != null:
		_tools.set_layout_mode(_edit_mode == 1)
	if _context != null:
		_context.visible = _edit_mode == 0
	if _edit_mode == 1 and session != null:
		_set_tool(QVoxelBrushTool.Mode.MOVE)
	elif _edit_mode == 0 and session != null and not QVoxelBrushTool.MODES.is_empty():
		# 切回模型编辑：默认第一个体素工具（画笔），而不是布局用的位移工具。
		_set_tool(int(QVoxelBrushTool.MODES[0]["mode"]))
	_attach_active()
	_rebuild_view()
	_rebuild_layout_overlay()
	# 切层级即聚焦：编辑模式对准当前模型，布局模式对准整个世界。
	if _edit_mode == 1:
		frame_world()
	else:
		frame_view()
	_refresh_hud()
	hud.flash("布局模式：拖动 gizmo 移动 / 旋转整个模型（Tab 切回模型编辑）" if _edit_mode == 1
			else "模型编辑模式（Tab 切到布局）")


## 按下：布局模式 → 移动 / 旋转**整个模型**；模型内部 → 移动 / 旋转**选区**。返回是否命中。
func _gizmo_begin(screen: Vector2) -> bool:
	if _move_gizmo == null or not _move_gizmo.visible:
		return false
	var a := _move_gizmo.axis_hit(screen, camera)
	if a >= 0:
		_gizmo_active = true
		_gizmo_axis = a
		_gizmo_delta = 0
		_gizmo_per_voxel = maxf(_move_gizmo.axis_world(a).length(), 1e-6)
		if _edit_mode == 1:
			# 布局：沿轴移动整个模型。参考钉在按下那一刻（模型随后会动，否则参数自漂移）。
			_gizmo_mode = 2
			_layout_center = _move_gizmo.center_global()
			_layout_axis_u = _move_gizmo.axis_world(a).normalized()
			_layout_base_offsets = _layout_capture_offsets()
			_gizmo_t0 = _layout_param(screen)
			return true
		# 模型内部：移动选区（没有选区就默认整体），并抓一份用于实时预览。
		if session.selection.is_empty():
			session.select_all()
		_refresh_hud()
		_gizmo_clip = session.capture_selection()
		_gizmo_base_lo = session.selection.lo()
		_gizmo_mode = 0
		_gizmo_t0 = _gizmo_param(screen)
		return true
	var r := _move_gizmo.ring_hit(screen, camera)
	if r >= 0:
		_gizmo_active = true
		_gizmo_axis = r
		_gizmo_rot_angle = 0.0
		_gizmo_rot_quarters = 0
		if _edit_mode == 1:
			_gizmo_mode = 3
			_layout_base_xfs = _layout_capture_xfs()
			_layout_pivot = _layout_pivot_from(_layout_base_xfs)
			# 钉住参考系：拖动中 gizmo 随模型转，实时 global_transform 会让夹角乱跳。
			_layout_rot_basis = _move_gizmo.global_transform.basis
			_layout_rot_center = _move_gizmo.center_global()
			_gizmo_t0 = _move_gizmo.ring_angle_ref(screen, camera, r, _layout_rot_basis, _layout_rot_center)
		else:
			_gizmo_mode = 1
			_gizmo_t0 = _move_gizmo.ring_angle(screen, camera, r)
		return true
	return false


## 拖动：布局模式实时移动 / 旋转模型整体；模型内部累积位移 / 夹角并预览。
func _gizmo_update(screen: Vector2) -> void:
	if not _gizmo_active:
		return
	if _gizmo_mode == 2:
		_move_gizmo.set_hover(_gizmo_axis, -1)
		var d := int(roundf((_layout_param(screen) - _gizmo_t0) / _gizmo_per_voxel))
		if d == _gizmo_delta:
			return
		_gizmo_delta = d
		var delta := _axis_delta(_gizmo_axis, d)
		for m in _layout_models():
			m.offset = (_layout_base_offsets[m.model_id] as Vector3i) + delta
		_update_layout_renderers()
		return
	if _gizmo_mode == 3:
		_gizmo_rot_angle = _move_gizmo.ring_angle_ref(screen, camera, _gizmo_axis,
				_layout_rot_basis, _layout_rot_center) - _gizmo_t0
		_move_gizmo.set_hover(-1, _gizmo_axis, _ring_seg_for(_gizmo_rot_angle))
		var q := roundi(_gizmo_rot_angle / (PI / 2.0))
		if q == _gizmo_rot_quarters:
			return
		_gizmo_rot_quarters = q
		hud.flash("旋转 %d°" % (q * 90))
		var rot := Basis([Vector3.RIGHT, Vector3.UP, Vector3.BACK][_gizmo_axis], float(q) * PI / 2.0)
		var rot_p := Transform3D(rot, _layout_pivot - rot * _layout_pivot)
		for m in _layout_models():
			var base: Transform3D = _layout_base_xfs[m.model_id]
			var pw := _parent_world(m)
			m.local_transform = pw.affine_inverse() * rot_p * pw * base
		_update_layout_renderers()
		return
	if _gizmo_mode == 1:
		_gizmo_rot_angle = _move_gizmo.ring_angle(screen, camera, _gizmo_axis) - _gizmo_t0
		_move_gizmo.set_hover(-1, _gizmo_axis, _ring_seg_for(_gizmo_rot_angle))
		var q := roundi(_gizmo_rot_angle / (PI / 2.0))
		if q == _gizmo_rot_quarters:
			return
		_gizmo_rot_quarters = q
		# 实时预览：旋转后的格以半透明 ghost 画出来（与移动同一套预览语言）。
		_ghost.set_cells(session.preview_rotation(_gizmo_axis, q), QVoxelUi.ACCENT, false)
		hud.flash("旋转 %d°" % (q * 90))
		return
	var d := int(roundf((_gizmo_param(screen) - _gizmo_t0) / _gizmo_per_voxel))
	if d == _gizmo_delta:
		return
	_gizmo_delta = d
	var dir := _gizmo_dir()
	# 实时预览：选区框落到目标处 + 体素以半透明 ghost 画在目标处（松手前就能看到搬去哪）。
	if not session.selection.is_empty():
		_set_preview_box(session.selection.offset_by(dir))
	if _gizmo_clip != null and not _gizmo_clip.is_empty():
		var target := _gizmo_base_lo + dir
		var cells: Array[Vector3i] = []
		for c in _gizmo_clip.cells():
			cells.append(target + c)
		_ghost.set_cells(cells, QVoxelUi.ACCENT, false)


## 松手：布局模式把整体位移 / 旋转提交成一条可撤销命令；模型内部提交移动 / 旋转选区命令。
func _gizmo_end() -> void:
	if not _gizmo_active:
		return
	_gizmo_active = false
	var ax := _gizmo_axis
	if _gizmo_mode == 2:
		_gizmo_mode = 0
		_gizmo_axis = -1
		var delta := _axis_delta(ax, _gizmo_delta)
		_gizmo_delta = 0
		var macro := QVoxelMacroCommand.new("移动模型")
		for m in _layout_models():
			var base: Vector3i = _layout_base_offsets[m.model_id]
			var final := base + delta
			if final == base:
				continue
			m.offset = base   # 复位，让命令抓到正确的 before
			var cmd := QVoxelPropertyCommand.begin(m, &"offset", m, "移动节点")
			m.offset = final
			if cmd.commit():
				macro.add(cmd)
		if not macro.is_empty():
			session.history.push(macro)
			_sess.mark_dirty()
		_attach_active()
		_rebuild_view()
		_refresh_hud()
		return
	if _gizmo_mode == 3:
		_gizmo_mode = 0
		_gizmo_axis = -1
		var q := roundi(_gizmo_rot_angle / (PI / 2.0))
		_gizmo_rot_angle = 0.0
		_gizmo_rot_quarters = 0
		if q != 0:
			var rot := Basis([Vector3.RIGHT, Vector3.UP, Vector3.BACK][ax], float(q) * PI / 2.0)
			var rot_p := Transform3D(rot, _layout_pivot - rot * _layout_pivot)
			var macro := QVoxelMacroCommand.new("旋转模型")
			for m in _layout_models():
				var base: Transform3D = _layout_base_xfs[m.model_id]
				var pw := _parent_world(m)
				var final := pw.affine_inverse() * rot_p * pw * base
				if final.is_equal_approx(base):
					continue
				m.local_transform = base   # 复位
				var cmd := QVoxelPropertyCommand.begin(m, &"local_transform", m, "旋转节点")
				m.local_transform = final
				if cmd.commit():
					macro.add(cmd)
			if not macro.is_empty():
				session.history.push(macro)
				_sess.mark_dirty()
		_attach_active()
		_rebuild_view()
		_refresh_hud()
		return
	if _gizmo_mode == 1:
		_gizmo_mode = 0
		_gizmo_axis = -1
		var q := roundi(_gizmo_rot_angle / (PI / 2.0))
		_gizmo_rot_angle = 0.0
		_gizmo_rot_quarters = 0
		_ghost.clear()
		if q != 0:
			var n := session.rotate_selection(ax, q)
			hud.flash("旋转 %d°" % (q * 90) if n > 0 else "转不动（越界 / 没有体素）")
		_refresh_hud()
		return
	var dir := _gizmo_dir()
	_gizmo_axis = -1
	_gizmo_delta = 0
	_gizmo_clip = null
	_ghost.clear()
	if dir != Vector3i.ZERO:
		var n := session.move_selection(dir)
		hud.flash("移动 %d 体素" % n if n > 0 else "移不动（越界 / 没有体素）")
	_refresh_hud()


## 悬停反馈：把命中的轴 / 环告诉 gizmo（高亮），命中与否一眼可见。
func _update_gizmo_hover(screen: Vector2) -> void:
	if _move_gizmo == null or not _move_gizmo.visible:
		return
	var a := _move_gizmo.axis_hit(screen, camera)
	var r := -1
	var seg := -1
	if a < 0:
		r = _move_gizmo.ring_hit(screen, camera)
		if r >= 0:
			seg = _move_gizmo.last_ring_seg()
	_move_gizmo.set_hover(a, r, seg)


## 角度 → 环段下标（分段高亮用）。
func _ring_seg_for(angle: float) -> int:
	var seg := float(QVoxelierMoveGizmo.RING_SEG)
	return posmod(int(round(angle / (TAU / seg))), int(seg))


## 单轴整数位移（axis 下标 + 步数 → Vector3i）。
func _axis_delta(axis: int, d: int) -> Vector3i:
	var out := Vector3i.ZERO
	match axis:
		0:
			out.x = d
		1:
			out.y = d
		2:
			out.z = d
	return out


func _gizmo_dir() -> Vector3i:
	return _axis_delta(_gizmo_axis, _gizmo_delta)


## 光标射线与所选轴直线的最近点参数（世界单位）。
func _gizmo_param(screen: Vector2) -> float:
	var c := _move_gizmo.center_global()
	var u := _move_gizmo.axis_world(_gizmo_axis).normalized()
	var ro := camera.project_ray_origin(screen)
	var rd := camera.project_ray_normal(screen)
	var w0 := c - ro
	var b := u.dot(rd)
	var d := u.dot(w0)
	var e := rd.dot(w0)
	var den := 1.0 - b * b
	if absf(den) < 1e-6:
		return 0.0
	return (b * e - d) / den


## 布局拖拽的轴参数：用**固定**的 center / axis（按下时抓的那份），因为模型随后会跟着动。
func _layout_param(screen: Vector2) -> float:
	var u := _layout_axis_u
	var ro := camera.project_ray_origin(screen)
	var rd := camera.project_ray_normal(screen)
	var w0 := _layout_center - ro
	var b := u.dot(rd)
	var d := u.dot(w0)
	var e := rd.dot(w0)
	var den := 1.0 - b * b
	if absf(den) < 1e-6:
		return 0.0
	return (b * e - d) / den


## 当前材质的基色（越界 / 世界未就绪时退回白色，预览不因为一次边界态而画不出来）。
func _material_color() -> Color:
	if world == null or _material_id <= 0 or _material_id >= world.materials.size():
		return Color(1, 1, 1)
	return world.material_color(_material_id)


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
## 让底部三块（左列 / 右列 / 坐标系）给常驻的动画帧条让出一条高度（它贴在状态栏上方）。
func _reserve_strip() -> void:
	var h := float(QVoxelUi.strip_height())
	if _dock != null:
		_dock.set_bottom_reserved(h)
	if _tools != null:
		_tools.set_bottom_reserved(h)
	if _gizmo != null:
		_gizmo.bottom_inset = h


## 逐帧步进（帧条的 ◀ / ▶）。
func _step_frame(delta: int) -> void:
	if session == null or session.object == null or not session.object.is_animated():
		return
	var n := session.object.frame_count()
	_select_frame(clampi(session.object.active_frame + delta, 0, n - 1))


## 改节点位置（对象属性面板的三个轴）。走一条可撤销命令。
## 【为什么不再重算数据】去摆放本地化之后，位置只影响渲染器的 transform（摆放由渲染器承载），
## 体素数据一个字节都不用动 —— 只重挂变换即可（比旧实现少一次整对象重取数）。
func _set_node_offset(node: QVoxelNode, value: Vector3i) -> void:
	if session == null or node == null or node.offset == value:
		return
	var cmd := QVoxelPropertyCommand.begin(node, &"offset", node, "移动节点")
	node.offset = value
	if cmd.commit():
		session.history.push(cmd)
	_sess.mark_dirty()
	_attach_active()
	_rebuild_view()
	_refresh_hud()


## 改模型分辨率（对象属性面板的"尺寸"）。结构级操作 → 可撤销命令 + 整对象重算。
func _resize_model(node: QVoxelNode, value: Vector3i) -> void:
	if session == null or node == null or not node.is_model():
		return
	var cmd := QVoxelResizeCommand.apply(node as QVoxelModel, value)
	if cmd == null:
		return
	session.history.push(cmd)
	session.rebuild()
	_sess.mark_dirty()
	_attach_active()
	_rebuild_view()
	_refresh_hud()


## 世界级：设置节点的旋转（对象属性面板的欧拉角，度）。轴对齐吸附由面板的 90° 步进保证。
func _set_node_rotation(node: QVoxelNode, degrees: Vector3) -> void:
	if session == null or node == null:
		return
	var xf := node.local_transform
	var b := Basis.from_euler(Vector3(
			deg_to_rad(degrees.x), deg_to_rad(degrees.y), deg_to_rad(degrees.z))).orthonormalized()
	var rotated := _center_preserving(xf, b, _node_center_voxel(node))
	if rotated.is_equal_approx(xf):
		return
	var cmd := QVoxelPropertyCommand.begin(node, &"local_transform", node, "旋转节点")
	node.local_transform = rotated
	if cmd.commit():
		session.history.push(cmd)
	_sess.mark_dirty()
	_attach_active()
	_rebuild_view()
	_refresh_hud()


## 节点盒中心（体素单位，节点本地坐标系）—— 旋转绕它，与 .vox 的"模型居中后再转"一致。
func _node_center_voxel(node: QVoxelNode) -> Vector3:
	if node == null:
		return Vector3.ZERO
	return Vector3(QVoxelEvalEngine.output_grid_size(node)) * 0.5


## 把 base 的旋转换成 b，同时**保持盒中心 C 不动**（new*C == base*C）→ 原地自转，不甩到别处。
func _center_preserving(base: Transform3D, b: Basis, c: Vector3) -> Transform3D:
	return Transform3D(b, base.origin + base.basis * c - b * c)


## 双击层级行：切到该节点（顺带显示「对象」页）并聚焦名字输入框开始改名。
func _begin_rename(node: QVoxelNode) -> void:
	_on_tree_selected(node)
	if _object_section != null:
		_object_section.begin_rename(node)


func _on_tree_selected(node: QVoxelNode) -> void:
	if node != null and node.is_model():
		_activate((node as QVoxelModel).model_id)
	# 选中一个节点 → 对象属性页跟着显示它的数据，并自动切到「对象」页签。
	_selected_node = node
	if _object_section != null:
		_object_section.bind(node)
	if _dock != null:
		_dock.show_property_by_title("对象")


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
	var pick := _pick_at(screen, _op)
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

## 顶栏「渲染」按钮：弹出 / 收起离屏渲染浮层（原「快照」分组）。
func _toggle_render_popup() -> void:
	if _snapshot_popup == null:
		return
	if _snapshot_popup.visible:
		_snapshot_popup.hide()
	else:
		_snapshot_popup.popup_centered()


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


## 补上网格扩展名（原生对话框不替我们补）：已带 .glb / .gltf 就原样，否则按默认 .glb 补。
func _ensure_mesh_ext(path: String) -> String:
	return path if path.get_extension().to_lower() in QVoxelMeshExport.EXTENSIONS \
			else path + "." + QVoxelMeshExport.EXTENSIONS[0]


# 时间轴（右侧抽屉·时间轴组，QVoxelSpec §12.6）
# 与层级树那一段同构：本段只做一件事 —— 把面板报告的用户意图翻译成"改哪个属性 + 记成哪条命令"。
# 帧的结构改动走 QVoxelPropertyCommand（`frames` 就是属性），而切帧 / 播放**不入栈**：
# 模型 active_frame 是"正在看第几帧"，是游标不是数据（§12.6）。

## 切帧：改游标 → 重算 → 刷界面。**不标脏、不入栈**。
## 【为什么不记进历史】"我看了第 3 帧"不是一次内容改动。若它也占一格，用户画一笔再翻十帧，
## 想撤掉那一笔就得连按十一次 —— 撤销栈会被浏览动作灌满，而里面 90% 是空操作。
func _select_frame(index: int) -> void:
	if session == null or not session.object.is_animated():
		return
	# 同步换帧（见 QVoxelEditSession.apply_frame）——播放才跟得上，不会"体素不变"。
	session.apply_frame(index)
	_attach_active()
	_rebuild_view()
	_refresh_hud()


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
	if _timeline != null:
		_timeline.stop_playback()
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


## 末尾新建一帧（复制最后一帧）；静态模型先转成动画。帧条末尾的 ＋ 走这条。
## 【为什么复制最后一帧而不是空帧】逐帧作画大多是在上一帧基础上改；从空帧开始几乎没人用。
func _append_frame() -> void:
	if session == null or world == null:
		return
	_run_frame_edit("新建帧", func(m: QVoxelModel) -> void:
		if not m.is_animated():
			m.make_animated()
		var last := m.frame_count() - 1
		var f: QVoxelFrame = m.frame_at(last).clone() if last >= 0 else QVoxelFrame.new()
		m.add_frame(f, m.frame_count())
		m.active_frame = m.frame_count() - 1)


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

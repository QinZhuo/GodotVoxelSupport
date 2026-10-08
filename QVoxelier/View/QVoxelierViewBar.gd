@tool
class_name QVoxelierViewBar
extends QVoxelierPanel
## 视图栏（视口左下角）—— 镜头类型 / 标准视图 / 网格线开关。
##
## 【为什么单独一条栏，而不是塞进顶部应用栏】顶栏是"对工程做什么"（新建 / 打开 / 保存 / 撤销），
## 本栏是"怎么看它"：前者改数据、后者只看不改。混在一排会让"保存"与"顶视图"读起来像同类操作。
## 视线习惯也让它在视口边上 —— 切视角时手不必跑到屏幕顶上再跑回来。
##
## 【为什么必须有按钮（而不是只有热键）】平板没有数字小键盘、也没有"中键 + 滚轮"那套组合。
## 视图预设是**触摸下唯一**的正交对齐手段（手指不可能精确拖出 0° 俯仰），
## 所以七个预设各占一个按钮，一个都不能省成"长按弹出"。
##
## 【预设按钮为什么用 pressed 而不是 toggled】预设是**瞬时**动作：连按两次"前视图"应各生效一次
## （用户可能刚转过视角想回来）。而按下的复选态在"已是按下"时不再发 toggled，
## 于是第二次点会被吞掉。改用 pressed，按下态只作为"当前角度 ≈ 这个预设"的回显。
## 同理，镜头与预设都**自己管互斥**（不挂 ButtonGroup）：回显只在 set_* 里一次性写完，
## 免得"程序设状态"与"组内自动互斥"两套逻辑互相拆台。

## 镜头类型（值同 QVoxViewCamera.Lens）。
signal lens_selected(mode: int)
## 标准视图（值同 QVoxViewCamera.View）。
signal view_selected(view: int)
## 网格线显隐。
signal grid_lines_toggled(enabled: bool)

const COLUMNS := 4

var _lens := {}              # Lens → Button
var _views := {}             # View → Button
var _grid: Button


func _build() -> void:
	# 左锚点、下锚点：面板贴着视口左下角，窗口变高变矮时它跟着底边走（见父类文档"常驻抬头层"）。
	# 底边留出状态栏的高度 —— 那条栏是全局的，任何面板都不该压在它上面。
	set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	offset_left = QVoxUi.space_m()
	offset_bottom = -(QVoxUi.status_height() + QVoxUi.space_s())

	var panel := QVoxUi.panel(QVoxUi.space_s())
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	add_child(panel)
	panel.resized.connect(func(): size = panel.size)

	var col := QVoxUi.vbox(QVoxUi.SPACE_XS)
	panel.add_child(col)

	col.add_child(QVoxUi.heading("视图"))
	col.add_child(_build_lens_row())

	col.add_child(QVoxUi.divider())
	col.add_child(_build_view_grid())

	col.add_child(QVoxUi.divider())
	_grid = QVoxUi.toggle_button("显示底面格线；关掉只剩外框，便于看清形状")
	_grid.text = "网格线"
	_grid.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_grid.set_pressed_no_signal(true)
	_grid.toggled.connect(func(on: bool): grid_lines_toggled.emit(on))
	col.add_child(_grid)

	set_lens(QVoxViewCamera.Lens.PERSPECTIVE)
	set_view(QVoxViewCamera.View.FREE)


## 镜头：透视 / 正交，二选一。不是复选组，而是单选 —— "没有镜头"不是一个能走到的状态。
func _build_lens_row() -> HBoxContainer:
	var row := QVoxUi.hbox(QVoxUi.SPACE_XS)
	for m in [QVoxViewCamera.Lens.PERSPECTIVE, QVoxViewCamera.Lens.ORTHO]:
		var b := QVoxUi.toggle_button(_lens_hint(m))
		b.text = QVoxViewCamera.LENS_NAMES[m]
		b.custom_minimum_size = Vector2(QVoxUi.hit_size() * 1.6, QVoxUi.hit_size())
		b.pressed.connect(func(): lens_selected.emit(m))
		_lens[m] = b
		row.add_child(b)
	return row


## 七个标准视图排成网格。FREE 只是个标签（"用户自己转过了"），不出按钮。
func _build_view_grid() -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = COLUMNS
	grid.add_theme_constant_override("h_separation", QVoxUi.SPACE_XS)
	grid.add_theme_constant_override("v_separation", QVoxUi.SPACE_XS)
	for v in QVoxViewCamera.VIEW_ANGLES_DEG:
		var b := QVoxUi.toggle_button("把视角转到%s视图" % QVoxViewCamera.VIEW_NAMES[v])
		b.text = QVoxViewCamera.VIEW_NAMES[v]
		b.custom_minimum_size = Vector2(QVoxUi.hit_size(), QVoxUi.hit_size())
		# pressed 而不是 toggled：见类文档（连按两次要各生效一次）。
		b.pressed.connect(func(): view_selected.emit(v))
		_views[v] = b
		grid.add_child(b)
	return grid


static func _lens_hint(mode: int) -> String:
	if mode == QVoxViewCamera.Lens.ORTHO:
		return "正交投影：没有近大远小，量比例、对齐体素用（等轴视角配它才正）"
	return "透视投影：有纵深感，看立体形状更直观"


# ----------------------------------------------------------------------------
# 对外：状态同步（只由 App 调用）
# ----------------------------------------------------------------------------

## 回显当前镜头。**两个按钮都写死状态**（按下 / 弹起），不依赖控件组自动互斥 ——
## 因为回显走的是"无信号"路径，控件组收不到通知就不会替我们弹起另一个。
func set_lens(mode: int) -> void:
	for m in _lens:
		var b: Button = _lens[m]
		b.set_pressed_no_signal(m == mode)


## 回显当前视角。Free（用户转过视角）时不点亮任何预设 —— 状态如实反映"没有对齐到预设"。
func set_view(view: int) -> void:
	for v in _views:
		var b: Button = _views[v]
		b.set_pressed_no_signal(v == view)


func set_grid_lines(on: bool) -> void:
	var b: Button = _grid
	if b != null:
		b.set_pressed_no_signal(on)

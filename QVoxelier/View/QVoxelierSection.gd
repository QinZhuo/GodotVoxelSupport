@tool
class_name QVoxelierSection
extends QVoxelierPanel
## 右侧抽屉里的一段**分组**：抬头一行（小标题）+ 内容。
## 【为什么不再可折叠】页签 / 固定分区已经把"选哪组"表达清楚，再给每组一个"点一下收起"只是
## 多一层隐藏状态：用户会误收起、又找不到内容。分组一律**常展开**，抬头只当小标题用。
## 【为什么用 _build_body 而不是让子类自己 _build】`_ready` 的次序固定（主题 → 层级 →
## 构建 → open，见基类文档）。子类若重写 _build 就要自己保证抬头先建好、body 后建好，
## 迟早有人把顺序写反 —— 于是把"建抬头 → 建 body → 交给子类填"钉在这里，子类只填内容。

var _header: Label
var _body: VBoxContainer
var _panel: PanelContainer
var _want_w := 0.0   # 本组内容想要的宽度（只增不减，见 _measure）


## 子类重写：分组标题（抬头文字）。
func section_title() -> String:
	return "分组"


## 子类重写：往 body 里填内容（此时主题、层级、抬头都已就绪）。
func _build_body(_body: VBoxContainer) -> void:
	pass


## body 容器（子类需要动态增删内容时用）。
func content() -> VBoxContainer:
	return _body


## 隐藏自带抬头（抽屉用别的标题承载时，抬头重复，就把它藏掉）。
func set_header_visible(on: bool) -> void:
	if _header != null:
		_header.visible = on
	if _body != null:
		_body.visible = true


func _build() -> void:
	_panel = QVoxelUi.panel(QVoxelUi.space_s())
	_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	add_child(_panel)
	# 本控件通常是 VBoxContainer 的孩子 —— 容器会覆盖 size，故"我有多高 / 多宽"要用
	# custom_minimum_size 报告（直接写 size 会被父容器在下一帧抹掉）。
	_panel.resized.connect(func():
		_measure()
		custom_minimum_size.y = _panel.size.y)

	var col := QVoxelUi.vbox(QVoxelUi.SPACE_XS)
	_panel.add_child(col)

	# 抬头是纯小标题（不可点、不折叠）。
	_header = QVoxelUi.heading(section_title())
	col.add_child(_header)

	_body = QVoxelUi.vbox(QVoxelUi.SPACE_XS)
	col.add_child(_body)

	_refresh()
	_build_body(_body)
	_measure()


## 记下内容想要的宽度并报给父容器（抽屉按它定右列的宽度）。
## 【为什么只增不减】宽度是布局输入，随内容抖动就会连锁改视口大小；一旦让某一组量出过宽度，
## 就一直给它留着（用户看到的是"右列一直这么宽"，而不是忽宽忽窄）。
func _measure() -> void:
	if _panel == null or _body == null:
		return
	var pad := QVoxelUi.space_s() * 2.0
	var sb := _panel.get_theme_stylebox("panel")
	if sb != null:
		pad = sb.get_margin(SIDE_LEFT) + sb.get_margin(SIDE_RIGHT)
	var want := _body.get_combined_minimum_size().x + pad
	if _header != null:
		want = maxf(want, _header.get_combined_minimum_size().x + pad)
	_want_w = maxf(_want_w, want)
	custom_minimum_size.x = _want_w


## 清掉"只增不减"的记忆，让下次 _measure 重新按当前内容量宽（动画轴展开 / 收起这类
## "宽度本来就该明显变化"的场合用）。
func reset_measure() -> void:
	_want_w = 0.0


func _refresh() -> void:
	if _header == null:
		return
	_header.text = section_title()
	if _body != null:
		_body.visible = true

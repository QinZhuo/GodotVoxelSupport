@tool
class_name QVoxelierSection
extends QVoxelierPanel
## 右侧抽屉里的一段**可折叠分组**：抬头一行（▾ 标题），点一下收起 / 展开。
## 【为什么必须能折叠】右列要放下颜色 / 对象 / 图层 / 变换四组，全展开会占掉半个视口。
## 折叠才是"屏幕不够时让位"的正解 —— 把命中区压到手指点不中（见 QVoxelUi 密度档的说明）
## 换来的是"按钮都在但按不准"，那是更糟的交换。
## 【为什么整条抬头都是按钮】触摸没有 hover、也没有 12px 的小箭头可瞄。把抬头整体做成按钮，
## 命中区就是整行（≥ 一个 hit_size），手指不会点空；▾ / ▸ 只是状态的文字提示。
## 【为什么用 _build_body 而不是让子类自己 _build】`_ready` 的次序固定（主题 → 层级 →
## 构建 → open，见基类文档）。子类若重写 _build 就要自己保证抬头先建好、body 后建好，
## 迟早有人把顺序写反 —— 于是把"建抬头 → 建 body → 交给子类填"钉在这里，子类只填内容。

## 折叠状态变化。
signal expanded_changed(expanded: bool)

## 折叠状态。**不持久化**：分组实例与应用同生命周期，改动不会丢；
## 真要跨启动记住，那属于"用户偏好存档"，不该让每个分组各记一份。
var expanded := true:
	set(v):
		if v == expanded:
			return
		expanded = v
		_refresh()

var _header: Button
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


## 隐藏自带抬头（抽屉改用页签时，抬头与页签重复，由页签负责切组）。
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

	_header = QVoxelUi.button("", "展开 / 收起这一组")
	_header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_header.pressed.connect(func(): expanded = not expanded)
	col.add_child(_header)

	_body = QVoxelUi.vbox(QVoxelUi.SPACE_XS)
	col.add_child(_body)

	_refresh()
	_build_body(_body)
	_measure()


## 记下内容想要的宽度并报给父容器（抽屉按它定右列的宽度）。
## 【为什么问 body 而不问 panel】PanelContainer / BoxContainer 算最小尺寸时会**跳过隐藏的孩子**，
## 而折叠正是 `_body.visible = false` —— 问 panel 在折叠后只剩"内边距"，抽屉就会随展开 / 折叠
## 忽宽忽窄（实测 134 ↔ 228，视口跟着一起弹）。body 自己的最小尺寸看的是**它的孩子**的 visible，
## 那些行并没有被隐藏，故折叠着也量得准。
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
	_header.text = "%s  %s" % ["▾" if expanded else "▸", section_title()]
	if _body != null:
		# 折叠时**只隐藏 body**，抬头始终在 —— 否则收起的组会彻底消失，无从再展开。
		_body.visible = expanded
	expanded_changed.emit(expanded)

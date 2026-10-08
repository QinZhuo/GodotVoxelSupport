@tool
class_name QVoxelierSection
extends QVoxelierPanel
## 右侧抽屉里的一段**可折叠分组**：抬头一行（▾ 标题），点一下收起 / 展开。
##
## 【为什么必须能折叠】右列要放下颜色 / 对象 / 图层 / 变换四组，全展开会占掉半个视口。
## 折叠才是"屏幕不够时让位"的正解 —— 把命中区压到手指点不中（见 QVoxUi 密度档的说明）
## 换来的是"按钮都在但按不准"，那是更糟的交换。
##
## 【为什么整条抬头都是按钮】触摸没有 hover、也没有 12px 的小箭头可瞄。把抬头整体做成按钮，
## 命中区就是整行（≥ 一个 hit_size），手指不会点空；▾ / ▸ 只是状态的文字提示。
##
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


## 子类重写：分组标题（抬头文字）。
func section_title() -> String:
	return "分组"


## 子类重写：往 body 里填内容（此时主题、层级、抬头都已就绪）。
func _build_body(_body: VBoxContainer) -> void:
	pass


## body 容器（子类需要动态增删内容时用）。
func content() -> VBoxContainer:
	return _body


func _build() -> void:
	var panel := QVoxUi.panel(QVoxUi.space_s())
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	add_child(panel)
	# 本控件通常是 VBoxContainer 的孩子 —— 容器会覆盖 size，故"我有多高"要用
	# custom_minimum_size 报告（直接写 size 会被父容器在下一帧抹掉）。
	panel.resized.connect(func(): custom_minimum_size.y = panel.size.y)

	var col := QVoxUi.vbox(QVoxUi.SPACE_XS)
	panel.add_child(col)

	_header = QVoxUi.button("", "展开 / 收起这一组")
	_header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_header.pressed.connect(func(): expanded = not expanded)
	col.add_child(_header)

	_body = QVoxUi.vbox(QVoxUi.SPACE_XS)
	col.add_child(_body)

	_refresh()
	_build_body(_body)


func _refresh() -> void:
	if _header == null:
		return
	_header.text = "%s  %s" % ["▾" if expanded else "▸", section_title()]
	if _body != null:
		# 折叠时**只隐藏 body**，抬头始终在 —— 否则收起的组会彻底消失，无从再展开。
		_body.visible = expanded
	expanded_changed.emit(expanded)

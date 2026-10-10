@tool
class_name QVoxelierDock
extends QVoxelierPanel
## 右侧抽屉 —— 竖排若干可折叠分组（颜色 / 对象 / 图层 / 变换）。
## 【为什么右列要有个容器，而不是四个各自定位的面板】四个面板各自"记住自己在屏幕哪一行"
## 是四份会互相打架的布局状态：折叠上面那组，下面三组必须整体上移 —— 容器一次就把这件事做完。
## 换句话说，位置关系交给容器，面板只管内容。
## 【为什么贴右上】左上与底部都已占（工具坞 / 视图栏 / 调色板 / 朝向指示器）。
## 右上还顺带贴着"应用栏"的下沿，于是纵向只有一条连续的面板带，视线不必来回横跳。
## 【宽度随密度档】触摸档要更宽（滑块更好点、文字更大），桌面档收窄把视口让出来。

var _scroll: ScrollContainer
var _col: VBoxContainer


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	offset_right = -QVoxelUi.space_m()
	offset_top = QVoxelUi.bar_height() + QVoxelUi.space_m()
	var w := float(QVoxelUi.dock_width()) + QVoxelUi.space_l()
	offset_left = offset_right - w

	# 【为什么必须滚动】右列五组全展开实测约 1400px 高，而默认窗口只有 648 ——
	# 不滚的话「时间轴」「快照」整块落在屏幕外，没有任何入口能到达（既点不到也滚不到）。
	_scroll = QVoxelUi.scroll(true)
	# 【为什么是 FULL_RECT 而不是 TOP_WIDE】ScrollContainer 会裁掉画在自己矩形之外的孩子，
	# 而它的固有高度是 0（滚动容器不把内容算进自己的最小尺寸）。TOP_WIDE 的上下 offset 都是 0，
	# 于是它的矩形高 0 —— 五组全在树上、矩形也都算出来了，就是一个像素都画不出来（整条右列消失）。
	# 本控件不是容器，不会替孩子排版，故这里必须显式让它填满我（见 _fit 写回的矩形）。
	_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_scroll)

	_col = QVoxelUi.vbox(QVoxelUi.space_s())
	_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_col)
	# 高度 = min(内容, 可用高度)：内容短时贴着内容，内容长时定高并在其中滚动。
	# 本控件（它的矩形会被调试器/自动化工具读到）因此始终如实反映画出来的东西。
	_col.resized.connect(_fit)
	get_viewport().size_changed.connect(_fit)


## 右列的矩形：高度 = min(内容固有高, 可用高度)；宽度 = max(设计宽度, 内容固有宽度)。
## 【高度】可用高度 = 视口高 − 顶边位置 − 底部状态栏 − 一点边距（状态栏是全局栏，不该被盖住）。
## 【为什么宽度也要跟着内容走】右列里有"＋组 / ＋模型 / 删除 / ＋滤镜"这种四连按钮行、有
## "缩进 + 开关 + 名字框 + 体素数"的树行，实测固有宽度 216，而设计宽度只有 128。窄了不是
## "挤一点"，是右边缘被整颗裁掉（"＋滤镜"按钮在视口里根本不存在），而横向滚动是关的，
## 用户没有任何办法把它找回来。规则与工具坞的 _fit 同一套：固有尺寸只描述"内容想要多大"。
func _fit() -> void:
	if _col == null:
		return
	var inner := _col.get_combined_minimum_size()
	var avail := get_viewport_rect().size.y - offset_top - QVoxelUi.status_height() - QVoxelUi.space_s()
	offset_bottom = offset_top + maxf(0.0, minf(inner.y, avail))
	offset_left = offset_right - maxf(float(QVoxelUi.dock_width()) + QVoxelUi.space_l(), inner.x)


## 追加一组。**只在 App 装配时调用**（组是从上到下固定的阅读顺序，不支持插队）。
## collapsed = true 表示这一组一进来是收起的（只留一条抬头，点一下才展开）。
func add_section(s: QVoxelierSection, collapsed := false) -> void:
	_col.add_child(s)
	if collapsed:
		s.expanded = false
	_fit()

@tool
extends RefCounted
## ======= 运行期可交互元素查询域 =======
##
## get_interactables: 把当前画面里可交互的东西(**2D 控件 + 3D 物体**)列成**带短引用(ref)的
## 结构化清单**, 供 AI 直接用 ref 驱动 simulate_click / simulate_drag, 不必为拿一个坐标而
## 额外截一次图。
##
## 独立于 take_screenshot 的理由: 截图回答"画面长什么样"(给模型看), 本工具回答"有哪些可点的、
## 各在哪"(给模型定位)。把定位寄生成截图的一个参数, 模型就必须先截图才能点, 而那图只是副产品。
##
## ## 坐标系(本域最易错处, 故置顶)
##
## Control.global_position 是**视口坐标**; 而 Input.parse_input_event 注入的
## InputEventMouseButton.position 是**窗口坐标**(引擎内部再除以 content_scale 映回视口)。
## 两者差一个 content_scale 系数(项目实测约 0.88) —— 把前者直接当点击坐标, 会稳定点在目标
## 左上方约 12%, 且偏移量随分辨率变化, 表现为"某些分辨率下点不准"。
## 故本工具对每个 2D 元素**同时给出两套矩形**, 且 ref 点击由本域在服务端换算: 调用方不需要知道
## content_scale 的存在, 这也是本工具优于"截图 + 自己算"的主要理由。
##
## ## 三套坐标空间(每条元素的 space 字段)
##
## 元素并不都活在同一个空间里, 混为一谈会给出点不中的坐标, 故显式区分:
##   window      —— 主视口内。给两套矩形(viewport_rect / window_rect); 点击按窗口坐标注入。
##   subviewport —— SubViewport 内。本项目把主菜单整块贴在一块 3D 平板模型上(Tablet + SubView3D),
##                  它的 UI 活在子视口里, 与窗口坐标之间没有任何换算关系, 故只给子视口坐标,
##                  点击时由工具直接 push_input 给那个子视口 —— 与真人点 3D 平板时 SubView3D
##                  的投递路径同源(见 addons/DEVFramework/View/SubView3D.gd), 不必再把 3D 命中点
##                  投影回屏幕。
##   3d          —— 3D 物体(Area3D)。**刻意不给矩形**: 它投影到屏幕是个点/梯形, 写一个矩形出来
##                  只会诱导调用方拿它当点击坐标。更关键的是相机可动(本项目 PlayerCamera 有鼠标
##                  跟随视角), 投影位置随相机朝向实时漂移, 任何缓存下来的坐标都会点偏。
##                  故 3D 点击**不投递鼠标事件**, 而是让工具在物体自身上激活(见 simulate_click)。
##
## 依赖: MCPResult + VariantTool。不引用 MCPDevServer。必须带 @tool 且不声明 class_name。

const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")

## ref -> NodePath。以最后一次 get_interactables 为准: 界面一变(节点重建/动画位移)旧 ref 就该
## 重查, 与其让它半失效, 不如让失效**显式** —— resolve_ref 会报"请重新查询", 而不是安静地点到别处。
static var _ref_paths: Dictionary = {}

## 交互判据之一: 有连接才说明"点了有反应"。没挂 pressed 的 Button 点了不会有任何事, 只看类型
## 会把它当成可点目标, AI 点完拿到"没反应"却不知道原因。
const _SIGNALS := ["pressed", "gui_input", "toggled", "value_changed", "item_selected",
	"text_changed", "text_submitted", "item_activated", "focus_entered"]

## 内置交互控件: 一个信号都没连, 但自身行为就是可交互的(输入框、滑动条、列表等)。
const _INTERACTIVE_CLASSES := ["LineEdit", "TextEdit", "Slider", "HSlider", "VSlider",
	"OptionButton", "CheckBox", "CheckButton", "ItemList", "Tree", "TabContainer",
	"ScrollContainer", "FileDialog", "AcceptDialog", "SpinBox"]


static func schema() -> Dictionary:
	return {"type": "object", "properties": {
		"filter": {"type": "string", "enum": ["interactive", "text", "all"],
			"description": "interactive=只返回可交互元素(默认, 最省 token); text=只返回带文字的; all=全部可见元素"},
		"space": {"type": "string", "enum": ["all", "window", "subviewport", "3d"],
			"description": "取哪一类: all=全部(默认); window=主视口 UI; subviewport=子视口 UI; 3d=3D 可交互物体。3D 物体往往比 UI 还多(本项目实测可见 75 个), 要专门点 3D 就用它取子集, 比在默认清单里翻更省"},
		"text_contains": {"type": "string", "description": "按可见文本子串过滤(忽略大小写); 空=不过滤"},
		"class_filter": {"type": "string", "description": "按类名子串过滤(如 Button); 对 3D 元素额外匹配脚本名(如 GameButtonView3D)。注意 2D 只匹配引擎类名(get_class), **不匹配节点名** —— 用节点名筛(如 ValueButton)会返回空, 要按名字找请用 text_contains 或直接看返回里的 name; 空=不过滤"},
		"max_nodes": {"type": "integer", "description": "返回条数上限, 默认 60, 上限 200"},
		"max_depth": {"type": "integer", "description": "遍历深度上限, 默认 24, 上限 32。本项目 UI 最深约 20 层(SettingsPanel 的选项按钮), 给小了只能看到空壳容器; 响应里 depth_capped=true 就是撞上了上限"},
	}}


static func _handle_get_interactables(args: Dictionary) -> Dictionary:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return MCPResult.fail("场景树不可用(游戏未运行?)")
	var filter := VariantTool.get_string(args, "filter", "interactive").strip_edges().to_lower()
	var space_filter := VariantTool.get_string(args, "space", "all").strip_edges().to_lower()
	var text_contains := VariantTool.get_string(args, "text_contains").strip_edges().to_lower()
	var class_filter := VariantTool.get_string(args, "class_filter").strip_edges().to_lower()
	var max_nodes: int = clampi(VariantTool.get_int(args, "max_nodes", 60), 1, 200)
	var max_depth: int = clampi(VariantTool.get_int(args, "max_depth", 24), 1, 32)

	# capped 必须单独报出来: 只报 max_nodes 截断的话, "面板真是空的"与"内容在深度上限之外"
	# 返回的清单长得一模一样(只剩几个空壳容器), 调用方无从下手。实测踩过 —— 设置面板在
	# 第 20 层, 上限 12 时看着像空面板, 白查半天项目代码。
	var controls: Array = []
	var depth_capped: bool = _collect_controls(loop.root, controls, max_depth, 0)
	var areas_3d: Array = []
	if _collect_interactables_3d(loop.root, areas_3d, max_depth, 0):
		depth_capped = true
	var cam := loop.root.get_camera_3d()

	# 先按调用方的筛选条件过滤, 再排序截断 —— 顺序反了会让前 max_nodes 条被背景装饰占满。
	var items: Array = []
	var total_3d := 0
	for node in controls:
		var c := node as Control
		var text := _visible_text(c)
		if not text_contains.is_empty() and not text.to_lower().contains(text_contains):
			continue
		if not class_filter.is_empty() and not c.get_class().to_lower().contains(class_filter):
			continue
		var interactive := _is_interactive(c)
		# 子视口内的元素换用**更严**的判据: 那边几乎所有 Label 都被框架挂了 gui_input(3D 物体的
		# 提示标签就是如此, 一屏就 297 个), 沿用"有信号连接"判会把这些纯展示标签全收进来,
		# 把真正能点的按钮挤光。只认"类型本身就自带交互"的控件。
		var in_window := c.get_viewport() == loop.root
		if not in_window:
			interactive = _is_directly_clickable(c)
		if filter == "interactive" and not interactive:
			continue
		if filter == "text" and text.is_empty():
			continue
		var sp2d := "window" if in_window else "subviewport"
		if space_filter != "all" and space_filter != sp2d:
			continue
		items.append({"node": c, "text": text, "interactive": interactive, "is_3d": false,
			"rank": 0 if in_window else 1, "dist": INF})
	for node3 in areas_3d:
		var n3 := node3 as Node3D
		if space_filter != "all" and space_filter != "3d":
			continue
		var text3 := _interactable_text_3d(n3)
		if not text_contains.is_empty() and not text3.to_lower().contains(text_contains):
			continue
		if not class_filter.is_empty() \
				and not n3.get_class().to_lower().contains(class_filter) \
				and not _script_path(n3).to_lower().contains(class_filter):
			continue
		if filter == "text" and text3.is_empty():
			continue
		total_3d += 1
		items.append({"node": n3, "text": text3, "interactive": true, "is_3d": true,
			"rank": 2, "dist": cam.global_position.distance_to(n3.global_position) if cam != null else INF})

	# 可交互的排前面, 其余按屏幕位置自上而下、同排自左而右 —— 与人读界面的顺序一致,
	# AI 读到的清单顺序也就与它看到的画面一致。3D 整体排在 2D 之后: 它们没有可直接复用的
	# 坐标, 要点得单独指定 ref, 不该在 max_nodes 截断时挤掉能直接点的 2D 元素。
	items.sort_custom(_sort_items)

	var truncated := items.size() > max_nodes
	if truncated:
		items.resize(max_nodes)

	var vp_size := loop.root.get_visible_rect().size
	var scale := window_scale()
	_ref_paths.clear()
	var elements: Array = []
	var count_3d := 0
	for i in items.size():
		var it: Dictionary = items[i]
		var node := it["node"] as Node
		var path := String(node.get_path())
		var ref := "e%d" % (i + 1)
		_ref_paths[ref] = path
		var e := {
			"ref": ref,
			"name": String(node.name),
			"class": node.get_class(),
			"path": path,
			"text": it["text"],
			"interactive": it["interactive"],
		}
		if it["is_3d"]:
			count_3d += 1
			e["space"] = "3d"
			var d: float = it["dist"]
			e["distance"] = null if d == INF else snappedf(d, 0.01)
			var sp3 := _script_path(node)
			if not sp3.is_empty():
				e["script"] = sp3
			# 刻意不给任何矩形: 3D 物体投影到屏幕是个点, 且本项目相机可动, 坐标会漂。
			# 要点它就用 simulate_click(ref=...), 由工具在物体自身上激活。
		else:
			var c2 := node as Control
			var in_window2: bool = it["rank"] == 0
			var r2 := c2.get_global_rect()
			e["space"] = "window" if in_window2 else "subviewport"
			e["viewport_rect"] = {"x": r2.position.x, "y": r2.position.y,
				"w": r2.size.x, "h": r2.size.y}
			if in_window2:
				e["window_rect"] = {"x": r2.position.x * scale.x, "y": r2.position.y * scale.y,
					"w": r2.size.x * scale.x, "h": r2.size.y * scale.y}
			else:
				# 刻意不给 window_rect: 子视口坐标与窗口坐标之间没有换算关系, 写一个出来只会被
				# 当成真坐标用。改为报出子视口自身, 让调用方知道点击会被投递到哪里。
				var sv := c2.get_viewport() as SubViewport
				e["sub_viewport"] = String(sv.get_path()) if sv != null else ""
				e["sub_viewport_size"] = {"x": float(sv.size.x), "y": float(sv.size.y)} if sv != null else {}
			if c2 is BaseButton:
				e["enabled"] = not (c2 as BaseButton).disabled
		elements.append(e)

	var win := Vector2(DisplayServer.window_get_size())
	return MCPResult.ok_json({
		"count": elements.size(),
		"count_3d": count_3d,
		"count_3d_total": total_3d,
		"truncated": truncated,
		"depth_capped": depth_capped,
		"filter": filter,
		"viewport_size": {"x": vp_size.x, "y": vp_size.y},
		"window_size": {"x": win.x, "y": win.y},
		"content_scale": {"x": scale.x, "y": scale.y},
		"elements": elements,
		"hint": "用 simulate_click(ref=...) 直接点, 坐标换算与 3D 激活都由工具做, 你不必自己算。space=window 的元素两套矩形都给了; space=subviewport 的元素在子视口内(本项目主菜单整块贴在 3D 平板上), 只给子视口坐标, 点击会被直接投递进那个子视口; space=3d 是 3D 物体(主菜单按钮/卡牌/媒体按钮都是), 刻意不给坐标——投影点会随相机漂移, 点击由工具在物体自身上激活。3D 元素排在 2D 之后, 若 count_3d < count_3d_total 说明被 max_nodes 截掉了, 用 space=3d 单独查。truncated=true 是被 max_nodes 截断(调大或缩小 space 缩小范围); depth_capped=true 是遍历没走完(调大 max_depth, 或用 space/filter 缩小范围)——两者都true 时面板可能看着空, 其实内容在上限之外, 别急着当项目 bug 查。ref 仅在本次清单内有效, 界面变化后重新查询。",
	})


## 窗口/视口的比例系数。点击坐标换算与布局输出共用这一个口径, 免得两处各算一遍而漂移。
static func window_scale() -> Vector2:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return Vector2.ONE
	var vp := loop.root.get_visible_rect().size
	if vp.x <= 0.0 or vp.y <= 0.0:
		return Vector2.ONE
	var win := Vector2(DisplayServer.window_get_size())
	return Vector2(win.x / vp.x, win.y / vp.y)


## 把上一次的 ref 解析成**当前**的窗口坐标。
##
## 刻意每次重新取实时 rect 而不复用查询时的数值: 界面常在查询与点击之间动(动画、布局重算、
## 分辨率变化)。存死坐标等于把"点偏"从一种原因换成另一种。ref 只当"是哪个节点"的标识,
## 位置永远现取。失效一律显式报错, 绝不退化成"按旧坐标点一下"。
static func resolve_ref(ref: String) -> Dictionary:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return {"ok": false, "error": "场景树不可用(游戏未运行?)"}
	if not _ref_paths.has(ref):
		return {"ok": false, "error": "未知 ref=%s。界面可能已变化, 请重新调用 get_interactables 取新清单。" % ref}
	var path: String = _ref_paths[ref]
	var node := loop.root.get_node_or_null(NodePath(path))
	if node == null:
		_ref_paths.erase(ref)
		return {"ok": false, "error": "ref=%s 指向的节点已不存在(界面已变化), 请重新调用 get_interactables。" % ref}
	if node is Node3D:
		return _resolve_ref_3d(ref, node as Node3D, path)
	var c := node as Control
	if c == null:
		return {"ok": false, "error": "ref=%s 既不是 2D 控件也不是 3D 节点, 请重新查询。" % ref}
	if not c.is_visible_in_tree():
		return {"ok": false, "error": "ref=%s(%s)当前不可见, 请重新调用 get_interactables。" % [ref, c.name]}
	var center := c.get_global_rect().get_center()
	var vp := c.get_viewport()
	if vp != loop.root:
		# 子视口内的元素: get_global_rect() 给的就是子视口像素坐标, 与 SubView3D 把 3D 命中点
		# 换算出来的坐标同一空间 —— 直接投递给该子视口即可命中, 不经过窗口坐标。
		return {
			"ok": true,
			"space": "subviewport",
			"pos": center,
			"sub_viewport_path": String(vp.get_path()),
			"path": path,
			"class": c.get_class(),
			"text": _visible_text(c),
		}
	var scale := window_scale()
	return {
		"ok": true,
		"space": "window",
		"pos": center * scale,
		"viewport_pos": center,
		"path": path,
		"class": c.get_class(),
		"text": _visible_text(c),
	}


## 返回 true = 有子树因触及上限而没被走到(深度上限或节点硬上限), 调用方据此报 depth_capped。
static func _collect_controls(node: Node, out: Array, max_depth: int, depth: int) -> bool:
	# 400 是收集阶段的硬上限: 界面重建时它防住"节点暴涨把一次调用拖死", 不影响结果集大小
	# (真正的上限由调用方的 max_nodes 决定)。
	if depth > max_depth or out.size() >= 400:
		return true
	var capped := false
	for child in node.get_children():
		if child is Control:
			var c := child as Control
			if c.is_visible_in_tree():
				out.append(c)
				if _collect_controls(c, out, max_depth, depth + 1):
					capped = true
			# 不可见的 Control 直接剪枝: 其子树的 is_visible_in_tree 必然也是 false,
			# 走进去只会在每帧变化的深层树上白跑一遍(这是本域唯一的性能热点)。
		elif _collect_controls(child, out, max_depth, depth + 1):
			capped = true
	return capped


static func _sort_items(a: Dictionary, b: Dictionary) -> bool:
	# 分层: 主视口 UI → 子视口 UI → 3D 物体。3D 排在最后不是"低一等", 而是它没有可直接
	# 复用的坐标(要另行指定 ref 激活), 不该在 max_nodes 截断时挤掉能直接点的 2D 元素。
	if a["rank"] != b["rank"]:
		return a["rank"] < b["rank"]
	if a["is_3d"]:
		# 3D 组内按离相机由近到远 —— 近的先入眼, 与人读画面的顺序一致。
		# 相机不可得时 dist 为 INF, 全体相等, 相对顺序保持插入序(稳定)。
		return a["dist"] < b["dist"]
	if a["interactive"] != b["interactive"]:
		return a["interactive"]
	var ra: Rect2 = (a["node"] as Control).get_global_rect()
	var rb: Rect2 = (b["node"] as Control).get_global_rect()
	if absf(ra.position.y - rb.position.y) > 8.0:
		return ra.position.y < rb.position.y
	return ra.position.x < rb.position.x


static func _visible_text(c: Control) -> String:
	# Label 与 BaseButton 各自都有 text, 但两者**无继承关系**(都直接继承 Control), 故必须分开
	# 判并各自 as 回具体类型: 写成 `c is BaseButton or c is Label` 再统一 as BaseButton,
	# 遇到 Label 会拿到 null, 再取 .text 就是运行时空引用崩溃。
	if c is Label:
		return (c as Label).text
	# RichTextLabel 的 text 存的是 bbcode 源码, 且用 append_text() 追加的内容不会写回 text,
	# 直接取恒为空串(3D 提示标签就是这种用法); 故空时回退到解析后的纯文本。
	if c is RichTextLabel:
		var rtl := c as RichTextLabel
		return rtl.text if not rtl.text.is_empty() else rtl.get_parsed_text()
	if c is BaseButton:
		return (c as BaseButton).text
	if c is LineEdit:
		return (c as LineEdit).text
	if c is TextEdit:
		return (c as TextEdit).text
	return ""


static func _is_interactive(c: Control) -> bool:
	# 先剔除"明确不可交互"的, 否则会把 disabled 的按钮当成可点目标, AI 点完只看到"没反应"。
	if c is BaseButton and (c as BaseButton).disabled:
		return false
	if c is LineEdit and not (c as LineEdit).editable:
		return false
	if c is BaseButton or _INTERACTIVE_CLASSES.has(c.get_class()):
		return true
	for sig in _SIGNALS:
		if not c.get_signal_connection_list(sig).is_empty():
			return true
	return false


## 子视口内元素专用的判据: 只认"类型本身就自带交互"的控件, 不看信号连接。
##
## 与 _is_interactive 的差别不是宽严松紧, 而是那边的一条数据在这个项目里不成立: 子视口中的
## Label 几乎都被 SubView3D 挂上了 gui_input(3D 物体的提示标签就有 297 个), 照"有连接"
## 判会把纯展示标签全当成可点目标。按类型判则只剩按钮/输入框这类真能点的。
static func _is_directly_clickable(c: Control) -> bool:
	if c is BaseButton:
		return not (c as BaseButton).disabled
	if c is LineEdit:
		return (c as LineEdit).editable
	return _INTERACTIVE_CLASSES.has(c.get_class())


# ============================================================
# 3D 可交互物体
# ============================================================

## 收集 3D 可交互物体(CollisionObject3D 子树里"能被人点"的那些)。
##
## 判据取鸭子类型而非某个类: 项目里 3D 交互物收敛在 ButtonView3D(Area3D) 一条继承链上, 但
## 约定并未被强制(SplitFlap 就绕过基类自写 _input_event), 认类会漏。InputTool 驱动手柄焦点
## 导航时用的是同一套判据, 这里与它保持一致。
static func _collect_interactables_3d(node: Node, out: Array, max_depth: int, depth: int) -> bool:
	if depth > max_depth or out.size() >= 400:
		return true
	var capped := false
	for child in node.get_children():
		if child is CollisionObject3D:
			var co := child as CollisionObject3D
			# input_ray_pickable 才是"点得到"的物理前提; 不可见的一律不进清单。
			if co.input_ray_pickable and co.is_visible_in_tree() and _is_interactable_3d(co):
				out.append(co)
		# 刻意不像 2D 那样对不可见节点剪枝: 3D 这边节点数远小于 Control, 为省一遍遍历而
		# 冒着漏报的风险不值得。
		if _collect_interactables_3d(child, out, max_depth, depth + 1):
			capped = true
	return capped


static func _is_interactable_3d(n: CollisionObject3D) -> bool:
	if n.has_method("is_disabled") and n.is_disabled():
		return false
	return n.has_method("activate") or n.has_method("_mouse_down")


## 3D 元素的文本: 走项目自己的提示来源, 与 TipPanel.open_panel 读的是同一组属性。
##
## 刻意不调 data.get_desc(context) —— 那要先构造并 game_ready 一个 GameContext, 是有副作用的
## 游戏逻辑, 一个"列清单"的只读工具不该碰它。取不到就交白: name/script/distance 足够 AI 认人。
static func _interactable_text_3d(n: Node3D) -> String:
	if "click_tip" in n:
		var s := str(n.get("click_tip")).strip_edges()
		if not s.is_empty():
			return s
	if "data" in n:
		var data = n.get("data")
		# 属性存在性用 in 检查而非直接 get: get 命中不存在的属性会刷错误日志, 而全树遍历
		# 必然碰到大量没有这些属性的普通 CollisionObject3D。
		if data != null and (data is Object or data is Dictionary) and "def" in data:
			var def = data.get("def")
			if def is Resource:
				return String((def as Resource).resource_name)
	return ""


static func _script_path(n: Node) -> String:
	var sc := n.get_script()
	return String(sc.resource_path) if sc != null else ""


## 3D ref 的解析: **刻意不产出坐标**, 只确认"这个 ref 现在还能被激活"。
##
## 调用方(simulate_click)拿到 space=3d 后走物体自身的 activate(), 而不是注入鼠标事件 ——
## 理由见 MCPDevServer._call_simulate_click 的 3D 分支注释。
static func _resolve_ref_3d(ref: String, n: Node3D, path: String) -> Dictionary:
	if not n.is_visible_in_tree():
		return {"ok": false, "error": "ref=%s(%s)当前不可见, 请重新调用 get_interactables。" % [ref, n.name]}
	var vp := n.get_viewport()
	var cam := vp.get_camera_3d() if vp != null else null
	return {
		"ok": true,
		"space": "3d",
		"path": path,
		"class": n.get_class(),
		"text": _interactable_text_3d(n),
		"distance": null if cam == null else snappedf(cam.global_position.distance_to(n.global_position), 0.01),
	}

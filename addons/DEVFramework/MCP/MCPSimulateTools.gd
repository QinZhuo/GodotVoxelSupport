@tool
extends RefCounted

## ======= 游戏内 UI 交互域 =======
## 画面查询(get_interactables) + 输入模拟(simulate_*) + 条件等待(wait_for)。
## 全部在**游戏进程内**执行; 编辑器进程经调试线转发(转发壳在 MCPDevServer)。
## **必须带 @tool 且不声明 class_name**, 理由见 MCPDevServer 顶部"工具域文件"一段。
const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPToolContract := preload("res://addons/DEVFramework/MCP/MCPToolContract.gd")
const MCPUITools := preload("res://addons/DEVFramework/MCP/MCPUITools.gd")

## wait_for 的条件种类(schema 的 enum 与实现共用同一份)。
const WAIT_CONDITIONS := ["text_visible", "text_gone", "node_exists", "node_gone", "value", "time"]


## 本域的工具清单(顺序即 tools/list 顺序: "先查后点"的使用顺序)。
## 宿主遍历它调用 _register_game_play_tool 注册 —— 元数据与实现同居, 宿主不再手写一遍。
static func tools() -> Array:
	return [
		{
			"name": "get_interactables",
			"desc": "列出当前画面可交互的 2D 控件与 3D 物体, 每条带短引用 ref(如 e3)。**先查后点**: 拿到 ref 后交给 simulate_click(ref=e3), 服务端解析成实时位置, 界面动了也不会点偏。2D 给两套矩形, 3D 刻意不给坐标。【只读】。详见 resources: devframework://docs/simulate_ui",
			"schema": MCPUITools.schema(),
			"handler": MCPUITools._handle_get_interactables,
		},
		{
			"name": "simulate_click",
			"desc": "在游戏窗口模拟鼠标左键点击(按下+释放)。**推荐先 get_interactables 拿 ref, 再 ref=e3**: 服务端解析实时位置, 不必自己换算坐标(3D 物体在物体自身上激活、子视口元素直接 push_input, 这两类用 x/y 永远点不到)。也可直接传 x/y。【副作用】真实输入事件, 重复调用重复触发, 不可自动重试; 游戏未运行会失败。详见 resources: devframework://docs/simulate_ui",
			"schema": MCPToolContract.simulate_click(),
			"handler": _handle_simulate_click,
		},
		{
			"name": "simulate_drag",
			"desc": "在游戏窗口模拟拖拽(按下→移动→释放)。坐标是**窗口坐标**。【副作用】真实输入事件, 重复调用会重复触发(重复拾取/重复移动), 不可自动重试; 游戏未运行会失败。",
			"schema": MCPToolContract.simulate_drag(),
			"handler": _handle_simulate_drag,
		},
		{
			"name": "simulate_key",
			"desc": "在游戏窗口模拟键盘按键(按下/释放)。只认内置键名表(space/enter/escape/tab/方向键/修饰键/单字符)。【副作用】真实输入事件, 重复调用会重复触发(重复跳两次/重复扣血), 不可自动重试; 游戏未运行会失败。中文等文本输入请用 simulate_text。",
			"schema": MCPToolContract.simulate_key(),
			"handler": _handle_simulate_key,
		},
		{
			"name": "simulate_text",
			"desc": "往输入框(LineEdit/TextEdit)里输入文本, 支持中文等任意字符。**不是**逐字符注入按键(直接调 insert_text_at_caret), 所以验证的是'输入之后的业务链路'(校验/提交/回填), 不是输入法本身。ref 优先, 也可给 path; replace=true(默认)先清空, submit=true 再发一次回车(触发 text_submitted)。【副作用】驱动真实业务逻辑, 重复调用会重复提交。",
			"schema": MCPToolContract.simulate_text(),
			"handler": _handle_simulate_text,
		},
		{
			"name": "simulate_scroll",
			"desc": "在游戏窗口发送滚轮事件(WHEEL_UP/DOWN), 用于滚动列表/滚动容器(这类控件不响应键盘翻页)。amount 正数=向下、负数=向上; ref 指定滚到哪个控件上, 省略则用 x/y 或视口中心。【副作用】真实输入事件, 重复调用会重复滚动。",
			"schema": MCPToolContract.simulate_scroll(),
			"handler": _handle_simulate_scroll,
		},
		{
			"name": "wait_for",
			"desc": "等待游戏里的条件成立再返回(内部轮询, 成立即返回, 超时返回 isError 并附最后一次观察到的值)。condition: text_visible=画面上出现含该文本的可见控件; text_gone=该文本消失; node_exists/node_gone=按节点路径(或名字); value=某节点属性等于期望值; time=单纯等 timeout_ms 毫秒。点击/输入之后等动画或加载结束用它, 别用固定 sleep。【只读】不驱动任何输入。",
			"schema": {
				"type": "object",
				"properties": {
					"condition": {"type": "string", "enum": WAIT_CONDITIONS, "description": "等待的条件种类"},
					"text": {"type": "string", "description": "condition=text_visible/text_gone 时: 要出现/消失的可见文本子串(忽略大小写)"},
					"path": {"type": "string", "description": "condition=node_exists/node_gone/value 时: 节点路径(绝对 /root/... 或相对场景根)或节点名字"},
					"property": {"type": "string", "description": "condition=value 时: 要比对的属性名"},
					"expected": {"description": "condition=value 时: 期望值(数字/字符串/布尔; 字符串与属性值按文本比较)"},
					"timeout_ms": {"type": "integer", "description": "最长等待毫秒数, 默认 5000, 上限 60000"},
					"interval_ms": {"type": "integer", "description": "轮询间隔毫秒, 默认 100, 最小 30"},
				},
				"required": ["condition"],
			},
			"handler": _handle_wait_for,
		},
	]


## ======= 输入模拟 =======

## 模拟鼠标左键点击。
## x/y 是调用方**自报**坐标系(space, 默认 window): Input.parse_input_event 收的是窗口坐标,
## 换分辨率就偏, 故不自作换算。ref 则交给 MCPUITools 解析成实时位置。
static func _handle_simulate_click(args: Dictionary) -> Dictionary:
	var pos := Vector2.ZERO
	var space := ""
	var target_space := "window"
	var sub_vp_path := ""
	var ref := VariantTool.get_string(args, "ref").strip_edges()
	if not ref.is_empty():
		var r := MCPUITools.resolve_ref(ref)
		if not bool(r.get("ok")):
			return MCPResult.fail(str(r.get("error", "ref 解析失败")))
		target_space = str(r.get("space", "window"))
		if target_space == "3d":
			return _activate_interactable_3d(str(r.get("path", "")), ref)
		pos = r["pos"]
		sub_vp_path = str(r.get("sub_viewport_path", ""))
	else:
		if not args.has("x") or not args.has("y"):
			return MCPResult.fail("需提供 ref(get_interactables 返回的元素引用), 或 x + y; 可加 space 声明 x/y 属于 window(默认) 还是 viewport")
		space = VariantTool.get_string(args, "space", "window").strip_edges().to_lower()
		if space != "window" and space != "viewport":
			return MCPResult.fail("space 只能是 window 或 viewport, 收到: %s; 子视口里的 UI(space=subviewport)请改用 ref 点击" % space)
		pos = Vector2(VariantTool.get_int(args, "x"), VariantTool.get_int(args, "y"))
		if space == "viewport":
			pos *= MCPUITools.window_scale()
	var sub_vp: SubViewport = null
	if not sub_vp_path.is_empty():
		var loop := _tree()
		if loop == null or loop.root == null:
			return MCPResult.fail("场景树不可用(游戏未运行?)")
		sub_vp = loop.root.get_node_or_null(NodePath(sub_vp_path)) as SubViewport
		if sub_vp == null:
			return MCPResult.fail("ref=%s 所在的子视口已不存在(界面已变化), 请重新调用 get_interactables。" % ref)
	var down_event := InputEventMouseButton.new()
	down_event.button_index = MOUSE_BUTTON_LEFT
	down_event.pressed = true
	down_event.position = pos
	down_event.global_position = pos
	var up_event := InputEventMouseButton.new()
	up_event.button_index = MOUSE_BUTTON_LEFT
	up_event.pressed = false
	up_event.position = pos
	up_event.global_position = pos
	if sub_vp != null:
		# 子视口元素: 直接投递给那个子视口, 与真人点 3D 平板的投递路径同源。
		# 必须先补一个 motion 建立 hover: push_input 是同步处理的, 不先"挪到"目标上,
		# 紧随其后的 press/release 不会让 BaseButton 进入按下态。
		var move_event := InputEventMouseMotion.new()
		move_event.position = pos
		move_event.global_position = pos
		sub_vp.push_input(move_event)
		sub_vp.push_input(down_event)
		sub_vp.push_input(up_event)
	else:
		Input.parse_input_event(down_event)
		Input.parse_input_event(up_event)
	return MCPResult.ok_json({
		"position": {"x": pos.x, "y": pos.y},
		"located_by": ("ref=%s" % ref) if not ref.is_empty() else ("x/y(space=%s)" % space),
		"space": target_space,
		"message": "鼠标左键点击事件已发送" if sub_vp == null else "鼠标左键点击事件已投递到子视口 %s" % sub_vp_path
	})


## 在 3D 物体自身上激活一次点击(不注入鼠标事件: 相机可动, 投影坐标必点偏)。
static func _activate_interactable_3d(path: String, ref: String) -> Dictionary:
	var loop := _tree()
	if loop == null or loop.root == null:
		return MCPResult.fail("场景树不可用(游戏未运行?)")
	# 刻意声明为 Variant: activate()/_mouse_down() 不在基类上, 按 Node 静态类型调用过不了编译。
	var node: Variant = loop.root.get_node_or_null(NodePath(path))
	if node == null:
		return MCPResult.fail("ref=%s 指向的 3D 物体已不存在(界面已变化), 请重新调用 get_interactables。" % ref)
	if node.has_method("activate"):
		node.activate()
	elif node.has_method("_mouse_down") and node.has_method("_mouse_up"):
		node._mouse_down()
		node._mouse_up()
	else:
		return MCPResult.fail("3D 物体 %s 既无 activate() 也无 _mouse_down/_mouse_up, 无法激活" % node.name)
	return MCPResult.ok_json({
		"located_by": "ref=%s" % ref,
		"space": "3d",
		"path": path,
		"message": "已在 3D 物体 %s 上激活一次点击(未注入鼠标事件)" % node.name,
	})


## 模拟鼠标拖拽(左键按下 -> 分步移动到目标 -> 释放)。分步是为了让拖拽类控件收到中间 motion。
static func _handle_simulate_drag(args: Dictionary) -> Dictionary:
	var from_x: int = VariantTool.get_int(args, "from_x")
	var from_y: int = VariantTool.get_int(args, "from_y")
	var to_x: int = VariantTool.get_int(args, "to_x")
	var to_y: int = VariantTool.get_int(args, "to_y")
	var down_event := InputEventMouseButton.new()
	down_event.button_index = MOUSE_BUTTON_LEFT
	down_event.pressed = true
	down_event.position = Vector2(from_x, from_y)
	down_event.global_position = Vector2(from_x, from_y)
	Input.parse_input_event(down_event)
	var steps := 15
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		var current_x := lerpf(float(from_x), float(to_x), t)
		var current_y := lerpf(float(from_y), float(to_y), t)
		var move_event := InputEventMouseMotion.new()
		move_event.position = Vector2(current_x, current_y)
		move_event.global_position = Vector2(current_x, current_y)
		move_event.relative = Vector2(current_x - from_x, current_y - from_y) if i > 0 else Vector2.ZERO
		move_event.button_mask = MOUSE_BUTTON_MASK_LEFT
		Input.parse_input_event(move_event)
		if i < steps:
			var loop := _tree()
			if loop != null:
				await loop.create_timer(0.016).timeout
	var up_event := InputEventMouseButton.new()
	up_event.button_index = MOUSE_BUTTON_LEFT
	up_event.pressed = false
	up_event.position = Vector2(to_x, to_y)
	up_event.global_position = Vector2(to_x, to_y)
	Input.parse_input_event(up_event)
	return MCPResult.ok_json({
		"from": {"x": from_x, "y": from_y},
		"to": {"x": to_x, "y": to_y},
		"message": "拖拽事件已发送"
	})


## 模拟键盘按键。只认内置键名表 + 单字符。
static func _handle_simulate_key(args: Dictionary) -> Dictionary:
	var key_str: String = VariantTool.get_string(args, "key").to_lower()
	var pressed := VariantTool.get_bool(args, "pressed", true)
	var key_code: Key
	match key_str:
		"space": key_code = KEY_SPACE
		"enter": key_code = KEY_ENTER
		"escape": key_code = KEY_ESCAPE
		"tab": key_code = KEY_TAB
		"backspace": key_code = KEY_BACKSPACE
		"delete": key_code = KEY_DELETE
		"up": key_code = KEY_UP
		"down": key_code = KEY_DOWN
		"left": key_code = KEY_LEFT
		"right": key_code = KEY_RIGHT
		"shift": key_code = KEY_SHIFT
		"ctrl": key_code = KEY_CTRL
		"alt": key_code = KEY_ALT
		_:
			if key_str.length() == 1:
				key_code = key_str.to_upper().unicode_at(0)
			else:
				return MCPResult.fail("未知的按键: %s" % key_str)
	var event := InputEventKey.new()
	event.keycode = key_code
	event.pressed = pressed
	Input.parse_input_event(event)
	return MCPResult.ok_json({
		"key": key_str,
		"pressed": pressed,
		"message": "按键事件已发送"
	})


## 往输入控件里输入文本。走控件自己的编辑 API(insert_text_at_caret), 不逐字符注入 InputEventKey:
## 后者要自己处理 IME、修饰键、选区与光标, 且中文根本注入不进去。代价是绕过了"按键→控件"那一段,
## 所以它验证的是"输入之后的业务链路", 不是输入法本身。
static func _handle_simulate_text(args: Dictionary) -> Dictionary:
	var text := VariantTool.get_string(args, "text")
	if text.is_empty():
		return MCPResult.fail("text 不能为空")
	var node := _resolve_target(args, "输入控件")
	if node.has("error"):
		return MCPResult.fail(str(node["error"]))
	var ctrl: Variant = node["node"]
	if not (ctrl is LineEdit) and not (ctrl is TextEdit):
		return MCPResult.fail("目标 %s [%s] 不是输入控件(只支持 LineEdit / TextEdit); 先用 get_interactables 找到输入框" % [str(ctrl.name), ctrl.get_class()])
	if not ctrl.is_visible_in_tree():
		return MCPResult.fail("目标 %s 当前不可见" % str(ctrl.name))
	ctrl.grab_focus()
	if VariantTool.get_bool(args, "replace", true):
		ctrl.clear()
	ctrl.insert_text_at_caret(text)
	var submit := VariantTool.get_bool(args, "submit", false)
	if submit:
		if ctrl is LineEdit:
			# 与真人回车同路: LineEdit 的 text_submitted 只在收到回车时发。
			(ctrl as LineEdit).text_submitted.emit((ctrl as LineEdit).text)
		else:
			ctrl.insert_text_at_caret("\n")
	return MCPResult.ok_json({
		"path": str(ctrl.get_path()),
		"class": ctrl.get_class(),
		"text": ctrl.text if ctrl is LineEdit else ctrl.get_parsed_text(),
		"submitted": submit,
		"message": "已向 %s 输入 %d 个字符%s" % [str(ctrl.name), text.length(), ("并提交" if submit else "")],
	})


## 滚轮。列表/滚动容器只认 WHEEL_UP/WHEEL_DOWN, 键盘翻页并不等价。
static func _handle_simulate_scroll(args: Dictionary) -> Dictionary:
	var amount := VariantTool.get_int(args, "amount", 1)
	if amount == 0:
		return MCPResult.fail("amount 不能为 0(正数=向下, 负数=向上)")
	var pos := Vector2.ZERO
	var located := ""
	var sub_vp: SubViewport = null
	var ref := VariantTool.get_string(args, "ref").strip_edges()
	if not ref.is_empty():
		var r := MCPUITools.resolve_ref(ref)
		if not bool(r.get("ok")):
			return MCPResult.fail(str(r.get("error", "ref 解析失败")))
		if str(r.get("space", "")) == "3d":
			return MCPResult.fail("ref=%s 指向 3D 物体, 滚轮只对 2D 控件/视口有意义" % ref)
		pos = r["pos"]
		located = "ref=%s" % ref
		var svp := str(r.get("sub_viewport_path", ""))
		if not svp.is_empty():
			var loop := _tree()
			if loop == null or loop.root == null:
				return MCPResult.fail("场景树不可用(游戏未运行?)")
			sub_vp = loop.root.get_node_or_null(NodePath(svp)) as SubViewport
			if sub_vp == null:
				return MCPResult.fail("ref=%s 所在的子视口已不存在(界面已变化), 请重新调用 get_interactables。" % ref)
	else:
		if args.has("x") and args.has("y"):
			pos = Vector2(VariantTool.get_int(args, "x"), VariantTool.get_int(args, "y"))
			located = "x/y(窗口坐标)"
		else:
			# 不给坐标就滚视口中心: 全屏列表这类场景里, 中心点几乎总在可滚区域内。
			var vp_node: Viewport = _viewport()
			if vp_node == null:
				return MCPResult.fail("无法获取游戏视口")
			pos = vp_node.get_visible_rect().size * 0.5
			located = "视口中心(未给 ref 与 x/y)"
	var dir := MOUSE_BUTTON_WHEEL_DOWN if amount > 0 else MOUSE_BUTTON_WHEEL_UP
	var steps := absi(amount)
	for i in steps:
		var ev := InputEventMouseButton.new()
		ev.button_index = dir
		ev.pressed = true
		ev.position = pos
		ev.global_position = pos
		ev.factor = 1.0
		if sub_vp != null:
			sub_vp.push_input(ev)
		else:
			Input.parse_input_event(ev)
		var rel := InputEventMouseButton.new()
		rel.button_index = dir
		rel.pressed = false
		rel.position = pos
		rel.global_position = pos
		rel.factor = 1.0
		if sub_vp != null:
			sub_vp.push_input(rel)
		else:
			Input.parse_input_event(rel)
	return MCPResult.ok_json({
		"amount": amount,
		"direction": "down" if amount > 0 else "up",
		"located_by": located,
		"position": {"x": pos.x, "y": pos.y},
		"message": "已向%s投递 %d 次滚轮%s事件" % [("子视口 " + str(sub_vp.get_path()) + " ") if sub_vp != null else " ", steps, "向下" if amount > 0 else "向上"],
	})


## ======= 条件等待 =======

## 把"等条件成立"的轮询收进服务器。写死 sleep 无法区分"还没好"与"条件写错了";
## 这里把最后一次观察到的实际值一并带回去, 两者就能当场区分。
static func _handle_wait_for(args: Dictionary) -> Dictionary:
	var c := VariantTool.get_string(args, "condition", "").strip_edges()
	if not c in WAIT_CONDITIONS:
		return MCPResult.err_validation("condition 无效: '%s'" % c, "可选: %s" % " / ".join(WAIT_CONDITIONS))
	var timeout_ms: int = clampi(VariantTool.get_int(args, "timeout_ms", 5000), 0, 60000)
	var interval_ms: int = clampi(VariantTool.get_int(args, "interval_ms", 100), 30, 2000)
	var text := VariantTool.get_string(args, "text", "")
	var path := VariantTool.get_string(args, "path", "")
	var property := VariantTool.get_string(args, "property", "")
	var expected: Variant = args.get("expected", null)
	# 前置校验: 缺参立刻报错而不是等满 timeout —— 否则调用方从"超时"里读不出是自己写错了。
	if c in ["text_visible", "text_gone"] and text.is_empty():
		return MCPResult.err_validation("condition=%s 需要 text" % c, "传 text(要出现/消失的可见文本子串)")
	if c in ["node_exists", "node_gone", "value"] and path.is_empty():
		return MCPResult.err_validation("condition=%s 需要 path" % c, "传节点路径(/root/... 或相对场景根)或节点名字")
	if c == "value" and property.is_empty():
		return MCPResult.err_validation("condition=value 需要 property" % c, "传要比对的属性名, 如 text / visible / position")
	var loop := _tree()
	if loop == null:
		return MCPResult.fail("场景树不可用(游戏未运行?)")
	if c == "time":
		if timeout_ms > 0:
			await loop.create_timer(float(timeout_ms) / 1000.0).timeout
		return MCPResult.ok_json({"condition": c, "met": true, "probes": 0, "waited_ms": timeout_ms, "observed": null})
	var started := Time.get_ticks_msec()
	var deadline := started + timeout_ms
	var probes := 0
	var last := ""
	while true:
		probes += 1
		var seen := _probe(c, text, path, property, expected)
		last = str(seen.get("observed", ""))
		if bool(seen.get("ok", false)):
			return MCPResult.ok_json({"condition": c, "met": true, "probes": probes,
				"waited_ms": Time.get_ticks_msec() - started, "observed": seen.get("observed", null)})
		if Time.get_ticks_msec() >= deadline:
			break
		await loop.create_timer(float(interval_ms) / 1000.0).timeout
	return MCPResult.err("等待条件超时(%d ms, 轮询 %d 次): %s。最后一次观察值: %s" % [timeout_ms, probes, c, last],
		MCPResult.CAT_TRANSIENT, true,
		"先确认条件本身写对(text/path/property 是否指向真实存在的目标 —— 观察值已给出实际是什么); 条件无误则调大 timeout_ms")


## 单次探测。observed 一律回"当前实际是什么", 用来区分"没等到"与"写错了"。
static func _probe(c: String, text: String, path: String, property: String, expected: Variant) -> Dictionary:
	var loop := _tree()
	if loop == null or loop.root == null:
		return {"ok": false, "observed": "场景树不可用"}
	match c:
		"text_visible", "text_gone":
			var needle := text.to_lower()
			var found := ""
			var stack: Array = [loop.root]
			while not stack.is_empty():
				var n: Node = stack.pop_back()
				var t := ""
				if n is Label:
					t = (n as Label).text
				elif n is BaseButton:
					t = (n as BaseButton).text
				elif n is LineEdit:
					t = (n as LineEdit).text
				elif n is TextEdit:
					t = (n as TextEdit).text
				if not t.is_empty() and t.to_lower().contains(needle) and (n as Control).is_visible_in_tree():
					found = t
					break
				for ch in n.get_children():
					stack.append(ch)
			var hit := not found.is_empty()
			return {"ok": hit if c == "text_visible" else not hit,
				"observed": ("找到: " + found) if hit else "画面上没有包含该文本的可见控件"}
		"node_exists", "node_gone":
			var node := _find_node(loop, path)
			var exists := node != null
			return {"ok": exists if c == "node_exists" else not exists,
				"observed": ("存在: " + str(node.get_path())) if exists else "找不到该节点"}
		"value":
			var node2 := _find_node(loop, path)
			if node2 == null:
				return {"ok": false, "observed": "找不到该节点: %s" % path}
			if not _has_prop(node2, property):
				return {"ok": false, "observed": "节点 %s 没有属性 %s" % [str(node2.name), property]}
			var actual: Variant = node2.get(property)
			return {"ok": _value_matches(actual, expected), "observed": str(actual)}
	return {"ok": false, "observed": "未知的 condition"}


## 按路径找节点: 先当绝对/相对路径, 再当名字在全树里找(名字是调用方最常用的写法)。
static func _find_node(loop: SceneTree, path: String) -> Node:
	var n := loop.root.get_node_or_null(NodePath(path))
	if n == null and loop.current_scene != null:
		n = loop.current_scene.get_node_or_null(NodePath(path))
		if n == null:
			# 也接受「场景根/子路径」: 场景根未必直接挂在 /root 下(编辑器里就在 @EditorNode 子树里),
			# 而 get_node_info 给的正是相对场景根的路径 —— 两边写法定要能互通。
			var root_name := str(loop.current_scene.name)
			if path.begins_with(root_name + "/"):
				n = loop.current_scene.get_node_or_null(NodePath(path.substr(root_name.length() + 1)))
	if n == null:
		n = loop.root.find_child(path, true, false)
	return n


static func _has_prop(node: Node, property: String) -> bool:
	for p in node.get_property_list():
		if str(p.name) == property:
			return true
	return false


## 期望值比对: 数字按容差比, 其余按文本比 —— 调用方写 "true"/true 不该有两种结果。
static func _value_matches(actual: Variant, expected: Variant) -> bool:
	if actual is float or actual is int:
		var e := str(expected)
		if e.is_valid_float():
			return absf(float(actual) - e.to_float()) < 0.0001
		return str(actual) == e
	if actual is bool:
		return str(actual).to_lower() == str(expected).to_lower()
	return str(actual) == str(expected)


## simulate_text / simulate_scroll 共用的目标解析: ref 优先, 否则 path, 否则报错。
## 返回 {node: Node} 或 {error: String} —— 不用 Dictionary 的 null 判别: Node 可能真为 null。
static func _resolve_target(args: Dictionary, what: String) -> Dictionary:
	var ref := VariantTool.get_string(args, "ref").strip_edges()
	var loop := _tree()
	if loop == null or loop.root == null:
		return {"error": "场景树不可用(游戏未运行?)"}
	if not ref.is_empty():
		var r := MCPUITools.resolve_ref(ref)
		if not bool(r.get("ok")):
			return {"error": str(r.get("error", "ref 解析失败"))}
		if str(r.get("space", "")) == "3d":
			return {"error": "ref=%s 指向 3D 物体, %s 只支持 2D 控件" % [ref, what]}
		var n := loop.root.get_node_or_null(NodePath(str(r.get("path", ""))))
		if n == null:
			return {"error": "ref=%s 指向的节点已不存在(界面已变化), 请重新调用 get_interactables。" % ref}
		return {"node": n}
	var path := VariantTool.get_string(args, "path").strip_edges()
	if path.is_empty():
		return {"error": "需要 ref(get_interactables 返回的元素引用)或 path(节点路径)"}
	var by_path := loop.root.get_node_or_null(NodePath(path))
	if by_path == null and loop.current_scene != null:
		by_path = loop.current_scene.get_node_or_null(NodePath(path))
	if by_path == null:
		return {"error": "找不到节点: %s(路径相对 /root; 也给相对游戏场景根的写法)" % path}
	return {"node": by_path}


## 本域没有 Node 宿主(纯 RefCounted), 场景树只能从主循环取。
static func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


static func _viewport() -> Viewport:
	var loop := _tree()
	return loop.root if loop != null else null

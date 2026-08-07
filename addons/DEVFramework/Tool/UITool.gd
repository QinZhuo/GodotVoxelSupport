## UI 管理器
##
## 纯栈管理器，不负责面板的显示/隐藏。
## 负责 UI 面板的注册/注销、栈排序、返回路由（[method back]）、焦点管理。
## UI 面板需预先摆放在场景树中，通过 [Panel2D] / [UIPanel3D] 的 [method open] / [method close] 同时完成显示与注册。
##
## 职责划分：
##   [b]Panel2D/UIPanel3D[/b] — 显示/隐藏动画、生命周期信号
##   [b]UITool[/b]            — 栈管理、层级互斥、返回路由、焦点管理
##
## 基于 [enum Layer] 将 UI 分为 6 种类型，每种类型有独立的行为逻辑：
##
##   [b]BACKGROUND (0)[/b] — 常驻背景层
##     入栈管理、最低优先级。
##
##   [b]HUD (100)[/b] — 抬头显示层
##     入栈管理、多元素共存、不参与 back() 返回键。
##
##   [b]PANEL (200)[/b] — 主界面层
##     入栈管理、多元素共存、参与 back() 返回键。完整生命周期。
##
##   [b]DIALOG (300)[/b] — 对话框层
##     同层互斥：打开新 DIALOG 时自动关闭已有 DIALOG。参与 back() 返回键。
##
##   [b]TOOLTIP (400)[/b] — 提示层
##     不入栈，单独管理。单实例：同时只允许一个 TOOLTIP。
##
##   [b]TOP (500)[/b] — 系统顶层
##     最高优先级，覆盖一切。用于 Loading、系统通知等。
##
## 使用方式：
##   [codeblock]
##   panel.open()                          # 显示面板并注册到 UITool（推荐）
##   panel.close()                         # 隐藏面板并从 UITool 注销（推荐）
##   UITool.register(panel)                # 仅注册到栈（不触发显示）
##   UITool.unregister(panel)              # 仅从栈注销（不触发隐藏）
##   UITool.toggle(panel)                  # 切换
##   UITool.back()                         # 返回键处理
##   UITool.is_focus(panel)                # 面板是否拥有焦点
##   UITool.Layer.PANEL                    # 层级常量
##   [/codeblock]
class_name UITool

## UI 层级常量，数字越大越靠前。
##
## 不同层级对应不同的 UI 类型和交互行为（见类文档）。
## [br]0: BACKGROUND — 背景
## [br]100: HUD — 抬头显示
## [br]200: PANEL — 主界面
## [br]300: DIALOG — 对话框
## [br]400: TOOLTIP — 提示
## [br]500: TOP — 系统顶层
enum Layer {
	BACKGROUND = 0,
	HUD = 100,
	PANEL = 200,
	DIALOG = 300,
	TOOLTIP = 400,
	TOP = 500,
}

# ============================================================
# 内部状态
# ============================================================

## 常规 UI 栈（全部六种入栈）
static var _stack: Array[Node] = []

## 当前 Tooltip（不入栈，单独管理）
static var _current_tooltip: Node = null

# ============================================================
# 公开接口 — 通用
# ============================================================

## 注册面板（仅栈管理，不触发面板显示）。
##
## 通常不需要主动调用 — [Panel2D] / [UIPanel3D] 的 [method open] 会自动调用此方法。
## 仅在需要绕过面板自身显示逻辑、仅做栈注册的极少数场景下使用。
##
## 自动根据面板的 [code]layer[/code] 属性判断 UI 类型，执行对应的注册逻辑：
## [br]• BACKGROUND / HUD / PANEL：入栈，多元素可共存。
## [br]• DIALOG：入栈，同层互斥（自动关闭已有 DIALOG）。
## [br]• TOOLTIP：不入栈，单实例（关闭旧的，记录新的）。
## [br][br][b]注意：[/b]此方法仅管理栈，不触发 [code]panel.open()[/code] 显示逻辑。
## 如需同时注册并显示，请直接调用 [code]panel.open()[/code]。
static func register(panel: Node) -> void:
	if not is_instance_valid(panel):
		return

	var panel_layer: int = _get_layer(panel)

	# ── 同层互斥处理 ──
	if panel_layer == Layer.DIALOG:
		_close_all_of_layer(Layer.DIALOG)

	# ── Tooltip 不入栈，单独管理 ──
	if panel_layer == Layer.TOOLTIP:
		if is_instance_valid(_current_tooltip):
			_current_tooltip.close()
		_current_tooltip = panel
		LogTool.log("界面管理", "注册 Tooltip: %s" % panel.name)
		return

	if panel in _stack:
		LogTool.warn("界面管理", "跳过注册（已在栈中）: %s (%s)" % [panel.name, get_layer_type_name(panel_layer)])
		return

	var old := get_top()
	if old and panel_layer >= _get_layer(old) and old.has_method("_focus_exit"):
		old._focus_exit()

	_stack.append(panel)
	_sort()
	if panel_layer != Layer.TOOLTIP:
		LogTool.log("界面管理", "注册: %s (%s)   栈大小=%d   内容=%s" % [panel.name, get_layer_type_name(panel_layer), _stack.size(), _stack_to_string()])

	if is_focus(panel) and panel.has_method("_focus_enter"):
		panel._focus_enter()

## 注销面板（仅栈管理，不触发面板隐藏）。
##
## 通常不需要主动调用 — [Panel2D] / [UIPanel3D] 的 [method close] 会自动调用此方法。
##
## [b]注意：[/b]此方法仅从栈中移除，不触发 [code]panel.close()[/code] 隐藏逻辑。
## 如需同时注销并隐藏，请直接调用 [code]panel.close()[/code]。
static func unregister(panel: Node) -> void:
	if not is_instance_valid(panel):
		_stack.erase(panel)
		if panel == _current_tooltip:
			_current_tooltip = null
		LogTool.warn("界面管理", "注销无效面板，已从栈中移除   栈大小=%d   内容=%s" % [_stack.size(), _stack_to_string()])
		return

	var panel_layer := _get_layer(panel)

	# ── Tooltip 单独注销 ──
	if panel_layer == Layer.TOOLTIP:
		if panel == _current_tooltip:
			_current_tooltip = null
		LogTool.log("界面管理", "注销 Tooltip: %s" % panel.name)
		return
	var is_focus_panel := is_focus(panel)
	if is_focus_panel and panel.has_method("_focus_exit"):
		panel._focus_exit()
	_stack.erase(panel)
	if panel_layer != Layer.TOOLTIP:
		LogTool.log("界面管理", "注销: %s (%s)   栈大小=%d   内容=%s" % [panel.name, get_layer_type_name(panel_layer), _stack.size(), _stack_to_string()])
	if is_focus_panel:
		var top := get_top()
		if top and top.has_method("_focus_enter"):
			top._focus_enter()

## 关闭栈顶面板（委托调用 [code]panel.close()[/code]，触发完整关闭 + 注销流程）。
static func close_top() -> void:
	var top := get_top()
	if top:
		top.close()

## 切换面板（委托调用 [code]panel.open()/close()[/code]，触发完整打开/关闭 + 注册/注销流程）。
static func toggle(panel: Node) -> void:
	if is_open(panel):
		panel.close()
	else:
		panel.open()

## 返回键处理。委托调用面板的 [code]close()[/code]，触发完整关闭 + 注销流程。
## 优先关闭栈顶 DIALOG，其次关闭栈顶 PANEL。
static func back() -> bool:
	# 优先处理 DIALOG
	var top_dialog := get_top_of_layer(Layer.DIALOG)
	if top_dialog:
		_call_back(top_dialog)
		return true

	# 其次处理 PANEL（主界面）
	var top_panel := get_top_of_layer(Layer.PANEL)
	if top_panel:
		_call_back(top_panel)
		return true

	return false

## 调用面板的 _back() 方法，若未实现则默认调用 close()。
static func _call_back(panel: Node) -> void:
	if panel.has_method("_back"):
		panel._back()
	else:
		panel.close()

## 关闭所有面板（委托调用每个面板的 [code]close()[/code]，触发完整关闭 + 注销流程）。
static func close_all() -> void:
	LogTool.warn("界面管理", "关闭全部   栈大小=%d   内容=%s" % [_stack.size(), _stack_to_string()])
	for panel in _stack.duplicate():
		if is_instance_valid(panel):
			panel.close()
		else:
			_stack.erase(panel)
	if is_instance_valid(_current_tooltip):
		_current_tooltip.close()

# ============================================================
# 查询
# ============================================================

## 获取栈顶面板
static func get_top() -> Node:
	return _stack.back() if _stack else null

## 面板是否已注册到栈中（等价于面板是否处于打开状态）。
static func is_open(panel: Node) -> bool:
	if not is_instance_valid(panel):
		return false
	return panel in _stack

## 栈是否为空
static func is_empty() -> bool:
	return _stack.is_empty()

## 获取栈中指定层级的最顶部面板
static func get_top_of_layer(layer: Layer) -> Node:
	for i in range(_stack.size() - 1, -1, -1):
		var panel := _stack[i]
		if is_instance_valid(panel) and _get_layer(panel) == layer:
			return panel
	return null

## 获取栈中指定层级的所有面板
static func get_panels_of_layer(layer: Layer) -> Array[Node]:
	var result: Array[Node] = []
	for panel in _stack:
		if is_instance_valid(panel) and _get_layer(panel) == layer:
			result.append(panel)
	return result

## 获取栈大小
static func get_stack_size() -> int:
	return _stack.size()

# ============================================================
# 公开接口 — 工具
# ============================================================

## 根据 Layer 值获取 UI 类型的名称（通过枚举 keys 自动获取）
static func get_layer_type_name(layer: int) -> String:
	var vals = Layer.values()
	var idx = vals.find(layer)
	if idx == -1:
		return "Unknown"
	var key = Layer.keys()[idx]
	return "HUD" if key == "HUD" else key.capitalize()

## 判断面板是否当前拥有焦点（顶层面板优先级高于自身且不是自己时失去焦点）
static func is_focus(panel: Node) -> bool:
	if not is_instance_valid(panel):
		return false
	if panel not in _stack:
		return false
	var top := get_top()
	if top and top != panel:
		return false
	return true

# ============================================================
# 内部 — 工具
# ============================================================

## 安全获取节点的 layer 属性，不存在时返回 0
static func _get_layer(node: Node) -> int:
	if not is_instance_valid(node):
		return 0
	var val = node.get("layer")
	return int(val) if val != null else 0

# ============================================================
# 内部 — 回调
# ============================================================

static func _sort() -> void:
	_stack.sort_custom(func(a, b):
		return _get_layer(a) < _get_layer(b)
	)

## 关闭指定层级的所有面板（委托调用面板的 [code]close()[/code]，触发完整关闭 + 注销流程）。
## 主要用于同层互斥场景（如打开新 DIALOG 时自动关闭已有的 DIALOG）。
static func _close_all_of_layer(layer: Layer) -> void:
	var to_close: Array[Node] = []
	for panel in _stack:
		if is_instance_valid(panel) and _get_layer(panel) == layer:
			to_close.append(panel)
	for panel in to_close:
		panel.close()

# ============================================================
# 调试
# ============================================================

## 生成当前栈内容的字符串表示
static func _stack_to_string() -> String:
	if _stack.is_empty():
		return "[]"
	var parts: Array[String] = []
	for panel in _stack:
		if is_instance_valid(panel):
			parts.append("%s(%s)" % [panel.name, get_layer_type_name(_get_layer(panel))])
		else:
			parts.append("(无效)")
	return "[%s]" % ", ".join(parts)

## 打印当前 UI 状态
static func debug() -> void:
	print("=== UI Stack (%d) ===" % _stack.size())
	for i in _stack.size():
		var p := _stack[i]
		print("  [%d] %s  layer=%s" % [i, p.name, get_layer_type_name(_get_layer(p))])

## 打印简要状态（一行）
static func debug_short() -> void:
	var info := ""
	for panel in _stack:
		if is_instance_valid(panel):
			info += "%s(%s) > " % [panel.name, get_layer_type_name(_get_layer(panel))]
	if info.is_empty():
		info = "(empty)"
	print("[UITool] %s" % info)

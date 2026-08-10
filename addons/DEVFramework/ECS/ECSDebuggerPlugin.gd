@tool
## ECS 运行时查看器(EditorDebuggerPlugin) —— 游戏运行时在 Godot Debugger 面板新增 tab。
## 参考 Godot 内置 Profiler(多列耗时 Tree) 与 远程场景树(分栏 + 组件字段树 + 属性编辑) 设计:
##   · 左侧: 每系统耗时(多列: 系统/耗时ms/占比%) + 系统拓扑(执行顺序) + 自动刷新开关
##   · 右侧: 实体查看(输入 ID → 组件折叠树, 字段带类型) + 改值(数值/向量/颜色/布尔)
## 数据来自 World 节点 EngineDebugger 推送(ecs_debug:view)与请求(ecs_debug)。

class_name ECSDebuggerPlugin
extends EditorDebuggerPlugin

const PREFIX := "ecs_debug"

var _ui: Control = null
var _session: EditorDebuggerSession = null

var _sys_tree: Tree = null        # 系统耗时 3 列
var _topo_label: Label = null
var _auto_refresh: CheckBox = null
var _last_times := {}             # 系统耗时缓存(算占比)

var _entity_edit: LineEdit = null
var _entity_list: Tree = null
var _entity_tree: Tree = null
var _time_hist := {}   # 系统名 -> Array[ms] 历史(算 avg/max)
var _value_edit: LineEdit = null
var _type_hint: Label = null


func _setup_session(session_id: int) -> void:
	var session := get_session(session_id)
	if session == null:
		return
	_session = session
	_build_ui()
	session.add_session_tab(_ui)
	session.started.connect(func() -> void:
		_request_view()
	)


func _has_capture(capture: String) -> bool:
	return capture.begins_with(PREFIX)


func _capture(message: String, data: Array, _session_id: int) -> bool:
	if not message.begins_with(PREFIX):
		return false
	# 兜底: 确保 UI 已构建(session 回调未触发时)
	if _ui == null or _sys_tree == null:
		_build_ui()
		if _ui != null and _session != null:
			_session.add_session_tab(_ui)
	if _ui != null:
		_apply_data(data)
	return true


## 加载 UI 场景(ECS 查看器布局/属性在 Inspector 可直接调整)。
func _build_ui() -> void:
	# 每次重建(避免跨会话复用旧控件悬垂)
	if _ui != null:
		_ui.queue_free()
	_ui = null
	_sys_tree = null
	_entity_list = null
	_entity_tree = null
	_topo_label = null
	_type_hint = null

	_ui = (load("res://addons/DEVFramework/ECS/ECSDebuggerView.tscn") as PackedScene).instantiate()
	_ui.name = "ECS 查看器"
	_sys_tree = _ui.get_node("%SysTree")
	_entity_list = _ui.get_node("%EntityList")
	_entity_tree = _ui.get_node("%EntityTree")
	_topo_label = _ui.get_node("%TopoLabel")
	_entity_edit = _ui.get_node("%EntityEdit")

	# 列标题/宽度(Tree 列数在场景设, 标题代码设)
	_sys_tree.set_column_title(0, "系统")
	_sys_tree.set_column_title(1, "耗时")
	_sys_tree.set_column_title(2, "占比")
	_sys_tree.set_column_title(3, "avg")
	_sys_tree.set_column_title(4, "max")
	_sys_tree.set_column_title(5, "调用")
	_sys_tree.set_column_custom_minimum_width(0, 140)
	_sys_tree.set_column_custom_minimum_width(1, 55)
	_sys_tree.set_column_custom_minimum_width(2, 45)
	_sys_tree.set_column_custom_minimum_width(3, 55)
	_sys_tree.set_column_custom_minimum_width(4, 55)
	_sys_tree.set_column_custom_minimum_width(5, 45)

	# 信号连接
	_ui.get_node("%RefreshBtn").pressed.connect(func() -> void: _request_view())
	_ui.get_node("%ViewBtn").pressed.connect(func() -> void:
		if _session != null:
			_session.send_message(PREFIX, ["entity", int(_entity_edit.text)])
	)
	_entity_list.item_activated.connect(func() -> void:
		var it := _entity_list.get_selected()
		if it != null and it.has_meta("eid") and _session != null:
			_session.send_message(PREFIX, ["entity", it.get_meta("eid")])
	)


func _request_view() -> void:
	if _session != null:
		_session.send_message(PREFIX, ["refresh"])


## 应用游戏推送: [payload], {systems, topology} 或 {entity, view}。
func _apply_data(data: Array) -> void:
	if data.is_empty() or not (data[0] is Dictionary):
		return
	var payload: Dictionary = data[0]
	if payload.has("systems"):
		_last_times = payload["systems"]
		_update_systems()
	if payload.has("topology"):
		_update_topology(payload["topology"])
	if payload.has("view"):
		_fill_entity_tree(int(payload.get("entity", -1)), payload["view"])
	if payload.has("groups"):
		_fill_entity_groups(payload["groups"])


## 系统耗时列表(含占比与历史 avg/max, 参考 Profiler)。防御: 值非数值时按 0。
func _update_systems() -> void:
	if _time_hist == null:
		_time_hist = {}
	if _last_times == null:
		_last_times = {}
	var vals := {}
	var runs := {}
	for s in _last_times:
		var x: Variant = _last_times[s]
		if x is Dictionary:
			vals[s] = float(x.get("ms", 0.0))
			runs[s] = int(x.get("runs", 0))
		else:
			vals[s] = float(x) if (x is float or x is int) else 0.0
	# 累计历史(最近 60 帧)
	for s in vals:
		var arr: Array = _time_hist.get(s, [])
		arr.append(vals[s])
		if arr.size() > 60:
			arr.pop_front()
		_time_hist[s] = arr
	_sys_tree.clear()
	var total := 0.0
	for s in vals:
		total += vals[s]
	var root := _sys_tree.create_item()
	root.set_text(0, "本帧系统耗时合计: %.3f ms" % total)
	for s in vals:
		var it := _sys_tree.create_item(root)
		it.set_text(0, str(s))
		it.set_text(1, "%.3f" % vals[s])
		it.set_text(2, "%.1f%%" % (vals[s] / total * 100.0 if total > 0.0 else 0.0))
		var hist: Array = _time_hist.get(s, [])
		if hist.size() > 1:
			var avg := 0.0
			var mx := 0.0
			for m in hist:
				avg += m
				mx = maxf(mx, m)
			avg /= hist.size()
			it.set_text(3, "%.3f" % avg)
			it.set_text(4, "%.3f" % mx)
			it.set_text(5, "%d" % runs.get(s, 0))


## 拓扑文本(执行顺序 + 可并行标记)。防御: 空/类型异常时显示占位。
func _update_topology(topo: Variant) -> void:
	var txt := "拓扑(执行顺序):\n"
	var n := 0
	if topo != null and (topo is Dictionary):
		for i in topo.get("order", []):
			if not (i is Dictionary):
				continue
			n += 1
			txt += "  %d. %s%s\n" % [n, i.get("name", "?"), "  (可并行)" if i.get("parallel", false) else ""]
	_topo_label.text = txt


## 实体按 archetype 分组显示(组=组件组合, 双击实体查看详情)。
func _fill_entity_groups(groups: Array) -> void:
	_entity_list.clear()
	var root := _entity_list.create_item()
	root.set_text(0, "实体分组")
	for g in groups:
		var comps: PackedStringArray = g["comps"]
		var cnt: int = int(g.get("count", 0))
		var gi := root.create_child()
		gi.set_text(0, "%s  (%d)" % ["+".join(comps), cnt])
		for id in g.get("entities", []):
			var ei := gi.create_child()
			ei.set_text(0, "实体 %d" % int(id))
			ei.set_meta("eid", int(id))
	root.collapsed = false

## 实体组件字段树(组件折叠, 字段带类型)。
func _fill_entity_tree(entity: int, view: Dictionary) -> void:
	_entity_tree.clear()
	_type_hint.text = ""
	var root := _entity_tree.create_item()
	root.set_text(0, "实体 %d" % entity)
	for cn in view:
		var ci := root.create_child()
		ci.set_text(0, str(cn))
		for f in view[cn]:
			var fi := ci.create_child()
			var v: Variant = view[cn][f]
			fi.set_text(0, "%s: %s = %s" % [f, _type_name(v), str(v)])
			fi.set_meta("entity", entity)
			fi.set_meta("comp", str(cn))
			fi.set_meta("field", str(f))
	root.collapsed = false



## 字段值类型名(GDScript 值推断, 便于显示)。
func _type_name(v: Variant) -> String:
	return type_string(typeof(v))



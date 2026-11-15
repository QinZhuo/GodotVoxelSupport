@tool
extends RefCounted

## ======= 多实例路由：这条调用该落在哪个编辑器 + 实例管理工具 =======
## 由 MCPDevServer 以 preload 常量 `MCPRouter` 引用。**必须 @tool 且不声明 class_name**
## **不做"唯一的其他实例自动选中"**: 那在"开了两个项目、只想改当前这个"时会静默改错项目;

const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")

## 实例管理工具名。它们**不**注入 `instance` 参数, 也不参与转发 ——
## 它们本身就在操作"实例"这个维度, 必须在收到请求的进程上执行。
const HUB_TOOLS := ["list_instances", "use_instance"]

## 注入进每个工具 schema 的 `instance` 参数说明。
const INSTANCE_ARG_DESC := "可选: 目标编辑器实例。省略则用 use_instance 设置的默认目标(未设置时=本实例)。可填实例 id(如 MyGame@a1b2c3d4)、唯一前缀、或端口号; 不确定时先调 list_instances。"

## MCPDevServer（Variant: 跨编译代次不信任类型标注）
var server = null


func _init(owner) -> void:
	server = owner


## tools/list 出口整形: 每个工具多一个可选 `instance` 参数(实例管理工具除外)。
func tools_for_list(defs: Array) -> Array:
	var hub = server._hub
	if hub == null:
		return defs
	return hub.inject_instance_arg(defs, INSTANCE_ARG_DESC, HUB_TOOLS)


## 解析本条 tools/call 该由谁执行。
func resolve_route(tool_name: String, args: Dictionary) -> Dictionary:
	var hub = server._hub
	# 成员进程没有注册表(它只是被转发的一端): 请求能到这里就说明是直连成员端口的。
	if hub == null or not bool(hub.hub_mode):
		return {"port": 0}
	# 实例管理工具本身不路由。
	if HUB_TOOLS.has(tool_name):
		return {"port": 0}
	var raw := VariantTool.get_string(args, "instance", "").strip_edges()
	if not raw.is_empty():
		var hit: Dictionary = hub.resolve(raw)
		if hit.is_empty():
			# 区分"不存在"与"有歧义": 恢复动作不同, 报同一句话会让调用方反复试同一个值。
			if hub.count_matches(raw) > 1:
				return {
					"error": "实例标识 '%s' 有歧义: 同时存在多个匹配(通常是同一个项目被打开了多次, 它们共享 instance_id)。\n%s" % [raw, hub.describe()],
					"recovery": "改用 uid(带 #进程号 的那个, 在 list_instances 的 uid 字段里)或直接传端口号来精确指定; 不要用 instance_id —— 同项目多开时它不唯一。",
				}
			return {
				"error": "找不到实例 '%s'。当前可用实例:\n%s" % [raw, hub.describe()],
				"recovery": "先调 list_instances 查看可用实例(uid / 唯一前缀 / 端口号), 再把 instance 换成清单里的值; 或省略 instance 用默认目标。",
			}
		return _route_of(hit, "instance=%s" % raw)
	# 默认目标: 先按 uid 找; uid 失效(编辑器重启换了进程号)时由 hub 按 instance_id 重解析。
	var def: Dictionary = hub.resolve_active()
	if def.is_empty():
		if hub.has_active():
			# 设过目标但不在线 ⇒ 必须报错。就地执行等于打到"当前碰巧当中枢的那个项目"。
			return {
				"error": "默认目标 %s 当前不在线(该编辑器正在重启, 或 MCP 中枢已从它切换到别的项目)。为避免改错项目, 本次调用不执行。\n%s" % [str(hub.active_label()), hub.describe()],
				"recovery": "等目标编辑器启动完成后重试(默认目标不会被清掉, 回来后会按项目身份自动接回); 或先 list_instances 再用 instance 参数指定本次目标。",
			}
		return {"port": 0}
	return _route_of(def, "默认目标 %s" % str(def.get("instance_id", "")))


## 把注册表条目翻译成路由结果。指向自己时 port=0。target 回填 uid(诊断要落到具体进程)。
func _route_of(entry: Dictionary, via: String) -> Dictionary:
	if bool(entry.get("is_self", false)):
		return {"port": 0}
	var port := int(entry.get("port", 0))
	if port <= 0:
		return {
			"error": "实例 %s 的端口未知(它刚启动还没登记完?)。\n%s" % [str(entry.get("instance_id", "?")), server._hub.describe()],
			"recovery": "几秒后重试; 若持续如此, 检查该实例的 MCP 是否启用(dev_framework/mcp/enabled)。",
		}
	return {"port": port, "target": str(entry.get("instance_id", "")), "uid": str(entry.get("uid", "")), "via": via}


## 转发一条 tools/call 到目标实例, 返回**已经可以回给客户端的** JSON-RPC 响应。
## 三件事必须做对:
func forward(req: Dictionary, req_id: Variant, _tool_name: String, route: Dictionary, proto: String, margin_ms: int) -> Dictionary:
	var hub = server._hub
	var fwd: Dictionary = req.duplicate(true)
	var fparams: Variant = fwd.get("params", null)
	if fparams is Dictionary:
		var fargs: Variant = (fparams as Dictionary).get("arguments", null)
		if fargs is Dictionary:
			(fargs as Dictionary).erase("instance")
	# id 必须原样带过去: 客户端只认自己发的那个 id。
	var timeout_ms := int(server._game_call_timeout_ms()) + margin_ms
	var resp: Dictionary = await hub.forward(int(route["port"]), fwd, timeout_ms, proto)
	if resp.is_empty() or resp.has("__http_status"):
		# 先探注册表里它还活着吗: 心跳过期与"TCP 拒绝"是两种不同诊断。
		var still: Dictionary = hub.find_by_uid(str(route.get("uid", "")))
		var tail := "该实例已不在注册表中(可能刚被关闭)。" if still.is_empty() else "该实例仍在注册表中, 但端口 %d 不接受连接(可能正在启动/卡住/防火墙拦截)。" % int(route["port"])
		return {"jsonrpc": "2.0", "id": req_id, "result": MCPResult.for_protocol(MCPResult.err_transient(
			"转发到实例 %s 失败(%s)。\n%s\n当前可用实例:\n%s" % [str(route.get("target", "?")), route.get("via", ""), tail, hub.describe()],
			"用 list_instances 确认实例清单后重试; 若该实例已关闭, 用 use_instance 换成活着的那个(或传空串恢复为「本实例」)。"))}
	if resp.has("error"):
		return resp
	resp["id"] = req_id
	_stamp_forwarded(resp, route)
	return resp


## 给工具结果盖上"本次在哪个项目执行"的章（`_meta.target` + 正文末尾一行）。
func stamp(result: Dictionary, iid: String, ppath: String, role: String) -> Dictionary:
	if iid.is_empty():
		return result
	var meta: Variant = result.get("_meta", null)
	if not (meta is Dictionary):
		meta = {}
	if (meta as Dictionary).has("target"):
		return result
	(meta as Dictionary)["target"] = {"instance_id": iid, "project_path": ppath, "role": role}
	result["_meta"] = meta
	var content: Variant = result.get("content", null)
	if content is Array and not (content as Array).is_empty():
		var last: Variant = (content as Array)[(content as Array).size() - 1]
		if last is Dictionary and str((last as Dictionary).get("type", "")) == "text":
			(last as Dictionary)["text"] = "%s\n\n[target: %s (%s)]" % [
				str((last as Dictionary).get("text", "")), iid, ppath]
	return result


## 转发结果若没有执行方盖的章(对端还是旧版本代码), 由中枢补一个 ——
func _stamp_forwarded(resp: Dictionary, route: Dictionary) -> void:
	var result: Variant = resp.get("result", null)
	if not (result is Dictionary):
		return
	var iid := str(route.get("target", ""))
	if iid.is_empty():
		return
	var ppath := ""
	var hub = server._hub
	if hub != null:
		var hits: Array = hub.find_all_by_instance_id(iid)
		# 同项目多开时命中多个，无法确定是哪一个 —— 宁可不填路径，也不要瞎填一个
		if hits.size() == 1:
			ppath = str((hits[0] as Dictionary).get("project_path", ""))
	stamp(result, iid, ppath, "remote")


## list_instances: 实例清单 + 当前默认目标。
func call_list_instances(_args: Dictionary) -> Dictionary:
	var hub = server._hub
	if hub == null:
		return MCPResult.fail("多实例功能未启用(dev_framework/mcp/hub=false)。同一时间只应有一个编辑器在用 MCP; 同时打开多个编辑器时请开启它。")
	# 成员侧顺手拉一次最新快照: 否则看到的是上一次心跳(最多 4 秒前)的清单。
	if not bool(hub.hub_mode):
		var resp: Dictionary = await hub.post_json(server._hub_port, hub.instances_path(), {}, 2000)
		if bool(resp.get("ok", false)) and resp.get("instances") is Array:
			hub.sync_from_snapshot(resp.get("instances"))
	hub.touch_self()
	var instances: Array = hub.snapshot()
	var self_entry := {}
	for item in instances:
		if bool(item.get("is_self", false)):
			self_entry = item
	var data := {
		"role": "hub" if bool(hub.hub_mode) else "member",
		"hub_port": server._hub_port,
		"active_instance": hub.get_active_uid(),
		"active_project": hub.active_label(),
		"instance_count": instances.size(),
		"instances": instances,
		"hint": "用 use_instance 设默认目标(跨重启保留), 或在任意工具调用里传 instance 参数单次指定。两者都没有时操作落在「本实例」; 目标不在线时报错, 不会改到别的项目。",
	}
	if self_entry.is_empty():
		data["warning"] = "注册表里没有本实例条目; 若持续出现请重启编辑器(热重载可能清掉了身份)。"
	return MCPResult.ok_json(data)


## use_instance: 设置默认目标实例。传空 = 恢复本实例。
func call_use_instance(args: Dictionary) -> Dictionary:
	var hub = server._hub
	if hub == null:
		return MCPResult.fail("多实例功能未启用(dev_framework/mcp/hub=false)。")
	var raw := VariantTool.get_string(args, "instance", "").strip_edges()
	if raw.is_empty():
		hub.set_active({})
		return MCPResult.ok_json({
			"active_instance": "",
			"active_uid": "",
			"message": "已恢复为「本实例」: 之后的工具调用都在本进程执行。",
		})
	var hit: Dictionary = hub.resolve(raw)
	if hit.is_empty():
		if hub.count_matches(raw) > 1:
			return MCPResult.err_validation(
				"实例标识 '%s' 有歧义: 有多个匹配(通常是同一项目被打开了多次, 它们共享 instance_id)。\n%s" % [raw, hub.describe()],
				"改用 uid(带 #进程号 的那个)或端口号, 它们必然唯一; 候选清单见 list_instances 的 uid 字段。")
		return MCPResult.err_validation(
			"找不到实例 '%s'。当前可用实例:\n%s" % [raw, hub.describe()],
			"先调 list_instances 拿准确的 uid / 端口, 再重试; 或传空字符串恢复为「本实例」。")
	# 同时记 uid(唯一) 与 instance_id(重启不变, 用于恢复), 一并落盘。
	var uid := str(hit.get("uid", ""))
	hub.set_active(hit)
	return MCPResult.ok_json({
		"active_instance": str(hit.get("instance_id", "")),
		"active_uid": uid,
		"is_self": bool(hit.get("is_self", false)),
		"port": int(hit.get("port", 0)),
		"message": ("已选中实例 %s" % str(hit.get("instance_id", ""))) + ("(就是本进程)" if bool(hit.get("is_self", false)) else " —— 之后的工具调用会转发到它") + "。",
	})

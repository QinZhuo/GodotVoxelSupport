@tool
extends RefCounted

## ======= MCP 多实例中枢(实例注册表 + 目标路由 + HTTP 转发) =======
##   · 一个**机器级**固定端口(见 MCPDevServer.SETTING_HUB_PORT)只有**一个**实例能持有, 它就是这个
##   · 其余实例各绑一个**系统分配的临时端口**(listen(0)), 每 4 秒把自己登记到中枢;
##   · 中枢对外只暴露固定端口那一个 MCP 端点, 工具表就是它自己的全量工具(每个工具多一个可选
##   · 中枢退出后, 成员心跳连续失败 → 抢绑固定端口(bind 是原子的), 抢到的那个成为新中枢,

## 心跳周期: 成员每隔这么久向中枢登记一次(登记即续约, 不另设 ping)。
const HEARTBEAT_MS := 4000
## 成员存活上限: 心跳停止超过这个时长即从表中剔除。
## 它只用于"手动关掉一个编辑器"后的清理 —— 崩溃/强杀同样走这条路径, 故不能太长(否则
## 会对着已死的实例报错); 也不能太短(否则一次 GC 卡顿就被误判为退出)。
const MEMBER_TTL_MS := 20000
## 连接阶段的独立超时(见 post_json 的说明)。本机回环一次握手是微秒级, 2 秒足够宽容;
## 超过它就只能判定"那个端口上没有活着的服务端"。**不能**与工具执行超时共用: 后者可达
## 610 秒, 共用会让"目标实例已关闭"表现为挂死十分钟(实测)。
const CONNECT_TIMEOUT_MS := 2000

## 中枢 HTTP 端点(非 MCP 协议, 只是实例间内部接口; AI 客户端不需要知道它们)
const HUB_REGISTER_PATH := "/hub/register"
const HUB_UNREGISTER_PATH := "/hub/unregister"
const HUB_INSTANCES_PATH := "/hub/instances"
const HUB_HEALTH_PATH := "/hub/health"

## 默认目标落盘的文件名(机器级共享; 目录见 _target_path)
const TARGET_FILE := "devframework_mcp_target.json"

## 测试用: 覆盖目标状态文件路径。空 = 用默认位置。
## 用例必须设它 —— 否则跑一次测试就会改掉开发者真实会话的默认目标。
static var target_path_override := ""

## uid -> 实例条目。条目形状见 _make_entry()。
var members := {}
## 默认目标(服务端唯一的全局状态)。三个字段一起落盘: uid 里的进程号会变, 而 instance_id
var active_instance := ""        # 目标 uid(带进程号, 唯一)
var active_instance_id := ""     # 目标项目级身份(重启不变, uid 失效时的恢复依据)
var active_project_path := ""    # 目标项目路径(仅用于报错/展示)
var _target_loaded := false

## 本实例身份
var own_uid := ""
var own_instance_id := ""
var own_name := ""
var own_project_path := ""
## 本实例的 MCP 端口(中枢=固定端口, 成员=系统分配的临时端口)
var own_port := 0

## 本进程是否持有固定端口(= 中枢)
var hub_mode := false
## 成员侧: 中枢的 instance_id(从登记响应里学到, 只用于展示/诊断)
var hub_instance_id := ""
## 成员侧: 上一次登记是否成功
var registered := false
## 成员侧: 连续登记失败次数(达到阈值才尝试接管, 避免中枢一次卡顿就抢端口)
var fail_streak := 0
## 转发时带去的中枢鉴权(见 MCPDevServer.SETTING_TOKEN)。各实例须用同一个值,
## 否则跨实例转发会被目标以 401 拒掉 —— 这是可见的失败, 比静默放行好。
var auth_token := ""


## ------- 常量访问器 -------

func heartbeat_ms() -> int:
	return HEARTBEAT_MS


func unregister_path() -> String:
	return HUB_UNREGISTER_PATH


func instances_path() -> String:
	return HUB_INSTANCES_PATH


## ------- 身份 -------

## 实例 id: "<项目名>@<项目路径哈希前 8 位>"。
static func make_instance_id(project_name: String, project_path: String) -> String:
	return "%s@%s" % [safe_name(project_name), hash8(_normalize_path(project_path))]


## 路径规范化: 反斜杠统一 + 去尾分隔符 + 转小写。
## **传进来的必须是绝对路径**(调用方负责 globalize): 传 "res://" 这种相对路径会让所有项目的
static func normalize_path(path: String) -> String:
	var norm := path.strip_edges().replace("\\", "/")
	while norm.ends_with("/"):
		norm = norm.substr(0, norm.length() - 1)
	return norm


static func _normalize_path(path: String) -> String:
	return normalize_path(path).to_lower()


static func hash8(text: String) -> String:
	return text.sha256_text().substr(0, 8)


## 把项目名压成可用作 id 前缀的形式(空格/路径分隔符/冒号/@ 一律换成下划线)。
static func safe_name(raw: String) -> String:
	var out := ""
	for i in raw.length():
		var ch := raw[i]
		if ch == " " or ch == "@" or ch == "/" or ch == "\\" or ch == ":" or ch == ".":
			out += "_"
		else:
			out += ch
	if out.is_empty():
		out = "project"
	return out.left(40)


## ------- 注册表 -------

## 登记本实例。端口在监听成功后才确定, 由 set_self_port 补上。
func set_self(uid: String, instance_id: String, project_name: String, project_path: String) -> void:
	own_uid = uid
	own_instance_id = instance_id
	own_name = project_name
	# 存规范化后的路径(去尾分隔符/统一斜杠): globalize_path("res://") 带尾斜杠, 原样存会让
	own_project_path = normalize_path(project_path)
	members[uid] = _make_entry(uid, instance_id, project_name, own_project_path, own_port, true)


func set_self_port(port: int) -> void:
	own_port = int(port)
	if members.has(own_uid):
		members[own_uid]["port"] = own_port


func set_hub_mode(on: bool) -> void:
	hub_mode = on


## 成员侧: 随心跳发给中枢的自身描述。
func register_payload() -> Dictionary:
	return {
		"uid": own_uid,
		"instance_id": own_instance_id,
		"name": own_name,
		"project_path": own_project_path,
		"port": own_port,
		"pid": OS.get_process_id(),
	}


func _make_entry(uid: String, instance_id: String, project_name: String, project_path: String, port: int, is_self: bool) -> Dictionary:
	return {
		"uid": uid,
		"instance_id": instance_id,
		"name": project_name,
		"project_path": project_path,
		"port": int(port),
		"is_self": is_self,
		"last_seen": Time.get_ticks_msec(),
	}


## 中枢侧: 接收一条登记(幂等 upsert)。**不接受覆盖自身条目** —— 自己那份以本地为准,
## 否则一个成员(或伪造的 uid)就能把中枢自己的端口改掉。
func upsert(data: Dictionary) -> void:
	var uid := str(data.get("uid", "")).strip_edges()
	if uid.is_empty() or uid == own_uid:
		return
	var port := int(data.get("port", 0))
	if port <= 0 or port > 65535:
		return
	members[uid] = _make_entry(
		uid,
		str(data.get("instance_id", "")).strip_edges(),
		str(data.get("name", "")).strip_edges(),
		str(data.get("project_path", "")).strip_edges(),
		port,
		false)


func touch_self() -> void:
	if members.has(own_uid):
		members[own_uid]["last_seen"] = Time.get_ticks_msec()


## 剔除心跳超时的成员。必须在**每次访问注册表前**调用(中枢的 handle 与对外快照都会调),
## 否则"刚关掉的那个编辑器"会在 TTL 内继续被当成可选目标, 调它只会等超时。
func prune(now: int = -1) -> void:
	var t := now if now >= 0 else Time.get_ticks_msec()
	for uid in members.keys():
		var e: Dictionary = members[uid]
		if bool(e.get("is_self", false)):
			continue
		if t - int(e.get("last_seen", 0)) > MEMBER_TTL_MS:
			members.erase(uid)


## 成员侧: 用中枢回包里的实例表**整体替换**非自身条目。
## 这样成员的 list_instances 也能看到全机器, 而不是只看到自己 —— 否则"选错实例"时的候选
func sync_from_snapshot(instances: Array) -> void:
	var self_entry: Variant = members.get(own_uid, null)
	members = {}
	if self_entry != null:
		members[own_uid] = self_entry
	var now := Time.get_ticks_msec()
	for item in instances:
		if not (item is Dictionary):
			continue
		var e: Dictionary = item
		var uid := str(e.get("uid", ""))
		if uid.is_empty() or uid == own_uid:
			continue
		var copy: Dictionary = e.duplicate(true)
		copy["is_self"] = false
		# 中枢给的是 age_ms(相对它自己的时钟), 换算回本进程时间轴, 否则 prune 会拿中枢的
		copy["last_seen"] = now - int(e.get("age_ms", 0))
		members[uid] = copy


## 全部活实例(含本实例), 本实例恒排第一, 其余按心跳新鲜度降序。
func live_members() -> Array:
	var out: Array = []
	for uid in members:
		out.append(members[uid])
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var sa := bool(a.get("is_self", false))
		var sb := bool(b.get("is_self", false))
		if sa != sb:
			return sa
		return int(a.get("last_seen", 0)) > int(b.get("last_seen", 0))
	)
	return out


## 对外可读快照(list_instances 工具 / /hub/instances)。附带 age_ms(心跳有多旧)与 is_hub
## **必须先 prune**: 快照是"当前有哪几个编辑器"的唯一对外答案, 若它把已经死掉的成员也列出来,
## 调用方就会去选一个已经关掉的实例, 然后收到一次转发超时。实测就是这样: 强杀第二个编辑器后,
func snapshot(now: int = -1) -> Array:
	var t := now if now >= 0 else Time.get_ticks_msec()
	prune(t)
	var out: Array = []
	for e in live_members():
		var item: Dictionary = (e as Dictionary).duplicate()
		item["age_ms"] = t - int(item.get("last_seen", t))
		item["is_hub"] = hub_mode and str(item.get("uid", "")) == own_uid
		item.erase("last_seen")
		out.append(item)
	return out


## 按 instance_id(= 项目级身份)查条目。**同项目多开时会把多个命中都返回**, 由调用方自己决定
func find_all_by_instance_id(instance_id: String) -> Array:
	var out: Array = []
	if instance_id.is_empty():
		return out
	for uid in members:
		if str(members[uid].get("instance_id", "")) == instance_id:
			out.append(members[uid])
	return out


## 按 uid 查条目(唯一键)。路由/绑定一律用 uid, 不用 instance_id —— 后者同项目多开时会撞。
func find_by_uid(uid: String) -> Dictionary:
	if uid.is_empty():
		return {}
	return members.get(uid, {})


## 解析调用方给的实例标识。四档匹配, 从精确到宽松:
##   1. uid 精确("MyGame@a1b2c3d4#12345", 带进程号, **唯一**, 路由与绑定都用它)
##   4. 前缀(项目名 / hash / hash 前缀 / uid 前缀) —— 必须**唯一命中**, 否则同样返回空。
func resolve(query: String) -> Dictionary:
	var q := query.strip_edges()
	if q.is_empty():
		return {}
	var ql := q.to_lower()
	for uid in members:
		if str(uid).to_lower() == ql:
			return members[uid]
	if q.is_valid_int():
		var want := q.to_int()
		for uid in members:
			if int(members[uid].get("port", 0)) == want:
				return members[uid]
	var exact := find_all_by_instance_id(q)
	# instance_id 大小写不敏感地再试一次(用户手抄清单时大小写常变)
	if exact.is_empty():
		for uid in members:
			if str(members[uid].get("instance_id", "")).to_lower() == ql:
				exact.append(members[uid])
	if exact.size() == 1:
		return exact[0]
	if exact.size() > 1:
		return {}
	var hits: Array = []
	for uid in members:
		var e: Dictionary = members[uid]
		var id := str(e.get("instance_id", "")).to_lower()
		var hash_part := id.get_slice("@", 1)
		if id.begins_with(ql) or hash_part.begins_with(ql) or str(uid).to_lower().begins_with(ql):
			hits.append(e)
	if hits.size() == 1:
		return hits[0]
	return {}


## 一个标识符命中了几个实例(用于把"有歧义"和"不存在"区分开 —— 两种的恢复动作不同)。
func count_matches(query: String) -> int:
	var q := query.strip_edges().to_lower()
	if q.is_empty():
		return 0
	var n := 0
	for uid in members:
		var e: Dictionary = members[uid]
		var id := str(e.get("instance_id", "")).to_lower()
		if id == q or str(uid).to_lower() == q or id.get_slice("@", 1).begins_with(q) or id.begins_with(q):
			n += 1
	return n


## ------- 目标绑定 -------
## 绑定用 **uid** 而非 instance_id: uid 带进程号, 唯一; 而 instance_id 在同项目多开时会撞,
func set_active(entry: Dictionary) -> void:
	active_instance = str(entry.get("uid", ""))
	active_instance_id = str(entry.get("instance_id", ""))
	active_project_path = str(entry.get("project_path", ""))
	_target_loaded = true
	_save_target()


## 是否设过默认目标(可能已离线 —— 调用方据此区分"从未设过"与"设过但不在线")。
func has_active() -> bool:
	_ensure_target_loaded()
	return not active_instance.is_empty() or not active_instance_id.is_empty()


## 当前默认目标对应的在线实例; 空字典 = 没设过 / 目标不在线(调用方必须报错, **不要就地执行**)。
func resolve_active() -> Dictionary:
	_ensure_target_loaded()
	if not active_instance.is_empty():
		var hit := find_by_uid(active_instance)
		if not hit.is_empty():
			return hit
	if active_instance_id.is_empty():
		return {}
	# 同项目多开时 resolve 会返回空(歧义), 此时同样交给调用方报错, 不挑一个。
	var again := resolve(active_instance_id)
	if not again.is_empty():
		set_active(again)   # uid 换代: 改写并落盘
	return again


## 默认目标的 uid(先确保已从磁盘恢复; 直接读字段会在首次调用前拿到空串)。
func get_active_uid() -> String:
	_ensure_target_loaded()
	return active_instance


## 默认目标的可读标签(报错用): 优先项目路径, 回退 instance_id。
func active_label() -> String:
	_ensure_target_loaded()
	if not active_project_path.is_empty():
		return "%s (%s)" % [active_project_path, active_instance_id]
	return active_instance_id if not active_instance_id.is_empty() else active_instance


## 默认目标是否落在**别的**实例上(落在自己身上等于不转发)。
func active_is_remote() -> bool:
	var e := resolve_active()
	return not e.is_empty() and not bool(e.get("is_self", false))


## ------- 默认目标持久化 -------
## 位置必须**机器级**: user:// 按项目隔离, 换一个项目当中枢就读不到上个项目写下的目标。

func _target_path() -> String:
	if not target_path_override.is_empty():
		return target_path_override
	var base := OS.get_environment("LOCALAPPDATA")
	if base.is_empty():
		base = OS.get_temp_dir()
	return base.path_join("DEVFrameworkMCP").path_join(TARGET_FILE)


func _ensure_target_loaded() -> void:
	if _target_loaded:
		return
	_target_loaded = true
	if not active_instance.is_empty() or not active_instance_id.is_empty():
		return   # 本进程内先设过, 以内存为准
	var path := _target_path()
	if not FileAccess.file_exists(path):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed is Dictionary:
		active_instance = str(parsed.get("uid", ""))
		active_instance_id = str(parsed.get("instance_id", ""))
		active_project_path = str(parsed.get("project_path", ""))


func _save_target() -> void:
	var path := _target_path()
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return   # 落盘失败不影响本进程; 下一个中枢会走"目标不在线 → 报错"的安全路径
	f.store_string(JSON.stringify({
		"uid": active_instance,
		"instance_id": active_instance_id,
		"project_path": active_project_path,
	}))
	f.close()


## ------- 可读描述 -------

## 人/AI 可读的实例清单(错误信息里直接拼它, 省得调用方再调一次 list_instances)。
func describe() -> String:
	var lines := PackedStringArray()
	for e in live_members():
		var tail := ""
		if bool(e.get("is_self", false)):
			tail = "  ← 本进程" + (" [中枢]" if hub_mode else "")
		lines.append("  - %s  (端口 %d)  %s%s" % [
			str(e.get("instance_id", "")), int(e.get("port", 0)),
			str(e.get("project_path", "")), tail])
	if lines.is_empty():
		return "  (无)"
	return "\n".join(lines)


func has_other_members() -> bool:
	for uid in members:
		if not bool(members[uid].get("is_self", false)):
			return true
	return false


## ------- tools/list 整形 -------

## 给中枢对外暴露的每一条工具 schema 注入可选的 `instance` 参数。
static func inject_instance_arg(defs: Array, desc: String, skip: Array = []) -> Array:
	var out: Array = []
	for d in defs:
		if not (d is Dictionary):
			out.append(d)
			continue
		var nd: Dictionary = (d as Dictionary).duplicate(true)
		if skip.has(str(nd.get("name", ""))):
			out.append(nd)
			continue
		var schema: Variant = nd.get("inputSchema", null)
		if not (schema is Dictionary):
			schema = {"type": "object", "properties": {}}
		var s: Dictionary = schema
		var props: Variant = s.get("properties", null)
		if not (props is Dictionary):
			props = {}
		(props as Dictionary)["instance"] = {"type": "string", "description": desc}
		s["properties"] = props
		nd["inputSchema"] = s
		out.append(nd)
	return out


## ------- 中枢侧 HTTP 端点 -------

## 处理一条 /hub/* 请求, 返回 {"status": int, "body": Dictionary}。
func handle(method: String, path: String, body: Dictionary) -> Dictionary:
	var now := Time.get_ticks_msec()
	prune(now)
	match path:
		HUB_REGISTER_PATH:
			if method != "POST":
				return {"status": 405, "body": {"ok": false, "error": "register 需要 POST"}}
			upsert(body)
			return {"status": 200, "body": {
				"ok": true,
				"hub": {"instance_id": own_instance_id, "uid": own_uid, "port": own_port},
				"instances": snapshot(now),
			}}
		HUB_UNREGISTER_PATH:
			if method != "POST":
				return {"status": 405, "body": {"ok": false, "error": "unregister 需要 POST"}}
			var uid := str(body.get("uid", "")).strip_edges()
			if not uid.is_empty() and uid != own_uid:
				members.erase(uid)
			return {"status": 200, "body": {"ok": true}}
		HUB_INSTANCES_PATH:
			return {"status": 200, "body": {
				"ok": true,
				"hub": {"instance_id": own_instance_id, "uid": own_uid, "port": own_port},
				"instances": snapshot(now),
			}}
		HUB_HEALTH_PATH:
			return {"status": 200, "body": {
				"ok": true,
				"hub": own_instance_id,
				"port": own_port,
				"count": members.size(),
			}}
	return {"status": 404, "body": {"ok": false, "error": "未知中枢端点: %s" % path}}


## ------- HTTP 客户端 -------

## 成员侧: 向中枢登记/续约。返回中枢响应({"ok": true, hub, instances})或空字典(失败)。
func register_to(hub_port: int, payload: Dictionary) -> Dictionary:
	return await post_json(hub_port, HUB_REGISTER_PATH, payload, 3000)


## 把一条 JSON-RPC 请求原样转发给目标实例的 MCP 端点, 返回它解析后的 JSON-RPC 响应。
## proto 经 HTTP 头带过去: 目标实例要按同一协议版本整形结果(2026-07-28 起 result 必须带
func forward(port: int, rpc: Dictionary, timeout_ms: int, proto: String = "") -> Dictionary:
	var extra := PackedStringArray()
	if not proto.is_empty():
		extra.append("mcp-protocol-version: " + proto)
	return await post_json(port, "/mcp", rpc, timeout_ms, extra)


## 最小 HTTP 客户端: POST 一个 JSON, 读回一个 JSON。
## 循环里的 `await` 是必须的 —— 不给主循环机会, 编辑器会整段卡住(转发是阻塞语义)。
## ## 连接阶段必须用**独立短超时**
## 端口没监听 → 一直等到 610 秒才报错。实测就是这样(中枢转发给一个已关闭实例时挂死)。
func post_json(port: int, path: String, payload: Dictionary, timeout_ms := 3000, extra_headers: PackedStringArray = PackedStringArray()) -> Dictionary:
	if port <= 0 or port > 65535:
		return {}
	var tree := Engine.get_main_loop() as SceneTree
	var client := HTTPClient.new()
	var connect_err := client.connect_to_host("127.0.0.1", port)
	if connect_err != OK:
		return {}
	var headers := PackedStringArray(["Content-Type: application/json"])
	# 鉴权: 各实例若配了 dev_framework/mcp/token, 必须**是同一个值**(见 Readme §7.3)。
	if not auth_token.is_empty():
		headers.append("Authorization: Bearer " + auth_token)
	headers.append_array(extra_headers)
	var deadline := Time.get_ticks_msec() + maxi(timeout_ms, 500)
	var connect_deadline := Time.get_ticks_msec() + CONNECT_TIMEOUT_MS
	while client.get_status() == HTTPClient.STATUS_CONNECTING or client.get_status() == HTTPClient.STATUS_RESOLVING:
		if Time.get_ticks_msec() > connect_deadline:
			client.close()
			return {}
		client.poll()
		await _wait_frame(tree)
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		client.close()
		return {}
	if client.request(HTTPClient.METHOD_POST, path, headers, JSON.stringify(payload)) != OK:
		client.close()
		return {}
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		if Time.get_ticks_msec() > deadline:
			client.close()
			return {}
		client.poll()
		await _wait_frame(tree)
	if not client.has_response():
		client.close()
		return {}
	var buf := PackedByteArray()
	while client.get_status() == HTTPClient.STATUS_BODY:
		if Time.get_ticks_msec() > deadline:
			client.close()
			return {}
		client.poll()
		if client.get_status() != HTTPClient.STATUS_BODY:
			break
		var chunk := client.read_response_body_chunk()
		if chunk.is_empty():
			await _wait_frame(tree)
		else:
			buf.append_array(chunk)
	var status := client.get_response_code()
	client.close()
	# 状态码不参与判定: 本服务器在"传输层拒绝"时也回 JSON-RPC 错误体(400/401/403),
	var parsed: Variant = JSON.parse_string(buf.get_string_from_utf8())
	if parsed is Dictionary:
		return parsed
	# 非 JSON 响应(极少数: 纯文本 4xx)也带上状态码, 便于诊断。
	if status >= 400:
		return {"__http_status": status}
	return {}


static func _wait_frame(tree: SceneTree) -> void:
	if tree != null:
		await tree.process_frame

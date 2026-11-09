@tool
extends RefCounted

## ======= MCP 多实例中枢(实例注册表 + 目标路由 + HTTP 转发) =======
##
## 解决的问题: 同一台机器上同时打开多个装了 DEVFramework 的 Godot 编辑器时, 每个实例都想绑
## 同一个固定端口 → 只有一个能绑上, 其余实例的 MCP 服务器直接起不来(而且端口值还写在各自的
## project.godot 里, 所以"换个端口"就等于让 AI 客户端再加一条配置)。结果: 多个编辑器 = 多份
## MCP 配置, 且很容易连到错的那个。
##
## 做法(hub-and-spoke):
##   · 一个**机器级**固定端口(见 MCPDevServer.SETTING_HUB_PORT)只有**一个**实例能持有, 它就是这个
##     "中枢(hub)";
##   · 其余实例各绑一个**系统分配的临时端口**(listen(0)), 每 4 秒把自己登记到中枢;
##   · 中枢对外只暴露固定端口那一个 MCP 端点, 工具表就是它自己的全量工具(每个工具多一个可选
##     `instance` 参数), tools/call 时按目标实例把 JSON-RPC **原样转发**到该实例的临时端口 ——
##     于是在中枢上调 eval_code / game_control / 场景编辑, 都会真正落到你指定的那个编辑器。
##   · 中枢退出后, 成员心跳连续失败 → 抢绑固定端口(bind 是原子的), 抢到的那个成为新中枢,
##     其余成员下个心跳周期自动登记到它。
##
## 为什么不聚合工具名(instance__tool): 那是工具数 × 实例数, 上下文直接爆掉; 而且改成转发后
## 每个工具的 schema/语义都不用动。详见 Readme §7.3 的方案对比。
## 为什么不引入外部 hub 进程: 中枢本身就是一个编辑器实例, 天然拥有完整工具实现, 零外部依赖
## (不需要 node/python/额外二进制)。代价是中枢随那个编辑器退出, 由接管逻辑补偿。
##
## 本文件由 MCPDevServer 以 `_mod("MCPInstanceHub")` 动态编译并 `.new()` 持有。
## **不声明 class_name**(理由同其它 MCP 域脚本, 见 MCPDevServer 顶部注释)。
##
## 边界: 本模块只管"注册表 + 目标路由 + HTTP 转发", 不含任何工具实现, 也不碰 MCP 协议形状。
## 工具/协议仍在 MCPDevServer 里, 这里只回普通字典, 由服务器负责包成 JSON-RPC。
## **导出安全**: 本文件不引用任何编辑器类(虽然只在编辑器进程被实例化, 但保持可解析)。

## 心跳周期: 成员每隔这么久向中枢登记一次(登记即续约, 不另设 ping)。
## 4 秒是在"中枢退出后多快能接管"与"空转 HTTP 请求量"之间取的: 单机零成本, 接管窗口约 3 拍。
const HEARTBEAT_MS := 4000
## 成员存活上限: 心跳停止超过这个时长即从表中剔除。
## 它只用于"手动关掉一个编辑器"后的清理 —— 崩溃/强杀同样走这条路径, 故不能太长(否则
## 会对着已死的实例报错); 也不能太短(否则一次 GC 卡顿就被误判为退出)。
## **不用 pid 存活判断**: Windows 的 pid 会被复用, 判错的方向恰恰是"把死实例当成活的"。
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

## uid -> 实例条目。条目形状见 _make_entry()。
var members := {}
## 默认目标实例的 instance_id(项目级身份)。空串 = 不转发, 就地执行。
##
## 为什么是**全局单值**而不是"按 MCP 会话绑定": 工具 handler 拿不到会话 id(handler 签名是
## args 字典), 把 sid 一路穿进 50+ 个 handler 只为这一个功能不划算; 且 MCP 2026-07-28 起
## 协议级会话被移除, 按会话 pin 在那之后本来就会失效。单值默认目标 + 单次调用 `instance`
## 参数覆盖, 覆盖了全部真实用法(一个开发者、一个 agent 会话对着一个编辑器干活)。
var active_instance := ""

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
## 服务器侧拿到的是本脚本的**动态实例**(Variant), 而 GDScript 的常量不是对象属性 ——
## `inst.SOME_CONST` 在动态访问下取不到("Invalid get index")。故把服务器需要的那几个常量
## 经方法暴露出来: 用方法而不是让服务器自己抄一份字面量, 是为了让"心跳周期/端点路径"这两个
## 约定仍只有一处定义(hub 与 member 两端都用同一个值才算对得上)。

func heartbeat_ms() -> int:
	return HEARTBEAT_MS


func unregister_path() -> String:
	return HUB_UNREGISTER_PATH


func instances_path() -> String:
	return HUB_INSTANCES_PATH


## ------- 身份 -------

## 实例 id: "<项目名>@<项目路径哈希前 8 位>"。
## 与 MCP for Unity 的 `Name@hash` 同构: 人能一眼看出是哪个项目, 机器能稳定复现,
## 且盘符大小写/斜杠/尾分隔符差异不会算出两个 id(见 _normalize_path)。
## 同一项目被打开两次时两者 id 相同 —— 这正是"默认实例应该按项目记"的依据,
## 而单次调用可以用 uid(带进程号)精确指定到某一个进程。
static func make_instance_id(project_name: String, project_path: String) -> String:
	return "%s@%s" % [safe_name(project_name), hash8(_normalize_path(project_path))]


## 路径规范化: 反斜杠统一 + 去尾分隔符 + 转小写。
## **传进来的必须是绝对路径**(调用方负责 globalize): 传 "res://" 这种相对路径会让所有项目的
## 哈希都撞在一起, 于是多个项目的实例 id 相同, 默认目标会随机落到其中一个。
## 也用于展示: globalize_path("res://") 带尾斜杠, 不统一就会出现 ".../Framework/" 与
## ".../Framework" 两种写法并列在实例清单里。
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
## 不做这一步的话 "My Game@a1b2c3d4" 里的空格会让复制粘贴到 URL/命令行时出错。
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
	# 实例清单里出现 ".../Framework/" 与 .../Framework 两种写法并列, 复制粘贴时容易出错。
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
## 清单在成员进程里只有一个条目, 等于没给。
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
		# 时间戳和本地 ticks 比, 结果要么立刻全删要么永不过期(中枢与本机同机, 时钟同源)。
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
## 两个派生字段: 调用方(以及 AI)判断"这个实例是不是已经死了"靠的就是 age_ms, 不给就得自己算。
##
## **必须先 prune**: 快照是"当前有哪几个编辑器"的唯一对外答案, 若它把已经死掉的成员也列出来,
## 调用方就会去选一个已经关掉的实例, 然后收到一次转发超时。实测就是这样: 强杀第二个编辑器后,
## 中枢的快照仍然列出它(age_ms 一路涨到 56 秒), 而 prune 只在 /hub/register 里被调。
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
## 怎么处理 —— 把"选哪个"藏在这里必然选出不可预期的那个(见 resolve 的歧义说明)。
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
##   2. 端口号(手工记过端口的场合仍可用)
##   3. instance_id 精确("MyGame@a1b2c3d4", 项目级) —— **同项目多开时会命中多个**:
##      此时不猜, 返回空并由调用方报"有歧义 + 候选清单", 让调用方改用 uid 或端口。
##      为什么这里不像 use_instance 那样优柔地挑一个: 一次写操作打错项目的代价远高于多一次调用,
##      而"同项目多开"恰恰是两个窗口各改各的场景, 挑错就等于把 A 窗口的改动写进 B 窗口。
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
##
## 绑定用 **uid** 而非 instance_id: uid 带进程号, 唯一; 而 instance_id 在同项目多开时会撞,
## 用它做键会让"选中 A 窗口"在 B 窗口也生效(且两边 id 相同, 从错误信息里看不出问题)。
func set_active(uid: String) -> void:
	active_instance = uid


## 默认目标是否落在**别的**实例上(落在自己身上等于不转发)。
func active_is_remote() -> bool:
	if active_instance.is_empty():
		return false
	var e := find_by_uid(active_instance)
	return not e.is_empty() and not bool(e.get("is_self", false))


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
##
## 为什么不给每个工具各写一份带 instance 的 schema: 50+ 个工具 × 两份 = 必然漂移,
## 而漂移的症状是"某个工具忘了带 instance, 于是它永远只能作用于中枢自己" —— 静默且难查。
## 为什么不改 _tool_defs 本身: 中枢的转发目标(成员)也跑同一套代码, 若把 instance 写进通用
## schema, 成员侧也会多收一个自己不会处理、却会进入参校验的参数。
## [param skip] 不需要注入的工具名(实例管理工具: 它们自己的 instance 参数语义不同)。
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
## 由 MCPDevServer 的 HTTP 处理器调用, 本函数不碰 socket。
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
## resultType/ttlMs), 不带的话客户端拿到的响应形状会与协商版本不符。
func forward(port: int, rpc: Dictionary, timeout_ms: int, proto: String = "") -> Dictionary:
	var extra := PackedStringArray()
	if not proto.is_empty():
		extra.append("mcp-protocol-version: " + proto)
	return await post_json(port, "/mcp", rpc, timeout_ms, extra)


## 最小 HTTP 客户端: POST 一个 JSON, 读回一个 JSON。
##
## 不引 HTTPRequest 节点: 那需要节点进场景树 + 信号接线, 而这里只是"成员↔中枢"的内部往返,
## HTTPClient 足够且不引入节点生命周期问题(转发请求可能在中枢被关掉时仍在飞)。
## 循环里的 `await` 是必须的 —— 不给主循环机会, 编辑器会整段卡住(转发是阻塞语义)。
##
## ## 连接阶段必须用**独立短超时**
##
## 转发工具调用时总超时给的是"游戏调用上限 + 余量"(最长约 610 秒), 那是给**工具执行**用的。
## 若连接阶段也共用它, 则"目标实例已关闭"这一最常见情况会表现为: connect 异步发起 →
## 端口没监听 → 一直等到 610 秒才报错。实测就是这样(中枢转发给一个已关闭实例时挂死)。
## 死实例的判定本来就是确定的、只需一次 TCP 握手的时间, 故连接阶段单独给 CONNECT_TIMEOUT_MS。
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
	# 丢掉它会让上层只看到"实例无响应", 掩盖真正原因(例如 token 不匹配的 401)。
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

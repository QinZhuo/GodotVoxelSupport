## Steam 集成统一入口（纯静态，**不依赖 godotsteam 插件存在**）。
class_name SteamTool extends RefCounted
## Reset: 进程级（平台查询缓存）

## Steam 入口名（引擎单例名 / autoload 节点名）
const SINGLETON_NAME := &"Steam"

## `is_initialized()` 的粘性结果：只在"确实已初始化"时缓存（初始化只发生一次，
static var _init_ok := false


## 取 Steam 入口对象：引擎单例 → autoload 节点；都没有则 null（静默降级）
static func get_steam() -> Object:
	if Engine.has_singleton(SINGLETON_NAME):
		return Engine.get_singleton(SINGLETON_NAME)
	var loop := Engine.get_main_loop() as SceneTree
	return loop.root.get_node_or_null(NodePath(SINGLETON_NAME)) if loop != null else null


## 是否为 Steam 平台包（插件存在即可，不要求客户端在跑）。
static func has_platform() -> bool:
	return get_steam() != null


## Steam 是否可用：插件已加载且 Steam 客户端在运行
static func is_available(log_tag: String = "") -> bool:
	var steam := get_steam()
	if steam == null:
		if not log_tag.is_empty():
			LogTool.warn(log_tag, "Steam插件不可用，已切换为离线模式")
		return false
	if not (steam.has_method("isSteamRunning") and steam.call("isSteamRunning")):
		if not log_tag.is_empty():
			LogTool.warn(log_tag, "Steam客户端未运行，已切换为离线模式")
		return false
	return true


## SteamAPI 是否**已真正初始化**（= 所有 `Steam.*` 子系统接口可用）。
## 与 `is_available()` 的分工：后者只回答"插件在 + Steam 客户端进程在跑"，用于"要不要尝试初始化"；
## 本方法回答"现在能不能安全调 SDK"。两者不等价 —— 编辑器直接起进程、或 Steam 客户端在跑而游戏
## 实测会刷 "X class not found, Steam may not be initialized"，并出现过 ntdll 0xc0000374 堆损坏崩溃。
static func is_initialized() -> bool:
	if _init_ok:
		return true
	var steam := get_steam()
	if steam == null or not steam.has_method("get_steam_init_result"):
		return false
	var res: Variant = steam.call("get_steam_init_result")
	if not (res is Dictionary) or int(res.get("status", -1)) > 0:
		return false
	var sid: Variant = steam.call("getSteamID") if steam.has_method("getSteamID") else null
	_init_ok = sid != null and str(sid) != "0" and not str(sid).is_empty()
	return _init_ok


## 驱动 Steam 回调（未初始化/不可用时空操作）。
## ⚠️ 必须在"已初始化"之后才驱动：对未初始化的 SDK 调 run_callbacks 是未定义行为。
static func run_callbacks() -> void:
	if not is_initialized():
		return
	get_steam().call("run_callbacks")


## 调用 Steam 单例方法；不可用 / 未初始化 / 无该方法时返回 [param default]
static func call_steam(method: StringName, args: Array = [], default_value: Variant = null) -> Variant:
	if not is_available() or not is_initialized():
		return default_value
	var steam := get_steam()
	if not steam.has_method(method):
		return default_value
	return steam.callv(method, args)


## 当前 SteamID（字符串）；不可用时返回空串
static func get_steam_id() -> String:
	var sid: Variant = call_steam(&"getSteamID", [], null)
	return "" if sid == null else str(sid)


## persona name 缓存：榜单一次要查上百个名字，跨 GDExtension 调用约 0.17ms/次。
static var _name_cache: Dictionary = {}


## 单个玩家的名字失效：persona_state_change 在好友上下线时会频繁触发，只清对应条目
static func invalidate_player_name(steam_id: int) -> void:
	_name_cache.erase(steam_id)


## 指定 SteamID 的玩家显示名；不可用时返回空串
static func get_player_name(steam_id: int) -> String:
	if _name_cache.has(steam_id):
		return _name_cache[steam_id]
	var name: Variant = call_steam(&"getFriendPersonaName", [steam_id], null)
	var result := "" if name == null else str(name)
	if not result.is_empty():
		_name_cache[steam_id] = result
	return result


## Steam Cloud 配额查询；Steam 不可用 / 无该方法时返回空字典。
static func get_cloud_quota() -> Dictionary:
	var quota: Variant = call_steam(&"getQuota", [], null)
	return quota if quota is Dictionary else {}


## 当前 Steam beta / 测试分支名；正式分支或不可用时返回空串。
static func get_beta_branch_name() -> String:
	var steam := get_steam()
	if not is_available() or steam == null or not steam.has_method("getCurrentBetaName"):
		return ""
	if _method_argc(steam, &"getCurrentBetaName") > 0:
		return str(steam.call("getCurrentBetaName", 256))
	return str(steam.call("getCurrentBetaName"))


## 动态取对象某方法的参数个数（Object 无 get_method_argument_count，只能查 method_list）
static func _method_argc(obj: Object, method: StringName) -> int:
	for info in obj.get_method_list():
		if StringName(info.get("name", "")) == method:
			return (info.get("args", []) as Array).size()
	return 0

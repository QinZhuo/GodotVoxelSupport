## Steam 集成统一入口（纯静态，**不依赖 godotsteam 插件存在**）。
##
## 动机：GodotSteam 把 `Steam` 暴露为引擎单例（部分版本为 autoload 节点）；编译期直接写
## `Steam.xxx` 会在**未安装插件**的项目里报 "Identifier Steam not declared"，导致整个脚本编译不过。
## 这里一律经动态入口取对象 + `call()` 调用，缺插件时返回 null / 降级为离线，从而无插件也能编译。
## 访问 Steam 的代码都应走本入口，避免各处口径不一。
class_name SteamTool extends RefCounted

## Steam 入口名（引擎单例名 / autoload 节点名）
const SINGLETON_NAME := &"Steam"


## 取 Steam 入口对象：引擎单例 → autoload 节点；都没有则 null（静默降级）
static func get_steam() -> Object:
	if Engine.has_singleton(SINGLETON_NAME):
		return Engine.get_singleton(SINGLETON_NAME)
	var loop := Engine.get_main_loop() as SceneTree
	return loop.root.get_node_or_null(NodePath(SINGLETON_NAME)) if loop != null else null


## Steam 是否可用：插件已加载且 Steam 客户端在运行
## [param log_tag] 非空时输出具体离线原因日志（供初始化流程诊断），判定本身不受影响
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


## 驱动 Steam 回调（不可用时空操作）
static func run_callbacks() -> void:
	if not is_available():
		return
	get_steam().call("run_callbacks")


## 调用 Steam 单例方法；不可用 / 无该方法时返回 [param default]
static func call_steam(method: StringName, args: Array = [], default_value: Variant = null) -> Variant:
	if not is_available():
		return default_value
	var steam := get_steam()
	if not steam.has_method(method):
		return default_value
	return steam.callv(method, args)


## 当前 SteamID（字符串）；不可用时返回空串
static func get_steam_id() -> String:
	var sid: Variant = call_steam(&"getSteamID", [], null)
	return "" if sid == null else str(sid)


## 指定 SteamID 的玩家显示名；不可用时返回空串
static func get_player_name(steam_id: int) -> String:
	var name: Variant = call_steam(&"getFriendPersonaName", [steam_id], null)
	return "" if name == null else str(name)


## Steam Cloud 配额查询；Steam 不可用 / 无该方法时返回空字典。
## 返回 {total_bytes, available_bytes}（Steam 原样字段）；"够不够写"的业务判断交给调用方。
static func get_cloud_quota() -> Dictionary:
	var quota: Variant = call_steam(&"getQuota", [], null)
	return quota if quota is Dictionary else {}


## 当前 Steam beta / 测试分支名；正式分支或不可用时返回空串。
## 兼容不同 GodotSteam 版本：部分版本 getCurrentBetaName 需要传入缓冲区长度。
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

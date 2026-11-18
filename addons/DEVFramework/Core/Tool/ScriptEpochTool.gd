@tool
class_name ScriptEpochTool extends RefCounted

## 脚本代次 + 项目缓存失效的单一入口。
## 【为什么需要它】GDScript 热重载不会清空 static 变量：旧一代脚本留下的静态缓存
## 会被新一代代码读到，出现"结构混代"（本项目地形索引/页缓存踩过）。
## 项目把"清缓存"注册进来，测试/重载时由框架统一调用，不必每个项目自己写 CACHE_VERSION。
##
## 用法（项目侧）：
##   ScriptEpochTool.register_cache(&"my_module", _clear_caches)
##   # 静态函数签名: static func _clear_caches() -> void
##
## 框架在 TestRunner 每轮开始前调用 begin_run()；编辑器文件系统变化时只 bump()，
## 是否清理由持有缓存的模块自己决定（避免在编辑态误清正在使用的资源）。

const MAX_HISTORY := 32

static var _epoch: int = 0
static var _cache_clearers: Dictionary = {}
static var _history: Array = []
## 上一次真正清缓存时的代次；begin_run 只在代次变化时清，避免每轮测试无谓清空。
static var _last_run_epoch: int = -1


## 当前脚本代次。缓存 key 可以拼上它，或只依赖 begin_run() 的失效回调。
static func current() -> int:
	return _epoch


## 仅递增代次（不清缓存）。编辑器保存/扫描后调用。
static func bump(reason: String = "") -> int:
	_epoch += 1
	_history.append({"epoch": _epoch, "reason": reason, "tick": Time.get_ticks_msec()})
	while _history.size() > MAX_HISTORY:
		_history.pop_front()
	return _epoch


## 注册一个清缓存回调。同一 key 重复注册时覆盖（便于热重载后替换旧 Callable）。
static func register_cache(key: StringName, clearer: Callable) -> bool:
	if not clearer.is_valid():
		LogTool.warn("脚本代次", "register_cache(%s) 收到无效 Callable" % String(key))
		return false
	_cache_clearers[key] = clearer
	return true


static func unregister_cache(key: StringName) -> void:
	_cache_clearers.erase(key)


## 依次调用所有已注册的清缓存回调；返回成功调用的数量。
## 某个回调失效（对象已释放）只跳过并移除，不影响其它模块。
static func invalidate_caches(reason: String = "") -> int:
	var cleared := 0
	for key in _cache_clearers.keys():
		var clearer: Callable = _cache_clearers[key]
		if not clearer.is_valid():
			_cache_clearers.erase(key)
			continue
		clearer.call()
		cleared += 1
	return cleared


## 测试/长任务开始：代次变化时才清项目缓存；没变化直接返回当前代次。
## （每轮无条件清会让第一用例无谓变慢，也会掩盖"缓存是否真的跨代残留"。）
static func begin_run(reason: String = "test_run") -> int:
	var e := current()
	if e != _last_run_epoch:
		_last_run_epoch = e
		invalidate_caches(reason)
	return e


## 诊断：当前注册了哪些缓存、最近发生了什么。
static func status() -> Dictionary:
	return {
		"epoch": _epoch,
		"caches": _cache_clearers.keys(),
		"history": _history.duplicate(true),
	}


## 会话级复位（由 ResetTool.all() 调用）：代次归零、清注册表与历史。
## 新会话不应继承上一局的脚本代次；正在跑的长任务不该被这里打断（JobTool 自己管）。
static func reset() -> void:
	_epoch = 0
	_last_run_epoch = -1
	_cache_clearers.clear()
	_history.clear()
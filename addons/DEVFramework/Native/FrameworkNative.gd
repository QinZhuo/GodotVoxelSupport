class_name FrameworkNative
extends RefCounted

## 框架级统一 GDExtension 原生桥接。
##
## 整个 DEVFramework 的 C++ 原生能力集中在**唯一一个共享扩展**：
##   res://addons/DEVFramework/Native/devecs.gdextension
## （ECS 的 ECSCore、未来 PCG 侵蚀加速等模块原生类都注册在这里，共用一份二进制）。
##
## 职责：
##   - 懒加载共享原生库（所有模块第一次访问时统一加载，避免各自重复检测）
##   - 按类名/方法名做存在性校验（缺库/版本不符时明确 push_error，无静默回退）
##   - 提供稳定的类实例化（ClassDB 派发 + 脚本 resource_path 加载两条路径）
##
## 各模块原生桥接（如 ECSNative）应通过本类获取实例，而非直接 ClassDB.instantiate，
## 保证整个框架共用一份原生库、错误信息统一。

## 共享原生库配置路径（相对 res://）
const NATIVE_EXTENSION_PATH := "res://addons/DEVFramework/Native/devecs.gdextension"

## 已缓存的原生实例（模块类名 → Object）
static var _cache: Dictionary = {}

## 已确认可用的类名集合（避免重复检测）
static var _checked: Dictionary = {}


## 原生库是否已加载（ClassDB 里能看到该扩展注册的类即视为已加载）
static func is_extension_loaded(native_class: StringName) -> bool:
	return ClassDB.class_exists(native_class)


## 获取某个原生类的共享实例（懒加载 + 方法校验）。
## native_class: 原生类名（如 &"ECSCore"）；required_methods: 必需方法名数组，用于版本校验。
## 失败时 push_error 并返回 null。
static func get_native(native_class: StringName, required_methods: Array[StringName] = []) -> Object:
	if _cache.has(native_class) and is_instance_valid(_cache[native_class]):
		return _cache[native_class]
	if not ClassDB.class_exists(native_class):
		push_error("FrameworkNative: 原生类 %s 不存在! 请确认 %s 已加载(框架强依赖 C++ 共享库)。" % [
			native_class, NATIVE_EXTENSION_PATH,
		])
		return null
	for m in required_methods:
		if not ClassDB.class_has_method(native_class, m, false):
			push_error("FrameworkNative: 原生类 %s 缺少必需方法 %s! 请重新编译共享原生库。" % [native_class, m])
			return null
	var inst: Object = ClassDB.instantiate(native_class)
	if inst == null:
		push_error("FrameworkNative: 原生类 %s 实例化失败! 请检查 %s 配置。" % [native_class, NATIVE_EXTENSION_PATH])
		return null
	_cache[native_class] = inst
	_checked[native_class] = true
	return inst


## 强制重新加载某原生类（清缓存；用于库热重载/测试）
static func refresh(native_class: StringName) -> void:
	_cache.erase(native_class)
	_checked.erase(native_class)


## 清空全部原生缓存
static func refresh_all() -> void:
	_cache.clear()
	_checked.clear()


## 稳定实例化脚本: 通过 resource_path 加载并 new, 规避全局类注册时序问题。
## 若脚本处于半编译状态(can_instantiate()=false), 主动 reload() 强制编译后再 new。
## 返回实例或 null。
static func instantiate_script(script: Script) -> Variant:
	if script == null:
		return null
	var path: String = script.resource_path
	if path == "":
		return null
	var loaded: Variant = load(path)
	if loaded == null:
		return null
	if not loaded.can_instantiate():
		loaded.reload()  # 强制编译: 修复首次加载半编译竞态
	return loaded.new()

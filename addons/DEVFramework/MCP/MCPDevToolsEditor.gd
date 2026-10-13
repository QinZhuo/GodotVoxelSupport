@tool
extends RefCounted

## ======= 开发辅助域: 编辑器专属部分 =======
##
## 从 MCPDevTools 拆出的、**依赖编辑器类**的两个工具: restart_editor(EditorInterface.restart_editor)
## 与 script_status(经 MCPScriptSync 比对已加载版本)。eval_code 留在导出安全的 MCPDevTools,
## 以便运行时服务器也能注册它。本文件由主服务器在编辑器分支经 _mod 按需加载, 不进导出包解析图。
##
## 依赖: MCPResult / MCPScriptSync / VariantTool。

const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPScriptSync := preload("res://addons/DEVFramework/MCP/MCPScriptSync.gd")


## 域注册入口。add_tool 是服务器 _add_tool 的 Callable, 签名 (name, desc, schema, handler)。
## handler 一律 static: MCPToolAudit 靠 get_method() 拿函数名切源码做入参自检。
static func register(add_tool: Callable) -> void:
	add_tool.call("restart_editor",
		"重启编辑器: 修改框架代码(addons/DEVFramework/**.gd)后调用, 以统一全局类脚本代次并让新逻辑生效(原重扫逻辑已由编辑器自动处理, 不再需要)。**总会先保存全部已打开的场景再重启**(EditorInterface.restart_editor(true), 故未保存的改动不会丢)。延迟默认1秒触发以保证本响应先送达; 重启期间MCP连接短暂断开(端口不变+插件自启自动恢复), 客户端等待数秒后重试调用即可继续。",
		{"type": "object", "properties": {
			"delay_sec": {"type": "number", "description": "延迟触发的秒数(留时间送达本响应), 默认 1.0, 上限 10"}
		}},
		_handle_restart_editor)

	add_tool.call("script_status",
		"检查脚本'磁盘内容'与'编辑器进程已加载版本'是否一致。eval_code(process=editor) 执行前会自动热重载(CACHE_MODE_REPLACE 换掉脚本缓存 + fs.scan() 刷新全局类表, 约1.8s, 远快于 restart_editor), 本工具用于诊断该热重载是否生效, 或主动核查指定脚本; 每个路径返回 state=in_sync/changed/not_loaded/missing 与两侧哈希。【范围】只反映本进程; 游戏进程同类问题由 eval_code(process=game) 在游戏侧自行判定。",
		{"type": "object", "properties": {
			"paths": {"type": "array", "description": "要检查的 res:// 脚本路径数组(如 [\"res://Scripts/Const/GameConstants.gd\"]); 单个也可传 path", "items": {"type": "string"}},
			"path": {"type": "string", "description": "可选: 单个脚本路径(与 paths 二选一)"}
		}},
		_handle_script_status)


## 取宿主进程的场景树。static 上下文没有 get_tree(), 故经 Engine 取主循环。
static func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


## restart_editor: 重启编辑器(修改框架代码后重启以统一全局类脚本代次)
static func _handle_restart_editor(args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return MCPResult.fail("仅在编辑器模式可用")
	var delay_sec: float = clampf(VariantTool.get_float(args, "delay_sec", 1.0), 0.0, 10.0)
	# 场景清单必须在触发前取: 重启后这段代码不会再跑, 而"到底存了哪些场景"正是重启之后
	# 无法复得的证据。把清单写进响应, "自动保存"才是可核对的承诺而不是一句说法。
	var open_scenes := PackedStringArray(EditorInterface.get_open_scenes())
	var names := PackedStringArray()
	for p in open_scenes:
		names.append(String(p).get_file())
	_delayed_restart(delay_sec)
	return MCPResult.ok_with_meta(
		"编辑器将在 %.1f 秒后重启(已安排保存全部 %d 个打开的场景: %s)。重启期间 MCP 连接短暂断开(端口不变+插件自启自动恢复), 客户端等待数秒后重试调用即可继续。" % [delay_sec, open_scenes.size(), ", ".join(names)],
		{"open_scene_count": open_scenes.size(), "open_scenes": Array(names)})


## 延迟重启。保存**交给引擎**: restart_editor(true) 内部先走保存再重启。
static func _delayed_restart(delay_sec: float) -> void:
	var loop := _tree()
	if delay_sec > 0.0 and loop != null:
		await loop.create_timer(delay_sec).timeout
	EditorInterface.restart_editor(true)


## 编辑器进程: 比对脚本"磁盘内容"与"编辑器已加载版本"。只读比对, 不改任何状态。
static func _handle_script_status(args: Dictionary) -> Dictionary:
	var paths: Array = VariantTool.get_array(args, "paths").duplicate()
	var single := VariantTool.get_string(args, "path")
	if not single.is_empty():
		paths.append(single)
	if paths.is_empty():
		return MCPResult.fail("需提供 path 或 paths(要检查的 res:// 脚本路径)")
	var items: Array = []
	var changed_count := 0
	for p in paths:
		var path := str(p)
		# 转发给 MCPScriptSync —— 与 eval 的自动同步同一判据, 避免"本工具说一致"与"实际不一致"分叉。
		var item := MCPScriptSync.script_status_of(path)
		if item.get("state", "") == "changed":
			changed_count += 1
		items.append(item)
	var out := {"items": items, "changed": changed_count, "total": items.size()}
	if changed_count > 0:
		out.hint = "有 %d 个脚本与编辑器已加载版本不一致(编辑器跑的是旧代码)。eval_code 会自动热重载; 若仍出现此提示说明自动热重载未生效, 请用 restart_editor 重启编辑器。" % changed_count
	return MCPResult.ok_json(out)

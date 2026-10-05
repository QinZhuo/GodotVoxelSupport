@tool
extends RefCounted
## ======= 跨域共享的编辑器环境辅助 =======
##
## 归属说明: `edited_root()` 原先是 MCPDevServer 的实例方法 `_edited_root()`, 被三个域
## 同时使用 —— 场景树编辑域(9 个工具的入口)、截图域(`_capture_scene_thumbnail`)、
## 项目信息域(`_call_get_project_info` / `_call_get_editor_state` /
## `_call_get_project_settings`)。三处都跨域, 所以它既不属于任何单一域, 也不该留在
## MCPDevServer 里(域文件禁止反向引用主文件)。
##
## 为什么不留在 MCPDevServer 而由各域各留一份私有副本: 那是**三份同名副本**。
## 各域的实现只会因为"运行期分支可达性"不同而略有差异, 但一旦分叉, 症状是
## "某个工具突然读不到编辑根节点", 从调用栈完全看不出根因是复制粘贴分叉。
## 单副本的代价是改这里等于改所有域 —— 这是显式的, 比隐式的静默分叉好。
##
## 依赖单向: 本文件不引用任何域文件, 只被各域 preload。
##
## static 化说明: 原为实例方法用 `get_tree()`, static 后改 `Engine.get_main_loop()`,
## 与 MCPDevTools 的 `_delayed_restart` 同一手法。`Engine.get_main_loop() as SceneTree`
## 在无 main loop 时得到 null, 与原 `var tree := get_tree()` 的空判等价。

## 当前正在编辑的场景根节点(编辑器模式)或运行中场景(运行时模式)。
##
## 注意: 各编辑器侧域只需编辑器分支 —— 那些工具只在编辑器进程注册, 运行期分支在
## 那些域里不可达。本函数保留完整形态, 因为主文件与游戏侧仍会用。
static func edited_root() -> Node:
	if Engine.is_editor_hint():
		return EditorInterface.get_edited_scene_root()
	var tree := Engine.get_main_loop() as SceneTree
	return tree.current_scene if tree else null

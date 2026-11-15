@tool
extends RefCounted
## ======= 跨域共享的编辑器环境辅助 =======
## MCPDevServer 里(域文件禁止反向引用主文件)。

## 当前正在编辑的场景根节点(编辑器模式)或运行中场景(运行时模式)。
## 注意: 各编辑器侧域只需编辑器分支 —— 那些工具只在编辑器进程注册, 运行期分支在
static func edited_root() -> Node:
	if Engine.is_editor_hint():
		return EditorInterface.get_edited_scene_root()
	var tree := Engine.get_main_loop() as SceneTree
	return tree.current_scene if tree else null


## 以调试模式启动指定场景(等效 F5)。编辑器专属 API 收口在此, 主服务器文件因导出需零
static func play_custom_scene(path: String) -> void:
	EditorInterface.play_custom_scene(path)


static func stop_playing_scene() -> void:
	EditorInterface.stop_playing_scene()

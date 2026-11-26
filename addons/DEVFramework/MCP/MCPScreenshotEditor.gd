@tool
extends RefCounted

## ======= 截图域: 编辑器侧捕获(仅编辑器进程) =======

const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPScreenshotTools := preload("res://addons/DEVFramework/MCP/MCPScreenshotTools.gd")
const MCPResourceTools := preload("res://addons/DEVFramework/MCP/MCPResourceTools.gd")

## ======= 域入口: 编辑器侧捕获 =======
static func capture_editor_side(capture_type: String, args: Dictionary) -> Dictionary:
	# 本函数只服务编辑器进程。
	if not Engine.is_editor_hint():
		return MCPResult.fail("take_screenshot: editor/scene 只能在编辑器进程捕获, 当前进程不可用(检查主服务器是否漏了 _mode 判断)")
	# scene 的渲染归属在资源域(与 resource_inspect 的 render 同一个底座), 这里只转发。
	if capture_type == "scene":
		return await MCPResourceTools.scene_thumbnail(args)
	if capture_type != "editor":
		# 这里**故意不做**"视作 editor"的兜底: schema 的 enum + MCPToolContract 只挡协议路径。
		return MCPResult.fail("capture_type=%s 不是本域支持的模式(本域只做 editor / scene; game 由主服务器转发去游戏进程)" % capture_type)
	var img: Image = await _capture_editor_viewport()
	if img == null or img.is_empty():
		return MCPResult.fail("截图失败: 编辑器视口纹理为空")
	# 统一走 ScreenshotTool: 颜色处理(auto 判定) -> 缩放 -> 保存。
	var shot: Dictionary = MCPResourceTools.save_shot(img, capture_type, args)
	if not shot.get("ok", false):
		return MCPResult.fail(str(shot.get("error", "截图失败")))
	var out := MCPResult.ok_json({
		"path": shot.get("path", ""),
		"res_path": shot.get("res_path", ""),
		"width": int(shot.get("width", 0)),
		"height": int(shot.get("height", 0)),
		"bytes": int(shot.get("bytes", 0)),
		"capture_type": capture_type,
		"color_mode": str(shot.get("color_mode", "")),
	})
	return MCPResult.attach_image(out, str(shot.get("res_path", "")))

## 捕获编辑器视口截图(原始读回数据; 颜色处理由 save_image 自动判定)
static func _capture_editor_viewport() -> Image:
	if not Engine.is_editor_hint():
		return null
	var base: Control = EditorInterface.get_base_control()
	if base == null:
		return null
	var viewport := base.get_viewport()
	var tree := base.get_tree()
	if viewport == null or tree == null:
		return null
	await _wait_frames(tree, 3, 2500)
	# 编辑器进程的 RenderingServer.frame_post_draw 不一定按时触发(与游戏的标准帧循环不同),
	return await ScreenshotTool.grab(viewport, {"await_draw": false})

## 等待若干帧, 带超时上限(毫秒, 0 表示不限)
static func _wait_frames(tree: SceneTree, frames: int, timeout_msec: int) -> void:
	var deadline := Time.get_ticks_msec() + timeout_msec
	for i in frames:
		if timeout_msec > 0 and Time.get_ticks_msec() > deadline:
			break
		await tree.process_frame

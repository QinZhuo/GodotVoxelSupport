@tool
class_name ScreenshotToolMenu
extends EditorScript

## 编辑器菜单入口 — 「项目 → 工具 → EditorScript → ScreenshotToolMenu」。
##
## 本脚本只是一层壳: 真正的截图能力全部在 ScreenshotTool(普通类, 编辑器与游戏共用)。
## 之所以分成两个文件, 是因为 EditorScript 只能在编辑器内实例化, 其静态方法在游戏运行时
## 也不可用(实测: "Class 'EditorScript' can only be instantiated by editor"),
## 而截图能力在游戏运行时同样需要。故核心逻辑放普通类, 此处仅负责菜单触发。
##
## 点击后: 捕获编辑器主视口 -> 存到 res://.godot/mcp_screenshots/ -> 打印路径。
## 需要别的目录/分辨率时, 直接调 ScreenshotTool.capture(viewport, opts),
## 参数与返回结构见 ScreenshotTool 文件头说明。

## 编辑器视口截图的最大宽度(超过则等比缩小; 0 表示保留原始分辨率)
const MAX_WIDTH := 0


func _run() -> void:
	var res: Dictionary = await _capture_editor()
	if res.get("ok", false):
		LogTool.log("截图", "已保存:", res.get("path", ""),
			"(%dx%d, %d 字节)" % [res.get("width", 0), res.get("height", 0), res.get("bytes", 0)])
	else:
		LogTool.error("截图", "失败:", res.get("error", "未知错误"))


## 捕获编辑器主视口并保存。返回 ScreenshotTool 结果字典。
func _capture_editor() -> Dictionary:
	if not Engine.is_editor_hint():
		return {"ok": false, "error": "该入口只能在编辑器内运行"}
	var base: Control = EditorInterface.get_base_control()
	if base == null:
		return {"ok": false, "error": "无法获取编辑器根控件"}
	var viewport := base.get_viewport()
	if viewport == null:
		return {"ok": false, "error": "无法获取编辑器视口"}
	var tree := base.get_tree()
	if tree != null:
		# 编辑器主循环由 process_frame 驱动, frame_post_draw 不保证按时触发,
		# 这里按编辑器节奏等 2 帧后再取图。
		for i in 2:
			await tree.process_frame
	return await ScreenshotTool.capture(viewport, {
		"dir": ScreenshotTool.DEFAULT_DIR_RES,
		"prefix": "editor",
		"max_width": MAX_WIDTH,
		"srgb": true,
		"await_draw": false,
		"capture_type": "editor",
	})

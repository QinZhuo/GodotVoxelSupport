@tool
extends RefCounted

## ======= 截图域: 编辑器侧捕获(仅编辑器进程) =======
##
## take_screenshot 的 editor / scene 两个模式: 分析的是**编辑器进程自己**的像素, 全程需要
## EditorInterface, 故与导出安全的 MCPScreenshotTools(只放 spec/color_opts)拆开。由主服务器
## 在编辑器分支内经 `_mod("MCPScreenshotEditor")` 按需加载, 不进导出包解析图。
##
## 依赖: MCPResult / MCPEditorEnv / MCPScreenshotTools(取 color_opts) + 全局 ScreenshotTool / VariantTool。

const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")
const MCPEditorEnv := preload("res://addons/DEVFramework/MCP/MCPEditorEnv.gd")
const MCPScreenshotTools := preload("res://addons/DEVFramework/MCP/MCPScreenshotTools.gd")


## ======= 域入口: 编辑器侧捕获 =======
##
## 由主服务器的分流器 _call_take_screenshot 在 capture_type 为 editor / scene 时转发进来。
##
## **入口名不可改回 `_call_take_screenshot`**: 那会与主文件的分流器同名, 而审计取
## `[runtime_handler, editor_handler]` 里第一个非 lambda 去切函数体 —— 一旦取到分流器, 它只读
## capture_type, schema 里 max_width / srgb / include_text / text_max_nodes 四处读取会**一处都不被
## 检查且完全无声**。
##
## [param capture_type] 只可能是 "editor" 或 "scene"; 其他值显式报错, 不做"视作 editor"的兜底。
## [param args] 原始入参, 读取 max_width / srgb。
## 返回: MCPResult 封装的结果字典(成功带 path/res_path/width/height/bytes/capture_type)。
static func capture_editor_side(capture_type: String, args: Dictionary) -> Dictionary:
	# 本函数只服务编辑器进程。被误从游戏进程转发进来时, EditorInterface 未必不可用, 但即使用得
	# 了, 抓到的也是**编辑器里正打开的场景**而不是游戏画面 —— 那会"静默"返回一张看着挺正常的错图。
	if not Engine.is_editor_hint():
		return MCPResult.fail("take_screenshot: editor/scene 只能在编辑器进程捕获, 当前进程不可用(检查主服务器是否漏了 _mode 判断)")
	var img: Image = null
	match capture_type:
		"editor":
			img = await _capture_editor_viewport()
			if img == null or img.is_empty():
				return MCPResult.fail("截图失败: 编辑器视口纹理为空")
		"scene":
			img = await _capture_scene_thumbnail(args)
			if img == null or img.is_empty():
				return MCPResult.fail("场景缩略图生成失败: 无法渲染场景或场景为空")
		_:
			# 这里**故意不做**"视作 editor"的兜底: schema 的 enum + MCPArgCheck 只挡协议路径,
			# 挡不住主服务器自己构造出来的 capture_type —— 兜底会静默返回一张编辑器视口。
			return MCPResult.fail("capture_type=%s 不是本域支持的模式(本域只做 editor / scene; text / game 由主服务器转发去游戏进程)" % capture_type)
	# 统一走 ScreenshotTool: 颜色处理(auto 判定) -> 缩放 -> 保存。
	var opts := {
		"dir": ScreenshotTool.DEFAULT_DIR_RES,
		"prefix": "mcp",
		"max_width": VariantTool.get_int(args, "max_width", ScreenshotTool.DEFAULT_MAX_WIDTH),
		"capture_type": capture_type,
	}
	opts.merge(MCPScreenshotTools.color_opts(args))
	var shot: Dictionary = ScreenshotTool.save_image(img, opts)
	if not shot.get("ok", false):
		return MCPResult.fail(str(shot.get("error", "截图失败")))
	return MCPResult.ok_json({
		"path": shot.get("path", ""),
		"res_path": shot.get("res_path", ""),
		"width": int(shot.get("width", 0)),
		"height": int(shot.get("height", 0)),
		"bytes": int(shot.get("bytes", 0)),
		"capture_type": capture_type,
		"color_mode": str(shot.get("color_mode", "")),
	})


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
	# 等待其会永久挂起。编辑器主循环由 process_frame 驱动, 等帧后直接读纹理即可。
	# 也不要调用 RenderingServer.force_draw(): 在线程化渲染下同步阻塞可能卡住编辑器。
	# await_draw=false: 上面已按编辑器节奏等帧, 不再等 frame_post_draw(会挂起)。
	return await ScreenshotTool.grab(viewport, {"await_draw": false})


## 生成当前编辑场景的缩略图(原始读回数据; 颜色处理由 save_image 自动判定)
static func _capture_scene_thumbnail(_args: Dictionary) -> Image:
	if not Engine.is_editor_hint():
		return null
	var thumbnail_size := 256
	var root := MCPEditorEnv.edited_root()
	if root == null:
		return null
	var scene_path := root.get_scene_file_path()
	if scene_path.is_empty():
		return null
	if not ResourceLoader.exists(scene_path):
		return null
	var scene_res: Resource = ResourceLoader.load(scene_path)
	if not scene_res is PackedScene:
		return null
	var scene_instance: Node = scene_res.instantiate()
	if scene_instance == null:
		return null
	var viewport := SubViewport.new()
	viewport.size = Vector2i(thumbnail_size, thumbnail_size)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.add_child(scene_instance)
	scene_instance.owner = viewport
	var base: Control = EditorInterface.get_base_control()
	if base == null:
		viewport.queue_free()
		return null
	var tree := base.get_tree()
	if tree == null:
		viewport.queue_free()
		return null
	tree.root.add_child(viewport)
	await _wait_frames(tree, 5, 3000)
	var img: Image = await ScreenshotTool.grab(viewport, {"await_draw": false})
	viewport.queue_free()
	return img


## 等待若干帧, 带超时上限(毫秒, 0 表示不限)
static func _wait_frames(tree: SceneTree, frames: int, timeout_msec: int) -> void:
	var deadline := Time.get_ticks_msec() + timeout_msec
	for i in frames:
		if timeout_msec > 0 and Time.get_ticks_msec() > deadline:
			break
		await tree.process_frame

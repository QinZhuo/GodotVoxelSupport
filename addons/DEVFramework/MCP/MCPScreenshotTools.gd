@tool
extends RefCounted

## ======= 截图域 =======
##
## take_screenshot 的编辑器侧实现(editor / scene 两个模式)。四个模式的分工:
##   text / game 分析的是**游戏运行画面**, 编辑器进程里没有那个画面, 必须经调试线转发去游戏
##         进程取 —— 那条通路全是服务器实例状态, 故留在 MCPDevServer, 不在本域。
##   editor / scene 分析的是**编辑器进程自己**的像素, 全程不碰游戏进程, 实现完全在本域。
##
## 响应里只有路径与几个标量, **没有图片数据**(见 capture_editor_side 返回值), 所以本工具不会
## 撞上输出上限; 体积由 max_width(默认降采样到 1280 宽)在**落盘前**压住。截断由协议层统一施加。
##
## 依赖严格单向: 只 preload MCPResult / MCPEditorEnv, 其余走全局 class_name(ScreenshotTool /
## VariantTool)。不引用 MCPDevServer、不持有服务器状态, 故下面三个捕获函数都能 static 化。
const MCPResult := preload("res://addons/DEVFramework/MCP/MCPResult.gd")

## 编辑根节点的读取走**跨域共享件**: 用点跨三个域, 留私有副本等于埋一份会静默分叉的复制粘贴。
const MCPEditorEnv := preload("res://addons/DEVFramework/MCP/MCPEditorEnv.gd")

## 不 preload MCPToolSchema: 本工具的 schema 是带 enum 的自定义字典, 那里没有对应工厂。


## ======= 请求形状(spec) =======
##
## 工具名 / 描述 / schema 归本域所有: 它们描述"截图这个能力要什么参数", 与"在哪个进程注册"无关。
## 主服务器用 spec() 替掉原先内联的描述与 schema 字面量, 免得同一个契约在两处各写一份。
static func spec() -> Dictionary:
	return {
		"name": "take_screenshot",
		"desc": "画面感知工具, 只回答画面长什么样。默认'text'文本化截图(推荐): 返回游戏画面可见节点布局(名称/类型/坐标/尺寸/文本), 无需真图省token, 适合点击模拟与无识图AI。capture_type='game'真实截图(保存PNG返回路径, 附带text快照可include_text=false关)。'editor'编辑器视口截图,'scene'场景缩略图。真实截图默认自动判定颜色空间(color_mode=auto: 按渲染缓冲的实际格式决定要不要补 sRGB 编码), 出图与实际看到的画面一致, 一般无需干预; 仅在极少数偏色场合用 color_mode 覆盖。仅当你能看到图片(多模态识图)时才用非text模式, 纯文本AI禁用game/editor/scene。要找可点的东西并按下, 别截图, 改用 get_interactables(给 ref; 2D 免坐标换算, 3D 直接激活)。",
		"schema": {"type": "object", "properties": {
			"capture_type": {"type": "string", "enum": ["text", "game", "editor", "scene"], "description": "模式: text=文本化截图(默认, 推荐, 需游戏运行), game=真实游戏截图(需游戏运行), editor=编辑器视口截图, scene=当前场景缩略图。传错值会直接报错而非静默回落到 editor"},
			"max_width": {"type": "integer", "description": "仅真实截图生效: 最大宽度, 超过则等比缩小。默认 1280, 传 0 或更大值可保留原始分辨率"},
			"color_mode": {"type": "string", "enum": ["auto", "srgb", "raw"], "description": "仅真实截图生效: 颜色处理模式, 默认 auto(按渲染缓冲的实际数据格式自动判定, 出图即所见)。srgb=强制补一次 linear→sRGB 编码(认定读回的是线性光值), raw=强制不转换(认定读回的已是显示值)。只有确认出图偏色时才需要手动指定"},
			"srgb": {"type": "boolean", "description": "[已废弃, 请用 color_mode] 仅真实截图生效: 旧的强制开关, 等价 color_mode=srgb(true)/raw(false); 与 color_mode 同时传时以 color_mode 为准。不传则走 auto"},
			"include_text": {"type": "boolean", "description": "仅真实截图生效: 是否附带文本化截图(text 字段), 默认 true"},
			"text_max_nodes": {"type": "integer", "description": "文本化截图最多节点数, 默认 50"}
		}},
	}


## ======= 域入口: 编辑器侧捕获 =======
##
## 由主服务器的分流器 _call_take_screenshot 在 capture_type 为 editor / scene 时转发进来:
## `return await MCPScreenshotTools.capture_editor_side(capture_type, args)`。
##
## **入口名不可改回 `_call_take_screenshot`**: 那会与主文件的分流器同名, 而审计取
## `[runtime_handler, editor_handler]` 里第一个非 lambda 去切函数体 —— 一旦取到分流器, 它只读
## capture_type, schema 里 max_width / srgb / include_text / text_max_nodes 四处读取会**一处都不被
## 检查且完全无声**(入参自检只报"读了未声明", 刻意不报"声明了没读")。改名后两边不再同名, 这条
## 恒成立。也不要在外面再加一层同名转发包装。
##
## 注册槽不能直填本函数: 槽要的是 (args) 单参 handler, 且要能自己处理默认模式 text/game(需要
## _pending / debugger_plugin, 本文件拿不到)。故模式分流留在主文件, 注册槽仍填分流器。
##
## [param capture_type] 只可能是 "editor" 或 "scene"; 其他值显式报错, 不做"视作 editor"的兜底。
## [param args] 原始入参, 读取 max_width / srgb。
## 返回: MCPResult 封装的结果字典(成功带 path/res_path/width/height/bytes/capture_type)。
static func capture_editor_side(capture_type: String, args: Dictionary) -> Dictionary:
	# [接缝自检 1/2 见文件末尾"接缝自检"] 本函数只服务编辑器进程。被误从游戏进程转发进来时,
	# EditorInterface 未必不可用, 但即使用得了, 抓到的也是**编辑器里正打开的场景**而不是游戏
	# 画面 —— 那会"静默"返回一张看着挺正常的错图。故此处显式报错, 把漏掉的 _mode 判断顶出来。
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
			# [接缝自检 2/2] 这里**故意不做**"视作 editor"的兜底。schema 的 enum + MCPArgCheck 只挡
			# 协议路径, 挡不住主服务器自己构造出来的 capture_type —— 接缝漏转发/错转发时, 兜底会静默
			# 返回一张编辑器视口、并把 capture_type 原样回显在响应里, 调用方(尤其纯文本模型)会当
			# 成游戏画面继续推理, 基于错的前提一路往下走。这正是必须显式报错的场合。
			# 曾长期靠这个兜底当默认值, 代价就是上面那条静默错图。
			return MCPResult.fail("capture_type=%s 不是本域支持的模式(本域只做 editor / scene; text / game 由主服务器转发去游戏进程)" % capture_type)
	# 统一走 ScreenshotTool: 颜色处理(auto 判定) -> 缩放 -> 保存。
	# 缺省降采样到 1280 宽以控制截图体积(大视口/高分屏尤其明显), 传更大的 max_width 可保留更高分辨率。
	var opts := {
		"dir": ScreenshotTool.DEFAULT_DIR_RES,
		"prefix": "mcp",
		"max_width": VariantTool.get_int(args, "max_width", ScreenshotTool.DEFAULT_MAX_WIDTH),
		"capture_type": capture_type,
	}
	opts.merge(color_opts(args))
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


## 从 MCP 入参里挑出**调用方显式指定**的颜色处理项, 交给 ScreenshotTool 的 opts。
##
## ⚠️ 刻意只透传"传了什么": 不传就一个键都不放, 让 ScreenshotTool 走 auto 自己判。
## 以前这里是 `srgb: get_bool(args, "srgb", true)` —— 由本层替引擎补默认值, 于是 8 位缓冲
## 也被强制编码一次, 出图比实际画面发灰发白。判定的位置只能是"看得见数据格式"的那一层。
## 两个键都在 spec 的 properties 里声明过, 故此处读取不会触发入参自检的"读了未声明"。
static func color_opts(args: Dictionary) -> Dictionary:
	var out := {}
	if args.has("color_mode"):
		out["color_mode"] = VariantTool.get_string(args, "color_mode", ScreenshotTool.COLOR_AUTO)
	if args.has("srgb"):
		out["srgb"] = VariantTool.get_bool(args, "srgb", true)
	return out


## ======= 接缝自检 =======
##
## 全局判据: **接缝可以存在, 但漏调必须可见; 漏调会静默失效的场合一律不许用接缝。**
##
## 本域用接缝, 唯一一处 = 上面那个入口。不能域内自建: 分流前半段必须走调试线, 那条线要用主
## 服务器的实例状态, 本文件既不该反向引用 MCPDevServer 也拿不到。
##
## 两种漏调形态都是**显式报错**, 所以接缝合法:
##   1. 进程错调(游戏进程里调本函数): 两个捕获函数开头各有 is_editor_hint 守卫会返回 null, 入口
##      随即 fail。入口那道守卫是冗余的第二道, 唯一价值是把报错从"纹理为空"(让人往渲染方向查)
##      换成"当前进程不可用, 检查是否漏了 _mode 判断"(直接指到漏调点)。
##   2. 模式错转发: match 的 `_` 分支**故意不做**"视作 editor"的兜底。schema 的 enum 与
##      MCPArgCheck 只挡协议路径, 挡不住主服务器自己构造的 capture_type —— 兜底会静默返回一张
##      编辑器视口并把 capture_type 原样回显, 调用方(尤其纯文本模型)会当成游戏画面继续推理。
##
## 若日后把这两处 fail 改回静默兜底, 那一刻起本域违反判据, 且违反在"看起来更统一"的假象下。


## ======= 捕获实现(本域专属辅助) =======

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


## 当前正在编辑的场景根节点走 MCPEditorEnv.edited_root()(三域共用, 不要在本域另开副本)。


## ======= 截断收口在哪 =======
##
## 输出上限由协议层在 handler 执行完紧接着统一施加(游戏进程侧同理), 收口在 handler **之上**,
## 与 handler 写在哪个文件里无关。故本域不需要、也不该复制那套截断实现。
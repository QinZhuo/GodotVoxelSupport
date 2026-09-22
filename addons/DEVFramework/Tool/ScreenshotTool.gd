class_name ScreenshotTool
extends RefCounted

## 统一截图工具 — 唯一的画面捕获管线。
##
## 设计目标:
##   1. 颜色正确: Godot 的 viewport 纹理是线性空间的(尤其在 Forward+ / HDR 管线下),
##      直接 get_texture().get_image() + save_png() 会得到偏暗发灰的图。
##      本管线在保存前统一做 linear_to_srgb() 校正, 因此"默认截图颜色就是对的"。
##   2. 接口统一: 取图 / 校正 / 缩放 / 保存 / 返回结果 收敛到一个函数, 编辑器侧与游戏侧
##      共用同一实现, 不再各自维护一份。
##
## 典型用法:
##   var res := await ScreenshotTool.capture(viewport, {"max_width": 1280})
##   if not res.ok: push_error(res.error)
##   print(res.path)
##
## 只要 Image 不落盘:
##   var img := await ScreenshotTool.grab(viewport)
##
## 调用方(编辑器脚本 / MCP 工具 / 游戏内)只需调用 capture(), 无需关心颜色空间细节。
##
## 注意: 本类必须是普通类(RefCounted), 不能继承 EditorScript。
## EditorScript 只能在编辑器内实例化(运行时报 "can only be instantiated by editor",
## 且其静态方法在游戏进程也不可用), 而本工具的截图能力在游戏运行时同样需要。
## 编辑器菜单入口见 Tool/ScreenshotToolMenu.gd(仅一层壳, 无逻辑)。

## 默认最大宽度: 超过则等比缩小以控制截图体积(大视口/高分屏尤其明显)。
## 传 0 或负值表示保留原始分辨率。
const DEFAULT_MAX_WIDTH := 1280

## 默认保存目录(相对 res://, 放在 .godot 下不会被 Godot 扫描为资源, 也不进版本控制)
const DEFAULT_DIR_RES := "res://.godot/mcp_screenshots"

## 保存目录(相对 user://, 游戏进程内使用 user:// 保证导出后也可写)
const DEFAULT_DIR_USER := "user://mcp_screenshots"


## ---------------------------------------------------------------------------
## 结果结构说明(capture / save_image 返回 Dictionary):
##   ok          : bool    是否成功
##   path        : String  绝对路径(失败为空)
##   res_path    : String  Godot 路径(res:// 或 user://, 失败为空)
##   width       : int     图片宽度
##   height      : int     图片高度
##   bytes       : int     文件字节数
##   capture_type: String  捕获类型(texture / scene / image)
##   error       : String  失败原因(仅失败时存在)
## ---------------------------------------------------------------------------


## 从视口纹理抓取一帧(不保存)。已做 sRGB 校正。
## viewport: 任意 Viewport(可为 SubViewport)。
## opts(可选):
##   max_width : int  最大宽度, 超宽则等比缩小; 默认 DEFAULT_MAX_WIDTH, <=0 保留原始
##   await_draw: bool 是否等待 RenderingServer.frame_post_draw 后再取图; 默认 true
## 返回: Image(已校正) 或 null(取图失败)。
static func grab(viewport: Viewport, opts: Dictionary = {}) -> Image:
	if viewport == null:
		return null
	if bool(opts.get("await_draw", true)):
		# 等渲染线程完成本帧绘制后再读纹理。
		# 不用 RenderingServer.force_draw(): 在线程化渲染 + vsync 下会阻塞主线程,
		# 可能导致窗口"未响应"或渲染帧停止(已实测复现)。
		await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()


## 把 Image 处理成可保存的正确颜色空间。就地修改并返回同一 Image。
## 这是"颜色正确"的关键: 缺省执行 sRGB 校正。
static func normalize(image: Image, opts: Dictionary = {}) -> Image:
	if image == null or image.is_empty():
		return image
	# 统一为 8 位 RGBA8: linear_to_srgb 只在该格式下有定义的良好行为,
	# 且 PNG 输出需要 8 位通道。
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	# sRGB 校正: 把线性光值转回 sRGB 显示值(缺省开启)。
	if bool(opts.get("srgb", true)):
		image.linear_to_srgb()
	return image


## 按最大宽度等比缩放 Image(就地修改)。max_width <= 0 或未超宽时不处理。
static func fit_width(image: Image, max_width: int) -> Image:
	if image == null or max_width <= 0:
		return image
	if image.get_width() <= max_width:
		return image
	var scale := float(max_width) / float(image.get_width())
	image.resize(max_width, maxi(1, int(image.get_height() * scale)), Image.INTERPOLATE_LANCZOS)
	return image


## 完整管线: 取图 -> sRGB 校正 -> 缩放 -> 保存为 PNG -> 返回结果字典。
## 这是各调用方(编辑器脚本 / MCP 工具 / 游戏内)应使用的统一入口。
##
## viewport  : 目标视口
## opts:
##   path       : String  完整保存路径(res:// 或 user://); 缺省自动生成到 DEFAULT_DIR_RES
##   dir        : String  保存目录(res:// 或 user://); path 未给时使用
##   prefix     : String  自动文件名前缀; 默认 "screenshot"
##   max_width  : int     最大宽度; 默认 DEFAULT_MAX_WIDTH
##   srgb       : bool    是否做 sRGB 校正; 默认 true(**正确颜色**)
##   await_draw : bool    取图前是否等待 frame_post_draw; 默认 true
##   capture_type: String 记录进结果的类型; 默认 "texture"
## 返回: 结果字典(见文件头结构说明)。
static func capture(viewport: Viewport, opts: Dictionary = {}) -> Dictionary:
	var capture_type := str(opts.get("capture_type", "texture"))
	if viewport == null:
		return _fail("无法获取视口", capture_type)

	var img: Image = await grab(viewport, opts)
	if img == null or img.is_empty():
		return _fail("截图失败: 视口纹理为空", capture_type)
	return save_image(img, _with_type(opts, capture_type))


## 把已有一张 Image 保存为 PNG(用于场景缩略图等已在别处渲染好的图)。
static func save_image(image: Image, opts: Dictionary = {}) -> Dictionary:
	var capture_type := str(opts.get("capture_type", "image"))
	if image == null or image.is_empty():
		return _fail("保存失败: 图像为空", capture_type)
	image = normalize(image, opts)
	image = fit_width(image, int(opts.get("max_width", DEFAULT_MAX_WIDTH)))
	var path := _resolve_path(opts)
	if path.is_empty():
		return _fail("保存失败: 无法解析保存路径", capture_type)
	var save_err := _ensure_dir(path)
	if save_err != OK:
		return _fail("创建截图目录失败: 错误码 %d" % save_err, capture_type)
	save_err = image.save_png(path)
	if save_err != OK:
		return _fail("保存截图失败: 错误码 %d" % save_err, capture_type)
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(path)
	return {
		"ok": true,
		"path": ProjectSettings.globalize_path(path),
		"res_path": path,
		"width": image.get_width(),
		"height": image.get_height(),
		"bytes": bytes.size() if bytes else 0,
		"capture_type": capture_type,
	}


## 生成默认截图文件名(带时间戳, 已清理 Windows 非法字符)。
static func make_filename(prefix: String = "screenshot") -> String:
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "_")
	var name := "%s_%s" % [prefix, stamp]
	for ch in ["/", "\\", "*", "?", "\"", "<", ">", "|"]:
		name = name.replace(ch, "_")
	if not name.ends_with(".png"):
		name += ".png"
	return name


## 列出指定目录下的截图文件(按名称倒序, 最新在前)。
static func list_shots(dir_res: String = DEFAULT_DIR_RES) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(dir_res)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and entry.ends_with(".png"):
			out.append(dir_res.path_join(entry))
		entry = dir.get_next()
	dir.list_dir_end()
	var arr: Array = Array(out)
	arr.sort()
	arr.reverse()
	return PackedStringArray(arr)


# -------- 内部工具 --------

static func _with_type(opts: Dictionary, capture_type: String) -> Dictionary:
	var merged := opts.duplicate()
	merged["capture_type"] = capture_type
	return merged


static func _resolve_path(opts: Dictionary) -> String:
	var path := str(opts.get("path", ""))
	if not path.is_empty():
		return path
	var dir_res := str(opts.get("dir", ""))
	if dir_res.is_empty():
		# 编辑器进程用 res://.godot(mcp 约定), 游戏进程用 user://(导出后仍可写)
		dir_res = DEFAULT_DIR_USER if _in_game() else DEFAULT_DIR_RES
	var prefix := str(opts.get("prefix", "screenshot"))
	return dir_res.path_join(make_filename(prefix))


static func _ensure_dir(path: String) -> int:
	var dir := path.get_base_dir()
	if dir.is_empty():
		return OK
	if DirAccess.dir_exists_absolute(dir):
		return OK
	if dir.begins_with("res://") or dir.begins_with("user://"):
		return DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	return DirAccess.make_dir_recursive_absolute(dir)


static func _in_game() -> bool:
	return not Engine.is_editor_hint()


static func _fail(reason: String, capture_type: String) -> Dictionary:
	return {"ok": false, "error": reason, "capture_type": capture_type}

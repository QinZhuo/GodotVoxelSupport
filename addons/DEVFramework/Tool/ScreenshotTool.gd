class_name ScreenshotTool
extends RefCounted

## 统一截图工具 — 唯一的画面捕获管线。
##
## 设计目标:
##   1. 颜色正确 —— **且是自动判定的, 无需调用方选**:
##      视口纹理读回的数据可能是**线性光值**, 也可能**已经是显示值(sRGB 编码后)**, 取决于
##      引擎给这块渲染目标分配的缓冲格式(见 is_linear_buffer())。
##      老做法是无条件 linear_to_srgb(): 对线性缓冲是对的, 但对 8 位缓冲就是**二次编码** ——
##      黑场被抬高、对比被压平, 整图发灰发白, 这正是"截图比实际画面蒙一层灰白"的来源。
##      现在默认走 color_mode=auto: 按读回数据的实际格式自己判, 出图即所见。
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

## ======= 颜色处理模式 =======
##
## 取代原先"总是做 sRGB 校正"的布尔开关。缺省 COLOR_AUTO, 由引擎给渲染目标分配的实际缓冲
## 格式决定要不要编码 —— 判据见 is_linear_buffer()。
const COLOR_AUTO := "auto"
## 强制认定读回的是线性光值, 做 linear→sRGB 编码(旧行为)。仅在极少数"格式判定与实际不符"
## 的场合手动兜底, 例如某些自定义渲染管线把线性值塞进 8 位缓冲。
const COLOR_SRGB := "srgb"
## 强制认定读回的已是显示值, 不做任何颜色转换。
const COLOR_RAW := "raw"


## ---------------------------------------------------------------------------
## 结果结构说明(capture / save_image 返回 Dictionary):
##   ok          : bool    是否成功
##   path        : String  绝对路径(失败为空)
##   res_path    : String  Godot 路径(res:// 或 user://, 失败为空)
##   width       : int     图片宽度
##   height      : int     图片高度
##   bytes       : int     文件字节数
##   capture_type: String  捕获类型(texture / scene / image)
##   color_mode  : String  本次实际采用的颜色处理(auto 判定的结果也回显成 srgb / raw)
##   error       : String  失败原因(仅失败时存在)
## ---------------------------------------------------------------------------


## 从视口纹理抓取一帧(不保存)。**返回的是原始读回数据, 未做任何颜色转换** ——
## 颜色处理统一推迟到 normalize()/save_image()(那里按数据格式自动判定, 见 is_linear_buffer)。
## viewport: 任意 Viewport(可为 SubViewport)。
## opts(可选):
##   await_draw: bool 是否等待 RenderingServer.frame_post_draw 后再取图; 默认 true
## 返回: Image(原始数据) 或 null(取图失败)。
static func grab(viewport: Viewport, opts: Dictionary = {}) -> Image:
	if viewport == null:
		return null
	if bool(opts.get("await_draw", true)):
		# 等渲染线程完成本帧绘制后再读纹理。
		# 不用 RenderingServer.force_draw(): 在线程化渲染 + vsync 下会阻塞主线程,
		# 可能导致窗口"未响应"或渲染帧停止(已实测复现)。
		await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()


## 视口纹理读回的数据是否处于**线性光**空间(即还需要补一次 sRGB 编码才是屏幕上的值)。
##
## 判据用 Image 的**数据格式**而不是猜项目设置 —— 格式就是引擎对这块缓冲的最终裁决,
## 项目里那些影响它的开关(rendering/renderer/rendering_method、rendering/viewport/hdr_2d、
## 视口是否走 3D)最后都汇总成"这块缓冲用什么格式分配"这一个事实:
##   · 浮点格式(RGBAF/RGBAH/RGBF/RGBH/RGF/RF/RGBE9995)= HDR 线性缓冲, 存的是线性光值
##     ⇒ 必须编码, 否则出图偏暗。
##   · 8 位格式(RGB8/RGBA8/…)= 引擎已把显示值写进目标 ⇒ **再编码一次就是二次编码**,
##     黑场被抬高、对比被压平, 表现为整图发灰发白("蒙一层灰白")。
##
## 实测(本项目, Godot 4.7.2 / forward_plus / hdr_2d=false): 往 SubViewport 放一块
## Color(0.5,0.5,0.5) 的 ColorRect, 读回 FORMAT_RGB8、像素 r≈0.502(128/255), 正是屏幕上
## 看到的值; 3D 探针(unshaded、albedo 0.5)同样是 0.498(127/255)。即**默认配置下读回来的
## 就是显示值**, 老管线无条件 linear_to_srgb() 会把它推到 0.735(187/255) —— 那层灰白。
## 开 hdr_2d 后 2D 目标转 RGBA16F, 格式判定随之翻到"线性", 无需改代码。
static func is_linear_buffer(image: Image) -> bool:
	if image == null:
		return false
	match image.get_format():
		Image.FORMAT_RF, Image.FORMAT_RGF, Image.FORMAT_RGBF, Image.FORMAT_RGBAF:
			return true
		Image.FORMAT_RH, Image.FORMAT_RGH, Image.FORMAT_RGBH, Image.FORMAT_RGBAH:
			return true
		Image.FORMAT_RGBE9995:
			return true
		_:
			return false


## 解析本次出图**最终生效**的颜色处理模式(返回 COLOR_SRGB / COLOR_RAW; auto 会在此收敛)。
## 这样结果里回显的永远是"实际做了什么", 出图偏色时一眼能分清是引擎判定还是调用方强指定。
##
## 优先级: color_mode(新) > srgb(旧布尔, **仅在显式传入时**生效) > auto。
## ⚠️ 调用方**不要**给 srgb 补默认值 true: 那样等于替引擎做了判定, 又把二次编码请回来。
## 缺省就是 auto, 不传才是对的。
static func resolve_color_mode(image: Image, opts: Dictionary = {}) -> String:
	if opts.has("color_mode"):
		var m := str(opts.get("color_mode", COLOR_AUTO)).strip_edges().to_lower()
		if m == COLOR_SRGB:
			return COLOR_SRGB
		if m == COLOR_RAW:
			return COLOR_RAW
		# 未知取值不静默回落成某个具体模式: 那会把调用方的笔误伪装成引擎判定, 出图偏色时
		# 无从分辨。落下去走 auto —— 至少颜色是按数据判的, 不会错。
	if opts.has("srgb"):
		return COLOR_SRGB if bool(opts.get("srgb", false)) else COLOR_RAW
	# auto 在此收敛成具体模式: 8 位缓冲里已经是显示值, 再编码就是二次编码(灰白蒙层的来源)。
	return COLOR_SRGB if is_linear_buffer(image) else COLOR_RAW


## 把 Image 处理成可保存的正确颜色空间。就地修改并返回同一 Image。
## 关键: 缺省 auto —— 按读回数据的格式自己判(见 is_linear_buffer), 出图即所见。
## opts:
##   color_mode: String 见 COLOR_*; 缺省 COLOR_AUTO
##   srgb      : bool   [旧参数] 等价 color_mode=srgb/raw, 仅在显式传入时生效
##   dither    : bool   量化到 8 位时是否做误差扩散抖动(防渐变条带 banding); 缺省 false。
##           ⚠️ 抖动补偿的必须是**最终 8 位量化**的误差 —— 因此本函数会先在线性值上做
##           sRGB 编码(**保持浮点、不量化**), 再量化到 8 位并扩散误差。
##           若顺序反过来(先量化再抖), 量化对已是 8 位的图像就是恒等操作, 抖动白做。
static func normalize(image: Image, opts: Dictionary = {}) -> Image:
	if image == null or image.is_empty():
		return image
	var srgb := resolve_color_mode(image, opts) == COLOR_SRGB
	if bool(opts.get("dither", false)):
		_dither_to_rgba8(image, srgb)
		return image
	# 统一为 8 位 RGBA8: linear_to_srgb 只在该格式下有定义的良好行为,
	# 且 PNG 输出需要 8 位通道。
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	# sRGB 校正: 把线性光值转回 sRGB 显示值(缺省开启)。
	if srgb:
		image.linear_to_srgb()
	return image


## 按最大宽度等比缩放 Image(就地修改)。max_width <= 0 或未超宽时不处理。
## 语义是**上限**(只缩不放、保持长宽比); 要"定死尺寸"用 resize_exact() / opts 的 exact_size。
static func fit_width(image: Image, max_width: int) -> Image:
	if image == null or max_width <= 0:
		return image
	if image.get_width() <= max_width:
		return image
	var scale := float(max_width) / float(image.get_width())
	image.resize(max_width, maxi(1, int(image.get_height() * scale)), Image.INTERPOLATE_LANCZOS)
	return image


## 缩放到**精确**尺寸(就地修改), 可放大、**不保持长宽比**(要保比例就先自己按比例算好 target)。
## target 任一分量 <= 0、或已是该尺寸时不处理。
## 与 fit_width 互为对照: 前者"装进包围盒", 本函数"定死输出" —— 对应 opts 的 exact_size。
static func resize_exact(image: Image, target: Vector2i) -> Image:
	if image == null or image.is_empty() or target.x <= 0 or target.y <= 0:
		return image
	if image.get_width() == target.x and image.get_height() == target.y:
		return image
	image.resize(target.x, target.y, Image.INTERPOLATE_LANCZOS)
	return image


## 完整管线: 取图 -> 缩放(exact_size / max_width) -> 颜色处理(默认 auto 判定, 含可选抖动)
## -> 保存为 PNG -> 返回结果字典。
## 这是各调用方(编辑器脚本 / MCP 工具 / 游戏内)应使用的统一入口。
##
## viewport  : 目标视口
## opts:
##   path       : String  完整保存路径(res:// 或 user://); 缺省自动生成到 DEFAULT_DIR_RES
##   dir        : String  保存目录(res:// 或 user://); path 未给时使用
##   prefix     : String  自动文件名前缀; 默认 "screenshot"
##   max_width  : int     最大宽度的**上限**(只缩不放, 超出才等比缩小); 默认 DEFAULT_MAX_WIDTH
##   exact_size : Vector2i **强制精确**输出尺寸(可放大, 不保比例); 给了它则忽略 max_width
##   color_mode : String  颜色处理模式, 见 COLOR_*; 默认 COLOR_AUTO(**出图即所见**)
##   srgb       : bool    [旧参数] 等价 color_mode=srgb/raw, 仅在显式传入时生效
##   dither     : bool    量化到 8 位时是否做误差扩散抖动(防 banding); 默认 false
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
## 可用 opts 与 capture() 相同(exact_size / max_width / color_mode / srgb / dither / path /
## dir / prefix), 只有 capture_type 缺省不同(此处默认 "image")。
static func save_image(image: Image, opts: Dictionary = {}) -> Dictionary:
	var capture_type := str(opts.get("capture_type", "image"))
	if image == null or image.is_empty():
		return _fail("保存失败: 图像为空", capture_type)
	# 模式必须在 normalize 之前解析: 那之后格式已被统一成 RGBA8, 再判就永远是"非浮点"了。
	# 结果里回显它, 出图偏色时一眼能看出是引擎判定(auto)还是调用方强指定的。
	var color_mode := resolve_color_mode(image, opts)
	# 几何(缩放)排在颜色归一化之前 —— 缩放作用在原始读回数据上: 线性缓冲按线性值平均(物理正确),
	# 且 normalize 里的抖动噪声不会被随后的重采样抹平(banding 是最终尺寸上的台阶, 顺序反了白做)。
	image = _apply_geometry(image, opts)
	image = normalize(image, opts)
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
		"color_mode": color_mode,
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


# -------- 抖动量化(防 banding) --------

## sRGB 编码查找表的步数。逐像素 pow() 在高分辨率出图时开销惊人(500 万像素 ≈ 1500 万次 pow),
## 改用 LUT + 线性插值代替 —— 1025 次 pow 建表, 之后每像素只是两次查表 + 一次插值。
## 1024 级在 [0,1] 上的插值误差远小于 1/255, 对 8 位输出无影响。
const SRGB_LUT_STEPS := 1024

## sRGB 编码 LUT(线性光值 → sRGB 显示值)。延迟构建, 只建一次。
static var _srgb_lut: PackedFloat32Array


## 线性光值 → sRGB 显示值(与 Godot 内部 Math::linear_to_srgb 同款公式)。保持浮点, 不量化。
static func srgb_encode(c: float) -> float:
	if c <= 0.0031308:
		return c * 12.92
	return 1.055 * pow(c, 1.0 / 2.4) - 0.055


## 带 Floyd–Steinberg 误差扩散地把图像量化到 8 位 RGBA8, 消除大面积渐变上的色阶断层(banding)。
##
## 顺序: 先在线性值上做 sRGB 编码(**浮点, 不量化**) → 再量化到 8 位并把量化误差扩散给邻居。
## banding 是"最终 8 位 sRGB 值"的台阶造成的, 所以抖动必须补偿这一步 —— 顺序反了就白做。
##
## 实现: 先把图像转 32 位浮点, 再用底层 PackedFloat32Array 直接读写, 避免逐像素
## get_pixel/set_pixel(Color 构造 + 边界检查)的开销; sRGB 编码走 LUT。
static func _dither_to_rgba8(image: Image, srgb: bool) -> void:
	var w := image.get_width()
	var h := image.get_height()
	if w <= 0 or h <= 0:
		return
	var steps := float(SRGB_LUT_STEPS)
	if srgb and _srgb_lut.size() != SRGB_LUT_STEPS + 1:
		var lut := PackedFloat32Array()
		lut.resize(SRGB_LUT_STEPS + 1)
		for i in SRGB_LUT_STEPS + 1:
			lut[i] = srgb_encode(float(i) / steps)
		_srgb_lut = lut
	if image.get_format() != Image.FORMAT_RGBAF:
		image.convert(Image.FORMAT_RGBAF)
	var buf := image.get_data().to_float32_array()
	var bytes := PackedByteArray()
	bytes.resize(w * h * 4)
	var inv := 1.0 / 255.0
	var src := 0
	var dst := 0
	for y in h:
		for x in w:
			var r := clampf(buf[src], 0.0, 1.0)
			var g := clampf(buf[src + 1], 0.0, 1.0)
			var b := clampf(buf[src + 2], 0.0, 1.0)
			if srgb:
				r = _lut_srgb(r, steps)
				g = _lut_srgb(g, steps)
				b = _lut_srgb(b, steps)
			var qr := roundf(r * 255.0)
			var qg := roundf(g * 255.0)
			var qb := roundf(b * 255.0)
			bytes[dst] = clampi(int(qr), 0, 255)
			bytes[dst + 1] = clampi(int(qg), 0, 255)
			bytes[dst + 2] = clampi(int(qb), 0, 255)
			bytes[dst + 3] = clampi(int(roundf(clampf(buf[src + 3], 0.0, 1.0) * 255.0)), 0, 255)
			## Floyd–Steinberg: 量化误差按 7/16、3/16、5/16、1/16 扩散给 右 / 左下 / 下 / 右下。
			## 注: PackedFloat32Array 是值类型(传参会拷贝), 所以这里必须内联而不能抽成小函数。
			var er := r - qr * inv
			var eg := g - qg * inv
			var eb := b - qb * inv
			if x + 1 < w:
				buf[src + 4] += er * 0.4375
				buf[src + 5] += eg * 0.4375
				buf[src + 6] += eb * 0.4375
			if y + 1 < h:
				if x > 0:
					var i_bl := src + (w - 1) * 4
					buf[i_bl] += er * 0.1875
					buf[i_bl + 1] += eg * 0.1875
					buf[i_bl + 2] += eb * 0.1875
				var i_b := src + w * 4
				buf[i_b] += er * 0.3125
				buf[i_b + 1] += eg * 0.3125
				buf[i_b + 2] += eb * 0.3125
				if x + 1 < w:
					var i_br := src + (w + 1) * 4
					buf[i_br] += er * 0.0625
					buf[i_br + 1] += eg * 0.0625
					buf[i_br + 2] += eb * 0.0625
			src += 4
			dst += 4
	image.copy_from(Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, bytes))


## 用 LUT + 线性插值做 sRGB 编码(见 SRGB_LUT_STEPS)。直接读静态表, 不传参以免拷贝。
static func _lut_srgb(c: float, steps: float) -> float:
	if c <= 0.0:
		return 0.0
	if c >= 1.0:
		return 1.0
	var t := c * steps
	var i := int(t)
	return lerpf(_srgb_lut[i], _srgb_lut[i + 1], t - float(i))


# -------- 内部工具 --------

static func _with_type(opts: Dictionary, capture_type: String) -> Dictionary:
	var merged := opts.duplicate()
	merged["capture_type"] = capture_type
	return merged


## 输出几何: 有合法的 exact_size 就强制精确缩放, 否则退到 max_width 上限(就地修改并返回)。
## 两者互斥(exact_size 优先), 不设"同时生效"的组合 —— 那只会让调用方搞不清最终按哪个算。
static func _apply_geometry(image: Image, opts: Dictionary) -> Image:
	var exact := _read_exact_size(opts)
	if exact.x > 0 and exact.y > 0:
		return resize_exact(image, exact)
	return fit_width(image, int(opts.get("max_width", DEFAULT_MAX_WIDTH)))


## 读 opts 的 exact_size: 接受 Vector2i / Vector2 / [w, h](MCP 侧 JSON 传参只能是后两者)。
## 缺省、类型不符或含非正分量一律返回 ZERO(= 未指定), 避免拿 0 尺寸去 resize。
static func _read_exact_size(opts: Dictionary) -> Vector2i:
	var raw: Variant = opts.get("exact_size")
	if raw is Vector2i:
		return raw
	if raw is Vector2:
		return Vector2i(raw)
	if raw is Array:
		var arr := raw as Array
		if arr.size() >= 2:
			return Vector2i(int(arr[0]), int(arr[1]))
	return Vector2i.ZERO


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

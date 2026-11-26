class_name ScreenshotTool
## Reset: 进程级（sRGB LUT）
extends RefCounted

## 统一截图工具 — 唯一的画面捕获管线。

## 默认最大宽度: 超过则等比缩小以控制截图体积(大视口/高分屏尤其明显)。
const DEFAULT_MAX_WIDTH := 1280

## 默认保存目录(相对 res://, 放在 .godot 下不会被 Godot 扫描为资源, 也不进版本控制)
const DEFAULT_DIR_RES := "res://.godot/mcp_screenshots"

## 保存目录(相对 user://, 游戏进程内使用 user:// 保证导出后也可写)
const DEFAULT_DIR_USER := "user://mcp_screenshots"

## ======= 颜色处理模式 =======
const COLOR_AUTO := "auto"
## 强制认定读回的是线性光值, 做 linear→sRGB 编码(旧行为)。
const COLOR_SRGB := "srgb"
## 强制认定读回的已是显示值, 不做任何颜色转换。
const COLOR_RAW := "raw"

## ----------------------------------------------------------------------…

## 从视口纹理抓取一帧(不保存)。
static func grab(viewport: Viewport, opts: Dictionary = {}) -> Image:
	if viewport == null:
		return null
	if bool(opts.get("await_draw", true)):
		# 等渲染线程完成本帧绘制后再读纹理。
		await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()

## 视口纹理读回的数据是否处于**线性光**空间(即还需要补一次 sRGB 编码才是屏幕上的值)。
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
static func resolve_color_mode(image: Image, opts: Dictionary = {}) -> String:
	if opts.has("color_mode"):
		var m := str(opts.get("color_mode", COLOR_AUTO)).strip_edges().to_lower()
		if m == COLOR_SRGB:
			return COLOR_SRGB
		if m == COLOR_RAW:
			return COLOR_RAW
		# 未知取值不静默回落成某个具体模式: 那会把调用方的笔误伪装成引擎判定, 出图偏色时
	if opts.has("srgb"):
		return COLOR_SRGB if bool(opts.get("srgb", false)) else COLOR_RAW
	# auto 在此收敛成具体模式: 8 位缓冲里已经是显示值, 再编码就是二次编码(灰白蒙层的来源)。
	return COLOR_SRGB if is_linear_buffer(image) else COLOR_RAW

## 把 Image 处理成可保存的正确颜色空间。
static func normalize(image: Image, opts: Dictionary = {}) -> Image:
	if image == null or image.is_empty():
		return image
	var srgb := resolve_color_mode(image, opts) == COLOR_SRGB
	if bool(opts.get("dither", false)):
		_dither_to_rgba8(image, srgb)
		return image
	# 统一为 8 位 RGBA8: linear_to_srgb 只在该格式下有定义的良好行为。
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	# sRGB 校正: 把线性光值转回 sRGB 显示值(缺省开启)。
	if srgb:
		image.linear_to_srgb()
	return image

## 按最大宽度等比缩放 Image(就地修改)。
static func fit_width(image: Image, max_width: int) -> Image:
	if image == null or max_width <= 0:
		return image
	if image.get_width() <= max_width:
		return image
	var scale := float(max_width) / float(image.get_width())
	image.resize(max_width, maxi(1, int(image.get_height() * scale)), Image.INTERPOLATE_LANCZOS)
	return image

## 缩放到**精确**尺寸(就地修改), 可放大、**不保持长宽比**(要保比例就先自己按比例算好 target)。
static func resize_exact(image: Image, target: Vector2i) -> Image:
	if image == null or image.is_empty() or target.x <= 0 or target.y <= 0:
		return image
	if image.get_width() == target.x and image.get_height() == target.y:
		return image
	image.resize(target.x, target.y, Image.INTERPOLATE_LANCZOS)
	return image

## 完整管线: 取图 -> 缩放(exact_size / max_width) -> 颜色处理(默认 auto 判定, 含可选抖动)
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
	# 模式必须在 normalize 之前解析: 那之后格式已被统一成 RGBA8, 再判就永远是"非浮点"了。
	var color_mode := resolve_color_mode(image, opts)
	# 几何(缩放)排在颜色归一化之前 —— 缩放作用在原始读回数据上: 线性缓冲按线性值平均(物理正确)。
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

## sRGB 编码查找表的步数。
const SRGB_LUT_STEPS := 1024

## sRGB 编码 LUT(线性光值 → sRGB 显示值)。
static var _srgb_lut: PackedFloat32Array

## 线性光值 → sRGB 显示值(与 Godot 内部 Math::linear_to_srgb 同款公式)。
static func srgb_encode(c: float) -> float:
	if c <= 0.0031308:
		return c * 12.92
	return 1.055 * pow(c, 1.0 / 2.4) - 0.055

## 带 Floyd–Steinberg 误差扩散地把图像量化到 8 位 RGBA8, 消除大面积渐变上的色阶断层(banding)。
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

## 用 LUT + 线性插值做 sRGB 编码(见 SRGB_LUT_STEPS)。
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
static func _apply_geometry(image: Image, opts: Dictionary) -> Image:
	var exact := _read_exact_size(opts)
	if exact.x > 0 and exact.y > 0:
		return resize_exact(image, exact)
	return fit_width(image, int(opts.get("max_width", DEFAULT_MAX_WIDTH)))

## 读 opts 的 exact_size: 接受 Vector2i / Vector2 / [w, h](MCP 侧 JSON…
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

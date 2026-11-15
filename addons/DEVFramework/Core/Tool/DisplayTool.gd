class_name DisplayTool
extends RefCounted
## 显示适配工具（纯静态接口，无状态，不需要挂载/实例化）。
##   · 运行时默认策略：QualityManager 在启动与 size_changed 时调用 apply_to_window()；
##     CameraBrain3D 在相机进树时调用一次（必须在 _ready 抓取 _base_fov 之前，否则
##   · 特殊显示目标（截图 / 指定分辨率出图）：fit_to_target(window, cam, target_resolution)
##   · ⚠️ 窗口尺寸不归适配逻辑管：由设置页（ResolutionDef 档位 + 持久化）全权决定，

## 项目设计分辨率所在的设置项
const SETTING_VIEWPORT_WIDTH := "display/window/size/viewport_width"
const SETTING_VIEWPORT_HEIGHT := "display/window/size/viewport_height"
## 读不到项目设置时的回退设计分辨率
const FALLBACK_DESIGN_SIZE := Vector2i(1920, 1080)


# ── 判定 ──

## 目标比例 ≥ 当前比例 ⇒ 保持高度（目标相对更宽，横向多出内容）；否则保持宽度
static func keeps_height(from_ratio: float, to_ratio: float) -> bool:
	return to_ratio >= from_ratio


static func ratio_of(size: Vector2i) -> float:
	return float(size.x) / float(maxi(1, size.y))


## 项目设计分辨率（display/window/size/viewport_*）；读不到时回退 1920×1080
static func design_size() -> Vector2i:
	return Vector2i(
		int(ProjectSettings.get_setting(SETTING_VIEWPORT_WIDTH, FALLBACK_DESIGN_SIZE.x)),
		int(ProjectSettings.get_setting(SETTING_VIEWPORT_HEIGHT, FALLBACK_DESIGN_SIZE.y)))


static func design_ratio() -> float:
	return ratio_of(design_size())


# ── 窗口模式与尺寸 ──

## 两档：窗口化 / 全屏。全屏是铺满显示器的无边框全屏，输出分辨率由显示器决定。
enum WindowMode { WINDOWED, FULLSCREEN }
const WINDOW_MODE_KEYS: Array[String] = ["windowed", "fullscreen"]
const DEFAULT_WINDOW_MODE := WindowMode.FULLSCREEN


## 应用窗口模式：全屏与窗口化的桌面档（fill）都用无边框铺满，其余为普通窗口。
static func apply_window_mode(window: Window, mode: int, fill := false) -> void:
	var target := Window.MODE_FULLSCREEN if mode == WindowMode.FULLSCREEN or fill else Window.MODE_WINDOWED
	if window.mode == target:
		return
	window.borderless = false
	window.mode = target


static func window_mode_key(mode: int) -> String:
	return WINDOW_MODE_KEYS[clampi(mode, 0, WINDOW_MODE_KEYS.size() - 1)]


## 存档值 → 模式。只认 key 字符串，缺失/脏数据一律回落默认模式
static func window_mode_from_saved(value: Variant) -> int:
	if value is not String:
		return DEFAULT_WINDOW_MODE
	var idx := WINDOW_MODE_KEYS.find(value)
	return idx if idx >= 0 else DEFAULT_WINDOW_MODE


## 变更窗口尺寸并摆到合适位置：可用区内居中；比可用区还大时左上对齐，保证标题栏可见
static func apply_window_size(window: Window, size: Vector2i) -> void:
	window.size = size
	var usable := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())
	var pos := usable.position + (usable.size - size) / 2
	window.position = Vector2i(maxi(pos.x, usable.position.x), maxi(pos.y, usable.position.y))


# ── 应用 ──

## 运行时分辨率适配主入口：按"设计分辨率 vs 当前窗口"选出保持基准轴，
static func apply_to_window(window: Window, cam: Camera3D = null) -> bool:
	var aspect := design_ratio()
	var keep_height := keeps_height(aspect, ratio_of(window.size))
	apply_keep_axis_to_window(window, keep_height)
	if cam:
		apply_keep_axis_to_camera(cam, keep_height, aspect)
	return keep_height


## 把保持基准轴应用到 3D 相机取景。
## ⚠️ Camera3D.fov 的含义随 keep_aspect 改变：KEEP_HEIGHT 下是**竖向** fov，
static func apply_keep_axis_to_camera(cam: Camera3D, keep_height: bool, design_aspect: float) -> void:
	if cam.projection != Camera3D.PROJECTION_PERSPECTIVE:
		# 正交相机的取景基准是 size（世界单位）而非 fov，换算方式不同；
		push_warning("[DisplayTool] 暂不支持非透视相机的基准轴切换：%s" % cam.get_path())
		return
	# 先把相机当前 fov 归一到"设计竖向 fov"（KEEP_WIDTH 下存的是水平 fov，需除回设计宽高比）
	var vfov := cam.fov
	if cam.keep_aspect == Camera3D.KEEP_WIDTH:
		vfov = _hfov_to_vfov(cam.fov, design_aspect)
	if keep_height:
		cam.keep_aspect = Camera3D.KEEP_HEIGHT
		cam.fov = vfov
	else:
		cam.keep_aspect = Camera3D.KEEP_WIDTH
		cam.fov = _vfov_to_hfov(vfov, design_aspect)


## 竖向 fov → 水平 fov（同一投影在宽高比 aspect 下的水平视野）
static func _vfov_to_hfov(vfov_deg: float, aspect: float) -> float:
	return rad_to_deg(2.0 * atan(tan(deg_to_rad(vfov_deg) * 0.5) * aspect))


## 水平 fov → 竖向 fov
static func _hfov_to_vfov(hfov_deg: float, aspect: float) -> float:
	return rad_to_deg(2.0 * atan(tan(deg_to_rad(hfov_deg) * 0.5) / aspect))


## 把保持基准轴应用到 2D/UI 缩放
static func apply_keep_axis_to_window(window: Window, keep_height: bool) -> void:
	window.content_scale_aspect = (
		Window.CONTENT_SCALE_ASPECT_KEEP_HEIGHT if keep_height else Window.CONTENT_SCALE_ASPECT_KEEP_WIDTH)


## 一次性场景用（如截图出图）：按"当前窗口比例 vs 目标分辨率比例"选出保持基准轴并应用，
## 注意：比较的是**当前窗口**而不是设计分辨率——保证调用前已有的构图/取景不被裁掉。
static func fit_to_target(window: Window, cam: Camera3D, target: Vector2i) -> bool:
	var keep_height := keeps_height(ratio_of(window.size), ratio_of(target))
	if cam:
		apply_keep_axis_to_camera(cam, keep_height, design_ratio())
	apply_keep_axis_to_window(window, keep_height)
	return keep_height

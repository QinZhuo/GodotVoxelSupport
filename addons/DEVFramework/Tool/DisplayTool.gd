class_name DisplayTool
extends RefCounted
## 显示适配工具（纯静态接口，无状态，不需要挂载/实例化）。
##
## 项目策略：**内容不少于设计帧** —— 按窗口比例动态选轴，任何比例下 16:9 设计帧的内容都完整可见：
##   窗口比设计**更宽** ⇒ 保持高度(KEEP_HEIGHT)：竖向取景=设计值，横向扩出额外场景内容
##   窗口比设计**更高** ⇒ 保持宽度(KEEP_WIDTH) ：水平取景=设计值，纵向扩出额外场景内容
##   扩出方向显示的是场景画框之外的内容（暗部/环境等）——这是预期行为，不是黑边。
## 2D/UI 用同一规则：画布沿扩出方向变大（永不在设计帧内裁剪），全屏元素用锚点即可自动铺满。
##
## == 用法 ==
##   · 运行时默认策略：QualityManager 在启动与 size_changed 时调用 apply_to_window()；
##     CameraBrain3D 在相机进树时调用一次（必须在 _ready 抓取 _base_fov 之前，否则
##     错误基准会被逐帧驱动放大——历史上真实踩过）。
##   · 特殊显示目标（截图 / 指定分辨率出图）：fit_to_target(window, cam, target_resolution)
##     （基准是**当前窗口**——保证调用前已有的构图不被裁掉，参见 ScreenshotCapture）
##   · ⚠️ 窗口尺寸不归适配逻辑管：由设置页（ResolutionDef 档位 + 持久化）全权决定，
##     任何"启动时改窗口尺寸"的逻辑都会和设置页打架（历史上真实踩过）。
##   · ⚠️ fov 的坑：Camera3D.fov 含义随 keep_aspect 翻转（KEEP_HEIGHT=竖向 / KEEP_WIDTH=水平），
##     切轴必须经 apply_keep_axis_to_camera 做设计宽高比换算，否则水平视野骤缩（历史上真实踩过）。
##   · 判定与换算的静态方法（keeps_height / ratio_of / fov 换算）可独立复用

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


# ── 应用 ──

## 运行时分辨率适配主入口：按"设计分辨率 vs 当前窗口"选出保持基准轴，
## 应用到 2D/UI 缩放与 3D 相机取景，返回所选基准轴（true = 保持高度）。
## 规则与动机见文件头：任何比例下设计帧内容完整保留，扩出方向显示额外场景内容。
static func apply_to_window(window: Window, cam: Camera3D = null) -> bool:
	var aspect := design_ratio()
	var keep_height := keeps_height(aspect, ratio_of(window.size))
	apply_keep_axis_to_window(window, keep_height)
	if cam:
		apply_keep_axis_to_camera(cam, keep_height, aspect)
	return keep_height


## 把保持基准轴应用到 3D 相机取景。
## ⚠️ Camera3D.fov 的含义随 keep_aspect 改变：KEEP_HEIGHT 下是**竖向** fov，
## KEEP_WIDTH 下同一数值被解释为**水平** fov。直接切换会让水平视野骤缩
## （16:9 设计 + fov 60 ⇒ 水平 ≈91°，切成 KEEP_WIDTH 后只剩 60°，表现为"看到的内容不够"），
## 所以这里以**设计宽高比**为基准做 fov 换算，保证设计分辨率下的可见内容在任意比例下完整保留。
static func apply_keep_axis_to_camera(cam: Camera3D, keep_height: bool, design_aspect: float) -> void:
	if cam.projection != Camera3D.PROJECTION_PERSPECTIVE:
		# 正交相机的取景基准是 size（世界单位）而非 fov，换算方式不同；
		# 项目当前未使用正交相机，遇到时保持原样并提示，避免按错误语义改写
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
## 返回所选基准轴（true = 保持高度）。
## 注意：比较的是**当前窗口**而不是设计分辨率——保证调用前已有的构图/取景不被裁掉。
static func fit_to_target(window: Window, cam: Camera3D, target: Vector2i) -> bool:
	var keep_height := keeps_height(ratio_of(window.size), ratio_of(target))
	if cam:
		apply_keep_axis_to_camera(cam, keep_height, design_ratio())
	apply_keep_axis_to_window(window, keep_height)
	return keep_height

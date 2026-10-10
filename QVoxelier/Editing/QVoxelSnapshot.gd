@tool
class_name QVoxelSnapshot
extends RefCounted
## 快照（PNG 预览图）：参数组、取景盒与命名这一段**纯逻辑**。
## 【为什么单独一层】快照的实现里"离屏 SubViewport + 相机 + 灯光 + 等网格"只能在有窗口时跑
## （无头测不了），但其中三件事错了都**不报错**，只产出"看起来正常"的错东西：
##   ① 视图表 —— 键写错，七个角度里有几个渲出来是同一个角度；
##   ② 文件名 —— 两次快照写同一个路径，用户以为存了七张，其实只剩最后一张；
##   ③ 拒绝判据 —— 空世界渲出来是一张纯背景图，用户会当成"渲染坏了"，而不是"世界是空的"。
## 于是把这三件收在这里由 TestCase 逐条钉住，视口那一层只剩"摆场景、等网格、按快门、落盘"。
## 【为什么选项表从 QVoxelViewCamera 派生，而不是自己抄一份角度】快照要的"标准视图 / 镜头"
## 就是视口那两套（前 / 后 / 右 / 左 / 顶 / 底 / 等轴，透视 / 正交）。在这里再抄一份，
## 迟早与视口的同名按钮对不上 —— 同一颗"顶视图"，两处解释不同，且两处都不报错。
## 【为什么是"方形取景"】标准视图下模型在屏幕上本来就要按最长轴取景，方形不会比 16:9 少看到
## 东西，却省掉"横竖哪个是长边"这一层选择；导出素材（贴图、缩略图、商品图）也普遍要方形。


## 尺寸档（像素，边长）。**开关组而不是下拉**：与批量导出的范围、笔刷形态同一套
## （见 QVoxelUi 的密度档）—— 触摸没有下拉，选项一眼全在。
## text 用 1K / 2K 而不是 1024 / 2048：右列只有约 116 逻辑像素宽，四位数字在触摸密度下
## 会把三个按钮挤出行外；真实像素数写在 tip 与渲染后的状态行里，不会丢。
const SIZES := [
	{"value": 512, "text": "512", "tip": "渲染成 512×512（快，适合当图标 / 缩略图）"},
	{"value": 1024, "text": "1K", "tip": "渲染成 1024×1024（默认档）"},
	{"value": 2048, "text": "2K", "tip": "渲染成 2048×2048（慢，适合当贴图 / 成品图）"},
]

## 默认尺寸。1024 是"够看清、又不至于让一次渲染等太久"的折中
## （体素数量级下 2048 要几秒，用户会以为卡死了）。
const DEFAULT_SIZE := 1024


## 视图选项表：`[{value, text, tip}]`，顺序 = QVoxelViewCamera 角度表的顺序。
## 【为什么 FREE 不在表内】FREE 的语义是"不改变角度"的标签（见 QVoxelViewCamera.apply_view），
## 快照要的是一个**确定**的角度；把它列出来只会给出一张"沿用上一次角度"的图 ——
## 用户点了"自由"，拿到的却取决于之前点过什么。
static func views() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for v in QVoxelViewCamera.VIEW_ANGLES_DEG:
		var name: String = QVoxelViewCamera.VIEW_NAMES[v]
		out.append({
			"value": v,
			"text": name,
			"tip": "以「%s」视图渲染（与视口同名按钮同一个角度）" % name,
		})
	return out


## 尺寸选项表，结构同 views()。
static func sizes() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for spec in SIZES:
		out.append(spec)
	return out


## 镜头选项表，结构同 views()。
## 【为什么快照要能选镜头】正交是体素素材的常规出图方式（近大远小会让等轴视图的
## 三条轴不等长，"等轴"就名不副实）。视口里这是常用开关，快照不给的话用户只能靠透视凑。
static func lenses() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for l in QVoxelViewCamera.LENS_NAMES:
		var name: String = QVoxelViewCamera.LENS_NAMES[l]
		out.append({
			"value": l,
			"text": name,
			"tip": "%s投影（与视口的镜头开关同一套）" % name,
		})
	return out


## 取景盒：把求值结果的体素范围翻成世界坐标下的 AABB。
## 【为什么是 origin + grid_size 而不是逐块并集】origin 就是"本体积的 (0,0,0) 在父画布里
## 是哪儿"（见 QVoxelEvalResult.origin），两者相加即内容盒。它与导出用的是同一组数，
## 于是"快照框住的"与"导出写出的"必然是同一块空间 —— 快照才不会出现"模型贴着边"或
## "缩在中间一小块"。
## 【为什么乘 voxel_scale】体素坐标是格号，相机在世界单位里取景。换算只有这一处，
## 否则"快照的取景比例"与"视口的取景比例"会各算一遍、迟早不一致。
static func frame_aabb(res: QVoxelEvalResult, voxel_scale: float) -> AABB:
	if res == null or res.volume.is_empty():
		return AABB()
	return AABB(Vector3(res.origin) * voxel_scale, Vector3(res.grid_size) * voxel_scale)


## 文件名主干（不含扩展名）：`<世界名>_<视图名>`。
## 【为什么带视图名】快照的常态用法是"同一个世界出七个角度"；只带世界名会七张互相覆盖 ——
## 覆盖还不报错，用户以为存下了七张。尺寸与镜头**不进名字**：多数人只出一种档位，
## 把档位塞进名字只会让常用名字变长，而"换了档位再存"这一步有保存对话框拦着（会提示覆盖）。
static func file_stem(world_name: String, view: int) -> String:
	var view_text: String = QVoxelViewCamera.VIEW_NAMES.get(view, "")
	var stem := world_name
	if not view_text.is_empty():
		stem = "%s_%s" % [world_name, view_text]
	# 消毒规则全项目一份（见 QVoxelNaming）：两个导出出口各写一份迟早分叉。
	return QVoxelNaming.safe_stem(stem)


## 该不该渲染：返回空串 = 可以，否则返回**给用户看的原因**。
## 【为什么要有这一步】空世界的渲染会成功、也会存下一张图 —— 一张纯背景色。
## 它不报任何错，于是用户的第一反应是"渲染坏了"，而不是"我还没建东西"。
## 宁可明确回话，也不产出一张"看起来像截图、其实什么都没有"的图。
static func blocker(world: QVoxelWorld) -> String:
	if world == null:
		return "还没有世界，先新建或载入一个"
	if world.all_models().is_empty():
		return "世界里还没有模型"
	return ""


## 预览图的一句话描述（状态行用）。带上真实像素数：尺寸档显示的是 1K / 2K 这类短名，
## 用户想确认"到底渲了多大"要看这里。
static func describe(size: int, view: int, lens: int) -> String:
	return "%d×%d · %s · %s" % [
		size, size,
		QVoxelViewCamera.VIEW_NAMES.get(view, "?"),
		QVoxelViewCamera.LENS_NAMES.get(lens, "?"),
	]


## 落盘后的一句话（应用层出用户文案，与 QVoxelBake.summary 同一分工）。
static func summary(path: String, size: int) -> String:
	return "已渲染 %d×%d → %s" % [size, size, path]

@tool
class_name QVoxelBake
extends RefCounted
## 批量烘焙（`.vox`）：把世界按"一次要几个文件"切成若干份，逐份求值 → 落盘。
## 【为什么它在应用层、而不是视口里的一串 if】范围决定的是"求值几次、每次拿哪个节点"——
## 那是求值引擎的编排，不是界面的事。于是视口只把选中的范围编号递进来（`plan`），拿到一份
## "文件名 + 资产"的清单后逐个落盘。分开之后本类无节点、无场景树、不碰界面，命名去重与
## 空/超限这些边界都能在 TestCase 里逐条钉住（视口本身没有可测的纯逻辑）。
## 【为什么"每个节点 / 每个模型 / 每个帧"都要有，而不是只给个"整个世界"】
##   整个世界 —— 与画面上看到的一致，拿去就能用（也是单次导出的语义）。
##   每个节点 —— 树上每一格各一块：组导出的是它子树的合成结果。要"每一部分单独一个文件"时用。
##   每个模型 —— 只取叶子，比"每个节点"少一层"组与它的孩子内容重复"，做素材库时更干净。
##   每个帧   —— 动画每一帧各一块。`.vox` 本身没有帧的概念，故一帧只能是一个文件。
## 【与单次导出的关系】单次导出 = `plan` 只产出一份。两者共用 `VoxAsset.from_result`，
## 于是"一块体积怎么变成 `.vox`"（含 Z 平移那套约定）全项目仍只有一份实现。


## 烘焙范围 —— "一次产出几个文件"。
enum Scope {
	WORLD,  ## 整个世界合成一块（与画面上看到的一致）
	NODE,   ## 树上每个节点各一块（组 = 它子树的合成结果）
	MODEL,  ## 每个模型各一块（只取叶子，组不产出）
	FRAME,  ## 每个动画帧各一块（世界在该帧的样子）
}

## 范围表：`text` 供界面显示，`tip` 供悬停解释。
## **表即配置**：界面按钮与 `plan` 的分派都从这一张表派生（数组下标 == `Scope` 的值）。
const SCOPES := [
	{"text": "整个世界", "tip": "整棵树合成一块，与画面上看到的一致"},
	{"text": "每个节点", "tip": "树上每一格各一块；组导出的是它子树的合成结果"},
	{"text": "每个模型", "tip": "每个模型各一块，只取叶子（组不产出）"},
	{"text": "每个帧", "tip": "动画每一帧各一块；.vox 没有帧概念，故一帧一个文件"},
]

## 帧号后缀。**定宽零填充**：否则按名字排序时 `_f10` 会排在 `_f9` 前面，顺序是乱的。
const FRAME_SUFFIX := "_f%03d"


## 一份待落盘的产物：文件名（**不含目录与扩展名**）+ 已烘好的资产。
class Batch:
	var name: String
	var asset: VoxAsset

	func _to_string() -> String:
		return str(name, " ", asset.box() if asset != null else "?")


# 对外

## 按范围切分世界，返回全部产物。**只求值、不落盘** —— 于是"切得对不对"与"写不写得出去"
## 是两件事，前者可以纯逻辑地测。
## prefix 接在每份文件名之前（用户按批次区分用途，如 `rock_`）。
static func plan(world: QVoxelWorld, scope: Scope, prefix := "") -> Array[Batch]:
	var out: Array[Batch] = []
	if world == null:
		return out
	# 重名表随本批走：一堆"未命名模型"或两个同名节点若直接落盘会互相覆盖，
	# 用户拿到 N-1 个文件还找不出少了谁。
	var taken := {}
	match scope:
		Scope.NODE:
			for node in world.all_nodes():
				_add(out, taken, prefix, node.display_name(), VoxAsset.from_node(world, node))
		Scope.MODEL:
			for m in world.all_models():
				_add(out, taken, prefix, m.display_name(), VoxAsset.from_node(world, m))
		Scope.FRAME:
			_plan_frames(world, prefix, out, taken)
		_:
			_add(out, taken, prefix, world.world_name(), VoxAsset.from_world(world))
	return out


## 逐个落盘到 dir。返回 `{"written": int, "skipped": {文件名: 原因}}`。
## 【为什么"跳过"走返回值而不是 push_error】空节点与超限**不是错误**，是"这一份没有可写的内容"
## —— 它们正是用户会问"我选了 8 个节点，怎么只出来 5 个文件"的东西，必须回话。写入失败
## （磁盘满 / 无权限）是环境问题，但一并放进同一张表：调用方只处理一种结构，也就不会漏掉一种。
static func write(dir_path: String, batches: Array) -> Dictionary:
	var written := 0
	var skipped := {}
	for b in batches:
		var batch: Batch = b
		# 【判据为什么是"一个模型都没有"、而不是"体素数为 0"】求值引擎用**空数组**表示"还没有
		# 既有体积"（见 QVoxelModel.to_volume 的说明），所以"这一份什么都没有"落地时连模型都没有
		# —— 写出去就是个只有调色板的残缺 `.vox`。而"模型在、里面是空的"是**合法**的一份
		# （动画的过渡帧就长这样），它有尺寸、能被打开，只是这一帧没有体素，不该被丢掉。
		if batch.asset == null or batch.asset.models.is_empty():
			skipped[batch.name] = "没有可写的体积"
			continue
		# 【为什么先查尺寸、再落盘】MagicaVoxel 的模型上限是 256³（`VoxAccess.MODEL_LIMIT`），
		# 超了它**不报错、直接截断**；而 XYZI 的坐标是单字节，写口会把 256 以外的体素丢掉。
		# 那对用户就是"导出成功了，可我的模型少了一层壳"。宁可明确跳过，也不产出悄悄少一块的文件。
		if not batch.asset.fits_magica():
			var box := batch.asset.box()
			skipped[batch.name] = "盒 %d×%d×%d 超过 %d 上限" % [box.x, box.y, box.z,
					VoxAccess.MODEL_LIMIT]
			continue
		var path := dir_path.path_join("%s.%s" % [batch.name, VoxAsset.VOX_EXTENSION])
		var err := VoxAccess.Save(path, batch.asset)
		if err != OK:
			skipped[batch.name] = "写入失败（错误码 %d）" % err
			continue
		written += 1
	return {"written": written, "skipped": skipped}


## 把 `write` 的结果说成一句人话（应用层出用户文案，与 QVoxelierSession 的 hint 同一分工）。
## 跳过的名字只列前几个 —— 一次几百个文件时，提示条该是"报数"而不是"清单"。
static func summary(report: Dictionary, dir_path: String) -> String:
	var skipped: Dictionary = report.get("skipped", {})
	var text := "已导出 %d 个 .vox → %s" % [int(report.get("written", 0)), dir_path]
	if skipped.is_empty():
		return text
	var detail := PackedStringArray()
	for name in skipped:
		if detail.size() >= 3:
			detail.append("…")
			break
		detail.append("%s（%s）" % [name, skipped[name]])
	return "%s；跳过 %d 个：%s" % [text, skipped.size(), "、".join(detail)]


# 内部

## 每个帧各一块。**帧号是全局的**（取所有动画模型里最长的那个）：各模型的帧数可以不同，
## 短的那些由 `source_blocks()` 自行钳到自己的末帧 —— 于是"第 7 帧"对所有模型都是"第 7 帧"，
## 不存在第二种解释。
## 没有动画时**退化成一整块**（名字也不带 `_f000`）：用户点了"每个帧"却发现只有一个文件，
## 总好过拿到一个叫 `名字_f000` 的孤零零的文件还得猜为什么只有一帧。
static func _plan_frames(world: QVoxelWorld, prefix: String, out: Array[Batch],
		taken: Dictionary) -> void:
	var models := world.all_models()
	var count := 0
	for m in models:
		count = maxi(count, m.frame_count())
	if count <= 1:
		_add(out, taken, prefix, world.world_name(), VoxAsset.from_world(world))
		return
	var restore := {}
	for m in models:
		restore[m] = m.active_frame
	for f in count:
		for m in restore:
			m.active_frame = f
		_add(out, taken, prefix, world.world_name() + FRAME_SUFFIX % f, VoxAsset.from_world(world))
	# 游标是"正在看第几帧"的瞬态状态（见 QVoxelModel.active_frame）：烘完必须放回去，
	# 否则用户会发现"导出之后画面停在最后一帧"。
	for m in restore:
		m.active_frame = restore[m]


## 加一份产物：文件名先消毒（规则见 QVoxelNaming），再在**本批内**去重。
static func _add(out: Array[Batch], taken: Dictionary, prefix: String, base: String,
		asset: VoxAsset) -> void:
	var stem := QVoxelNaming.safe_stem(prefix + base)
	var name := stem
	var n := 2
	while taken.has(name):
		name = "%s_%d" % [stem, n]
		n += 1
	taken[name] = true
	var batch := Batch.new()
	batch.name = name
	batch.asset = asset
	out.append(batch)

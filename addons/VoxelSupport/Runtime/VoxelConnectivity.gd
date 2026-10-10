class_name VoxelConnectivity
extends RefCounted

## 6 方向连通性内核：泛洪、连通分组、支撑（悬空）判定。
## 【为什么单独成类】这些算法原先长在 `QVoxelSource`（2200+ 行的 God 类）里，但它们与
## "体素怎么存"无关 —— 只依赖"某位置是不是实体素"这一个判据。抽成纯函数库后，
## 存储/序列化不再被连通性代码挤占，连通性也能脱离 `QVoxelSource` 单测（传个 lambda 当判据即可）。
## 【依赖方向】本类**不引用** `QVoxelSource`（无反向依赖），判据由调用方以参数传入：
##   `is_solid: Callable(pos: Vector3i) -> bool`  实体素判据
##   `all_positions: Callable() -> Array`         全量位置枚举（只在确实需要全量时才会被调用）
## 热路径（`partition_connected` / `find_unsupported_around`）完全在原生 C++，不经 Callable、
## 无额外开销；Callable 只出现在"少用"的 GDScript 子集路径与辅助查询上。
## 【为什么判据是 Callable 而不是直接传 QVoxelSource】`QVoxelSource.has_voxel` 会访问**仅存在于磁盘**
## 的 chunk（必要时流式载入）。抽成判据后，本类既不需要知道存储布局，也不会有人误用
## "只读内存缓冲"当判据——那会把磁盘上的体素误判成空（见 find_unsupported 的注释）。

## 6 方向邻居偏移（上下左右前后），连通性 BFS/泛洪共用
const NEIGHBORS_6: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
]


## 从种子体素位置集合出发，6 方向泛洪标记所有连通的体素，返回位置集合 (Dictionary 作 Set)
## seeds 可为单个 Vector3i 或 Array[Vector3i]；返回 {pos: true} 可直接用 has() 判断
## 若 restrict 提供，则只允许在 restrict 集合内扩散（用于只分析某子集内部的连通性）
## 否则以"实体素"（is_solid 判据）为扩散边界
## 【两条分支的实现位置不同，这是有意的】
##   restrict 非空 → 不查世界体素、只认传入集合 → 完全下沉原生
##     （NativeLoader.flood_fill_positions）：BFS 的"每节点一次 `in result` 字典查找"开销归零，
##     破坏一堵墙这类大集合泛洪不再卡帧。
##   restrict 为空 → 判据 is_solid 是 Callable，会回调宿主（`QVoxelSource.has_voxel` 可能触发
##     磁盘 chunk 流式载入）→ 无法脱离宿主语言，只能留在 GDScript。
##   两分支对"restrict 恰好等于实体素全集"的输入结果相同（见 test_voxel_fix_regressions 的交叉断言）。
static func flood_fill(seeds, is_solid: Callable, restrict: Dictionary = {}) -> Dictionary:
	if seeds == null:
		return {}
	# 归一化种子为数组
	var seed_list: Array = []
	if seeds is Vector3i:
		seed_list.append(seeds)
	elif seeds is Array:
		seed_list = seeds
	if not restrict.is_empty():
		return NativeLoader.flood_fill_positions(seed_list, restrict)
	var result := {}
	for s in seed_list:
		var pos: Vector3i = s
		if pos in result:
			continue
		if not is_solid.call(pos):
			continue
		result[pos] = true
		var stack: Array = [pos]
		while not stack.is_empty():
			var cur: Vector3i = stack.pop_back()
			for d: Vector3i in NEIGHBORS_6:
				var nb := cur + d
				if nb in result:
					continue
				if not is_solid.call(nb):
					continue
				result[nb] = true
				stack.append(nb)
	return result


## 找出某个体素所在的整个连通块（6 方向连通），返回该连通块的位置集合
## 用于悬空判断、反应波及范围等
static func find_connected(pos: Vector3i, is_solid: Callable) -> Dictionary:
	if not is_solid.call(pos):
		return {}
	return flood_fill(pos, is_solid)


## 某个体素的连接度：相邻的实体素数 (0-6)
## 可用于薄弱点判断、支撑接触面积估算等
static func connectivity(pos: Vector3i, is_solid: Callable) -> int:
	var count := 0
	for d: Vector3i in NEIGHBORS_6:
		if is_solid.call(pos + d):
			count += 1
	return count


## 返回某体素的所有相邻实体素位置数组 (6 方向)
static func neighbors(pos: Vector3i, is_solid: Callable) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	for d: Vector3i in NEIGHBORS_6:
		var nb := pos + d
		if is_solid.call(nb):
			result.append(nb)
	return result


## 将一组位置按 6 方向连通性分组，返回 Array[Array[Vector3i]]
## 每组的体素两两 6 方向连通，组与组之间不连通。用于分块塌落、分块破坏等。
## 实现完全在原生 C++（partition_connected）：大崩塌掉落体分组主线程提速。
static func partition_connected(positions: Array) -> Array:
	if positions.is_empty():
		return []
	return NativeLoader.partition_connected(positions)


## 找出"悬空"体素：与贴地(y==0)体素 6 方向连通判定，完全断开的返回
## 这是崩塌检测的底座：全量判定哪些与地面断开
## voxels_set 提供时只在该集合内判定（子集场景）；否则基于全部实体素
## 【全量路径已下沉原生】旧实现要跑**两趟** all_positions()（每趟都含一次 stream 合并，
## 并把百万级位置装箱成 Array）再在其上做 GDScript 字典 flood fill —— 大世界是秒级
## 主线程阻塞。现在只枚举一趟，flood fill 交给原生（见 NativeLoader.find_unsupported_positions）。
## 【必须传"位置集合"而非 chunk 缓冲】判据经 is_solid 会访问**仅存在于磁盘**的 chunk，
## 只读内存缓冲会把那些体素误判成悬空。
static func find_unsupported(voxels_set: Dictionary, all_positions: Callable, is_solid: Callable) -> Dictionary:
	if voxels_set.is_empty():
		var all_unsupported := {}
		for pos in NativeLoader.find_unsupported_positions(all_positions.call()):
			all_unsupported[pos] = true
		return all_unsupported
	# 子集路径（少用）：保持 GDScript 原样，避免引入"原生只认传入集合"的语义分歧
	var seeds: Array = []
	for key in voxels_set:
		var pos: Vector3i = key
		if pos.y == 0:
			seeds.append(key)
	var supported := flood_fill(seeds, is_solid, voxels_set)
	var unsupported := {}
	for key in voxels_set:
		if not supported.has(key):
			unsupported[key] = true
	return unsupported


## 找出"悬空"体素（连通性检测，原生 C++ 实现）：只检查 removed 附近可能失稳的体素
## 算法（业界标准做法，与 Minecraft 沙砾 / Teardown 类破坏游戏一致）：
##   体素稳定 ⟺ 与地面（y<=0）6 方向连通。
##   破坏移除 R 后，从 R 的 6 方向邻居 + 正上方列扫描收集候选；
##   对每个候选做局部 6 方向 BFS：若所在连通分量含地面 → 稳定；否则该分量整体悬空。
## 效果真实（区别于"只正下方"的一刀切）：
##   - 台阶/斜坡：斜向通过水平+垂直连到地面 → 稳定不掉
##   - 悬空平台（多柱支撑）：平台通过柱子连通地面 → 稳定
##   - 外墙底部被破坏但侧连完好墙（连地面）→ 稳定；完全断连 → 掉落
## 性能（局部 + 早停）：
##   - 只从破坏点附近候选出发，不遍历整世界
##   - 共享 visited 去重；BFS 遇到地面提前终止（稳定分量不用遍历完）
##   - 悬空分量必须完整遍历（需要移除），规模受破坏影响区域限制
## 实现完全在 GDExtension (C++) 中，无 GDScript 兜底。
## 返回失稳体素位置集合 {pos: true}（原生列支撑，横向传播无上限 = 基线行为）。
static func find_unsupported_around(buffers: Dictionary, removed: Array) -> Dictionary:
	if removed.is_empty() or buffers.is_empty():
		return {}
	return NativeLoader.find_unsupported_around(buffers, removed)

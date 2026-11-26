class_name VoxelConnectivity
extends RefCounted

## 6 方向连通性内核：泛洪、连通分组、支撑（悬空）判定。

## 6 方向邻居偏移（上下左右前后），连通性 BFS/泛洪共用
const NEIGHBORS_6: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
]

## 从种子体素位置集合出发，6 方向泛洪标记所有连通的体素，返回位置集合 (Dictionary 作 Set)
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

## 将一组位置按 6 方向连通性分组，返回 Array[Array[Vector3i]]
static func partition_connected(positions: Array) -> Array:
	if positions.is_empty():
		return []
	return NativeLoader.partition_connected(positions)

## 找出"悬空"体素：与贴地(y==0)体素 6 方向连通判定，完全断开的返回
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
static func find_unsupported_around(buffers: Dictionary, removed: Array) -> Dictionary:
	if removed.is_empty() or buffers.is_empty():
		return {}
	return NativeLoader.find_unsupported_around(buffers, removed)

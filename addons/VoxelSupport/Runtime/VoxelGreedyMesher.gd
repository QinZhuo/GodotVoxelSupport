class_name VoxelGreedyMesher
extends RefCounted

## 贪婪网格合并器
##
## 提供统一的贪婪网格算法，供 VoxelMeshGenerator（编辑器导入）和
## VoxelChunkGenerator（运行时）共享调用。
##
## 核心算法：对一个 2D 网格中的同材质单元格进行矩形合并，降低三角形数量。
## 只保留一条性能关键路径（greedy_merge_dense）：直接扫描密集数组。
##
## 密集扫描为经典"快速贪婪"：种子格向右扩展宽度、再逐行验证扩展高度，
## 合并后的格子清零标记已处理，保证每个格子至多被处理常数次 → 近似 O(n)，
## 取代旧实现的 O(n·w·h) 逐格字典哈希查找。

## 矩形合并结果
class RectInfo:
	var position: Vector2i
	var size: Vector2i
	var value: int

	func _init(p: Vector2i, s: Vector2i, v: int):
		position = p
		size = s
		value = v


## 对密集 2D 网格执行贪婪合并（性能关键路径）
## grid: PackedInt32Array，行优先。统一材质契约：0 = 空，否则 = 材质ID（id 0 保留为空）
## width/height: 网格宽高
## 返回: Array[RectInfo]，rect.value 为材质ID（与 grid 存储值一致）
static func greedy_merge_dense(grid: PackedInt32Array, width: int, height: int) -> Array[RectInfo]:
	var g := grid.duplicate()
	var result: Array[RectInfo] = []
	for v in height:
		var u := 0
		while u < width:
			var c := g[u + v * width]
			if c <= 0:
				u += 1
				continue
			# 向右扩展宽度
			var w := 1
			while u + w < width and g[u + w + v * width] == c:
				w += 1
			# 向下扩展高度（每行必须连续 w 格都同材质）
			var h := 1
			var extend := true
			while extend and v + h < height:
				for k in w:
					if g[(u + k) + (v + h) * width] != c:
						extend = false
						break
				if extend:
					h += 1
			result.append(RectInfo.new(Vector2i(u, v), Vector2i(w, h), c))
			# 清零标记已处理，保证每个格子至多被合并一次
			for y in h:
				var base := u + (v + y) * width
				for x in w:
					g[base + x] = 0
			u += w
	return result

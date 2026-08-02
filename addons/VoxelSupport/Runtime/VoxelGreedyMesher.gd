class_name VoxelGreedyMesher
extends RefCounted

## 贪婪网格合并器
##
## 提供统一的贪婪网格算法，供 VoxelMeshGenerator（编辑器导入）和
## VoxelChunkGenerator（运行时）共享调用。
##
## 核心算法：对一个 2D 网格中的同材质单元格进行矩形合并，降低三角形数量。
## 输入：Dictionary[Vector2i, int]（UV坐标 -> 材质ID）
## 输出：Array[RectInfo]（每个矩形包含 position, size, value）

## 矩形合并结果
class RectInfo:
	var position: Vector2i
	var size: Vector2i
	var value: int
	
	func _init(p: Vector2i, s: Vector2i, v: int):
		position = p
		size = s
		value = v

## 对 2D 网格执行贪婪合并
##
## grid: Dictionary[Vector2i, int] — UV坐标到材质ID的映射
## 返回: Array[RectInfo] — 合并后的矩形列表
##
## 算法：从左上到右下扫描网格，对每个未处理的单元格，
## 向右扩展找到最大宽度，再向下扩展找到最大高度，
## 生成一个矩形并标记所有单元格为已处理。
static func greedy_merge(grid: Dictionary) -> Array[RectInfo]:
	var result: Array[RectInfo] = []
	var processed := {}
	for uv in grid:
		if processed.has(uv):
			continue
		var value: int = grid[uv]
		var rect := _find_largest_rect(grid, processed, uv, value)
		# 标记矩形内的所有单元格为已处理
		for u in range(rect.position.x, rect.position.x + rect.size.x):
			for v in range(rect.position.y, rect.position.y + rect.size.y):
				processed[Vector2i(u, v)] = true
		result.append(rect)
	return result


## 在 2D 网格中查找最大的同材质矩形
## 从 seed 开始，向右扩展宽度，再向下扩展高度
## 返回 RectInfo
static func _find_largest_rect(grid: Dictionary, processed: Dictionary, seed: Vector2i, value: int) -> RectInfo:
	# 向右扩展宽度
	var width := 1
	while true:
		var test := seed + Vector2i(width, 0)
		if not grid.has(test) or processed.has(test) or grid[test] != value:
			break
		width += 1

	# 向下扩展高度（每行必须连续 width 个单元格都匹配）
	var height := 1
	while true:
		var row_valid := true
		for u in width:
			var test := seed + Vector2i(u, height)
			if not grid.has(test) or processed.has(test) or grid[test] != value:
				row_valid = false
				break
		if not row_valid:
			break
		height += 1

	return RectInfo.new(seed, Vector2i(width, height), value)
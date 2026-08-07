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
##
## 性能优化：返回平坦 packed array 而非对象数组，消除每个矩形的
## RefCounted 对象分配。直接修改传入的 grid（清零已合并格子），
## 消除 grid.duplicate() 拷贝开销。


## 对密集 2D 网格执行贪婪合并（性能关键路径）
## grid: PackedInt32Array，行优先。统一材质契约：0 = 空，否则 = 材质ID（id 0 保留为空）
## 注意：grid 会被修改（已合并的格子清零），调用方不应在调用后继续使用原始 grid 内容。
## width/height: 网格宽高
## 返回: Dictionary，{pos: PackedInt32Array, size: PackedInt32Array, val: PackedInt32Array}
##   pos[i*2] = u, pos[i*2+1] = v
##   size[i*2] = w, size[i*2+1] = h
##   val[i] = 材质ID
##   三个数组等长，第 i 个矩形 = (u, v, w, h, val[i])
static func greedy_merge_dense(grid: PackedInt32Array, width: int, height: int) -> Dictionary:
	var pos_arr := PackedInt32Array()
	var size_arr := PackedInt32Array()
	var val_arr := PackedInt32Array()

	for v in height:
		var u := 0
		while u < width:
			var c := grid[u + v * width]
			if c <= 0:
				u += 1
				continue
			# 向右扩展宽度
			var w := 1
			while u + w < width and grid[u + w + v * width] == c:
				w += 1
			# 向下扩展高度（每行必须连续 w 格都同材质）
			var h := 1
			var extend := true
			while extend and v + h < height:
				for k in w:
					if grid[(u + k) + (v + h) * width] != c:
						extend = false
						break
				if extend:
					h += 1
			pos_arr.append(u)
			pos_arr.append(v)
			size_arr.append(w)
			size_arr.append(h)
			val_arr.append(c)
			# 清零标记已处理，保证每个格子至多被合并一次
			for y in h:
				var base := u + (v + y) * width
				for x in w:
					grid[base + x] = 0
			u += w
	return {"pos": pos_arr, "size": size_arr, "val": val_arr}
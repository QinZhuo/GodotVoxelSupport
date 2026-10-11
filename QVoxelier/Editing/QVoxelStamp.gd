@tool
class_name QVoxelStamp
extends RefCounted
## 自定义笔刷内核 —— 把"一个做好的模型"抓成图案（`capture`），再用它像盖章一样绘画（`stamp`）。
## 【为什么要它】程序化算子是"机器生成形状"，与体素建模的手感不一致；而"我画好一个形状，
## 拿它当笔刷到处盖"才是 PS 自定义笔刷式的直觉。图案就是一组带材质的体素，与手绘完全同构。
## 【合并方式 = 操作三态】添加 = 并集、移除 = 差集、上色 = 用图案实心处重上当前材质。
## 【一次点击 = 一条可撤销命令】写入走 QVoxelEditCommand，与手绘同一时间线。

## 图案 = {cells: Array[Vector3i]（相对图案最小角，最小角在原点）, mats: PackedInt32Array, size: Vector3i}。


## 从一个模型的实心体素抓出图案（以内容包围盒为界）。空模型返回 {}。
static func capture(model: QVoxelModel) -> Dictionary:
	if model == null or model.is_empty():
		return {}
	var g := model.grid_size
	var lo := Vector3i(g.x, g.y, g.z)
	var hi := Vector3i(-1, -1, -1)
	for bk in model.block_keys():
		var o := QVoxelSpec.block_origin(bk, model.block_size)
		var blk := model.get_block(bk)
		var bs := model.block_size
		for lz in bs:
			for ly in bs:
				for lx in bs:
					if blk[lx + ly * bs + lz * bs * bs] <= 0:
						continue
					var p := o + Vector3i(lx, ly, lz)
					lo.x = mini(lo.x, p.x); lo.y = mini(lo.y, p.y); lo.z = mini(lo.z, p.z)
					hi.x = maxi(hi.x, p.x); hi.y = maxi(hi.y, p.y); hi.z = maxi(hi.z, p.z)
	if hi.x < lo.x or hi.y < lo.y or hi.z < lo.z:
		return {}
	var size := hi - lo + Vector3i.ONE
	var cells: Array[Vector3i] = []
	var mats := PackedInt32Array()
	for z in size.z:
		for y in size.y:
			for x in size.x:
				var m := model.get_voxel(lo.x + x, lo.y + y, lo.z + z)
				if m > 0:
					cells.append(Vector3i(x, y, z))
					mats.append(m)
	return {"cells": cells, "mats": mats, "size": size}


## 以 center 为中心盖一次图案。mode 取值同 QVoxelBrushTool.Op。返回真正改动的体素数。
static func stamp(cmd: QVoxelEditCommand, obj: QVoxelModel, pattern: Dictionary,
		center: Vector3i, mode: int, material_id: int) -> int:
	if cmd == null or obj == null or pattern.is_empty():
		return 0
	var size: Vector3i = pattern["size"]
	var cells: Array = pattern["cells"]
	var mats: PackedInt32Array = pattern["mats"]
	var anchor := center - Vector3i(size.x >> 1, size.y >> 1, size.z >> 1)
	var n := 0
	for i in cells.size():
		var p: Vector3i = anchor + cells[i]
		match mode:
			QVoxelBrushTool.Op.REMOVE:
				if cmd.set_voxel(p.x, p.y, p.z, 0):
					n += 1
			QVoxelBrushTool.Op.PAINT:
				if obj.get_voxel(p.x, p.y, p.z) > 0 and cmd.set_voxel(p.x, p.y, p.z, material_id):
					n += 1
			_:
				if cmd.set_voxel(p.x, p.y, p.z, mats[i]):
					n += 1
	return n

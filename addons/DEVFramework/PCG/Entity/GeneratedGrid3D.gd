class_name GeneratedGrid3D extends RefCounted
## 3D 整数栅格（体素）— PCG 3D 内容生成的基础数据结构

var width := 0
var height := 0
var depth := 0
var cells := PackedInt32Array()

static func create(w: int, h: int, d: int, default_value := 0) -> GeneratedGrid3D:
	var g := GeneratedGrid3D.new()
	g.width = w
	g.height = h
	g.depth = d
	g.cells.resize(w * h * d)
	g.cells.fill(default_value)
	return g

func _index(x: int, y: int, z: int) -> int:
	return (z * height + y) * width + x

func in_bounds(x: int, y: int, z: int) -> bool:
	return x >= 0 and x < width and y >= 0 and y < height and z >= 0 and z < depth

## 越界返回 out_of_bounds
func get_cell(x: int, y: int, z: int, out_of_bounds := -1) -> int:
	if not in_bounds(x, y, z):
		return out_of_bounds
	return cells[_index(x, y, z)]

func set_cell(x: int, y: int, z: int, v: int) -> void:
	if in_bounds(x, y, z):
		cells[_index(x, y, z)] = v

func fill(v: int) -> void:
	cells.fill(v)

func count(v: int) -> int:
	var n := 0
	for c in cells:
		if c == v:
			n += 1
	return n

## 邻域统计与 v 相等的格数（diagonal=false 仅 6 邻域，true 用 26 邻域）
func neighbors(x: int, y: int, z: int, v: int, diagonal := true) -> int:
	var n := 0
	for dz in range(-1, 2):
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if dx == 0 and dy == 0 and dz == 0:
					continue
				if not diagonal and (abs(dx) + abs(dy) + abs(dz)) > 1:
					continue
				if get_cell(x + dx, y + dy, z + dz, -1) == v:
					n += 1
	return n

## 连通域分析（6 邻域），返回所有值 == value 的连通分量（每分量一组线性索引）
func components(value := 1) -> Array[PackedInt32Array]:
	var visited := PackedByteArray()
	visited.resize(width * height * depth)
	var dirs: Array[Vector3i] = [
		Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
		Vector3i(0, 1, 0), Vector3i(0, -1, 0),
		Vector3i(0, 0, 1), Vector3i(0, 0, -1),
	]
	var comps: Array[PackedInt32Array] = []
	for i in cells.size():
		if cells[i] == value and visited[i] == 0:
			var comp := PackedInt32Array()
			var stack: Array[int] = [i]
			visited[i] = 1
			while not stack.is_empty():
				var cur: int = stack.pop_back()
				comp.append(cur)
				var x := cur % width
				var y := (cur / width) % height
				var z := cur / (width * height)
				for d in dirs:
					var nx := x + d.x
					var ny := y + d.y
					var nz := z + d.z
					if in_bounds(nx, ny, nz) and visited[_index(nx, ny, nz)] == 0 and cells[_index(nx, ny, nz)] == value:
						visited[_index(nx, ny, nz)] = 1
						stack.append(_index(nx, ny, nz))
			comps.append(comp)
	return comps

## —— 序列化 ——

## 转为可存档字典
func to_data() -> Dictionary:
	return {"w": width, "h": height, "d": depth, "cells": cells}

## 从存档字典还原
static func from_data(data: Dictionary) -> GeneratedGrid3D:
	var g := create(int(data.get("w", 0)), int(data.get("h", 0)), int(data.get("d", 0)))
	var raw = data.get("cells", [])
	g.cells = PackedInt32Array(raw) if raw is Array else (raw as PackedInt32Array)
	return g

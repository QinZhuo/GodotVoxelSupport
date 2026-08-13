class_name GeneratedGrid extends RefCounted
## PCG 生成结果 — 2D 整数栅格（运行时数据）

var width := 0
var height := 0
var cells := PackedInt32Array()

static func create(w: int, h: int, default_value := 0) -> GeneratedGrid:
	var g := GeneratedGrid.new()
	g.width = w
	g.height = h
	g.cells.resize(w * h)
	g.cells.fill(default_value)
	return g

func _index(x: int, y: int) -> int:
	return y * width + x

func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < width and y >= 0 and y < height

## 越界返回 out_of_bounds
func get_cell(x: int, y: int, out_of_bounds := -1) -> int:
	if not in_bounds(x, y):
		return out_of_bounds
	return cells[_index(x, y)]

func set_cell(x: int, y: int, v: int) -> void:
	if in_bounds(x, y):
		cells[_index(x, y)] = v

func fill(v: int) -> void:
	cells.fill(v)

func count(v: int) -> int:
	var n := 0
	for c in cells:
		if c == v:
			n += 1
	return n

## 8 邻域统计与 v 相等的格数（越界不计）
func neighbors(x: int, y: int, v: int) -> int:
	var n := 0
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			if get_cell(x + dx, y + dy, -1) == v:
				n += 1
	return n

## 连通域分析（默认 4 邻域），返回所有值 == value 的连通分量（每分量一组格索引）
func components(value := 1, diagonal := false) -> Array[PackedInt32Array]:
	var visited := PackedByteArray()
	visited.resize(width * height)
	var dirs: Array[Vector2i] = [
		Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	]
	if diagonal:
		dirs.append(Vector2i(1, 1))
		dirs.append(Vector2i(1, -1))
		dirs.append(Vector2i(-1, 1))
		dirs.append(Vector2i(-1, -1))
	var comps: Array[PackedInt32Array] = []
	for i in cells.size():
		if cells[i] == value and visited[i] == 0:
			var comp := PackedInt32Array()
			var stack: Array[int] = [i]
			visited[i] = 1
			while not stack.is_empty():
				var cur: int = stack.pop_back()
				comp.append(cur)
				var cx := cur % width
				var cy := cur / width
				for d in dirs:
					var nx := cx + d.x
					var ny := cy + d.y
					if in_bounds(nx, ny) and visited[_index(nx, ny)] == 0 and cells[_index(nx, ny)] == value:
						visited[_index(nx, ny)] = 1
						stack.append(_index(nx, ny))
			comps.append(comp)
	return comps

## —— 序列化 ——

## 转为可存档字典（与 SaveTool 的 JSON/GZIP 兼容）
func to_data() -> Dictionary:
	return {"w": width, "h": height, "cells": cells}

## 从存档字典还原
static func from_data(data: Dictionary) -> GeneratedGrid:
	var g := create(int(data.get("w", 0)), int(data.get("h", 0)))
	var raw = data.get("cells", [])
	g.cells = PackedInt32Array(raw) if raw is Array else (raw as PackedInt32Array)
	return g

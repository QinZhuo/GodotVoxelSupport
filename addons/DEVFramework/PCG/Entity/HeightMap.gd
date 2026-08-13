class_name HeightMap extends RefCounted
## 高度图生成结果 — 连续高度场（每格 0..1 高度）
##
## 2D 栅格 / 3D 体素的连续地基。支持：采样 / 坡度查询 / 海陆判定 / 序列化。
## 高度 0=海平面（水面以下），1=最高峰。消费方可自由离散化为任意地形。

var width := 0
var height := 0
## 每格高度（0..1），行优先 y*width+x
var heights := PackedFloat32Array()


static func create(w: int, h: int, default_value := 0.0) -> HeightMap:
	var m := HeightMap.new()
	m.width = w
	m.height = h
	m.heights.resize(w * h)
	m.heights.fill(default_value)
	return m


func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < width and y >= 0 and y < height


func _index(x: int, y: int) -> int:
	return y * width + x


## 取某格高度（越界返回 out_of_bounds）
func get_height(x: int, y: int, out_of_bounds := -1.0) -> float:
	if not in_bounds(x, y):
		return out_of_bounds
	return heights[_index(x, y)]


func set_height(x: int, y: int, v: float) -> void:
	if in_bounds(x, y):
		heights[_index(x, y)] = v


## 双线性插值采样（浮点坐标，越界 clamp 到边缘）
func sample(x: float, y: float) -> float:
	var x0 := clampi(int(floorf(x)), 0, width - 1)
	var y0 := clampi(int(floorf(y)), 0, height - 1)
	var x1 := clampi(x0 + 1, 0, width - 1)
	var y1 := clampi(y0 + 1, 0, height - 1)
	var fx := clampf(x - floorf(x), 0.0, 1.0)
	var fy := clampf(y - floorf(y), 0.0, 1.0)
	var h00 := get_height(x0, y0)
	var h10 := get_height(x1, y0)
	var h01 := get_height(x0, y1)
	var h11 := get_height(x1, y1)
	var a := lerpf(h00, h10, fx)
	var b := lerpf(h01, h11, fx)
	return lerpf(a, b, fy)


## 该格是否陆地（>= 海平面高度）
func is_land(x: int, y: int, sea_level := 0.5) -> bool:
	return get_height(x, y) >= sea_level


## 坡度（该格与 4 邻域最大高度差，用于悬崖/斜坡查询；无邻域返回 0）
func slope(x: int, y: int) -> float:
	var h := get_height(x, y)
	var m := 0.0
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var nh := get_height(x + d.x, y + d.y, h)
		m = maxf(m, absf(nh - h))
	return m


## 统计高度分布（每 level 档一个计数，用于水位/植被分层）
func histogram(levels := 10) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(levels)
	for v in heights:
		var idx := clampi(int(v * levels), 0, levels - 1)
		out[idx] += 1
	return out


## —— 序列化 ——

func to_data() -> Dictionary:
	return {"w": width, "h": height, "heights": heights}


static func from_data(data: Dictionary) -> HeightMap:
	var m := create(int(data.get("w", 0)), int(data.get("h", 0)))
	var raw = data.get("heights", [])
	m.heights = PackedFloat32Array(raw) if raw is Array else (raw as PackedFloat32Array)
	return m

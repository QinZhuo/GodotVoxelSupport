class_name WFCAnimator extends RefCounted
## WFC 生成过程动画器 — 分步执行"观测 → 传播"，随时渲染当前波函数状态
##
## 用于可视化 WFC 的生成过程：未坍缩格显示候选瓦片平均色（熵越高越杂），
## 已确定格显示瓦片色，矛盾格显示红色。
## 用法:
##   var anim := WFCAnimator.new()
##   anim.setup(def, rng, fixed)
##   while not anim.step():            # 逐帧推进，每帧调若干次
##       tex.texture = anim.render_image()

var def: GridGenDef
var rng: RandomNumberGenerator
var fixed: Dictionary = {}
var wave := PackedInt32Array()
var width := 0
var height := 0
var tiles: Array = []
var done := false
var failed := false
var step_count := 0

## C++ 核心（框架级共享原生库 PCGWFCAnimator，有状态逐步推进）
var _core: Object = null


## 初始化波函数（应用固定格并先传播一轮）
func setup(p_def: GridGenDef, p_rng: RandomNumberGenerator, p_fixed: Dictionary = {}) -> void:
	def = p_def
	rng = p_rng
	fixed = p_fixed
	width = def.width
	height = def.height
	tiles = def.tile_set.tiles if def.tile_set else []
	done = false
	failed = false
	step_count = 0
	var n := tiles.size()
	wave.resize(width * height)
	wave.fill((1 << n) - 1 if n > 0 and n < 30 else 0)
	# 纯 C++ 实现（框架强依赖 PCGWFCAnimator，无 GDScript 回退）
	var native := FrameworkNative.get_native(&"PCGWFCAnimator", [&"setup", &"step", &"get_wave"])
	if native == null:
		push_error("WFCAnimator.setup: 原生库 PCGWFCAnimator 不可用! 请确认 Native/devecs.gdextension 已加载。")
		done = true
		return
	_core = native
	var socket_map := {}
	var next_id := 0
	var socket_ids := func(s: String) -> int:
		if not socket_map.has(s):
			socket_map[s] = next_id
			next_id += 1
		return socket_map[s]
	var sockets := PackedInt32Array()
	var weights := PackedFloat32Array()
	for t in tiles:
		sockets.append(socket_ids.call(t.socket(0)))
		sockets.append(socket_ids.call(t.socket(1)))
		sockets.append(socket_ids.call(t.socket(2)))
		sockets.append(socket_ids.call(t.socket(3)))
		weights.append(t.weight)
	var fixed_idx := PackedInt32Array()
	var fixed_tile := PackedInt32Array()
	var merged := {}
	for key in def.wfc_fixed_cells:
		merged[key] = def.wfc_fixed_cells[key]
	for key in fixed:
		merged[key] = fixed[key]
	for key in merged:
		var tile_idx := int(merged[key])
		if tile_idx < 0 or tile_idx >= n:
			continue
		if key is Rect2i:
			var r := key as Rect2i
			for ry in range(maxi(0, r.position.y), mini(height, r.end.y)):
				for rx in range(maxi(0, r.position.x), mini(width, r.end.x)):
					fixed_idx.append(ry * width + rx)
					fixed_tile.append(tile_idx)
			continue
		var idx := _fixed_index(key)
		if idx >= 0:
			fixed_idx.append(idx)
			fixed_tile.append(tile_idx)
	_core.call(&"setup", width, height, sockets, weights,
		def.wfc_max_backtracks, def.wfc_max_propagations,
		fixed_idx, fixed_tile, rng.seed)
	wave = _core.call(&"get_wave")


## 推进一步（一次观测+传播），完成时返回 true
func step() -> bool:
	if _core == null or done or failed:
		return true
	var finish: bool = _core.call(&"step")
	step_count = _core.call(&"step_count")
	wave = _core.call(&"get_wave")
	if finish:
		done = true
		failed = _core.call(&"is_failed")
		return true
	return false


## 渲染当前波函数状态
func render_image() -> Image:
	var img := Image.create(width, height, false, Image.FORMAT_RGB8)
	for i in wave.size():
		var m := wave[i]
		var c := Color(0.1, 0.1, 0.1)
		if m == 0:
			c = Color(0.75, 0.15, 0.15)  # 矛盾
		elif (m & (m - 1)) == 0:
			var ti := _bit_index(m)
			c = tiles[ti].color if ti >= 0 and ti < tiles.size() else Color.WHITE
		else:
			c = _average_color(m)
		img.set_pixel(i % width, i / width, c)
	return img


## 单候选 bitmask → 瓦片索引（渲染用）
func _bit_index(mask: int) -> int:
	var i := 0
	while mask > 1:
		mask >>= 1
		i += 1
	return i


## —— 内部 ——







func _average_color(mask: int) -> Color:
	var acc := Color(0, 0, 0)
	var cnt := 0
	for i in tiles.size():
		if mask & (1 << i):
			acc += tiles[i].color
			cnt += 1
	return acc / maxi(cnt, 1)


func _fixed_index(key) -> int:
	if key is Vector2i:
		return key.y * width + key.x if key.x >= 0 and key.x < width and key.y >= 0 and key.y < height else -1
	if key is int:
		return key if key >= 0 and key < width * height else -1
	if key is String:
		var parts := String(key).split(",")
		if parts.size() == 2:
			var x := int(parts[0])
			var y := int(parts[1])
			if x >= 0 and x < width and y >= 0 and y < height:
				return y * width + x
	return -1




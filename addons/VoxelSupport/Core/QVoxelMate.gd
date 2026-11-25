@tool
class_name QVoxelMate
extends RefCounted

## MATE 条目（材质表项）的**唯一**语义实现：12 字节 ↔ Dictionary。
##
## 【为什么单独一个类】MATE 的键形状原先有**两种**：读盘路径（本类的 decode）产出
## 12 键（含 r/g/b/a），而 QVoxelWorld 建空气条目时借的是 `VoxelMaterial.air_mate()` —— 它只有
## 8 键、**没有 r/g/b/a**。于是 `material_color()` 读那种条目时按"缺键 → 缺省 r=255,g=0,b=255"
## 算，返回**洋红**，并由 Mesh/QVoxelScript 原样导给用户脚本。洋红在本工程里是"错误色"的约定，
## 用户看到的是一个没有任何报错的错色。收敛到本类后，"空气条目"与"入文件条目"是同一个形状。
##
## 【canonical 形状 = 12 键】rgba / r / g / b / a / metal / rough / hardness / mass / e_r / e_g / e_b。
## r/g/b/a 是 rgba 的冗余展开（面板与 VoxelMaterial 都爱按通道读），**权威值是 rgba**：
## `color()` 只认 rgba，故历史 8 键条目（rgba 齐全、通道缺失）也不会再变洋红。

## 语义键：条目"是否为空气"的判据只看这些。
## 【为什么不比 12 字节原始块】reserved 字节按规范写 0；用原始字节比较会把 reserved 非零的
## 文件误判成"非空气"。
## 【为什么不算 roughness/hardness】读端给未使用的调色板槽建条目时是 rgba=0 配 rough/hardness
## 的**默认值**（不是 0）；把它们算进判据会让那些槽被判成"有内容"。
const AIR_KEYS := ["rgba", "metal", "rough", "hardness", "mass", "e_r", "e_g", "e_b"]

## 空气条目：12 键全零（含 r/g/b/a —— 缺这四个键正是洋红 bug 的来源）。
static func air_entry() -> Dictionary:
	return {
		"rgba": 0,
		"r": 0, "g": 0, "b": 0, "a": 0,
		"metal": 0, "rough": 0, "hardness": 0, "mass": 0,
		"e_r": 0, "e_g": 0, "e_b": 0,
	}


## 该条目是否为空气（条目 0 保留且全零）。非 Dictionary 一律视为"不是空气"——
## 结构非法应当被上层报出来，而不是在这里悄悄当成空气。
static func is_air_entry(entry: Variant) -> bool:
	if not (entry is Dictionary):
		return false
	var e: Dictionary = entry
	for k in AIR_KEYS:
		if int(e.get(k, 0)) != 0:
			return false
	return true


## 解析 MATE payload → Array（每项 12 键）。非致命异常（条目数不合法 / 越界）走 warn 回调，
## 并降级为"无材质"：MATE 块坏了不该拖垮整个文件（模型与节点树仍然可用）。
## warn 形如 Callable(String) —— 调用方把它接到自己的诊断收集器（避免本类依赖 QVoxelNotes）。
static func decode(payload: PackedByteArray, warn: Callable = Callable()) -> Array:
	var out: Array = []
	if payload.size() < 2:
		_note(warn, "MATE payload 不足 2 字节（无法读取 entry_count），按无材质处理")
		return out
	var count := payload.decode_u16(0)
	if count == 0:
		# MATE 至少含条目 0（空气）；entry_count=0 违反规范 → 视为"未声明材质"并告警。
		_note(warn, "MATE entry_count=0（§4 要求至少含条目 0），按无材质处理")
		return out
	var need := 2 + count * QVoxelSpec.MATE_ENTRY_SIZE
	if payload.size() < need:
		_note(warn, "MATE 条目越界（声明 %d 条需 %d 字节，实际 %d），按无材质处理"
				% [count, need, payload.size()])
		return out
	for i in count:
		var off := 2 + i * QVoxelSpec.MATE_ENTRY_SIZE
		out.append(entry_from_bytes(payload, off))
	return out


## 从 payload 的 off 处解出一个条目（12 字节）。reserved 字节按规范忽略。
static func entry_from_bytes(payload: PackedByteArray, off: int) -> Dictionary:
	var rgba := payload.decode_u32(off)
	return {
		"rgba": rgba,
		"r": (rgba >> 24) & 0xFF,
		"g": (rgba >> 16) & 0xFF,
		"b": (rgba >> 8) & 0xFF,
		"a": rgba & 0xFF,
		"metal": payload[off + 4],
		"rough": payload[off + 5],
		"hardness": payload[off + 6],
		"mass": payload[off + 7],
		"e_r": payload[off + 8],
		"e_g": payload[off + 9],
		"e_b": payload[off + 10],
	}


## 条目数组 → MATE payload（uint16 count + count×12 字节）。**只读 rgba**：
## 通道键是冗余展开，若两者不一致应以 rgba 为准（写入端唯一权威）。
static func encode(entries: Array) -> PackedByteArray:
	var count := entries.size()
	var out := PackedByteArray()
	out.resize(2 + count * QVoxelSpec.MATE_ENTRY_SIZE)
	out.encode_u16(0, count & 0xFFFF)
	for i in count:
		var e: Variant = entries[i]
		var d: Dictionary = e if e is Dictionary else {}
		var off := 2 + i * QVoxelSpec.MATE_ENTRY_SIZE
		out.encode_u32(off, int(d.get("rgba", 0)) & 0xFFFFFFFF)
		out[off + 4] = int(d.get("metal", 0)) & 0xFF
		out[off + 5] = int(d.get("rough", 0)) & 0xFF
		out[off + 6] = int(d.get("hardness", 0)) & 0xFF
		out[off + 7] = int(d.get("mass", 0)) & 0xFF
		out[off + 8] = int(d.get("e_r", 0)) & 0xFF
		out[off + 9] = int(d.get("e_g", 0)) & 0xFF
		out[off + 10] = int(d.get("e_b", 0)) & 0xFF
		out[off + 11] = 0  # reserved
	return out


## 条目 → 颜色。**只认 rgba**（权威值）；条目不是 Dictionary 时返回洋红（可见的错误色）。
## 【为什么不读 r/g/b/a】那四个键是展开值，历史上恰恰因为"某些条目没有它们"而产生洋红。
static func color(entry: Variant) -> Color:
	if not (entry is Dictionary):
		return Color.MAGENTA
	return rgba_to_color(int((entry as Dictionary).get("rgba", 0)))


## rgba 位模式（r<<24 | g<<16 | b<<8 | a）→ Color。
static func rgba_to_color(rgba: int) -> Color:
	return Color8((rgba >> 24) & 0xFF, (rgba >> 16) & 0xFF, (rgba >> 8) & 0xFF, rgba & 0xFF)


## Color → rgba 位模式。
static func color_to_rgba(c: Color) -> int:
	return (byte_of(c.r) << 24) | (byte_of(c.g) << 16) | (byte_of(c.b) << 8) | byte_of(c.a)


## 换掉条目的颜色：**整体替换**为新字典（绝不就地改键）。
## 【为什么必须换整份】撤销走 QVoxelPropertyCommand(world, &"materials")，其快照只浅拷数组；
## 就地改嵌套字典会让"改前值"跟着变（见 QVoxelWorld 类头铁律）。
static func with_color(entry: Variant, color: Color) -> Dictionary:
	var out: Dictionary = (entry as Dictionary).duplicate() if entry is Dictionary else air_entry()
	var rgba := color_to_rgba(color)
	out["rgba"] = rgba
	out["r"] = (rgba >> 24) & 0xFF
	out["g"] = (rgba >> 16) & 0xFF
	out["b"] = (rgba >> 8) & 0xFF
	out["a"] = rgba & 0xFF
	return out


## 单通道浮点（0–1）→ 字节（0–255），四舍五入并夹取。
static func byte_of(value: float) -> int:
	return clampi(int(round(value * 255.0)), 0, 255)


static func _note(warn: Callable, msg: String) -> void:
	# 有调用方接诊断就交给它（它自己会 push），否则就地告警 —— 否则同一句话会被打印两遍。
	if warn.is_valid():
		warn.call(msg)
		return
	push_warning("[QVX] " + msg)

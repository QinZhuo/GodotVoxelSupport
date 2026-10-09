@tool
class_name QVoxelFrame
extends RefCounted
## 动画的一帧 —— 「该模型在该时刻的**一整套块表**」+ 本帧时长（QVoxelSpec §12.1）。
##
## 【为什么是一整套块表，而不是"相对上一帧的差异"】差异是**存储态**（写盘时算、读盘时还原），
## 编辑态必须每帧都完整：落笔只改一帧、求值只看一帧、撤销快照的粒度也是"某帧的某块"。
## 若把增量当编辑态，每次读一帧都要沿链回放一遍，撤销还得处理"改了一帧 → 后面所有帧都变了"
## 的连锁 —— 增量对编辑器与运行时**完全不可见**（同 §12.1 的三态分离）。
##
## 【为什么块表形状与 QVoxelModel.blocks 逐字一致】`Dictionary[Vector3i → PackedInt32Array]`
## 就是 `VXEL` 的负载形状，于是"帧 0 全量"在读写两端**共用同一套块编解码**，本类零转换。
##
## 【为什么 duration_ms 在帧上而不是全局 fps】逐帧可变时长是动画的常态（Aseprite 的
## `frame.durationMs` 优先于 `header.speed`）；全局 `fps` 只是"本帧没写时长"时的兜底，
## 它属于节点的 `anim` 元数据，不属于帧。

## 本帧时长（毫秒）。0 = 用节点 `anim.fps` 的缺省帧时长（§12.3）。
var duration_ms := 0

## 本帧的完整块表：块坐标（Vector3i）→ PackedInt32Array(B³，块内 ZXY，值 = 材质 ID，0 = 空）。
## 空块不存在（= 坐标缺失），与 QVoxelModel.blocks 同一约定。
var blocks: Dictionary = {}


## 空帧判定（块表空即空，O(1)）。
func is_empty() -> bool:
	return blocks.is_empty()


## 已分配块数。
func block_count() -> int:
	return blocks.size()


## 独立副本。**必须深到块缓冲**：帧会被复制（"复制帧"、"新建帧继承上一帧"），
## 而 PackedInt32Array 是引用类型 —— 浅拷会让两帧共享同一缓冲，"改一帧另一帧跟着变"。
func clone() -> QVoxelFrame:
	var f := QVoxelFrame.new()
	f.duration_ms = duration_ms
	for k: Vector3i in blocks:
		f.blocks[k] = (blocks[k] as PackedInt32Array).duplicate()
	return f


## 已分配块坐标（按 x → y → z 排序）。理由同 QVoxelModel.block_keys：
## 落盘字节与回归测试的逐字节哈希都要求"同一份数据 ⇒ 同一串字节"。
func block_keys() -> Array[Vector3i]:
	var keys: Array[Vector3i] = []
	for k in blocks:
		keys.append(k)
	keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x:
			return a.x < b.x
		if a.y != b.y:
			return a.y < b.y
		return a.z < b.z)
	return keys


# ----------------------------------------------------------------------------
# 与格式层（QVoxelFile 的传输结构）互转
# ----------------------------------------------------------------------------
# 【为什么转换放在这里，而不是让格式层认识本类】QVoxelFile 是"字节 ⇄ 传输结构"的格式内核，
# 它的帧是**纯 JSON 味的字典**（`{"duration_ms":…, "blocks":…}`），刻意不认识编辑层的类型
# —— 否则格式内核就得依赖编辑模型，换一个编辑模型（或没有编辑器）时它跟着塌。
# 两个方向的转换各只有一处，收在这里，QVoxelWorld 只做"遍历 + 调用"。

## 传输结构 → 帧。缺键一律取缺省（读路径不制造错误，只按规格补默认值）。
static func from_dict(d: Variant) -> QVoxelFrame:
	var f := QVoxelFrame.new()
	if not (d is Dictionary):
		return f
	var src: Dictionary = d
	f.duration_ms = maxi(0, int(src.get("duration_ms", 0)))
	var b: Variant = src.get("blocks")
	f.blocks = b if b is Dictionary else {}
	return f


## 帧 → 传输结构。**只交出引用**（不拷贝块缓冲）：doc 是瞬时 DTO，用完即弃，
## 拷贝一份几百万格的数据纯属浪费（同 QVoxelWorld.from_document 的"接管"约定）。
func to_dict() -> Dictionary:
	return {"duration_ms": duration_ms, "blocks": blocks}

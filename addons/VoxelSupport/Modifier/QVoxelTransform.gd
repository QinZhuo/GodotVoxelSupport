@tool
class_name QVoxelTransform
extends RefCounted
## 整对象体素重排：轴置换 + 各轴取反（旋转 90° / 镜像的全部可能），外加平铺（复制族）。
## 【为什么是"轴置换 + 符号"而不是 4×4 矩阵】
## 体素变换必须是**格到格的整数双射**才谈得上无损。整数格上"把网格映回自身"的映射，
## 恰好就是"给三个轴做重排 + 各轴各自取反"——共 48 种（正方体的旋转群 24 × 镜像 2，即
## 立方体的全对称群）。用矩阵表达则要额外证明"无剪切、行列式为 ±1、平移量是整数"，
## 而用置换 + 符号，这些性质**由构造直接成立**，写不出一个把格子错开半格的变换。
## 【为什么偏移量由尺寸推出来，不单独存】
## 镜像必须相对网格中心，否则整个模型会平移。故本类规定：sign 为负的轴，映射恒为
## `源尺寸-1-目的坐标`。于是只存 perm 与 sign 两个 Vector3i，源尺寸一变
## （非立方网格旋转时 X/Y 尺寸互换），偏移自动跟着变 —— 不存在"忘了同步偏移"的隐患。
## 【为什么 remap 走"每轴一张查表"】
## 三重循环里每格现算一次置换与取反，256³ 就是 1600 万次分支。三个轴的映射与其它轴无关，
## 各预生成一张"目的坐标 → 源坐标"的表（长度 ≤ 单轴尺寸）即可，内层循环退化成三次数组取数。
## 【本类不碰命令 / 不碰 QVoxelier】
## 它只做纯数据重排（进 / 出都是密集体积），写回对象与记撤销由调用方负责 ——
## 于是它能无头测试，也不需要认识 QVoxelier 里的任何类型。

## 目的轴 a ← 源轴 perm[a]。必须是置换（三个分量互不相同）。
var perm := Vector3i(0, 1, 2)
## 目的轴 a 上的取反：< 0 表示 `源尺寸-1-目的坐标`，> 0 表示原样。
var sign := Vector3i.ONE


func _init(p_perm := Vector3i(0, 1, 2), p_sign := Vector3i.ONE) -> void:
	perm = p_perm
	sign = p_sign


# 构造：双射族（旋转 / 镜像）

static func identity() -> QVoxelTransform:
	return QVoxelTransform.new()


## 沿 axis 镜像（axis：0 = X，1 = Y，2 = Z）。网格尺寸不变。
static func mirror(axis: int) -> QVoxelTransform:
	var s := [1, 1, 1]
	s[axis] = -1
	return QVoxelTransform.new(Vector3i(0, 1, 2), Vector3i(s[0], s[1], s[2]))


## 绕 axis 轴转 90°（dir = +1 / -1 为两个方向）。两个非轴尺寸互换。
## 【轴对 (u, v) 取 (axis+1, axis+2) mod 3 的循环序】于是"绕 X 时 Y→Z"这类右手系约定
## 由公式统一给出，三个轴共用一个实现，不必三份手写的轴字母表（那种表迟早有一处写反）。
static func rotate90(axis: int, dir: int) -> QVoxelTransform:
	var u := (axis + 1) % 3
	var v := (axis + 2) % 3
	var p := [0, 1, 2]
	var s := [1, 1, 1]
	p[u] = v
	s[u] = dir
	p[v] = u
	s[v] = -dir
	return QVoxelTransform.new(Vector3i(p[0], p[1], p[2]), Vector3i(s[0], s[1], s[2]))


func is_identity() -> bool:
	return perm == Vector3i(0, 1, 2) and sign == Vector3i.ONE


# 双射族：尺寸与重排

## 变换后的网格尺寸：new[a] = old[perm[a]]（尺寸跟着源轴走，故旋转会互换尺寸）。
func new_size(old: Vector3i) -> Vector3i:
	return Vector3i(old[perm.x], old[perm.y], old[perm.z])


## 把旧密集体积（布局 = PcgModel.index_of，尺寸 old）重排成新体积（尺寸 new_size(old)）。
## src 尺寸不足时返回同尺寸的全零体积 —— 宁可得到一个空对象，也不要越界读。
func remap(src: PackedInt32Array, old: Vector3i) -> PackedInt32Array:
	var dst_size := new_size(old)
	var out := PackedInt32Array()
	out.resize(dst_size.x * dst_size.y * dst_size.z)
	if old.x <= 0 or old.y <= 0 or old.z <= 0 or src.size() < old.x * old.y * old.z:
		return out
	# 源数组的下标布局只认**源轴**顺序：x 步长 1、y 步长 old.x、z 步长 old.x*old.y。
	var stride := Vector3i(1, old.x, old.x * old.y)
	var cx := _axis_contrib(0, old, stride)
	var cy := _axis_contrib(1, old, stride)
	var cz := _axis_contrib(2, old, stride)
	var i := 0
	for dz in dst_size.z:
		var zc := cz[dz]
		for dy in dst_size.y:
			var yc := zc + cy[dy]
			for dx in dst_size.x:
				out[i] = src[yc + cx[dx]]
				i += 1
	return out


## 目的轴 a 的"目的坐标 → 源数组下标增量"查表：源坐标先按镜像规则取（`源尺寸-1-坐标` 或原样），
## 再乘上**该源轴自己在源数组里的步长**。
## 【为什么必须乘源轴步长，而不能按目的轴顺序套步长】
## 目的轴 a 对应的是源轴 perm[a]，而 perm 可能是置换（绕 Z 旋转时目的 X 对应源 Y）。
## 按目的轴顺序套步长（x→1、y→old.x……）只对恒等置换成立；一旦置换，下标会算到数组之外 ——
## 这不是"结果偏一点"，是越界崩溃。故此处每个源坐标都乘"它自己那根源轴"的步长。
## 顺带把乘法挪出内层循环：三重循环里只剩两次加法与一次取数。
func _axis_contrib(a: int, old: Vector3i, stride: Vector3i) -> PackedInt32Array:
	var p: int = perm[a]
	var n: int = old[p]
	var step: int = stride[p]
	var m := PackedInt32Array()
	m.resize(n)
	var flip: bool = sign[a] < 0
	for d in n:
		m[d] = ((n - 1 - d) if flip else d) * step
	return m


# 复制族：平铺（repeat）
# 【为什么与上面的双射族分开成两个函数，而不是塞进 perm/sign】
# 平铺不是双射：源格会被多份共用（同一格映到多个目的格）。硬套置换形态要么表达不了，
# 要么要靠额外的"重复次数"字段把语义搅浑。分开写，"重排"与"复制"两种语义各有其名，
# 调用方也不可能把两者混着用错。两者的**对外接口形状是一致的**
# （给源体积与源尺寸，得到新尺寸与新体积），故编排侧（写回 + 撤销）仍只有一条路径。

## 平铺后的网格尺寸：沿 axis 变成 times 倍，其余轴不变。
static func repeat_size(old: Vector3i, axis: int, times: int) -> Vector3i:
	var n := maxi(1, times)
	var d := [old.x, old.y, old.z]
	d[axis] = old[axis] * n
	return Vector3i(d[0], d[1], d[2])


## 把体积沿 axis 复制 times 份（源坐标 = 目的坐标对源尺寸取模）。
static func repeat_volume(src: PackedInt32Array, old: Vector3i, axis: int, times: int) -> PackedInt32Array:
	var dst_size := repeat_size(old, axis, times)
	var out := PackedInt32Array()
	out.resize(dst_size.x * dst_size.y * dst_size.z)
	if old.x <= 0 or old.y <= 0 or old.z <= 0 or src.size() < old.x * old.y * old.z:
		return out
	var sw := old.x
	var sh := old.y
	var dw := dst_size.x
	var dh := dst_size.y
	var i := 0
	for dz in dst_size.z:
		var zb := (dz % old.z) * sw * sh
		for dy in dh:
			var yb := zb + (dy % old.y) * sw
			for dx in dw:
				out[i] = src[yb + (dx % sw)]
				i += 1
	return out

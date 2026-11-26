@tool
class_name VoxelWorldUtil
extends RefCounted
## 体素世界坐标/距离/视锥通用静态工具：VoxelRenderer / VoxelDestructible 等组件
## 统一复用同一套 chunk 世界换算与距离判定，避免各处重复实现。
## 所有方法为纯函数（参数传入一切），无状态、线程安全。


## chunk 的世界空间 AABB（chunk 子节点局部坐标需加上所属节点的 global_position）
static func chunk_world_aabb(ck: Vector3i, chunk_size_world: float, world_offset: Vector3) -> AABB:
	var origin := world_offset + Vector3(ck) * chunk_size_world
	return AABB(origin, Vector3(chunk_size_world, chunk_size_world, chunk_size_world))


## 相机到 chunk 中心的距离（欧氏；与 chunk_world_aabb 一致）
static func chunk_center_dist(ck: Vector3i, cam_pos: Vector3, chunk_size_world: float, world_offset: Vector3) -> float:
	return cam_pos.distance_to(chunk_world_aabb(ck, chunk_size_world, world_offset).get_center())


## 世界坐标 → chunk key（与 chunk_world_aabb 一致）
static func chunk_from_world(world_pos: Vector3, chunk_size_world: float, world_offset: Vector3) -> Vector3i:
	var local := world_pos - world_offset
	return Vector3i(
			floori(local.x / chunk_size_world),
			floori(local.y / chunk_size_world),
			floori(local.z / chunk_size_world))


## AABB 是否有任意顶点在视锥内（保守：8 顶点逐一测试，任一在内则生成整个 chunk）。
## 使用 Godot 内置 is_position_in_frustum，保证判定与引擎渲染剔除一致。
static func aabb_has_vertex_in_frustum(aabb: AABB, cam: Camera3D) -> bool:
	for i in 8:
		var v := Vector3(
			aabb.position.x if (i & 1) == 0 else aabb.end.x,
			aabb.position.y if (i & 2) == 0 else aabb.end.y,
			aabb.position.z if (i & 4) == 0 else aabb.end.z)
		if cam.is_position_in_frustum(v):
			return true
	return false


## 取"分层字典数组"的第 level 层（必要时补足到该层）。全项目唯一维护这类数组的地方：
## 各层各自一张 {key: value} 表；越界即补空层，避免每处手写 while-append（易漏、易越界）。
## 数据层的粗层缓冲表与脏账的标记表都用它，所以放在基础层而不是其中任一方的私有实现。
static func ensure_layer(layers: Array[Dictionary], level: int) -> Dictionary:
	while layers.size() <= level:
		layers.append({})
	return layers[level]


# 资产原点语义（基础层唯一出处）
# 【为什么在基础层】网格生成 / 导入器都要它，而它们**不该依赖动态层的 QVoxelSource**——
# 否则"只导入静态网格"的游戏也得拖着整个运行时数据层。

## 资产原点模式（导入选项 mesh/origin 的取值）。
enum OriginMode {
	WORLD_ORIGIN,    ## 保留文件坐标 —— 默认
	BOTTOM_CENTER,   ## 内容包围盒：X/Z 居中 + Y 贴底（游戏资产惯例）
	CONTENT_CENTER,  ## 内容包围盒三轴居中
}


## 体素单位的原点偏移：把内容摆成 `mode` 描述的样子，渲染顶点再叠加它。
## 取整用"先除再 floor"（`-floor(extent/2)`），结果恒为整数体素；WORLD_ORIGIN 返回零。
static func origin_offset(bounds: Dictionary, mode: int) -> Vector3:
	if bounds.is_empty() or mode == OriginMode.WORLD_ORIGIN:
		return Vector3.ZERO
	var lo: Vector3i = bounds["min"]
	var hi: Vector3i = bounds["max"]
	var half := (Vector3(hi - lo + Vector3I_ONE) / 2.0).floor()
	var y := -float(lo.y) if mode == OriginMode.BOTTOM_CENTER else -(float(lo.y) + half.y)
	return Vector3(-(float(lo.x) + half.x), y, -(float(lo.z) + half.z))


const Vector3I_ONE := Vector3i(1, 1, 1)


## 一组体素位置的整数包围盒 `[最小角, 最大角]`（含端点，单位=体素格）；空集合返回 `[]`。
## **这里是"体素求界"的唯一实现**：入参既接受 `Array[Vector3i]`（位置列表）也接受
## `Dictionary`（键为位置，如 `{Vector3i: 材质ID}`）—— GDScript 里 `for x in dict` 遍历的
## 正是键，两种形状共用同一趟扫描，不必先转成对方再算。
## 【为什么返回数组】"空集合"与"单点集合"必须能区分：单点集合的 min == max，而空集合没有
## 包围盒。用 `[]` 表达空、`[min, max]` 表达非空，调用方判 `is_empty()` 即可，不需要额外的
## 有效标志位（也不必像 `{}` 那样让调用方猜键是否存在）。
static func voxel_span(source: Variant) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	if source == null:
		return out
	if source is Array and (source as Array).is_empty():
		return out
	if source is Dictionary and (source as Dictionary).is_empty():
		return out
	var min_pos := Vector3i.MAX
	var max_pos := Vector3i.MIN
	var any := false
	for pos_key in source:
		var pos: Vector3i = pos_key
		any = true
		min_pos.x = mini(min_pos.x, pos.x)
		min_pos.y = mini(min_pos.y, pos.y)
		min_pos.z = mini(min_pos.z, pos.z)
		max_pos.x = maxi(max_pos.x, pos.x)
		max_pos.y = maxi(max_pos.y, pos.y)
		max_pos.z = maxi(max_pos.z, pos.z)
	if any:
		out.append(min_pos)
		out.append(max_pos)
	return out


## 体素字典 `{Vector3i: 材质ID}` 的精确包围盒 `{"min", "max"}`（含端点）；空集合返回 `{}`。
## 唯一实现是上面的 `voxel_span`，这里只把它的返回形状转成字典（导入 / 原点偏移 / 网格生成
## 都按字典取键，改成数组会牵动一大片调用点）。
## 【另外两处求界为什么不合并】QVoxelAsset 的 `bounds_for_blocks` 服务于**帧缓存**（按块缓冲
## 逐体素判空）；VoxAssetWorld 的 `_voxel_bounds` 服务于**模型导入**：返回 `{"min", "size"}`
## （不是 max），且空模型给 1³ 而非 `{}` —— 下游要拿 size 直接建 QVoxelModel 的非负局部坐标。
## 两者的输入形状与语义都不同，硬合并只会把两套契约塞进一个函数。
static func voxel_bounds(voxels: Dictionary) -> Dictionary:
	var span := voxel_span(voxels)
	if span.is_empty():
		return {}
	return {"min": span[0], "max": span[1]}

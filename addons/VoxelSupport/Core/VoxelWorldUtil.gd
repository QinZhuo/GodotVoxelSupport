@tool
class_name VoxelWorldUtil
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


# 资产原点语义（基础层唯一出处）
# 【为什么在基础层】网格生成 / 导入器都要它，而它们**不该依赖动态层的 QVoxelSource**——
# 否则"只导入静态网格"的游戏也得拖着整个运行时数据层。QVoxelSource 保留同名转发以兼容旧调用点。

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


## 体素字典 `{Vector3i: 材质ID}` 的精确包围盒 `{"min", "max"}`（含端点）；空集合返回 `{}`。
## **全项目唯一的"体素字典求界"实现**（导入 / 原点偏移 / 网格生成都调它）。
static func voxel_bounds(voxels: Dictionary) -> Dictionary:
	if voxels.is_empty():
		return {}
	var min_pos := Vector3i.MAX
	var max_pos := Vector3i.MIN
	for pos_key in voxels:
		var pos: Vector3i = pos_key
		min_pos.x = mini(min_pos.x, pos.x)
		min_pos.y = mini(min_pos.y, pos.y)
		min_pos.z = mini(min_pos.z, pos.z)
		max_pos.x = maxi(max_pos.x, pos.x)
		max_pos.y = maxi(max_pos.y, pos.y)
		max_pos.z = maxi(max_pos.z, pos.z)
	return {"min": min_pos, "max": max_pos}

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

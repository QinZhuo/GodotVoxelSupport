extends RefCounted
## 空洞检测工具：检查相机视锥内近处地面各位置的 LOD mesh 覆盖。
## 客观判定"应显示 LOD mesh 但未挂载"的空洞位置，替代肉眼观察。
## 用法（游戏运行中）：load("res://_hole_detect.gd").run(...)

static func run(node: Node3D, cam: Camera3D) -> Dictionary:
	var cam_pos: Vector3 = cam.global_position
	var chunk_world: float = float(node.voxel_scale) * 32.0
	var cam_dir: Vector3 = -cam.global_transform.basis.z
	cam_dir.y = 0.0
	cam_dir = cam_dir.normalized()
	var right: Vector3 = cam.global_transform.basis.x
	right.y = 0.0
	right = right.normalized()
	var unload_d: float = node.unload_distance if node.unload_distance > node.view_distance else node.view_distance * 1.2
	var hole_keys: Dictionary = {}
	for di in range(1, 9):
		for si in range(-5, 6):
			var wpos: Vector3 = cam_pos + cam_dir * (di * chunk_world) + right * (si * chunk_world * 0.6)
			wpos.y = 0.0
			var ck: Vector3i = node._chunk_from_world(wpos, chunk_world, node.global_position)
			var level: int = node._chunk_render_level(ck, cam_pos)
			var bk: Vector3i = node._lod_block_of_chunk(ck, level) if level > 0 else ck
			var dist: float = node._block_dist(bk, level, cam_pos)
			var edge: float = node._lod_block_edge_world(level) if level > 0 else chunk_world
			if dist > unload_d + edge * 0.5:
				continue
			var covered := false
			if level == 0:
				covered = node._lod_meshes[0].get(ck) != null
			else:
				covered = node._lod_meshes[level].get(bk) != null
			if not covered:
				hole_keys["%s_L%d" % [ck, level]] = {"ck": ck, "level": level, "dist": int(dist)}
	var holes: Array = []
	for k in hole_keys:
		holes.append(hole_keys[k])
	var lod1_size: int = node._lod_meshes[1].size() if node._lod_meshes.size() > 1 else 0
	var coarse_data_l1: int = node.data.get_lod_block_keys(1).size() if node.data else 0
	var result := {
		"cam": Vector3i(cam_pos), "holes_count": holes.size(), "holes": holes,
		"lod0": node._lod_meshes[0].size(), "lod1": lod1_size,
		"coarse_data_l1": coarse_data_l1,
	}
	print("[空洞检测] count=", holes.size(), " cam=", Vector3i(cam_pos), " lod0=", node._lod_meshes[0].size(), " lod1=", lod1_size)
	return result

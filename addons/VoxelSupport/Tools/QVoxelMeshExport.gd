@tool
class_name QVoxelMeshExport
extends RefCounted
## 世界 → 三角网格 → glTF 2.0（`.glb` 二进制 / `.gltf` 文本 + 贴图）。

## 支持的扩展名（文件对话框过滤 + 扩展名判定）。
const EXTENSIONS := ["glb", "gltf"]
## 一个体素的边长（世界单位）。
const DEFAULT_VOXEL_SCALE := 1.0

# 对外

## 世界 → glTF 文件（`.glb`/`.gltf` 由扩展名决定）。
static func export(world: QVoxelWorld, path: String,
		voxel_scale := DEFAULT_VOXEL_SCALE) -> Error:
	if world == null or path.is_empty():
		return ERR_INVALID_PARAMETER
	var mesh := build_mesh(world, voxel_scale)
	if mesh == null:
		return ERR_CANT_CREATE
	var root := Node3D.new()
	root.name = _safe_name(world.world_name())
	var inst := MeshInstance3D.new()
	inst.name = root.name
	inst.mesh = mesh
	root.add_child(inst)
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_scene(root, state)
	# 【防"静默空壳"】编辑器进程下 `append_from_scene` 实测不导出网格（`state.get_meshes()` 为空），
	if err == OK and state.get_meshes().is_empty():
		err = ERR_UNAVAILABLE
	if err == OK:
		err = doc.write_to_filesystem(state, path)
	root.free()
	return err

## 世界求值 → 三角网格（实心 / 透明两个 surface）。
static func build_mesh(world: QVoxelWorld,
		voxel_scale := DEFAULT_VOXEL_SCALE) -> ArrayMesh:
	if world == null:
		return null
	# 直接判字典空否：先 solid_count() 再建字典等于把整个体积扫两遍（大模型是热点）。
	var voxels := _voxel_dict(QVoxelEvalEngine.evaluate_world(world, QVoxelEvalContext.new()))
	if voxels.is_empty():
		return null
	var materials := _materials(world)
	var arrays := NativeLoader.generate_arrays_native(voxels,
			VoxelMaterial.build_trans_flags(materials), voxel_scale, Vector3.ZERO)
	if arrays.is_empty():
		return null
	var mesh := ArrayMesh.new()
	# 两桶→surface 的装配是 VoxelMeshGenerator.append_arrays_to_mesh 的唯一实现
	if not VoxelMeshGenerator.append_arrays_to_mesh(
			mesh, arrays, VoxelMeshGenerator.generate_textured_materials_runtime(materials)):
		return null
	return mesh

# 内部

## 求值体积 → 稀疏体素字典（世界坐标 → 材质ID），供原生几何内核消费。
static func _voxel_dict(res: QVoxelEvalResult) -> Dictionary:
	var out := {}
	var vol := res.volume
	var gs := res.grid_size
	if gs.x <= 0 or gs.y <= 0 or gs.z <= 0 or vol.is_empty():
		return out
	var o := res.origin
	var plane := gs.x * gs.y
	var n := mini(vol.size(), plane * gs.z)
	for i in n:
		var m := vol[i]
		if m <= 0:
			continue
		var rest := i % plane
		var lx := rest % gs.x
		out[Vector3i(o.x + lx, o.y + (rest - lx) / gs.x, o.z + (i - rest) / plane)] = m
	return out

## 世界调色板（MATE 字典）→ VoxelMaterial 数组（索引 = 材质ID，0 恒为 null 空气占位）。
static func _materials(world: QVoxelWorld) -> Array:
	var out: Array = []
	out.resize(256)
	for i in range(1, 256):
		if i < world.materials.size() and world.materials[i] is Dictionary:
			out[i] = VoxelMaterial.from_mate(world.materials[i], i)
		else:
			var m := VoxelMaterial.new()
			m.id = i
			out[i] = m
	return out

static func _safe_name(name: String) -> String:
	var s := name.strip_edges()
	return s if not s.is_empty() else "voxel"

@tool
class_name QVoxelMeshExport
extends RefCounted
## 世界 → 三角网格 → glTF 2.0（`.glb` 二进制 / `.gltf` 文本 + 贴图）。
## 【为什么是 glTF】Godot 内核**唯一自带**的网格/场景交换格式就是 glTF 2.0（`GLTFDocument`）：
## `append_from_scene()` 把 Godot 场景转成 glTF 状态、`write_to_filesystem()` 按扩展名写出
## `.glb` 或 `.gltf`。OBJ / STL 等内核没有导出实现，要另引第三方插件，故这里只做 glTF。
## 【与渲染同源】体素几何走原生几何内核（与运行时/导入同一套贪婪面片），颜色走世界调色板
## （每材质 4 张 256×1 通道图），于是"导出结果"与"编辑器所见"一致。

## 支持的扩展名（文件对话框过滤 + 扩展名判定）。
const EXTENSIONS := ["glb", "gltf"]
## 一个体素的边长（世界单位）。1.0 = 一体素一单位，便于在 Blender 等里按整数对齐。
const DEFAULT_VOXEL_SCALE := 1.0


# 对外

## 世界 → glTF 文件（`.glb`/`.gltf` 由扩展名决定）。返回 Error。
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
	# 写出来会是个没有几何的 .glb。宁可明确报错，也不产出打不开的空文件。
	if err == OK and state.get_meshes().is_empty():
		err = ERR_UNAVAILABLE
	if err == OK:
		err = doc.write_to_filesystem(state, path)
	root.free()
	return err


## 世界求值 → 三角网格（实心 / 透明两个 surface）。空世界或几何内核不可用时返回 null。
static func build_mesh(world: QVoxelWorld,
		voxel_scale := DEFAULT_VOXEL_SCALE) -> ArrayMesh:
	if world == null:
		return null
	var res := QVoxelEvalEngine.evaluate_world(world, QVoxelEvalContext.new())
	if res.solid_count() == 0:
		return null
	var materials := _materials(world)
	var arrays := NativeLoader.generate_arrays_native(_voxel_dict(res),
			VoxelMaterial.build_trans_flags(materials), voxel_scale, Vector3.ZERO)
	if arrays.is_empty():
		return null
	var mesh := ArrayMesh.new()
	var mats := VoxelMeshGenerator.generate_textured_materials_runtime(materials)
	for i in 2:
		var prefix := "solid" if i == 0 else "trans"
		var sa := VoxelMeshGenerator._surface_arrays(arrays, prefix)
		if sa.is_empty():
			continue
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sa)
		mesh.surface_set_material(mesh.get_surface_count() - 1, mats[i])
	return mesh


# 内部

## 求值体积 → 稀疏体素字典（世界坐标 → 材质ID），供原生几何内核消费。
static func _voxel_dict(res: QVoxelEvalResult) -> Dictionary:
	var out := {}
	var gs := res.grid_size
	var o := res.origin
	var i := 0
	for z in gs.z:
		for y in gs.y:
			for x in gs.x:
				var m := res.volume[i]
				if m > 0:
					out[Vector3i(o.x + x, o.y + y, o.z + z)] = m
				i += 1
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

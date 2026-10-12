@tool
class_name VoxelMeshImporter
extends VoxelImportPluginBase

## `.vox` / `.qvx` → **单个静态网格**（ArrayMesh）。绝大多数用户的期望产物，故优先级最高。
## 选项定义见 VoxelImportOptions；分派与落盘见基类。

# 选项名 / 枚举的**兼容别名**（旧引用点仍可用）；权威定义在 VoxelImportOptions。
const Shape = VoxelImportOptions.Shape
const shape := VoxelImportOptions.SHAPE
const sphere_subdivisions := VoxelImportOptions.SPHERE_SUBDIVISIONS
const sphere_scale := VoxelImportOptions.SPHERE_SCALE
const frame_index := VoxelImportOptions.FRAME_INDEX
const scale := VoxelImportOptions.SCALE
const origin := VoxelImportOptions.ORIGIN
const unwrap_lightmap_uv2 := VoxelImportOptions.UNWRAP_UV2
const uv2_texel_size := VoxelImportOptions.UV2_TEXEL_SIZE
const import_materials_textures := VoxelImportOptions.IMPORT_MATERIALS_TEXTURES


func _get_importer_name():
	return "voxel_mesh"


func _get_visible_name():
	return "Voxel Mesh"


func _get_save_extension():
	return "mesh"


func _get_resource_type():
	return "Mesh"


## 网格是绝大多数用户的期望产物，故作为新文件的默认导入器（Noop=0、MeshLibrary=1.5 次之）。
func _get_priority() -> float:
	return 2.0


func _get_import_options(_path, _preset) -> Array[Dictionary]:
	return VoxelImportOptions.mesh_specs()


## 选项名 → 默认值：给拿不到插件实例的调用方（headless 测试 / 工具脚本）。
static func default_options() -> Dictionary:
	return VoxelImportOptions.defaults(VoxelImportOptions.mesh_specs())


## sphere_* 仅在形状为 sphere 时显示（依赖 shape 的 UPDATE_ALL_IF_MODIFIED 触发刷新，godot#49641）。
## frame_index 恒可见：可见性回调拿不到已解析资产，为它多 load 一次文件不值当。
func _get_option_visibility(_path: String, option_name: StringName, options: Dictionary) -> bool:
	if String(option_name).begins_with("mesh/sphere_"):
		return options.get(VoxelImportOptions.SHAPE, VoxelImportOptions.Shape.cube) == VoxelImportOptions.Shape.sphere
	return true


func _from_qvx(qvx, options, source_file) -> Resource:
	return VoxelMeshGenerator.generate_mesh_from_qvx(qvx, options, source_file)


func _from_vox(vox, options, source_file) -> Resource:
	return VoxelMeshGenerator.generate_mesh(vox, options, source_file)

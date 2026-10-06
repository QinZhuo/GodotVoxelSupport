@tool
class_name VoxelDataImporter
extends EditorImportPlugin

## 导入 .vox / .qvox 为 VoxelData (.res)
## 保存可序列化的体素数据，供 VoxelRenderer / VoxelDestructible 等运行时节点使用
## 不生成 mesh，仅保存原始体素数据，便于运行时动态修改和破坏
##
## 【按扩展名分派】两种源格式形状不同，各走各的适配器（详见 QVoxAsset 的类注释）：
##   .qvox → QVoxAsset（块级 + NODE 摆放）→ VoxelData.from_qvox
##   .vox  → VoxAsset（MagicaVoxel 场景图）→ VoxelData.from_voxel_data

## 选项名统一取自 VoxAsset 单一出处（与 VoxelMeshImporter 共用，避免同值重复定义）
const frame_index := VoxAsset.OPT_FRAME_INDEX
const scale := VoxAsset.OPT_SCALE
## 资产原点：与 VoxelMeshImporter 同名同义（原先是本类独有的 `mesh/center` 布尔，
## 只表达"居中/不居中"两态，无法表达"内容居中"与"保留作者摆放"——统一成三态枚举）。
const origin := VoxAsset.OPT_ORIGIN


func _get_importer_name():
	return 'voxel_data'


func _get_visible_name():
	return "Voxel Data Resource"


func _get_recognized_extensions():
	return VoxAsset.SUPPORTED_EXTENSIONS.duplicate()


func _get_save_extension():
	return "res"


func _get_resource_type():
	return "Resource"


func _get_priority() -> float:
	return 1.0


func _get_import_options(path, preset) -> Array[Dictionary]:
	return [
		{
			name = frame_index,
			default_value = 0,
		},
		{
			name = scale,
			default_value = 0.1,
		},
		{
			name = origin,
			default_value = VoxelData.OriginMode.BOTTOM_CENTER,
			property_hint = PropertyHint.PROPERTY_HINT_ENUM,
			hint_string = "bottom_center,content_center,keep",
		},
	]


## frame_index 对两种源格式都有效（都有"帧"的概念）：`.vox` 取动画帧；`.qvox` 取 NODE 里
## 第一段动画的 frames[] 下标——它是"该时刻各节点的局部变换覆盖值"，缺省 0 即起始姿态。
func _get_option_visibility(_path: String, _option_name: StringName, _options: Dictionary) -> bool:
	return true


func _import(source_file, save_path, options, _platforms, gen_files):
	var res: VoxelData
	if QVoxAsset.handles(source_file):
		var qvox := QVoxAsset.from_file(source_file, options[frame_index])
		if qvox == null:
			return FAILED
		res = VoxelData.from_qvox(qvox, options[origin])
	else:
		var voxel_data := VoxAsset.from_asset(source_file)
		if voxel_data == null:
			return FAILED
		res = VoxelData.from_voxel_data(voxel_data, options[frame_index], options[origin])
	res.default_scale = options[scale]
	return ResourceSaver.save(res, "%s.%s" % [save_path, _get_save_extension()])

@tool
class_name QVoxelSourceImporter
extends EditorImportPlugin

## 导入 .vox / .qvx 为 QVoxelSource (.res) —— **动态体素**路径（运行时逐格增删 / 破坏）。
## 保存可序列化的体素数据，供 VoxelRenderer / VoxelDestructible 等运行时节点使用；
## 不生成 mesh，仅保存原始体素数据，便于运行时动态修改和破坏。
## 【与 VoxelMeshImporter 的关系】两者都读同一份源文件，但产物不同：本导入器出**数据**
## （QVoxelSource），VoxelMeshImporter 出**静态网格**。只做静态展示的游戏用后者即可。
## 【按扩展名分派】两种源格式形状不同，各走各的适配器（详见 QVoxelAsset 的类注释）：
##   .qvx → QVoxelAsset（块级 + NODE 摆放）→ QVoxelSource.from_qvx
##   .vox  → VoxAsset（MagicaVoxel 场景图）→ QVoxelSource.from_voxel_data

## 选项名统一取自 VoxAsset 单一出处（与 VoxelMeshImporter 共用，避免同值重复定义）
const frame_index := VoxelImportOptions.FRAME_INDEX
const scale := VoxelImportOptions.SCALE
## 资产原点：与 VoxelMeshImporter 同名同义（原先是本类独有的 `mesh/center` 布尔，
## 只表达"居中/不居中"两态，无法表达"内容居中"与"保留作者摆放"——统一成三态枚举）。
const origin := VoxelImportOptions.ORIGIN


## 【importer id 保持 "voxel_data"】它是**序列化键**（每个 `.import` 里记着它），改名会让
## 既有资产全部找不到导入器而需重导；类名 / 文件名改了，这个稳定 id 不动。
func _get_importer_name():
	return "voxel_data"


func _get_visible_name():
	return "QVoxel Source Resource"


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
			# 与 Mesh 导入器同一默认值：默认不改动几何，要贴地居中再显式选 bottom_center。
			name = origin,
			default_value = QVoxelSource.OriginMode.WORLD_ORIGIN,
			property_hint = PropertyHint.PROPERTY_HINT_ENUM,
			hint_string = "world_origin,bottom_center,content_center",
		},
	]


## frame_index = 取哪一帧烤进这份 QVoxelSource：`.vox` 是 MagicaVoxel 的体素动画帧；
## `.qvx` 是 `ANIM` 帧动画（§12）。两者都产出**单帧静态快照**——静态 `.qvx` 只有第 0 帧，
## 该选项恒等于 0、无副作用。运行时连续播放仍不在本层（见 QVoxelSource.from_qvx 的注释）。
func _get_option_visibility(_path: String, _option_name: StringName, _options: Dictionary) -> bool:
	return true


func _import(source_file, save_path, options, _platforms, gen_files):
	var res: QVoxelSource
	if QVoxelAsset.handles(source_file):
		var qvx := QVoxelAsset.from_file(source_file)
		if qvx == null:
			return FAILED
		res = QVoxelSource.from_qvx(qvx, options[origin], options[frame_index])
	else:
		var voxel_data := VoxAsset.from_asset(source_file)
		if voxel_data == null:
			return FAILED
		res = QVoxelSource.from_voxel_data(voxel_data, options[frame_index], options[origin])
	res.default_scale = options[scale]
	return ResourceSaver.save(res, "%s.%s" % [save_path, _get_save_extension()])

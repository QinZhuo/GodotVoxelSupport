@tool
class_name VoxelImportOptions
extends RefCounted

## 导入选项的**单一出处**：选项名、枚举、各导入器的选项描述表、默认值。
## 【为什么独立成类】此前选项名一半在 `VoxAsset.OPT_*`、一半散在各插件里，枚举（Shape/MeshMode）
## 又在插件里；且 `default_options()` 必须逐子类重写（GDScript 静态派发不继承，见基类注释）。
## 集中到这里后：名字一份、表一份、默认值一份，且 headless（拿不到 `EditorImportPlugin` 实例）也能用。
## 【选项名是稳定键】它们落进每个 `.import` 文件，改名会让既有资产全部重导 —— 故只增不改。

## 体素网格形状。
enum Shape { cube, sphere }
## MeshLibrary 的分项方式。
enum MeshMode { split_by_model, split_by_node, split_by_frame }
## 分项网格的落盘策略。与 `ResourceImporterScene` 的 `materials/extract` 同构：
##   built_in         不落盘，每次导入全部重建（无散文件，改一项就会全量重算）
##   extract_once     落盘，未改动的项直接复用（跨导入的分项缓存）
##   extract_overwrite 落盘且每次覆盖（缓存命不命中都重算，用于验证生成逻辑）
enum Storage { built_in, extract_once, extract_overwrite }

# 选项名
const SCALE := "mesh/scale"
const ORIGIN := "mesh/origin"
const SHAPE := "mesh/shape"
const SPHERE_SUBDIVISIONS := "mesh/sphere_subdivisions"
const SPHERE_SCALE := "mesh/sphere_scale"
const FRAME_INDEX := "mesh/frame_index"
const UNWRAP_UV2 := "mesh/unwrap_lightmap_uv2"
const UV2_TEXEL_SIZE := "mesh/uv2_texel_size"
const IMPORT_MATERIALS_TEXTURES := "material/import_materials_textures"
const MESH_MODE := "mesh/mode"
## 旧键，保留为**兼容读取**：既有 `.import` 里存的是布尔。
## 选项名是落进 `.import` 的稳定键，只增不改 —— 新写入一律用 STORAGE。
const IMPORT_MESHES := "mesh/import_meshes"
const STORAGE := "mesh/storage"


## 网格导入器的选项表（VoxelMeshImporter 用）。
## 静态，故 headless/CI 也能读到与编辑器同一份定义。
static func mesh_specs() -> Array[Dictionary]:
	return [
		{
			name = SCALE,
			default_value = 0.1,
		},
		{
			# 资产原点：默认 world_origin = 原样保留文件坐标（升级不挪位）；要"X/Z 居中 + Y 贴底"
			# 这种游戏资产惯例，再显式选 bottom_center。与 QVoxelSourceImporter 同名同义。
			name = ORIGIN,
			default_value = VoxelWorldUtil.OriginMode.WORLD_ORIGIN,
			property_hint = PropertyHint.PROPERTY_HINT_ENUM,
			hint_string = "world_origin,bottom_center,content_center",
		},
		{
			name = SHAPE,
			default_value = Shape.cube,
			property_hint = PropertyHint.PROPERTY_HINT_ENUM,
			hint_string = "cube,sphere",
			# 修改 shape 时强制刷新全部选项可见性，否则编辑器不会重新调用 _get_option_visibility (godot#49641)
			usage = PropertyUsageFlags.PROPERTY_USAGE_DEFAULT | PropertyUsageFlags.PROPERTY_USAGE_UPDATE_ALL_IF_MODIFIED,
		},
		{
			name = SPHERE_SUBDIVISIONS,
			default_value = 0,
			property_hint = PropertyHint.PROPERTY_HINT_ENUM,
			hint_string = "20,80,320",
		},
		{
			name = SPHERE_SCALE,
			default_value = 1.0,
			property_hint = PropertyHint.PROPERTY_HINT_RANGE,
			hint_string = "0.05,2.0,0.05",
		},
		{
			name = FRAME_INDEX,
			default_value = 0,
		},
		{
			name = UNWRAP_UV2,
			default_value = false,
		},
		{
			name = UV2_TEXEL_SIZE,
			default_value = 0.2,
			property_hint = PropertyHint.PROPERTY_HINT_RANGE,
			hint_string = "0.01,100,0.001",
		},
		{
			name = IMPORT_MATERIALS_TEXTURES,
			default_value = false,
		},
	]


## MeshLibrary 导入器 = 网格选项 + 两项专属。
static func mesh_library_specs() -> Array[Dictionary]:
	var options := mesh_specs()
	options.append_array([
		{
			name = MESH_MODE,
			default_value = MeshMode.split_by_model,
			property_hint = PropertyHint.PROPERTY_HINT_ENUM,
			hint_string = "split_by_model,split_by_node,split_by_frame",
		},
		{
			name = STORAGE,
			default_value = Storage.extract_once,
			property_hint = PropertyHint.PROPERTY_HINT_ENUM,
			hint_string = "built_in,extract_once,extract_overwrite",
		},
	])
	return options


## 分项落盘策略（把两种历史形态归一到一个判据）。
## 优先级：新键 STORAGE 存在即用它；否则回退旧布尔 IMPORT_MESHES（true → extract_once）。
## 【为什么默认 extract_once】分项网格一旦落盘就能跨导入复用；不落盘时改一个模型会全量重建，
## 而"不产生散文件"这个理由在 `gen_files` 登记之后已不成立（产物由引擎代管清理）。
static func storage_of(options: Dictionary) -> int:
	if options.has(STORAGE):
		return int(options[STORAGE])
	return Storage.extract_once if bool(options.get(IMPORT_MESHES, false)) else Storage.built_in


## 该策略下分项要不要落盘。
static func storage_writes(storage: int) -> bool:
	return storage != Storage.built_in


## 该策略下缓存是否可以命中（extract_overwrite = 每次都重算）。
static func storage_reuses(storage: int) -> bool:
	return storage == Storage.extract_once


## 选项表 → {名: 默认值}（给拿不到插件实例的调用方：headless 测试 / 工具脚本）。
static func defaults(specs: Array[Dictionary]) -> Dictionary:
	var out := {}
	for o in specs:
		out[o["name"]] = o["default_value"]
	return out

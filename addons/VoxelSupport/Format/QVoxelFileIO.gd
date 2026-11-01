@tool
class_name QVoxelFileIO
extends RefCounted
## 体素文件 I/O 内核：**世界 ⇄ 字节 ⇄ 磁盘**，`.qvx`（工程）与 `.vox`（交换格式）共用一条接线。
## 【为什么下沉到插件层】编辑器、脚本、MCP 读写的是同一批文件；"按扩展名选格式"放这里之后
## 只有一份实现，编辑器那侧（QVoxelProject）只再补一层框架的原子写与备份回退。
## 【失败用返回值表达】读失败 null、写失败 false —— 调用方据此提示，坏文件不会打崩调用方。

const PROJECT_EXTENSION := "qvx"


# 路径判定

## 工程文件（`.qvx`），大小写不敏感。
static func is_project_path(path: String) -> bool:
	return path.get_extension().to_lower() == PROJECT_EXTENSION


## MagicaVoxel 文件（`.vox`）。
static func is_vox_path(path: String) -> bool:
	return path.get_extension().to_lower() == VoxAsset.VOX_EXTENSION


## 能由 load_world 打开：工程 + 外部 `.vox`。
static func is_openable(path: String) -> bool:
	return is_project_path(path) or is_vox_path(path)


## 补后缀（"另存为"没写扩展名时按工程 `.qvx` 补）。
static func ensure_extension(path: String) -> String:
	return path if is_openable(path) else path + "." + PROJECT_EXTENSION


# 编解码（不碰盘）

## 世界 → 字节。按**目标**扩展名分派：`.vox` 由 VoxWriter 校验并转成合规出口格式。
static func encode(world: QVoxelWorld, path := "") -> PackedByteArray:
	if world == null:
		return PackedByteArray()
	if is_vox_path(path):
		return VoxWriter.encode(world)
	return QVoxelFile.serialize(world.to_document())


## `.qvx` 字节 → 世界。
static func decode(bytes: PackedByteArray) -> QVoxelWorld:
	if bytes.is_empty():
		return null
	var doc := QVoxelFile.parse(bytes)
	return QVoxelWorld.from_document(doc) if doc != null else null


# 磁盘

## 文件 → 世界。`.vox` 经 VoxAssetWorld 烘焙成与 `.qvx` 同一套模型树，
## 于是"打开 MagicaVoxel 文件继续编辑"与"打开工程"是同一条路径。
static func load_world(path: String) -> QVoxelWorld:
	if path.is_empty() or not FileAccess.file_exists(path):
		return null
	if is_vox_path(path):
		var vox := VoxAsset.from_asset(path)
		return VoxAssetWorld.to_world(vox) if vox != null else null
	return decode(FileAccess.get_file_as_bytes(path))


## 世界 → 磁盘。`.vox` 不合规（超 256 / 非整数平移 / 朝向）时 encode 返回空，
## 这里据此拒绝落盘 —— 绝不写出一份打不开的文件。
static func save(world: QVoxelWorld, path: String) -> bool:
	if world == null or path.is_empty():
		return false
	var bytes := encode(world, path)
	if bytes.is_empty():
		return false
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("[QVX] 无法写入 %s：%s" % [path, error_string(FileAccess.get_open_error())])
		return false
	f.store_buffer(bytes)
	f.close()
	return true

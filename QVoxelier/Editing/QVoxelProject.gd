@tool
class_name QVoxelProject
extends RefCounted
## 工程文件读写（`.qvx` / `.vox`）：在 `QVoxelFileIO` 的字节层之上再套一层**落盘策略**。
## 【为什么还留这一层】格式分派（按扩展名选编码器、`.vox` 烘焙）已经下沉到插件层，
## 编辑器这边唯一多出来的是框架的 `SaveTool`（原子写 + 滚动备份 + 损坏回退）；
## 而 DEVFramework 与 VoxelSupport 两插件禁止互引，这条接线只能落在 QVoxelier 一侧。
## 【失败一律用返回值表达】读失败 null、写失败 Error / 空字节 —— 坏文件不该打崩应用。

const EXTENSION := QVoxelFileIO.PROJECT_EXTENSION


## 保存：世界 → 字节（按扩展名选编码器）→ 原子落盘（含滚动备份）。返回 Error。
static func save(world: QVoxelWorld, path: String) -> Error:
	if world == null or path.is_empty():
		return ERR_INVALID_PARAMETER
	var bytes := QVoxelFileIO.encode(world, path)
	if bytes.is_empty():
		return ERR_INVALID_DATA
	return SaveTool.save_data(path, bytes, SaveTool.Mode.BYTES)


## 读取：文件 → 字节 → 文档 → 世界。
## 【`decode` 交给 SaveTool】读得出来 ≠ 能用 —— 签名 / CRC / 结构校验只有格式层知道结果。
## 把判据交回去之后，"写坏了"与"读不出来"在框架眼里是同一种失败，都会退回上一次的存档。
static func load_world(path: String) -> QVoxelWorld:
	if path.is_empty() or not FileAccess.file_exists(path):
		return null
	if QVoxelFileIO.is_vox_path(path):
		return QVoxelFileIO.load_world(path)
	return SaveTool.load_data(path, SaveTool.Mode.BYTES, decode) as QVoxelWorld


## 世界 → `.qvx` 字节（不落盘）。导出、剪贴板、测试都用它。
static func encode(world: QVoxelWorld) -> PackedByteArray:
	return QVoxelFileIO.encode(world)


## 字节 → 世界（不读盘）。
static func decode(bytes: PackedByteArray) -> QVoxelWorld:
	return QVoxelFileIO.decode(bytes)


static func is_project_path(path: String) -> bool:
	return QVoxelFileIO.is_project_path(path)


## 是否可由 `load_world` 打开（`.qvx` 工程 + `.vox` 外部文件）。
static func is_openable(path: String) -> bool:
	return QVoxelFileIO.is_openable(path)


static func is_vox_path(path: String) -> bool:
	return QVoxelFileIO.is_vox_path(path)


## 补上缺失的后缀（已带 `.qvx` / `.vox` 就原样）。
static func ensure_extension(path: String) -> String:
	return QVoxelFileIO.ensure_extension(path)

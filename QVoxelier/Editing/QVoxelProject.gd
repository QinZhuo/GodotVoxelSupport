@tool
class_name QVoxelProject
extends RefCounted
## 工程文件（`.qvx`）读写：**世界 ⇄ 字节 ⇄ 磁盘** 这一段接线。
## 【为什么它在应用层】"编辑模型 ⇄ 传输结构"（`QVoxelWorld.to_document/from_document`）与
## "传输结构 ⇄ 字节"（`QVoxelFile`）都在插件里，缺的只是"字节 ⇄ 磁盘"。而这一步必须用框架的
## `SaveTool`（原子写 + 滚动备份 + 损坏回退）—— DEVFramework 与 VoxelSupport 两插件之间禁止
## 互引，所以这条接线只能在 QVoxelier 这一侧。
## 【为什么单独一类，而不是塞进视口】视口要知道的是"能不能打开 / 怎么提示用户"；
## "文件长什么样、写坏了怎么办"是另一个问题。分开之后本类无节点、无场景树、不碰界面，
## 于是往返、坏字节、备份回退这些边界都能在 TestCase 里逐条钉住（视口本身没有可测的纯逻辑）。
## 【失败一律用返回值表达】读失败返回 null、写失败返回 Error —— 调用方据此提示，
## 而不是让一个坏文件把整个应用打崩。

## 工程文件扩展名（"另存为"补后缀、拖放过滤都用它）。
const EXTENSION := "qvx"


# 对外

## 保存：世界 → 文档 → 字节 → 原子落盘（含滚动备份）。返回 Error。
static func save(world: QVoxelWorld, path: String) -> Error:
	if world == null or path.is_empty():
		return ERR_INVALID_PARAMETER
	return SaveTool.save_data(path, encode(world), SaveTool.Mode.BYTES)


## 读取：文件 → 字节 → 文档 → 世界。文件缺失 / 为空 / 不是合法 `.qvx` 一律返回 null。
## 【把 `decode` 交给 SaveTool，而不是"读完再自己校验"】读得出来 ≠ 能用：`.qvx` 的签名 / CRC /
## 结构校验是在**格式层**才知道结果的。若在框架外自己判，框架就只看到"字节读成功"，
## 永远不会去翻备份 —— 文件写坏了只能报错，而"原子写 + 滚动备份"等于白做。
## 把判据交回去之后，"写坏了"与"读不出来"在框架眼里是同一种失败，都退回上一次的存档。
static func load_world(path: String) -> QVoxelWorld:
	if path.is_empty() or not FileAccess.file_exists(path):
		return null
	return SaveTool.load_data(path, SaveTool.Mode.BYTES, decode) as QVoxelWorld


## 世界 → `.qvx` 字节（不落盘）。导出、剪贴板、测试都用它。
static func encode(world: QVoxelWorld) -> PackedByteArray:
	if world == null:
		return PackedByteArray()
	return QVoxelFile.serialize(world.to_document())


## 字节 → 世界（不读盘）。给"打开一份刚生成的字节"这类调用方用。
static func decode(bytes: PackedByteArray) -> QVoxelWorld:
	if bytes.is_empty():
		return null
	var doc := QVoxelFile.parse(bytes)
	if doc == null:
		return null
	return QVoxelWorld.from_document(doc)


## 扩展名判定（大小写不敏感）：给"另存为"补后缀、给拖放过滤。
static func is_project_path(path: String) -> bool:
	return path.get_extension().to_lower() == EXTENSION


## 补上缺失的 `.qvx` 后缀（已有就不动）。
static func ensure_extension(path: String) -> String:
	return path if is_project_path(path) else path + "." + EXTENSION

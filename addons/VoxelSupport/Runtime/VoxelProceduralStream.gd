@abstract
class_name VoxelProceduralStream
extends VoxelStream

## 程序化无限世界数据流【虚基类】：子类通过覆写 _generate_chunk(chunk_key)
## 实现自己的确定性生成算法（Minecraft 式无限世界）。
##
## 设计：
##   - 未修改 chunk：由子类 _generate_chunk 按 chunk key 程序化生成（确定性，可重复，零存储）
##   - 用户破坏的 chunk：save_chunk 记录修改，覆盖程序化数据
##   - 可选 persist_directory：修改的 chunk 复用 VoxelFileStream 写盘，重启保留破坏
##   - get_all_chunk_keys：只枚举修改的（无限世界不枚举程序化全部）
##
## 确定性要求：_generate_chunk 必须对同一 chunk_key 返回相同地形（如噪声 hash(chunk_key)），
## origin shift 平移 chunk key 后地形保持世界连续。
## 注意：基类为虚基类约定，直接实例化会报错——子类必须覆写 _generate_chunk。

## 修改持久化目录（可选）：用户破坏的 chunk 写盘，重启后保留。留空则修改仅存内存。
@export var persist_directory: String = ""

# 修改过的 chunk（破坏覆盖程序化）：chunk_key -> PackedInt32Array
var _modified: Dictionary = {}
# 可选文件持久化（复用 VoxelFileStream 的 region 存储）
var _file_stream: VoxelFileStream = null


func _init() -> void:
	if persist_directory != "":
		_file_stream = VoxelFileStream.new()
		_file_stream.directory = persist_directory


## 虚函数：按 chunk key 生成 16³ chunk 缓冲（值 = 材质ID，0=空）。
## 子类必须覆写实现生成算法；基类默认实现仅提示错误（抽象基类约定）。
@abstract 
func _generate_chunk(chunk_key: Vector3i) -> PackedInt32Array


## 从流加载 chunk。优先级：修改的 > 文件持久化 > 子类程序化生成。
func load_chunk(chunk_key: Vector3i) -> PackedInt32Array:
	if _modified.has(chunk_key):
		return _modified[chunk_key]
	if _file_stream and _file_stream.has_chunk(chunk_key):
		return _file_stream.load_chunk(chunk_key)
	return _generate_chunk(chunk_key)


## 保存 chunk（破坏写入）：记录修改，可选写盘。
func save_chunk(chunk_key: Vector3i, buffer: PackedInt32Array) -> void:
	_modified[chunk_key] = buffer
	if _file_stream:
		_file_stream.save_chunk(chunk_key, buffer)


## 无限世界任何 chunk 都可程序化生成（子类 _generate_chunk 覆写后）。
func has_chunk(chunk_key: Vector3i) -> bool:
	return true


## 移除 chunk（世界该处清空）：回退到程序化（清除修改记录）。
func erase_chunk(chunk_key: Vector3i) -> void:
	_modified.erase(chunk_key)
	if _file_stream:
		_file_stream.erase_chunk(chunk_key)


## 只枚举修改的 chunk（无限世界不枚举程序化全部）。
func get_all_chunk_keys() -> Array[Vector3i]:
	var keys: Array[Vector3i] = []
	for ck in _modified:
		keys.append(ck)
	if _file_stream:
		for ck in _file_stream.get_all_chunk_keys():
			if not keys.has(ck):
				keys.append(ck)
	return keys


## 平移 chunk key（origin shift 用）：所有修改/缓存 key 加偏移，保持世界坐标连续性。
func shift_origin(offset: Vector3i) -> void:
	var new_modified: Dictionary = {}
	for ck in _modified:
		new_modified[ck + offset] = _modified[ck]
	_modified = new_modified


func flush() -> void:
	if _file_stream:
		_file_stream.flush()


func get_stream_path() -> String:
	return persist_directory

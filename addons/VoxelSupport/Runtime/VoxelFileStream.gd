class_name VoxelFileStream
extends VoxelStream

## 磁盘文件流：把 chunk 数据持久化为独立二进制文件（每 chunk 一个文件）。
##
## 文件布局：
##   {directory}/{x}_{y}_{z}.vchunk
##   每文件 = 稀疏体素对 (local_index, mat_id)，local_index ∈ [0, 16³)
##   只存非空体素，空 chunk 不落盘（世界该处无数据）。
##
## 使用：
##   var stream := VoxelFileStream.new()
##   stream.directory = "user://voxel_world"
##   renderer.data_stream = stream
##
## 支持 user://、res:// 及 OS 绝对路径目录。默认目录为 user://voxel_data。

const CHUNK_VOLUME := VoxelChunk.CHUNK_VOLUME
const FILE_EXT := ".vchunk"
const FORMAT_VERSION := 1

## 存储目录（支持 user://、res:// 或绝对路径）
@export var directory: String = "user://voxel_data"


func _chunk_path(ck: Vector3i) -> String:
	return "%s/%d_%d_%d%s" % [directory, ck.x, ck.y, ck.z, FILE_EXT]


func _ensure_dir() -> void:
	var abs := ProjectSettings.globalize_path(directory)
	if not DirAccess.dir_exists_absolute(abs):
		DirAccess.make_dir_recursive_absolute(abs)


func save_chunk(chunk_key: Vector3i, buffer: PackedInt32Array) -> void:
	if buffer.is_empty():
		return
	# 稀疏化：只存非空体素 (local_index, mat_id)
	var voxel_list := PackedInt32Array()
	for i in CHUNK_VOLUME:
		var v: int = buffer[i]
		if v > 0:
			voxel_list.append(i)
			voxel_list.append(v)
	if voxel_list.is_empty():
		# 全空 chunk：不落盘（确保磁盘无残留）
		erase_chunk(chunk_key)
		return
	_ensure_dir()
	var f := FileAccess.open(_chunk_path(chunk_key), FileAccess.WRITE)
	if f == null:
		push_error("[VoxelFileStream] 无法写入 chunk %s: %s" % [chunk_key, error_string(FileAccess.get_open_error())])
		return
	f.store_32(FORMAT_VERSION)
	f.store_32(voxel_list.size() / 2)
	for v in voxel_list:
		f.store_32(v)
	f.close()


func load_chunk(chunk_key: Vector3i) -> PackedInt32Array:
	var path := _chunk_path(chunk_key)
	if not FileAccess.file_exists(path):
		return PackedInt32Array()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[VoxelFileStream] 无法读取 chunk %s: %s" % [chunk_key, error_string(FileAccess.get_open_error())])
		return PackedInt32Array()
	var version := f.get_32()
	if version != FORMAT_VERSION:
		f.close()
		push_error("[VoxelFileStream] 文件格式版本不兼容: %s (期望 %d, 实际 %d)" % [path, FORMAT_VERSION, version])
		return PackedInt32Array()
	var count := f.get_32()
	var buf := PackedInt32Array()
	buf.resize(CHUNK_VOLUME)
	for i in count:
		var idx := f.get_32()
		var mat := f.get_32()
		if idx >= 0 and idx < CHUNK_VOLUME and mat > 0:
			buf[idx] = mat
	f.close()
	return buf


func has_chunk(chunk_key: Vector3i) -> bool:
	return FileAccess.file_exists(_chunk_path(chunk_key))


func erase_chunk(chunk_key: Vector3i) -> void:
	var path := _chunk_path(chunk_key)
	if not FileAccess.file_exists(path):
		return
	var parent := path.get_base_dir()
	var d := DirAccess.open(parent)
	if d == null:
		push_error("[VoxelFileStream] 无法打开目录删除 chunk: %s" % parent)
		return
	var err := d.remove(path.get_file())
	if err != OK:
		push_error("[VoxelFileStream] 无法删除文件: %s (err=%d)" % [path, err])


func get_all_chunk_keys() -> Array[Vector3i]:
	var keys: Array[Vector3i] = []
	var dir := DirAccess.open(directory)
	if dir == null:
		return keys
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.ends_with(FILE_EXT):
			var stem := name.substr(0, name.length() - FILE_EXT.length())
			var parts := stem.split("_")
			if parts.size() == 3:
				keys.append(Vector3i(int(parts[0]), int(parts[1]), int(parts[2])))
		name = dir.get_next()
	dir.list_dir_end()
	return keys


func get_stream_path() -> String:
	return directory

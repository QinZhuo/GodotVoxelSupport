class_name VoxelPayloadCodec
extends RefCounted

## QVoxelSource 资源载荷的**帧格式唯一实现**：
##   Dictionary ⇄ base64( "GZIP" + gzip( var_to_bytes(dict) ) )
## 载荷随资源保存/加载（隐藏 storage 属性 `voxel_data_payload`），内容字典为
## `{v, grid_size, blocks}` —— 具体组装与回填在 QVoxelSource（`_encode_payload` /
## `_set`），本类只负责"过帧"与"拆帧 + 校验"。
## 【为什么 encode 不写版本号、decode 却校验版本】不对称是有意的：
## encode 处理的是**可信数据**（自己的内存状态），只保证内容原样过帧；
## decode 面对的是**不可信输入**（磁盘/场景文件可能被改坏、跨版本），必须校验。
## 版本号由内容字典的 "v" 承载，写入方用 VERSION 常量；encode 不干预内容，
## 于是测试也能用同一个 encode 造出"版本不符"的载荷，不必再复制一份帧格式。
## 【为什么不复用 DEVFramework.SaveTool.gzip_encode】帧格式确实同款（"GZIP" 魔数），
## 但 VoxelSupport 是**可独立拖入任意项目的插件**，对框架零依赖；为 8 行帧格式
## 反向依赖框架会破坏这条边界。此处保留同款约定，仅重复实现帧封装。
## 【版本策略】只此一版，不提供任何旧版读取路径 —— 载荷是私有存储属性
## （PROPERTY_USAGE_STORAGE），没有对外契约，格式变更时重新导入/保存即可；
## 读端保留兼容分支只会变成永久的负担。版本号仍在，是为了让"版本不符"当场变成
## 一条明确报错，而不是静默按新格式误读。

## 压缩魔数（"GZIP" 头，用于识别压缩格式；与 SaveTool 的约定一致）
const MAGIC := "GZIP"
## 载荷格式版本
const VERSION := 1


## 过帧：内容字典 → "GZIP" + gzip(var_to_bytes(data)) → base64 字符串
static func encode(data: Dictionary) -> String:
	var compressed := var_to_bytes(data).compress(FileAccess.COMPRESSION_GZIP)
	var out := MAGIC.to_utf8_buffer()
	out.append_array(compressed)
	return Marshalls.raw_to_base64(out)


## 拆帧：base64 → 校验魔数 → 解压 → 校验版本 → 内容字典。
## 任一环节不符即报错并返回 null（调用方按"载荷无效"处理，不猜着读）。
static func decode(value: String) -> Variant:
	if value.is_empty():
		return null
	var raw := Marshalls.base64_to_raw(value)
	# 魔数已在 base64 之前写入，故解出来必以 "GZ" 开头（校验它能挡住"非本格式的字符串"）。
	if raw.size() < 4 or raw[0] != 0x47 or raw[1] != 0x5A:  # "GZ"
		push_error("[VoxelPayloadCodec] 载荷缺少 GZIP 压缩头，载荷无效")
		return null
	var decompressed := raw.slice(4).decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
	if decompressed.is_empty():
		return null
	var data: Variant = bytes_to_var(decompressed)
	if not (data is Dictionary):
		return null
	if int((data as Dictionary).get("v", 0)) != VERSION:
		push_error("[VoxelPayloadCodec] 载荷版本 %s 不受支持（本版仅 %d），请重新导入/保存"
				% [(data as Dictionary).get("v"), VERSION])
		return null
	return data

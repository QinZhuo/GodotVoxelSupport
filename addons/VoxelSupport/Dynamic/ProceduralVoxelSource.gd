@tool
class_name ProceduralVoxelSource
extends QVoxelSource

## 程序化体素源的通用基类：子类只需覆写 generate(key, lod)。
##
## 普通 QVoxelSource 的四个判定都围绕 node/stream：
##   is_in_node_bounds / can_generate_chunk / is_streaming / generate
## 程序化源没有 node，少覆写任何一个都会静默空白。这里把"无限可造、按 key 流式生成"
## 作为基类默认，避免每个项目重复抄四份判定（VX-01/02/03）。
##
## 用法：
##   extends ProceduralVoxelSource
##   func generate(key: Vector3i, lod: int = 0) -> PackedInt32Array:
##       # 返回 VoxelChunk.CHUNK_VOLUME（lod=0）或 LOD_BLOCK_SIZE³（lod>=1）
##
## infinite 不在这里自动置 true：它决定 origin shift 语义，程序化绝对坐标世界应保持 false。

func is_in_node_bounds(_key: Vector3i, _lod: int = 0) -> bool:
	return true


func can_generate_chunk(_key: Vector3i, _lod: int = 0) -> bool:
	return true


func is_streaming() -> bool:
	return true

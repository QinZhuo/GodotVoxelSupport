@tool
class_name ProceduralVoxelSource
extends QVoxelSource

## 程序化体素源的通用基类：子类只需覆写 generate(key, lod)。

func is_in_node_bounds(_key: Vector3i, _lod: int = 0) -> bool:
	return true

func can_generate_chunk(_key: Vector3i, _lod: int = 0) -> bool:
	return true

func is_streaming() -> bool:
	return true

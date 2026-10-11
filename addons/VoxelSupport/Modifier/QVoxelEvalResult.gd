class_name QVoxelEvalResult
extends RefCounted

## 求值结果 —— 一棵节点树跑完之后的数据形态。
## 【去链之后只剩三样】产出体积、盒尺寸、盒在父画布里的偏移。程序化生成已整体移除，
## 求值不再有"链 / 域 / 检查点"这些概念。

## 产出体积（布局 = VoxelVolume.index_of）。空数组 = 该节点（或子树）没有任何可见体素。
var volume := PackedInt32Array()

## 本体积的 (0,0,0) 在**父画布**里的整数偏移 —— 由节点 offset 逐层累加得到。
var origin := Vector3i.ZERO

## 本次求值的盒尺寸（体素）。
var grid_size := Vector3i.ZERO

## 输入签名（节点身份 + 手绘版本号 + 网格 + 帧）。同签名可复用上一次结果；去链后仅作提示。
var input_signature := ""

## 本次求值的序号（QVoxelEvalContext.epoch）。
var epoch := 0


## 是否有可用体积。
func has_volume() -> bool:
	return not volume.is_empty()


## 实心体素数量（UI 状态栏用）。
func solid_count() -> int:
	var n := 0
	for m in volume:
		if m > 0:
			n += 1
	return n

class_name QVoxelEvalResult
extends RefCounted

## 求值结果 —— 一棵节点树跑完之后的数据形态。

## 产出体积（布局 = VoxelVolume.index_of）。
var volume := PackedInt32Array()

## 本体积的 (0,0,0) 在**父画布**里的整数偏移 —— 由节点 offset 逐层累加得到。
var origin := Vector3i.ZERO

## 本次求值的盒尺寸（体素）。
var grid_size := Vector3i.ZERO

## 输入签名（节点身份 + 手绘版本号 + 网格 + 帧）。
var input_signature := ""

## 本次求值的序号（QVoxelEvalContext.epoch）。
var epoch := 0

## 本次求值是否**被取消**（`QVoxelEvalContext.cancelled()` 在热循环里返回过 true）。
var cancelled := false

## 实心体素数量（UI 状态栏用）。
func solid_count() -> int:
	var n := 0
	for m in volume:
		if m > 0:
			n += 1
	return n

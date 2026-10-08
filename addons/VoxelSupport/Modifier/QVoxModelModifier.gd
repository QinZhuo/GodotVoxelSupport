@tool
class_name QVoxModelModifier
extends QVoxModifier

## 体素域（VOXEL）修改器（自足产出型）—— 算法核是一个 PcgModel，自己重建整块体素。
##
## 【为什么"自足产出"要单独一种子类】这类核（L-系统 / 元胞自动机 / WFC）不读既有体素，
## 它吐出的是一整块新体积，于是可以和前面的结果做并 / 差 / 交；而就地改写型
## （见 QVoxVolumeModifier）被调用时已经吃到了整块体积，引擎无法在事后替它做布尔。
## 这个区别在链校验（QVoxDomain.validate_chain）里是硬约束，所以必须是类型级的。

## 体素源算子。
@export var model: PcgModel


## 便捷构造（见 QVoxVolumeModifier.of）。
static func of(model_: PcgModel, combine_: QVoxDomain.Combine = QVoxDomain.Combine.REPLACE) -> QVoxModelModifier:
	var m := QVoxModelModifier.new()
	m.model = model_
	m.combine = combine_
	return m


func kind() -> String:
	return KIND_MODEL


func op() -> Resource:
	return model


func set_op(value: Resource) -> bool:
	model = value as PcgModel
	return model != null or value == null

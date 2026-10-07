@tool
class_name QVoxVolumeModifier
extends QVoxModifier

## 体素域（VOXEL）修改器（就地改写型）—— 算法核是一个 PcgDetail，直接改写既有体积。
##
## 【合成方式只能是「替换」】核被调用时整块体积已经是它的入参，引擎没有再插一脚的机会
## （见 QVoxModifier.is_source）。所以"挖洞""只削朝上面"这类形态决策必须由核自己决定，
## 链上只能声明"它是替换"。

## 体素处理算子。
@export var detail: PcgDetail


func kind() -> String:
	return KIND_VOLUME


func op() -> Resource:
	return detail


func set_op(value: Resource) -> bool:
	detail = value as PcgDetail
	return detail != null or value == null

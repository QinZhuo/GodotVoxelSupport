@tool
class_name QVoxVolumeModifier
extends QVoxModifier

## 体素域（VOXEL）修改器（就地改写型）—— 算法核是一个 PcgDetail，直接改写既有体积。
##
## 【合成方式只能是「替换」】核被调用时整块体积已经是它的入参，引擎没有再插一脚的机会
## （见 QVoxModifier.is_source）。所以"挖洞""只削朝上面"这类形态决策必须由核自己决定，
## 链上只能声明"它是替换"。

## 体素处理算子。
##
## 【挂核即校正 combine】「替换」是本类唯一合法的合成方式（见类注释与 QVoxDomain.chain_errors），
## 而基类默认值是「并集」。校正钉在赋值处，则造出非法条目的三条路径 —— 工厂、参数面板选中算子、
## 读盘 —— 一并收口：调用方不必记得"体素处理型要手动改 combine"，也不可能挂上一条自带红标的条目。
@export var detail: PcgDetail:
	set(v):
		detail = v
		combine = QVoxDomain.Combine.REPLACE


## 便捷构造：把已有算子直接包成链接目，省掉 new + 赋值三行样板。
## 链易读与否全看这里 —— 一条链能一眼读完，才谈得上"可插拔、可旁通"。
static func of(detail_: PcgDetail) -> QVoxVolumeModifier:
	var m := QVoxVolumeModifier.new()
	m.detail = detail_
	return m


func kind() -> String:
	return KIND_VOLUME


func op() -> Resource:
	return detail


func set_op(value: Resource) -> bool:
	detail = value as PcgDetail
	return detail != null or value == null

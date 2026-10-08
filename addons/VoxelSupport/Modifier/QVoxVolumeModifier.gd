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


## 便捷构造：把已有算子直接包成链接目，省掉 new + 赋值三行样板。
## 链易读与否全看这里 —— 一条链能一眼读完，才谈得上"可插拔、可旁通"。
##
## combine 固定为「替换」—— 这是本类**唯一合法**的取值（见类注释与 QVoxDomain.validate_chain），
## 而 QVoxModifier 的默认值是「并集」。工厂在这里把默认值校正到合法值：
## 新构造的条目直接就是合法链，调用方不必记得"体素处理型要手动改 combine"。
static func of(detail_: PcgDetail) -> QVoxVolumeModifier:
	var m := QVoxVolumeModifier.new()
	m.detail = detail_
	m.combine = QVoxDomain.Combine.REPLACE
	return m


func kind() -> String:
	return KIND_VOLUME


func op() -> Resource:
	return detail


func set_op(value: Resource) -> bool:
	detail = value as PcgDetail
	return detail != null or value == null

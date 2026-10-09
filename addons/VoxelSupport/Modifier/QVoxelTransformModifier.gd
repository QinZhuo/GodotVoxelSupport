@tool
class_name QVoxelTransformModifier
extends QVoxelModifier

## 体素域（VOXEL）修改器（**重排 / 摆放**型）—— 算法核是一个 PcgTransform，变换整块体积
## （镜像 / 旋转 90° / 平铺改盒尺寸；平移只改摆放）。
##
## 【为什么变换要入链（"万物皆修改器"）】把它做成独立功能模块时，"变换"是**第二个入口**：
## 不入链、不可旁通、改完即不可逆、也无法参数化。入链之后它自动获得链上的一切待遇 ——
## 可重排、可旁通、可撤销（一条属性命令改一个字段即可）、与其它修改器共用同一套面板 /
## 校验 / 落盘，于是"变换面板"这个第二入口可以整体删掉。
##
## 【摆放（平移）为什么也在这里，而不是节点字段】见 PcgTransform 类头。一句话：摆放与
## "对内容做一次变换"要回答的是同一组问题（顺序、旁通、撤销、落盘），分开存就等于两套答案。
##
## 【域恒为 VOXEL，且必然在 FIELD 段之后】它消费的是"已光栅化的当前累积结果"——
## 连续距离场谈不上"重排到格点上"（体素一旦光栅化就回不到连续域，见 QVoxelDomain）。
##
## 【合成方式恒为「替换」】整块结果的盒尺寸 / 摆放由它自己决定，谈不上"并进已累积结果"；
## 这条规则由 QVoxelDomain.chain_errors 统一报出（重排型不是源，见 QVoxelModifier.is_source）。

## 体素重排算子。
##
## 【挂核即校正 combine】同 QVoxelVolumeModifier：本类唯一合法的合成方式是「替换」，钉在赋值处。
@export var transform: PcgTransform:
	set(v):
		transform = v
		combine = QVoxelDomain.Combine.REPLACE


## 便捷构造（见 QVoxelVolumeModifier.of）。
static func of(transform_: PcgTransform) -> QVoxelTransformModifier:
	var m := QVoxelTransformModifier.new()
	m.transform = transform_
	return m


func kind() -> String:
	return KIND_TRANSFORM


func op() -> Resource:
	return transform


func set_op(value: Resource) -> bool:
	transform = value as PcgTransform
	return transform != null or value == null


## UI 显示名：优先自定义 label，其次算子的具体变换名（"镜像 X"比"PcgTransform"有用得多）。
func display_name() -> String:
	if not label.is_empty():
		return label
	return "（空修改器）" if transform == null else transform.display_name()

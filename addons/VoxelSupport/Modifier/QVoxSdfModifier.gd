@tool
class_name QVoxSdfModifier
extends QVoxModifier

## 连续域（FIELD）修改器 —— 算法核是一棵 SDF 表达式树。
##
## 【布尔放在树里，还是放在链上】两者都表达得出来，但**链上的布尔一律走 combine**：
## 并 / 差 / 交 / 平滑并回答的是"这一条怎么并进已有结果"，属于条目自身的属性；把
## SdfUnion / SdfSubtract 也当成链条目，只会让同一件事有两种画法。组合算子留给
## "一个修改器内部本来就是一棵子树"的场合（例如由十块拼成的岩石，希望它作为一个整体
## 被后面的修改器剪切）。

## 树的根。叶子是 SdfBox / SdfSphere 这类原语，内部节点是 SdfUnion / SdfSubtract 这类组合。
@export var field: Sdf


## 便捷构造（见 QVoxVolumeModifier.of）。combine 默认 REPLACE：链首一条 SDF 通常就是"定义模型"。
static func of(field_: Sdf, combine_: QVoxDomain.Combine = QVoxDomain.Combine.REPLACE) -> QVoxSdfModifier:
	var m := QVoxSdfModifier.new()
	m.field = field_
	m.combine = combine_
	return m


func kind() -> String:
	return KIND_SDF


func op() -> Resource:
	return field


func set_op(value: Resource) -> bool:
	field = value as Sdf
	return field != null or value == null

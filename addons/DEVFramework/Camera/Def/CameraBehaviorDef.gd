@tool
## 机位行为: 描述机位如何根据目标计算出自己的姿态。
##
## 这是相机模块唯一的扩展点。框架只提供两件事:
## [br]1. [member VirtualCamera3D.target] —— 目标节点(在机位上直接拖, 符合 Godot 原生体验)
## [br]2. [method apply] —— 在机位姿态求解阶段被调用
##
## 具体算法交给 Resource 子类: 框架内置跟随与朝向两种, 项目可任意继承扩展。
## 行为是资源, 因此能在 Inspector 里选类型 / 配参数, 也能跨机位复用同一份配置。
##
## 大多数机位是固定取景, 不需要挂任何行为 —— 此时机位的 Inspector 非常干净。
##
## 自定义示例:
## [codeblock]
## class_name OrbitBehaviorDef extends CameraBehaviorDef
##
## @export var radius: float = 5.0
##
## func apply(vcam: VirtualCamera3D, delta: float, instant: bool = false) -> void:
##     var t := vcam.target
##     if t == null:
##         return
##     vcam.global_position = t.global_position + vcam.global_basis.z * radius
## [/codeblock]
##
## 注意: 行为是可被多个机位共享的配置资源, 因此[b]不得存放运行时状态[/b](与 [Def] 同源的约定)。
## 需要按机位累积的量(如抖动相位)请向宿主机位取, 见 [method VirtualCamera3D.get_behavior_time]。
class_name CameraBehaviorDef extends Resource


## 求解机位姿态(可写 vcam 的 transform)。由 VirtualCamera3D 每帧按 behaviors 顺序调用。
## [br]vcam: 宿主机位; delta: 帧间隔(秒); instant: true 表示忽略阻尼立刻到位
## ([method VirtualCamera3D.snap_pose] 与冷机位上台时)
func apply(vcam: VirtualCamera3D, delta: float, instant: bool = false) -> void:
	pass


## 在机位基础姿态之上叠加偏移并返回新姿态, [b]不写回节点[/b]。用于手持抖动这类"只影响画面、
## 不该污染场景 transform 也不该反馈给跟随计算"的效果。由 [method VirtualCamera3D.get_pose] 调用。
## [br]与 [method apply] 的分工: apply 写节点(决定机位在哪), apply_offset 只修饰输出画面。
func apply_offset(vcam: VirtualCamera3D, pose: Transform3D) -> Transform3D:
	return pose


## 本机位正在瞄准的点, 用于球面/柱面混合的枢纽点。
## 默认返回 null(不提供枢纽点); 有"朝向"语义的行为应重写此方法。
## 返回 null 时 Brain 会退回自己的 blend_pivot, 再没有则退化为直线混合。
func get_aim_point(vcam: VirtualCamera3D) -> Variant:
	return null

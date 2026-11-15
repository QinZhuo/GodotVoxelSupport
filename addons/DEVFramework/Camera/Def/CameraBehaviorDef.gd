@tool
## 机位行为: 描述机位如何根据目标计算出自己的姿态。
## 这是相机模块唯一的扩展点。框架只提供两件事:
## 注意: 行为是可被多个机位共享的配置资源, 因此[b]不得存放运行时状态[/b](与 [Def] 同源的约定)。
class_name CameraBehaviorDef extends Resource


## 求解机位姿态(可写 vcam 的 transform)。由 VirtualCamera3D 每帧按 behaviors 顺序调用。
func apply(vcam: VirtualCamera3D, delta: float, instant: bool = false) -> void:
	pass


## 在机位基础姿态之上叠加偏移并返回新姿态, [b]不写回节点[/b]。用于手持抖动这类"只影响画面、
func apply_offset(vcam: VirtualCamera3D, pose: Transform3D) -> Transform3D:
	return pose


## 本机位正在瞄准的点, 用于球面/柱面混合的枢纽点。
func get_aim_point(vcam: VirtualCamera3D) -> Variant:
	return null

@tool
@abstract
## 任务定义抽象基类。子类：SignalTaskDef（信号驱动）、CountTaskDef（计数驱动）、GroupTaskDef（分组）。
class_name TaskDef extends EntityDef

## 任务状态
enum Status {
	INACTIVE, ## 未激活(初始/已停用, 等待重新 activate)
	ACTIVE, ## 进行中, 正在监听完成信号
	COMPLETED, ## 已完成(终态)
	FAILED, ## 已失败(终态: 超时/判定不通过)
	CANCELLED, ## 已取消(终态: 玩家放弃/被替换)
}

## 创建对应的任务实体
@abstract func create_entity() -> Task

## 前置条件: 非空时, activate() 仅在条件满足后才真正激活;
## 未满足则保持 INACTIVE 并发 blocked(由外部决定重试时机, 如界面点亮/前置任务完成)。
@export var prerequisite: ConditionDef

## 跳过条件(门控): 激活时条件已满足则视为"已达成"直接完成并推进 —— 教程"老玩家跳过前几步"、
## 任务"背包里已有材料则该目标直接完成"。视为达成会正常执行 next; 不想执行 next 请改用入口分流。
## 配在 GroupTaskDef 上 = 整组跳过(子任务静默完成, 不执行子任务 next)。
@export var skip_if: ConditionDef

## 任务完成后执行的操作(单个, 也可以是任务奖励): complete() 时 apply(context)。
## 语义是"任务结束做一次什么" —— 既可发奖励, 也可做任意副作用/衔接下一段逻辑。
## 需要级联多个效果时用 EffectsDef 打包, 或多个任务通过后续编排串联。
@export var next: EffectDef

func get_desc(_data) -> String:
	return tr(str(name, "_desc"))

func _to_string() -> String:
	return str(tr(name),get_desc(null))

func get_csv_path() -> String:
	return "res://Assets/Translation/task.csv"

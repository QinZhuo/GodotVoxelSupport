@tool
class_name TownStepDef extends Resource
## 城镇生成步骤基类 — 可插拔、自包含的生成阶段
##
## 每个 Step 子类:
##   · @export 自含全部本阶段参数（策划在 Inspector 直接调参）
##   · 重写 apply(ctx) 实现阶段逻辑（读写 TownGenContext 共享数据）
## · 不同 steps 组合 + 参数 = 不同风格城镇
## · 新增内容类型：新建一个 Step 资源即可，核心编排零改动
##
## 参考: Minecraft Feature 注册表 / RimWorld GenStep / UE5 PCG 图节点

## 是否启用本步骤（false = 跳过，不执行）
@export var enabled := true
## 步骤显示名（编辑器/调试用）
@export var step_name := ""


func apply(_ctx: TownGenContext) -> void:
	pass


func step_id() -> String:
	if not step_name.is_empty():
		return step_name
	return String(get_script().resource_path).get_file().get_basename()

@tool
## 游戏命令：一次玩家/AI 决策或操作的记录单元（命令即数据）。
## 序列化后可用于回放、战绩审计与 headless 自动化测试。
class_name GameCommand extends RefCounted

## 命令类型，如 &"use_equip"、&"levelup_pick"
var type: StringName = &""
## 通用时序序号（回合制游戏下为回合号/tick；其他场景可自定义含义）
var tick: int = -1
## 决策参数（按操作顺序：点选的列号/目标格/选项序号...；首个参数惯例为命令主体标识）
var params: Array = []

func _init(p_type: StringName = &"", p_tick: int = -1, p_params: Array = []) -> void:
	type = p_type
	tick = p_tick
	params.assign(p_params)

func save_data() -> Dictionary:
	return {type = type, tick = tick, params = params.duplicate(true)}

## 从存档字典还原；非字典输入返回空命令（调用方决定如何兜底）
static func load_data(data) -> GameCommand:
	var cmd := GameCommand.new()
	if data is Dictionary:
		cmd.type = StringName(str(data.get("type", data.get("action", ""))))
		cmd.tick = int(data.get("tick", data.get("index", -1)))
		var p = data.get("params", [])
		if p is Array:
			cmd.params.assign(p)
	return cmd

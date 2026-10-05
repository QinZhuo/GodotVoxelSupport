@tool
class_name CommandHistory extends RefCounted

## 会话命令日志：按序记录 GameCommand，支持按 tick 过滤与序列化。
## 由实战答案源在命令成功后写入；回放器据此重放。

var commands: Array[GameCommand] = []

func append(cmd: GameCommand) -> void:
	assert(not commands.has(cmd), "CommandHistory: 重复追加同一条命令")
	commands.append(cmd)

func size() -> int:
	return commands.size()

## 取指定 tick 的全部命令（保持记录顺序）
func commands_for(tick: int) -> Array[GameCommand]:
	var result: Array[GameCommand] = []
	for cmd in commands:
		if cmd.tick == tick:
			result.append(cmd)
	return result

func clear() -> void:
	commands.clear()

func is_empty() -> bool:
	return commands.is_empty()

func save_data() -> Array:
	var out := []
	for cmd in commands:
		out.append(cmd.save_data())
	return out

func load_data(data) -> void:
	commands.clear()
	if data is Array:
		for entry in data:
			commands.append(GameCommand.load_data(entry))

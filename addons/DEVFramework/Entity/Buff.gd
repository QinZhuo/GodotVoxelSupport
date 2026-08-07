class_name Buff extends Entity

var def: BuffDef

var tags: Array[BuffTagDef]:
	get(): return def.tags

var data

var stacks: int:
	set(value):
		value = max(value, 0)
		if stacks != value:
			if value > 0 and stacks <= 0:
				if def.effect:
					def.effect.apply(data)
			elif value <= 0 and stacks > 0:
				if def.effect:
					def.effect.revert(data)
			var old := stacks
			stacks = value
			stacks_changed.emit(value - old)

signal stacks_changed(offset: int)

func reset():
	stacks = 0

func save_data():
	return {
		name = def.name,
		stacks = stacks
	}

func get_desc(data) -> String:
	return def.get_desc(data)

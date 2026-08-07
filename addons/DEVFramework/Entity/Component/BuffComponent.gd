class_name BuffComponent extends Component

@export_dir var defs_dir: String = "res://Assets/Def/Buff"

signal buff_changed(buff: Buff, offset: int)

var buffs: Array[Buff] = []
var context_provider: Callable

func get_def(buff_name: String) -> BuffDef:
	return load(defs_dir.path_join(buff_name + ".tres"))

func get_buff(buff_name: String) -> Buff:
	for buff in buffs:
		if buff.def.name == buff_name:
			return buff
	var def: BuffDef = get_def(buff_name)
	var buff = Buff.new(def)
	if context_provider.is_valid():
		buff.data = context_provider.call(buff)
	buffs.append(buff)
	buff.stacks_changed.connect(_on_buff_stacks_changed.bind(buff))
	return buff

func get_stacks(buff_name: String) -> int:
	for buff in buffs:
		if buff.def.name == buff_name:
			return buff.stacks
	return 0

func _on_buff_stacks_changed(offset: int, buff: Buff):
	buff_changed.emit(buff, offset)

func add_stacks(buff_name: String, stacks: int):
	if not is_multiplayer_authority(): return
	var buff := get_buff(buff_name)
	buff.stacks += stacks

func remove_stacks(buff_name: String, stacks: int):
	if not is_multiplayer_authority(): return 0
	for buff in buffs:
		if buff.def.name == buff_name:
			var last_stacks = buff.stacks
			buff.stacks -= stacks
			return last_stacks - buff.stacks
	return 0

func clear_stacks(buff_name: String):
	remove_stacks(buff_name, get_stacks(buff_name))

func clear():
	for buff in buffs:
		buff.stacks = 0

func game_ready():
	clear()

func save_data():
	var data := []
	for buff in buffs:
		if buff.stacks > 0:
			data.append(buff.save_data())
	return data

func load_data(data):
	clear()
	if not data:
		return
	for buff_data in data:
		add_stacks(buff_data.name, buff_data.stacks)

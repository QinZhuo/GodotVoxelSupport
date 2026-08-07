class_name AttributeComponent extends Component

@export_dir var defs_dir: String = "res://Assets/Def/Attribute"

signal attribute_changed(attribute: ModifierValue, modifier: Modifier)

var attributes: Array[ModifierValue] = []

func get_def(attribute_name: String) -> AttributeDef:
	var path := defs_dir.path_join(attribute_name + ".tres")
	if not ResourceLoader.exists(path):
		printerr("属性资源不存在: ", path)
		return null
	return load(path)

func get_attribute(attribute_name: String) -> ModifierValue:
	for attribute in attributes:
		if attribute.def.name == attribute_name:
			return attribute
	var def: AttributeDef = get_def(attribute_name)
	if not def:
		return null
	var attribute = ModifierValue.new(def)
	attributes.append(attribute)
	attribute.value_changed.connect(_on_attr_value_changed.bind(attribute))
	return attribute

func _on_attr_value_changed(modifier: Modifier, attr: ModifierValue):
	attribute_changed.emit(attr, modifier)

func add_modifier(attr_name: String, modifier: Modifier, immediate: bool = false):
	if immediate:
		get_attribute(attr_name).apply_modifier(modifier)
	else:
		get_attribute(attr_name).add_modifier(modifier)

func remove_modifiers(source):
	for attr in attributes:
		attr.remove_modifiers(source)

func clear_modifiers(source = null):
	for attr in attributes:
		attr.clear_modifiers(source)

func game_ready():
	clear()

func clear():
	for attribute in attributes:
		attribute.reset()

func save_data():
	var data := {}
	for attr in attributes:
		data[attr.def.name] = attr.base_value
	return data

func load_data(data):
	if not data:
		return
	clear()
	for attr_name in data:
		var attr := get_attribute(attr_name)
		if not attr:
			continue
		attr.base_value = data[attr_name]

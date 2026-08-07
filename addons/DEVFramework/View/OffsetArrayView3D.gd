@tool
class_name OffsetArrayView3D extends SlotArrayView3D

@export var offset: Vector3

func _ready():
	super ()
	update_layout()
	child_entered_tree.connect(_on_child_entered)
	child_exiting_tree.connect(_on_child_exiting)

func _on_child_entered(node: Node):
	if node is Node3D:
		node.visibility_changed.connect(_on_visibility_changed)
	update_layout.call_deferred()

func _on_child_exiting(node: Node):
	if node is Node3D and node.visibility_changed.is_connected(_on_visibility_changed):
		node.visibility_changed.disconnect(_on_visibility_changed)
	update_layout.call_deferred()

func _on_visibility_changed():
	update_layout.call_deferred()

func _update_slot_visibility():
	super._update_slot_visibility()
	update_layout()

func update_layout():
	var slots := get_children()
	var visible_slots: Array[Node3D] = []
	for child in slots:
		if child is Node3D and child.visible:
			visible_slots.append(child)
	var count := visible_slots.size()
	if count == 0:
		return
	var total := offset * (count - 1)
	var start_pos := -total / 2.0
	for i in count:
		var slot := visible_slots[i]
		slot.position = start_pos + offset * i

func _validate_property(_property: Dictionary) -> void:
	update_layout()

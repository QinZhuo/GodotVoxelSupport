@tool
class_name OffsetArrayView3D extends SlotArrayView3D

## 相邻槽位的位移向量（含方向 ⇒ 可以斜排 / 纵深排）
@export var offset: Vector3:
	set(value):
		offset = value
		update_layout()

## 原点语义：true（默认）= 当前位置是整排**中点**；false = 当前位置是**第一项的槽位**。
@export var centered: bool = true:
	set(value):
		centered = value
		update_layout()

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
	var visible_slots: Array[Node3D] = []
	for slot in _get_slots():
		if slot.visible:
			visible_slots.append(slot)
	var count := visible_slots.size()
	if count == 0:
		return
	var total := offset * (count - 1)
	var start_pos := Vector3.ZERO
	if centered:
		start_pos = -total / 2.0
	for i in count:
		var slot := visible_slots[i]
		slot.position = start_pos + offset * i


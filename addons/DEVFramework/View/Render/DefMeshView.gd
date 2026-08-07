@tool
class_name DefMeshView extends Node3D

@export var def: Def:
	set(value):
		def = value
		if not def:
			return
		if 'mesh' in def:
			mesh = def.mesh
		elif def_mesh.has(def):
			mesh = def_mesh[def]

@export var def_mesh: Dictionary[Def, ArrayMesh]

@export var mesh: ArrayMesh:
	set(value):
		if value == mesh:
			return
		_remove_view()
		mesh = value
		_add_view()

var view: MeshInstance3D

## 存储在 view 上的 material_overlay，view 重建后自动恢复
var _saved_overlay: Material = null

## 存储在 view 上的 material_override，view 重建后自动恢复
var _saved_override: Material = null

func _ready():
	if Engine.is_editor_hint():
		return
	await get_tree().process_frame
	if not mesh or not view:
		return
	var pool := BakedPoolManager.find_pool(_get_pool_key())
	if pool and not pool.used_items.has(view):
		_remove_view()
		_add_view()

func _enter_tree():
	_add_view()

func _exit_tree():
	_remove_view()

func _get_pool_key() -> String:
	return mesh.resource_path.get_file().get_basename()

func _add_view():
	if not mesh or view:
		return
	view = BakedPoolManager.pool_get(_get_pool_key())
	if not view:
		view = MeshInstance3D.new()
		view.mesh = mesh
	add_child(view)
	# view 重建后恢复之前保存的材质状态
	if _saved_overlay:
		view.material_overlay = _saved_overlay
	if _saved_override:
		view.material_override = _saved_override

func _remove_view():
	if not view:
		return
	# 保存当前材质状态，以便 view 重建后恢复
	_saved_overlay = view.material_overlay
	_saved_override = view.material_override
	# 清除可能残留的 material_overlay（对象池复用时避免发光效果残留）
	view.material_overlay = null
	view.material_override = null
	if mesh:
		BakedPoolManager.pool_push(_get_pool_key(), view)
	else:
		view.queue_free()
	view = null

@tool
class_name DefMeshView extends BakedMeshInstance3D

@export var def: Def:
	set(value):
		def = value
		if def == null:
			return
		if 'mesh' in def:
			_show(def.mesh)
		elif def_mesh.has(def):
			_show(def_mesh[def])

@export var def_mesh: Dictionary[Def, ArrayMesh]

## 换网格：先摘旧光，新网格的 surface 才不会被上一份光照顶着
func _show(value: ArrayMesh) -> void:
	if value == mesh:
		return
	AssetLightmapBinder.clear(self)
	mesh = value
	apply_lightmap()

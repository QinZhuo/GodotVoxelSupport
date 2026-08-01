@tool
class_name VoxelRaymarchMultiRenderer
extends MultiMeshInstance3D

## GPU 光线步进体素渲染器（MultiMesh 批处理版）
## 使用 MultiMeshInstance3D 批量渲染多个同构体素体积
## 所有实例共享同一份体素数据，仅变换不同
## 适合大量相同体素模型的场景（如树木、石块、建筑等）

## 体素数据源
@export var data: VoxelDataResource:
	set(v):
		if data != v:
			if data and data.changed.is_connected(_on_data_changed):
				data.changed.disconnect(_on_data_changed)
			data = v
			if data:
				data.changed.connect(_on_data_changed)
			_update_all()

## 每个体素的世界单位大小（基础值，实例变换可叠加缩放）
@export var voxel_scale: float = 0.1:
	set(v):
		voxel_scale = v
		_update_mesh(_get_grid_size())

## 编辑器内实时更新
@export var update_in_editor: bool = true

## 最大材质数量
const MAX_MATERIALS: int = 256

var _mat: ShaderMaterial
var _voxel_texture: Texture3D
var _transforms: Array[Transform3D] = []


func _ready() -> void:
	_update_all()


func _get_grid_size() -> Vector3i:
	if data and data.grid_size.x > 0 and data.grid_size.y > 0 and data.grid_size.z > 0:
		return data.grid_size
	
	var max_pos := Vector3i(1, 1, 1)
	if data:
		for pos in data.voxels.keys():
			max_pos.x = max(max_pos.x, pos.x + 1)
			max_pos.y = max(max_pos.y, pos.y + 1)
			max_pos.z = max(max_pos.z, pos.z + 1)
	return max_pos


func _update_all() -> void:
	var gs := _get_grid_size()
	_update_mesh(gs)
	_update_texture(gs)
	_update_materials()
	_update_instances()


func _update_mesh(gs: Vector3i) -> void:
	if not data or gs.x <= 0 or gs.y <= 0 or gs.z <= 0:
		return
	
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(gs) * voxel_scale
	
	# 创建或更新 MultiMesh
	if not multimesh:
		multimesh = MultiMesh.new()
	multimesh.mesh = box_mesh
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = false
	multimesh.use_custom_data = false


func _update_texture(gs: Vector3i) -> void:
	if not data or gs.x <= 0 or gs.y <= 0 or gs.z <= 0:
		_voxel_texture = null
		if _mat:
			_mat.set_shader_parameter("voxel_data", null)
		return
	
	# 创建 3D 纹理：每个纹素存储材质 ID (R8)
	var images: Array[Image] = []
	images.resize(gs.z)
	
	for z in gs.z:
		var img := Image.create(gs.x, gs.y, false, Image.FORMAT_R8)
		for y in gs.y:
			for x in gs.x:
				var pos := Vector3i(x, y, z)
				var id := data.get_voxel(pos)
				if id < 0:
					id = 0
				img.set_pixel(x, y, Color(id / 255.0, 0.0, 0.0, 0.0))
		images[z] = img
	
	_voxel_texture = ImageTexture3D.new()
	_voxel_texture.create(Image.FORMAT_R8, gs.x, gs.y, gs.z, false, images)
	
	_get_or_create_material()
	_mat.set_shader_parameter("voxel_data", _voxel_texture)
	_mat.set_shader_parameter("voxel_grid_size", gs)
	_mat.set_shader_parameter("voxel_scale", voxel_scale)


func _update_materials() -> void:
	if not data or data.materials.is_empty():
		return
	
	var colors := PackedColorArray()
	var pbrs := PackedColorArray()
	colors.resize(MAX_MATERIALS)
	pbrs.resize(MAX_MATERIALS)
	
	colors[0] = Color(0, 0, 0, 0)
	pbrs[0] = Color(0, 0, 0, 0)
	
	for i in min(data.materials.size(), MAX_MATERIALS):
		var mat := data.materials[i] as VoxelMaterial
		if not mat:
			continue
		colors[i] = Color(mat.color.r, mat.color.g, mat.color.b, 1.0 - mat.trans)
		pbrs[i] = Color(mat.metal, mat.rough, mat.emission, 0.0)
	
	_get_or_create_material()
	_mat.set_shader_parameter("material_colors", colors)
	_mat.set_shader_parameter("material_pbrs", pbrs)


func _update_instances() -> void:
	if not multimesh:
		return
	multimesh.instance_count = _transforms.size()
	for i in _transforms.size():
		multimesh.set_instance_transform(i, _transforms[i])


func _get_or_create_material() -> void:
	if _mat:
		return
	
	var shader := preload("res://addons/VoxelSupport/Shaders/voxel_raymarch.gdshader")
	_mat = ShaderMaterial.new()
	_mat.shader = shader
	material_override = _mat


# ---- 公开实例管理 API ----

## 添加一个实例，返回实例索引
func add_instance(transform: Transform3D) -> int:
	_transforms.append(transform)
	_update_instances()
	return _transforms.size() - 1


## 移除指定索引的实例
func remove_instance(index: int) -> void:
	if index >= 0 and index < _transforms.size():
		_transforms.remove_at(index)
		_update_instances()


## 批量设置所有实例
func set_instances(transforms: Array[Transform3D]) -> void:
	_transforms = transforms.duplicate()
	_update_instances()


## 获取所有实例变换
func get_instances() -> Array[Transform3D]:
	return _transforms.duplicate()


## 获取实例数量
func get_instance_count() -> int:
	return _transforms.size()


## 清空所有实例
func clear_instances() -> void:
	_transforms.clear()
	if multimesh:
		multimesh.instance_count = 0


# ---- 信号处理 ----

func _on_data_changed() -> void:
	var gs := _get_grid_size()
	_update_texture(gs)
	_update_materials()


func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		if data and data.changed.is_connected(_on_data_changed) == false:
			data.changed.connect(_on_data_changed)
		_update_all()
	
	if what == NOTIFICATION_EXIT_TREE:
		if data and data.changed.is_connected(_on_data_changed):
			data.changed.disconnect(_on_data_changed)
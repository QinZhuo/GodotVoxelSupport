@tool
@warning_ignore("INTEGER_DIVISION")
class_name BakedPoolManager extends Node3D

static var singleton: BakedPoolManager

static func find_pool(key: String) -> BakedPool:
	if not singleton:
		return null
	return singleton.find_child(key, false)

static func pool_get(key: String) -> Node3D:
	if singleton:
		var pool := singleton.find_child(key, false)
		if pool is BakedPool:
			return pool.pool_get()
		printerr("不存在[", key, "]对象池 ")
	return null

static func pool_push(key: String, item: Node3D):
	if not item:
		return
	if Engine.is_editor_hint():
		item.queue_free()
		return
	if singleton:
		var pool := singleton.find_child(key, false)
		if pool is BakedPool:
			pool.pool_push(item)
			return
	printerr("不存在[", key, "]对象池 ")
	item.queue_free()

func _enter_tree() -> void:
	singleton = self

@export var mesh_pool: Array[ArrayMesh]

@export var scene_pool: Array[PackedScene]

@export_dir var pool_dir: Array[String]

@export var pool_min_size: int = 3

@export var gap: float = 10.0

const SIZE = 10

@export_tool_button("刷新对象池") var create_pools_button = _create_pools

func _create_pools() -> void:
	if not Engine.is_editor_hint():
		return

	var layout := {x = 0.0, z = 0.0, placed_count = 0}

	# 先处理手动指定的资源（优先级更高）
	for mesh in mesh_pool:
		if not mesh:
			continue
		var pool := _create_or_update_mesh_pool(mesh)
		if pool:
			_layout_pool(pool, layout)

	for scene in scene_pool:
		if not scene:
			continue
		var pool := _create_or_update_scene_pool(scene)
		if pool:
			_layout_pool(pool, layout)

	# 再处理文件夹中的资源
	for dir_path in pool_dir:
		var dir = DirAccess.open(dir_path)
		if not dir:
			continue
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name:
			var file_path := dir_path.path_join(file_name)
			var res := ResourceLoader.load(file_path)
			var pool: BakedPool = null
			if res is ArrayMesh:
				pool = _create_or_update_mesh_pool(res as ArrayMesh)
			elif res is PackedScene:
				pool = _create_or_update_scene_pool(res as PackedScene)
			if pool:
				_layout_pool(pool, layout)
			file_name = dir.get_next()

func _layout_pool(pool: BakedPool, layout: Dictionary) -> void:
	pool.position = Vector3(layout.x, 0.0, layout.z)
	move_child(pool, layout.placed_count)
	layout.placed_count += 1
	layout.x += gap
	if layout.placed_count % SIZE == 0:
		layout.x = 0.0
		layout.z += gap

func _get_resource_key(res: Resource) -> String:
	var path := res.resource_path
	if path:
		return path.get_file().get_basename()
	if res.resource_name:
		return res.resource_name
	return str("pool_", hash(res))

func _create_or_update_mesh_pool(mesh: ArrayMesh) -> BakedPool:
	var key := _get_resource_key(mesh)
	var existing_pool := find_child(key, false)
	if existing_pool is BakedPool:
		var current_count := existing_pool.get_child_count()
		for i in current_count:
			var mesh_instance := existing_pool.get_child(i)
			if mesh_instance is MeshInstance3D:
				if not mesh_instance.mesh:
					mesh_instance.mesh = mesh
					LogTool.log("烘焙池", "更新", mesh_instance.name)
		# 数量不足，补充到目标数量
		for i in range(current_count, pool_min_size):
			var mesh_instance := MeshInstance3D.new()
			mesh_instance.mesh = mesh
			mesh_instance.name = str(key, '_', i + 1)
			existing_pool.add_child(mesh_instance)
			mesh_instance.owner = self
			LogTool.log("烘焙池", "补充", mesh_instance.name)
		return existing_pool

	var new_pool := BakedPool.new()
	new_pool.name = key
	add_child(new_pool)
	new_pool.owner = self

	for i in pool_min_size:
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.mesh = mesh
		mesh_instance.name = str(key, '_', i + 1)
		new_pool.add_child(mesh_instance)
		mesh_instance.owner = self

	LogTool.log("烘焙池", "创建", key, "数量:", pool_min_size, "=>", new_pool)
	return new_pool

func _create_or_update_scene_pool(scene: PackedScene) -> BakedPool:
	var key := _get_resource_key(scene)
	var existing_pool := find_child(key, false)
	if existing_pool is BakedPool:
		var current_count := existing_pool.get_child_count()
		# 数量不足，补充到目标数量（range 为空时自动跳过）
		for i in range(current_count, pool_min_size):
			var item := scene.instantiate()
			item.name = str(key, '_', i + 1)
			existing_pool.add_child(item)
			item.owner = self
		if current_count < pool_min_size:
			LogTool.log("烘焙池", "补充", key, "数量:", current_count, "=>", pool_min_size)
		return existing_pool

	var new_pool := BakedPool.new()
	new_pool.name = key
	add_child(new_pool)
	new_pool.owner = self

	for i in pool_min_size:
		var item := scene.instantiate()
		item.name = str(key, '_', i + 1)
		new_pool.add_child(item)
		item.owner = self

	LogTool.log("烘焙池", "创建", key, "数量:", pool_min_size, "=>", new_pool)
	return new_pool

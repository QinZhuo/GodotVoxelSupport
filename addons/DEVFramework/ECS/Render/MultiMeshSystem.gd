class_name MultiMeshSystem
extends ECSSystem

## 把 ECS 列批量写进 MultiMesh(3D) —— **显式选择**的多实例渲染后端。
##
## ===== 为什么只有 3D =====
## 2D 的实例规模通常是几十~几百, 走 Node 完全够用, 没有把视图数据列化的必要;
## 真正会把"逐节点 set_property"顶穿的是 3D 成片实例(上千子弹/碎片)。所以本模块只做 3D。
##
## ===== 为什么不"按数量自动切换" =====
## 框架里有两个渲染后端, 由**调用方显式选择**, 不做任何自动判断:
##   · `ECSSyncSystem`（Entity ↔ Node3D）：实体有身份、需要节点属性/碰撞/拾取/动画；
##   · 本系统（Entity → MultiMesh 实例）：**无身份**的成片实例。
## 自动切换的三个真问题: ①实体在两后端间来回迁移 → 视觉抖动; ②MultiMesh 模式下没有碰撞/拾取/节点信号,
## 静默切换 = 静默丢功能; ③出问题时"走的是哪条路径"无法从代码看出。
## 业界(Bevy / Unity DOTS / flecs / Godot 自身)同样只给显式路径, 不做隐式降级。
##
## 规则: **没 bind 的 layer 就不画**, 并通过返回值 / `last_unbound` 把漏绑暴露出来。
##
## 用法:
##   var sys := MultiMeshSystem.new()
##   sys.bind(0, mm_bullet)            # 显式: layer 0 → 这份 MultiMesh(transform_format = TRANSFORM_3D)
##   sys.bind(1, mm_debris)
##   sys.sync(world)                   # 每帧一次; 或 world.scheduler().register_system(sys)
##   if sys.last_unbound > 0: ...      # 有实体落在未绑定的 layer 上
##
## 成本: `query_entities`(1 次跨语言) + `multimesh_sync`(1 次跨语言; 逐实例 set_instance_transform
## 全在 C++ 内)。与"每实体一个 Node3D 并逐帧写 position"相比通常快一个量级; 与"GDScript 逐实例
## set_instance_transform"相比只是略快 —— 因为后者已经跳过了节点/反射那一层, 剩下的引擎调用谁都要付。

## layer -> MultiMesh
var _meshes := {}

## 最近一次 sync 中"落在未绑定 layer 上、被跳过"的实例数（0 = 全部画出来了）。
var last_unbound := 0

## 为 true 时，若发现漏绑的 layer 会用 push_warning 提示一次（默认关：框架不主动制造告警噪音，
## 漏绑由 last_unbound / sync() 返回值暴露，调用方自己决定要不要报）。
var diagnose := false

var _warned := false


## 绑定/替换某一层的 MultiMesh(layer 与 MultiMeshComponent.layer 对应)。
func bind(layer: int, mm: MultiMesh) -> void:
	if mm == null:
		_meshes.erase(layer)
		return
	_meshes[layer] = mm


func unbind(layer: int) -> void:
	_meshes.erase(layer)


func layer_count() -> int:
	return _meshes.size()


func required_components() -> Array[Script]:
	return [MultiMeshComponent]


func read_components() -> Array[Script]:
	return [MultiMeshComponent]


## 触碰渲染资源(MultiMesh) → 主线程串行。
func can_run_parallel() -> bool:
	return false


func _run(ctx: ECSSystemContext, _delta: float) -> void:
	sync(ctx.world)


## 同步一帧。返回**实际写入**的实例数。
## 小于实体总数 ⇒ 有实体的 layer 没 bind: 属调用方配置问题, 这里只报告, 不代劳(不做隐式回退)。
func sync(world: ECSWorld) -> int:
	last_unbound = 0
	if world == null or _meshes.is_empty():
		return 0
	world.register_component(MultiMeshComponent)
	var ents := world.query_entities(MultiMeshComponent)
	if ents.is_empty():
		return 0
	# 按 layer 升序拼成 Array(meshes[layer] = MultiMesh / null), 原生侧按下标直接取
	var max_layer := 0
	for k in _meshes:
		max_layer = maxi(max_layer, int(k))
	var meshes: Array = []
	meshes.resize(max_layer + 1)
	for k in _meshes:
		meshes[int(k)] = _meshes[k]
	var written := int(world.native().call(&"multimesh_sync", world.component_name(MultiMeshComponent),
			ents, &"layer", &"pos", &"rot", &"scale", &"color", meshes))
	if written < ents.size():
		last_unbound = ents.size() - written
		if diagnose and not _warned:
			_warned = true
			push_warning("MultiMeshSystem: %d 个实例的 layer 没有 bind 对应的 MultiMesh，已被跳过。\
已绑定 layer: %s。这是**显式配置**问题：请 bind() 缺失的 layer，或把这些实体改用 ECSSyncSystem。" % [
				last_unbound, str(_meshes.keys())])
	return written

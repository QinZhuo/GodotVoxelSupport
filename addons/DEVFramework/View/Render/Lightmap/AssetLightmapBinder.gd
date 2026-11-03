## 把一份 [AssetLightmapRegion] 绑到 MeshInstance3D 的材质上。
##
## 做法：把实例实际用到的每个 surface 材质复制一份，把 SH 加色 shader 接在 next_pass 上。
## 主材质资源不动（同一份 mesh 能被任意多个实例共用），也不必额外挂一个重合的 MeshInstance3D。
##
## 为什么不是 material_overlay：它是「整个实例一份材质」，多 surface 模型（盒体 + 玻璃罩）
## 会被同一份材质盖到每个 surface 上，光叠加不止一次；而且描边（OutlineEffect）已经占着它。
## next_pass 挂在具体 surface 的材质上，surface 各管各的，与 material_overlay 互不干扰。
##
## 代价：surface 材质换成实例级副本（material_override / set_surface_override_material）。
## 副本按「光照 + 基材质」缓存，同类物品共用一份，不随实例数量膨胀，重复 apply 也不会再套一层。
@tool
class_name AssetLightmapBinder

const SHADER := preload("res://addons/DEVFramework/View/Render/Lightmap/AssetLightmapPass.gdshader")

## 全局混合强度：加色叠加层的整体亮度，1.0 ≈ 与烘焙图一致。
## 调它不需要重烘，设为 0 等于关掉叠加光
static var strength := 0.2

## 宿主材质上记着它复制自哪份基材质。重复 apply 时靠它找回原材质，
## 避免把宿主再复制一遍套出第二层 next_pass，也避免换场景换光照后残留旧光
const BASE_META := &"asset_lightmap_base"

## 「光照 + 基材质」→ 复制出来的宿主材质（宿主再 next_pass → SH 材质）
static var _pairs: Dictionary = {}

## 已挂光的实例（instance_id → weakref）：换光照库 / 全局开关时靠它整体重挂。
## 由 [BakedMeshInstance3D] 进出树时登记，Binder 不认识它（只按方法名回调），避免两边互相引用
static var _live: Dictionary = {}

## 逐面可叠加结论按 mesh 资源缓存：每次借出都遍历所有 surface 的顶点数组太浪费
static var _bakeable: Dictionary = {}

## 缺材质的告警只打一次，别在借还热路径里刷屏
static var _warned_no_material := false

## 挂光。重复调用只更新参数，不会叠出第二层。
## 逐面判定：缺 UV2 的面只是跳过，不拖累同一模型上有 UV2 的面
static func apply(mi: MeshInstance3D, light: AssetLightmapRegion, atlas: TextureLayered) -> bool:
	if mi == null or not is_instance_valid(mi) or light == null or not light.has_area():
		return false
	if atlas == null or mi.mesh == null:
		return false
	var flags := _surface_flags(mi.mesh)
	if not (true in flags):
		return false
	## material_override 压过所有 surface 材质，只能改它本身
	if mi.material_override != null:
		if not _opaque(mi.material_override):
			return false
		mi.material_override = _shared(mi.material_override, light, atlas)
		return true
	var ok := false
	for i in flags.size():
		if not flags[i]:
			continue
		var base := _base(mi, i)
		if base == null:
			## 没有材质就没有 next_pass 可挂：这是"烘了却看不见"的经典原因，静默跳过太坑
			_warn_missing_material(mi)
			continue
		if not _opaque(base):
			continue
		mi.set_surface_override_material(i, _shared(base, light, atlas))
		ok = true
	return ok

## 取这个 surface 实际生效的材质（没有材质返回 null：没有材质就没有 next_pass 可挂）
static func _base(mi: MeshInstance3D, i: int) -> Material:
	var m := mi.get_surface_override_material(i)
	return m if m != null else mi.mesh.surface_get_material(i)

static func _warn_missing_material(mi: MeshInstance3D) -> void:
	if _warned_no_material:
		return
	_warned_no_material = true
	LogTool.warn("光照", "%s 的面没有材质，挂不上烘焙光（给网格或其 surface 指定材质）" % mi.name)

## 透明面（玻璃罩）叠加加色会把背后的画面糊成一片白雾，跳过
static func _opaque(mat: Material) -> bool:
	return not (mat is BaseMaterial3D) or (mat as BaseMaterial3D).transparency == BaseMaterial3D.TRANSPARENCY_DISABLED

## 整网格是否值得烘焙：至少有一个不透明面带 UV2。
## 只看会叠加的面：玻璃罩本来就不叠，它缺 UV2 不该拖累整个模型
## 骨骼网格照样挂：next_pass 跟着主材质一起走，不涉及顶点，变形网格也正确
static func can_bake(mesh: Mesh) -> bool:
	return true in _surface_flags(mesh)

## 逐面结论（true = 该面能安全叠加）：没有 UV2 就采样不到 SH 贴图，
## 会退化成单点取色（一整块纯色 + bloom），这种面跳过即可
static func _surface_flags(mesh: Mesh) -> Array:
	if mesh == null or mesh.get_surface_count() == 0:
		return []
	## 编辑器里网格随时可能被重新导入，缓存会一直拿到旧结论
	var cache := not Engine.is_editor_hint()
	var key := mesh.get_instance_id()
	if cache and _bakeable.has(key):
		return _bakeable[key]
	var flags := []
	for i in range(mesh.get_surface_count()):
		flags.append(_surface_bakeable(mesh, i))
	if cache:
		_bakeable[key] = flags
	return flags

static func _surface_bakeable(mesh: Mesh, i: int) -> bool:
	if not _opaque(mesh.surface_get_material(i)):
		return false
	var arrays := mesh.surface_get_arrays(i)
	return arrays.size() > Mesh.ARRAY_TEX_UV2 and arrays[Mesh.ARRAY_TEX_UV2] != null

## 基材质 → 挂了 SH next_pass 的副本。同一份基材质 + 同一份光照只复制一次。
## ⚠️ 基材质自带的 next_pass 会被替换掉：物品材质是标准材质直出，不存在这条链
static func _shared(base: Material, light: AssetLightmapRegion, atlas: TextureLayered) -> Material:
	## 传进来的可能已经是上次挂好的宿主，先还原成它复制自的那份
	if base.has_meta(BASE_META):
		base = base.get_meta(BASE_META) as Material
	var key := "%d_%d" % [light.get_instance_id(), base.get_instance_id()]
	var cached: Material = _pairs.get(key)
	if cached != null:
		return cached
	var host: Material = base.duplicate()
	host.next_pass = _pass(base, light, atlas)
	host.set_meta(BASE_META, base)
	_pairs[key] = host
	return host

## 回收某份光照名下的材质副本：缓存键里带着光照实例 id，
## 光照被整套换掉后这些副本再也没人认领，不清就一路堆到进程结束
static func release(light: AssetLightmapRegion) -> void:
	if light == null:
		return
	var prefix := "%d_" % light.get_instance_id()
	for key in _pairs.keys():
		if String(key).begins_with(prefix):
			_pairs.erase(key)

## 运行中整体调亮度：已经挂好的 pass 一起改，不必重烘也不必重新挂
static func set_strength(value: float) -> void:
	strength = value
	for host in _pairs.values():
		var sm := (host as Material).next_pass as ShaderMaterial
		if sm != null:
			sm.set_shader_parameter(&"strength", value)

## 登记一个在树上的挂光实例（由 [BakedMeshInstance3D] 调用）
static func track(mi: MeshInstance3D) -> void:
	if mi != null:
		_live[mi.get_instance_id()] = weakref(mi)

static func untrack(mi: MeshInstance3D) -> void:
	if mi != null:
		_live.erase(mi.get_instance_id())

## 让所有在树上的实例按当前 [member AssetLightmapSet.current] 重挂一遍：
## 换库 / 全局开关都要它，否则先入树的实例会一直停在旧状态
static func refresh_all() -> void:
	for id in _live.keys():
		var mi := _live[id].get_ref() as MeshInstance3D
		if mi == null:
			_live.erase(id)
		elif mi.is_inside_tree():
			mi.call(&"apply_lightmap")

## 摘掉挂上去的光，还原成基材质本身。
## 调用方不必先判断"有没有挂过"：没有就什么都不做（幂等）
## 实例池与场景是分开的：同一份 CardBox 可能先在商店里带光、再被别的场景借走，
## 那边没有烘焙图，得把它擦干净，否则会顶着上一个场景的光出现
static func clear(mi: MeshInstance3D) -> void:
	if mi == null or not is_instance_valid(mi) or mi.mesh == null:
		return
	## material_override 压过所有 surface，也得还原，否则整件仍带着光
	if mi.material_override != null and mi.material_override.has_meta(BASE_META):
		mi.material_override = mi.material_override.get_meta(BASE_META) as Material
	for i in mi.mesh.get_surface_count():
		var m := mi.get_surface_override_material(i)
		if m == null or not m.has_meta(BASE_META):
			continue
		## 还原成"挂光之前那份"：原本没有 override 就置空，原本是业务自设的就还回去
		var base := m.get_meta(BASE_META) as Material
		mi.set_surface_override_material(i, null if base == mi.mesh.surface_get_material(i) else base)

## SH 材质按「光照 + 基材质」各一份：albedo / 粗糙度这些 PBR 特征要从基材质取
static func _pass(base: Material, light: AssetLightmapRegion, atlas: TextureLayered) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter(&"lm_atlas", atlas)
	mat.set_shader_parameter(&"lm_uv", light.uv)
	mat.set_shader_parameter(&"lm_slice", light.slice * 4)
	mat.set_shader_parameter(&"strength", strength)
	## 0 = 纯加色、不写 alpha（见 shader 里的 premul_alpha 说明）
	mat.set_shader_parameter(&"opacity", 0.0)

	## 从基材质取 PBR 参数，让 SH 求值后的颜色仍然带材质特征
	if base is StandardMaterial3D:
		var std := base as StandardMaterial3D
		mat.set_shader_parameter(&"albedo_tex", std.albedo_texture)
		mat.set_shader_parameter(&"roughness_tex", std.roughness_texture)
		mat.set_shader_parameter(&"metallic", std.metallic)
		mat.set_shader_parameter(&"roughness_default", std.roughness)
	else:
		mat.set_shader_parameter(&"metallic", 0.0)
		mat.set_shader_parameter(&"roughness_default", 0.5)
	return mat

## 自带烘焙光照的网格实例：进树就挂光，编辑器里也直接看得到。
## 换网格或换 material_override 之后调一次 [method apply_lightmap] 重挂。
##
## 整套光照系统对外的门面就是这一个节点类：美术把 MeshInstance3D 换成它即可，
## 全局开关和整体亮度也都收在这里，不用再去翻 Binder。
@tool
class_name BakedMeshInstance3D extends MeshInstance3D

## 单实例开关：只摘自己这份光，方便对着原材质看差别
@export var lightmap_visible := true:
	set(value):
		lightmap_visible = value
		apply_lightmap()

## 只读状态，检查器里一眼看出挂没挂上
@export var lightmap_state := "未挂载"

@export_tool_button("重新挂载") var remap_lightmap := apply_lightmap

## 全局开关：一次摘掉所有实例的光，不用逐个关
static var all_visible := true

## 活着的实例，全局切换时逐个刷新
static var _live: Dictionary = {}

func _enter_tree() -> void:
	_live[get_instance_id()] = weakref(self)
	apply_lightmap()

func _exit_tree() -> void:
	_live.erase(get_instance_id())

## 幂等：重复调用只更新参数，不会叠出第二层 next_pass
func apply_lightmap() -> void:
	if not lightmap_visible or not all_visible:
		AssetLightmapBinder.clear(self)
		lightmap_state = "已关闭"
	elif AssetLightmapSet.bind_to(self):
		lightmap_state = "已挂载"
	else:
		AssetLightmapBinder.clear(self)
		lightmap_state = "无烘焙数据"

static func set_all_visible(value: bool) -> void:
	all_visible = value
	for ref in _live.values():
		var node := ref.get_ref() as BakedMeshInstance3D
		if node != null:
			node.apply_lightmap()

## 全局亮度：0 等于没有叠加光，1.0 ≈ 与烘焙图一致。不必重烘
static func set_strength(value: float) -> void:
	AssetLightmapBinder.set_strength(value)

## 状态是给人看的，别存进场景
func _validate_property(prop: Dictionary) -> void:
	if prop.name == &"lightmap_state":
		prop.usage |= PROPERTY_USAGE_READ_ONLY
		prop.usage &= ~PROPERTY_USAGE_STORAGE

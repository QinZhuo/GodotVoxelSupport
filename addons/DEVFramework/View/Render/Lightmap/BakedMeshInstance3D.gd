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

## 进出树登记到 Binder：它持有"谁在树上"，换光照库时整体重挂
func _enter_tree() -> void:
	AssetLightmapBinder.track(self)
	apply_lightmap()

func _exit_tree() -> void:
	AssetLightmapBinder.untrack(self)

## 幂等：重复调用只更新参数，不会叠出第二层
func apply_lightmap() -> void:
	if not lightmap_visible or not all_visible:
		AssetLightmapBinder.clear(self)
		lightmap_state = "已关闭"
	elif AssetLightmapSet.bind_to(self):
		lightmap_state = "已挂载"
	else:
		## 没有库 / 没有这份网格的数据：bind_to 内部已擦干净，这里只更新状态
		lightmap_state = "无烘焙数据"

static func set_all_visible(value: bool) -> void:
	all_visible = value
	AssetLightmapBinder.refresh_all()

## 全局亮度：0 等于没有烘焙光，1.0 ≈ 与烘焙场景里引擎 LightmapGI 的观感一致。不必重烘
static func set_strength(value: float) -> void:
	AssetLightmapBinder.set_strength(value)

## 全局「减掉多少环境光」：0 = 纯叠加（更亮），标定值 = 等价替换（与烘焙场景一致）
static func set_ambient_ref(value: float) -> void:
	AssetLightmapBinder.set_ambient_ref(value)

## 状态是给人看的，别存进场景
func _validate_property(prop: Dictionary) -> void:
	if prop.name == &"lightmap_state":
		prop.usage |= PROPERTY_USAGE_READ_ONLY
		prop.usage &= ~PROPERTY_USAGE_STORAGE

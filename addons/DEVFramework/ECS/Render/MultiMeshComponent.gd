class_name MultiMeshComponent
extends ECSComponent

## 多实例(3D)渲染条目 —— 大量**同网格同材质**实例(子弹/碎片/单位/粒子)的视图侧数据。
##
## 为什么是 3D 而不是 2D:
##   2D 的实例数通常只有几十~几百, 走 Node 完全够用, 没有把视图数据列化的必要;
##   真正会把"逐节点 set_property"顶穿的是 3D 的成片实例(上千). 所以框架的批量渲染出口只做 3D。
##
## 这是**显式选择**的渲染后端之一, 框架不会按数量自动切换:
##   · 有身份、要节点属性/碰撞/拾取/动画 → `NodeLink` + `ECSSyncSystem`（每实体一个 Node3D）
##   · 无身份、成片同网格同材质          → 本组件 + `MultiMeshSystem`（一份网格, N 个实例）
## 自动切换会让同一实体在两后端间迁移(视觉抖动)、静默丢失碰撞/拾取, 且"问题出在哪条路径"不可查;
## Bevy / Unity DOTS / flecs / Godot 自身都是只给显式路径。
##
## 用法:
##   world.register_component(MultiMeshComponent)
##   var sys := MultiMeshSystem.new()
##   sys.bind(0, bullet_multimesh)                 # layer 0 → 某个 MultiMesh(TRANSFORM_3D)
##   ...
##   sys.sync(world)                               # 每帧一次(或挂 scheduler)
##
## ⚠ 实例槽位按"聚合行序"分配: 实体增删会让同层内下标平移 → 视觉上可能有一帧"对调"。
##   对子弹/碎片这类无身份对象无影响; 需要稳定身份的用 NodeLink + 节点。

## 写到哪个 MultiMesh(对应 MultiMeshSystem.bind 的 layer)
@export var layer: int = 0
## 世界坐标(3D)
@export var pos: Vector3 = Vector3.ZERO
## 欧拉角(弧度, YXZ 顺序). 只绕 Y 转的子弹填 (0, yaw, 0) 即可
@export var rot: Vector3 = Vector3.ZERO
## 缩放(3D)
@export var scale: Vector3 = Vector3.ONE
## 实例颜色(MultiMesh 需 use_colors = true 才会写入)
@export var color: Color = Color.WHITE

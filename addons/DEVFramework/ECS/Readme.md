# ECS

C++ 原生列存储（`ECSCore`，注册在框架共享库 `Native/dev.gdextension`）+ GDScript 封装（`ECSWorld` / `ECSSystem` / 查询链 DSL）。

`ECSWorld` 只管数据面；系统注册、拓扑排序、频率节流、并行分批与耗时统计都在 `ECSScheduler`（`world.scheduler()`）。

三种用法：**海量实体**（纯数据 + 渲染直读列）、**关键实体**（`Entity2D/3D` 桥接场景节点）、**数值逻辑**（系统内批量执行）。

## 快速开始

```gdscript
var world := ECSWorld.new()              # 多世界隔离传 false
world.register_component(HealthComponent)

var e := world.create_entity()
world.add_component(e, HealthComponent)
world.set_field(e, HealthComponent, &"hp", 50)

world.register_system(HealSystem.new())  # priority 越大越先执行
world.tick(delta)                        # 或用 ECSTick 节点自动驱动
```

| 操作 | API |
|---|---|
| 创建 / 销毁 | `create_entity()` / `destroy_entity(e)` |
| 附加 / 移除 / 判断 | `add_component(e, Comp)` / `remove_component` / `has_component` |
| 读写字段 | `get_field(e, Comp, &"hp")` / `set_field(...)` |
| 存活 / 数量 | `is_alive(e)` / `count(Comp)` |

系统内的结构变更走命令缓冲（见下）。

## 组件

纯数据 schema，继承 `ECSComponent`（Resource），`@export` 即字段；支持 `int/float/bool/Vector2/Vector3/Vector4/Color/String`。

```gdscript
class_name HealthComponent extends ECSComponent
@export var max_hp: int = 100
@export var hp: int = 100
```

## 系统

系统是**纯运行时对象**（`ECSSystem extends RefCounted`），不继承 `Def`、无配置资源层：参数创建时直接赋值。

```gdscript
class_name DemoWorld extends World

func _setup_world(world: ECSWorld) -> void:
	var sys := HealSystem.new()
	sys.heal_amount = 5.0
	world.register_system(sys)

	var sync := ECSSyncSystem.new()
	sync.add_field_rule(HealthComponent, &"hp", &"value")
	world.register_system(sync)
```

| 成员 | 说明 |
|---|---|
| `required_components()` | 需要的组件（自动注册） |
| `read_components()` / `write_components()` | 读写声明（并行冲突检测 + 依赖排序） |
| `can_run_parallel()` | 默认 true；访问场景树/节点须覆写 false |
| `_run(ctx, delta)` | 每帧逻辑 |
| `priority` / `enabled` | 注册权重（`register_system` 不传参时取它）/ 启停 |
| `interval` / `rate` / `fixed_step` | 频率控制，`fixed_step` > `interval` > `rate` |

## 查询链

`ctx.for_each(Comp, must, without)` 链式构建，**链尾 `.execute()`**（系统 `_run` 结束也会自动执行）。

```gdscript
# 标量
ctx.for_each(HealthComponent).where(&"hp").less_than(50).add(&"hp", 10).execute()

# 列间：目标 = 源 * factor + addend
ctx.for_each(BattleCell).set_from(&"size", BattleCell, &"hp", 0.08, 8.0).execute()

# 列间：目标 += 源列
ctx.for_each(BattleCell).add_from(&"dmg", BattleCell, &"atk").execute()

# 条件钳制
ctx.for_each(BattleCell).where(&"hp").greater_than(0).clamp_where(&"hp", BattleCell, &"min_hp", BattleCell, &"max_hp").execute()
```

动作：`.add/.sub/.mul/.div/.set_value`（标量）、`.add_from/.sub_from/.mul_from/.div_from/.set_from/.clamp_where`（列间）、`.process(cb)`（回调）。
条件：`less_than` / `less_or_equal` / `greater_than` / `greater_or_equal` / `equal` / `not_equal`，多个为 AND。
组件过滤：`ctx.for_each(Unit, [HealthComponent], [Dead])`。

### process 回调

```gdscript
# 推荐：.with 声明字段，回调直接收列（框架自动写回）
ctx.for_each(BattleCell).with([&"hp", &"pos"]).process(_cb).execute()

func _cb(rows: PackedInt32Array, hp: PackedFloat32Array, pos: PackedVector2Array) -> void:
	for r in rows: hp[r] -= 1

# 或预拉字典：data[组件类名][字段名]
ctx.for_each(BattleCell).process(func(rows, data): ... , {BattleCell: [&"hp"]}).execute()
```

## 查询与批量列

```gdscript
var rows: PackedInt32Array = world.query_rows(HealthComponent, [MoveComponent], [Dead])
var aligned: Array = world.query_aligned(MoveComponent, [HealthComponent])   # [0]=anchor 行号, [1]=对齐行号
var cols: Dictionary = world.get_columns([{comp = HealthComponent, fields = [&"hp"]}])
var data: Dictionary = world.borrow_columns(norm)   # 独占引用，改完 return_columns
```

## 并行调度

默认开启、自动生效：首帧串行预热采集访问集，之后按冲突分批并行（C++ 持久线程池）。

```gdscript
world.parallel_enabled = true
world.parallel_threads = 0        # 0 = 自动
```

并行系统要求：不访问场景树、读写声明准确、结构变更走命令缓冲。调试：`is_parallel_active()` / `debug_parallel_stats()`。

## 命令缓冲 / 钩子 / 事件

```gdscript
var ph := world.cmd_create()
world.cmd_add_component(ph, HealthComponent)
world.cmd_destroy(e)              # tick 帧末自动 flush

world.on_component_added(HealthComponent, _cb)   # 另有 removed / entity_destroyed
world.is_component_dirty(HealthComponent)        # 本帧是否被写过
world.emit_event(&"killed", {})                  # 帧内累积、帧末派发
world.on_event(&"killed", _handler)
```

## Prefab 与存档

```gdscript
var ids := world.spawn_from_def(crowd_def, 20000)      # ECSPrefabDef 配置驱动批量生成
var prefab := world.create_prefab()
world.prefab_add(prefab, HealthComponent, {"hp": 100})
var ids2 := world.instantiate(prefab, 50, {HealthComponent: {"hp": 80}})

var data := world.serialize()
var restored := world.deserialize(data)
```

## Entity 桥接

```gdscript
# Entity2D/3D 子类：@export 纯数据变量 = ECS 字段（不想进 ECS 的用 const ECS_EXCLUDE 排除）
var unit := DemoUnit.new()
unit.world = world
unit.hp = 80
unit.register_to_ecs()                      # 自动注册组件 + 写入初值
unit.sync_from_ecs(&"pos", &"position")     # ECS → 节点属性
unit.sync_to_ecs(&"position", &"pos")       # 节点属性 → ECS
unit.destroy()

# 任意对象也能同步
ecs.sync_from(comp, &"pos", label_node, &"position")
```

挂在实体下的逻辑用**普通 Node**：持有实体引用（`@export var entity: Entity2D`，或 `get_parent() as Entity2D`），直接调 `entity.set_field(...)` / `entity.add_component(...)`。
`ECSSyncSystem` 批量把带 `NodeLink` 的实体字段同步到节点（主线程，`can_run_parallel()=false`）。

## 性能要点

- 数值热点用规则 DSL（C++ batch）；复杂逻辑用 `process(fields)` 预拉列 + 自动写回。
- 高频写用 `borrow_columns` / `return_columns` 避免 COW。
- 海量实体渲染直读列（参考 `ECSPointCloud`），关键实体用 `Entity2D/3D`。
- 位置用 `Vector2`/`Vector3` 单字段，不拆 x/y。

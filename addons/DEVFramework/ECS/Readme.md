# ECS

C++ 原生列存储（`Native/dev.gdextension`）+ GDScript 封装。
`ECSWorld` 管数据，`ECSScheduler` 管系统注册/排序/并行（`world.scheduler()`）。

三种用法：**海量实体**（纯数据 + 渲染直读列）、**关键实体**（`Entity2D/3D` 桥接节点）、**数值逻辑**（系统内批量跑）。

## 快速开始

> 节点侧（`Entity2D/3D`）的 ECS 世界属性是 **`ecs_world`**，不是 `world`；
> `world` 留给项目自己的世界对象（避免每个项目被迫改名）。

```gdscript
var world := ECSWorld.new()
world.register_component(HealthComponent)
var e := world.create_entity()
world.add_component(e, HealthComponent)
world.set_field(e, HealthComponent, &"hp", 50)
world.register_system(HealSystem.new())   # priority 越大越先跑
world.tick(delta)                         # 或用 ECSTick 节点自动驱动
```

| 操作 | API |
|---|---|
| 创建 / 销毁 | `create_entity()` / `destroy_entity(e)` |
| 组件 | `add_component` / `remove_component` / `has_component` |
| 字段 | `get_field(e, Comp, &"hp")` / `set_field(...)` |
| 查询 | `is_alive(e)` / `count(Comp)` |

系统内改结构必须走命令缓冲（见下）。

## 组件

纯数据 schema，`extends ECSComponent`（Resource），`@export` 即字段。
支持 `int/float/bool/Vector2/3/4/Color/String`。

```gdscript
class_name HealthComponent extends ECSComponent
@export var hp: int = 100
```

## 系统

`extends ECSSystem`（RefCounted），**纯运行时对象**，参数创建时赋值：

```gdscript
var sys := HealSystem.new()
sys.heal_amount = 5.0
world.register_system(sys)
```

| 成员 | 说明 |
|---|---|
| `required_components()` | 需要的组件（自动注册） |
| `read_components()` / `write_components()` | 读写声明（并行冲突检测 + 依赖排序） |
| `can_run_parallel()` | 默认 true；碰场景树须覆写 false |
| `_run(ctx, delta)` | 每帧逻辑 |
| `priority` / `enabled` | 权重 / 启停 |
| `interval` / `rate` / `fixed_step` | 频率控制（优先级 `fixed_step` > `interval` > `rate`） |

## 查询链

`ctx.for_each(Comp, must, without)` 链式构建，链尾 `.execute()`（`_run` 结束自动执行）。

```gdscript
# 标量
ctx.for_each(HealthComponent).where(&"hp").less_than(50).add(&"hp", 10).execute()
# 列间：目标 = 源 * factor + addend
ctx.for_each(BattleCell).set_from(&"size", BattleCell, &"hp", 0.08, 8.0).execute()
# 列间累加 / 条件钳制
ctx.for_each(BattleCell).add_from(&"dmg", BattleCell, &"atk").execute()
ctx.for_each(BattleCell).where(&"hp").greater_than(0).clamp_where(&"hp", BattleCell, &"min_hp", BattleCell, &"max_hp").execute()
```

- 动作：`.add/.sub/.mul/.div/.set_value`（标量）、`.add_from/.sub_from/.mul_from/.div_from/.set_from/.clamp_where`（列间）、`.process(cb)`
- 条件：`less_than / less_or_equal / greater_than / greater_or_equal / equal / not_equal`（多个为 AND）
- 组件过滤：`ctx.for_each(Unit, [HealthComponent], [Dead])`

回调（推荐 `.with` 预拉列，框架自动写回）：

```gdscript
ctx.for_each(Cell).with([&"hp", &"pos"]).process(_cb).execute()
func _cb(rows: PackedInt32Array, hp: PackedFloat32Array, pos: PackedVector2Array) -> void:
	for r in rows: hp[r] -= 1
```

## 批量列 / 并行

```gdscript
world.query_rows(Comp, [must], [without])
world.query_aligned(MoveComponent, [HealthComponent])   # [0]=anchor 行, [1]=对齐行
world.get_columns([{comp = Comp, fields = [&"hp"]}])
world.borrow_columns(x) / return_columns(x)              # 高频写避免 COW
world.parallel_enabled / parallel_threads                 # 0 = 自动
```

并行系统要求：不碰场景树、读写声明准确、结构变更走命令缓冲。调试 `is_parallel_active()` / `debug_parallel_stats()`。

## 命令缓冲 / 钩子 / 事件

```gdscript
var ph := world.cmd_create()
world.cmd_add_component(ph, HealthComponent)
world.cmd_destroy(e)                       # tick 帧末 flush
world.on_component_added(Comp, _cb)        # 另有 removed / entity_destroyed
world.is_component_dirty(Comp)
world.emit_event(&"killed", {})            # 帧末派发
world.on_event(&"killed", _handler)
```

## Prefab / 存档

```gdscript
world.spawn_from_def(prefab_def, 20000)    # ECSPrefabDef 批量生成
var p := world.create_prefab(); world.prefab_add(p, Comp, {"hp": 100})
world.instantiate(p, 50, {Comp: {"hp": 80}})
world.serialize() / world.deserialize(data)
```

## Entity 桥接

```gdscript
var unit := DemoUnit.new()      # Entity2D/3D 子类：@export 纯数据 = ECS 字段
unit.world = world
unit.hp = 80
unit.register_to_ecs()
unit.sync_from_ecs(&"pos", &"position")
unit.sync_to_ecs(&"position", &"pos")
```

挂实体下的逻辑用**普通 Node**，持有 `entity` 引用直接调 `entity.set_field(...)`。
`ECSSyncSystem` 批量把带 `NodeLink` 的字段同步到节点（主线程）。

## 性能

- 数值热点用规则 DSL（C++ batch）；复杂逻辑用 `process(fields)` 预拉列
- 高频写用 `borrow_columns` / `return_columns`
- 海量渲染直读列（见 `ECSPointCloud`）
- 位置用 `Vector2/3` 单字段，不拆 x/y

## Demo

`Scenes/ECS/ECSDemo.tscn`、`ECSNodeDemo.tscn`、`impl_query.tscn`。

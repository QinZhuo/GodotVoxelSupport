# Core 框架地基

六层可复用的底座：`Def`（配置）→ `Entity`（运行时）→ `Tool`（静态机制），外加 `Pool`、`Async`、`Editor`。
依赖单向：能力模块可引用 Core，Core 不引用能力模块；已知例外见 [LAYERS.md](../LAYERS.md) 第七节（33 处 / 9 文件），新增模块不要再加重这层环。

## 六层放什么

| 层 | 目录 | 职责 | 代表类 |
|---|---|---|---|
| Def | `Core/Def` | 编辑器可配的静态数据，必带 `@tool` | `Def` / `EntityDef` / `TagDef` |
| Entity | `Core/Entity` | 有状态的运行时载体 | `Entity` / `Entity2D` / `Entity3D` / `Modifier` / `ModifierValue` / `StateMachine` |
| Tool | `Core/Tool` | 全 `static`、无实例状态的横切机制（24 个） | `LogTool` / `VariantTool` / `SaveTool` / `TimeTool` / `TickTool` |
| Pool | `Core/Pool` | 节点复用。`Pool` 只管实例，`PoolTool` 是 key → 池的注册表 | `Pool` / `PoolTool` |
| Async | `Core/Async` | 协程等待与超时、后台线程、协程互斥、可撤销作用域 | `AsyncTool` / `AsyncScope` |
| Editor | `Core/Editor` | 编辑器侧：`DefTable` 表格视图、`Generate` 构建工具、`Setup` 项目脚手架 | `DefTableView` / `GDExtensionRebuild` / `DevProjectSetup` |

## 怎么用
### Def → Entity

```gdscript
# SomeDef.gd
@tool
class_name SomeDef extends EntityDef      # 基类已有 icon / color / effect / tr_desc
@export var max_hp: int = 100

# SomeEntity.gd
class_name SomeEntity extends Entity
var def: SomeDef
func _init(d: Def = null) -> void:
	super(d)                              # Entity._init 会把 d 写进同名成员 def

# 加载与构造
var defs := Def.load_defs_in_dir(Def.DEFS_BASE, func(r): return r is SomeDef)
var e := SomeEntity.new(defs[0])
```

`Def.name` 由资源文件名或 `class_name` 推导，`tr_name` 存在翻译 CSV 而不写进 `.tres`；`save_data()` 只存相对 `DEFS_BASE` 的短路径，`Def.load_data()` 两种格式都认。

### 常用 Tool

| Tool | 常用入口 | 说明 |
|---|---|---|
| `LogTool` | `log(tag, ...)` / `warn` / `error` / `timer(tag, msg)` | 标签配色 + 项目设置开关；`set_mirror_path()` 把日志写给别人进程读 |
| `VariantTool` | `as_int(v, def)` / `as_bool` / `get_string(dict, key, def)` / `infer` | Variant 规范化的统一入口：空白串、数字字符串、Packed 数组都在此归一 |
| `SaveTool` | `save_data(path, data, Mode.JSON)` / `load_data` / `check_version` | 原子写 + 单份 `.bak` 回退；`GZIP` 模式的路径会被哈希成槽名 |
| `FileTool` | `list_files(dir, [".tres"])` / `write_text` / `atomic_write_text` | 落盘原语；`.tmp` 必须与被写文件同目录，跨文件系统 rename 会失败 |
| `TimeTool` | `set_modifier(key, scale)` / `set_base_speed` / `pause` / `resume` | 用 `ModifierValue`（×100）管 `Engine.time_scale`，同步抬高物理频率 |
| `InputTool` | `set_device_mode` / `register_focus_group` / `handle_input(event)` | 键鼠 ↔ 手柄切换与焦点导航；`last_device` 决定提示条显示哪套键 |
| `UITool` | `register(panel)` / `close_top()` / `back()` / `get_top_of_layer` | 面板栈按 `Layer` 分层；注册只入栈，不触发 `panel.open()` |
| `PerfTool` | `measure(callable)` / `bench(action, iters, warmup)` / `bench_auto` | 计时与分位统计：预热样本丢弃，`cv` 判这次测量可不可信 |
| `PoolTool` | `ensure(key, view_scene.instantiate)` / `pool_get(key)` / `pool_return(key, node)` | 池注册表；同一 key 被两个视图场景复用会告警（会借出错节点） |
| `TickTool` | `defer(lane, action)`，宿主每物理 tick 末尾调 `tick()` | 同一 tick 内的恢复顺序确定：`lane` 升序，同 lane 先登先执行 |

### 长任务与异步

```gdscript
await AsyncTool.await_until(func(): return is_ready, 5000, "等就绪")   # 默认按物理 tick 计时
var r := await AsyncTool.await_signal(some_signal, 3000, "等信号")     # {ok, args}，超时不挂死
var res := await AsyncTool.load_resource_async(path)
var snap := JobTool.start("build", func(): return await do_work())     # 立即返回凭据
snap = await JobTool.wait(snap.job_id)                                 # running == false 才是结果
JobTool.report(3, 10, "step")                                         # 进度/速率/ETA 由它算
var scope := AsyncScope.new(host)                                      # 本轮流程持有的可撤销等待
if not await scope.delay(0.2):
	return                                                               # 宿主销毁或被 cancel_all
```

## 坑

1. 改 Core 的脚本后必须重启编辑器：已注册的全局类不会被真正 reload，行为与磁盘不一致且没有任何提示。
2. `TickTool` 需要宿主在**物理 tick 末尾**调一次 `tick()`；没人驱动时 `defer` 退回立即执行并告警一次，顺序不再受控。
3. `ModifierValue.value` 只读，直接赋值会走 `LogTool.error`——改 `base_value` 或 `add_modifier`；聚合是 `(base + ΣVALUE) × ΠPERCENT`，不是逐条累加。
4. 含 `static var` 的 Tool 必须在 `ResetTool.all()` 里登记，否则 `test_contract_reset` 失败；进程级缓存要在类头标 `## Reset: 进程级` 豁免。
5. `Entity2D/3D` 的 ECS 世界字段叫 `ecs_world`（`world` 留给项目）；`Core/Entity` 直接引用 `ECSLink` / `ECSWorld`，删 ECS 会编译失败。
6. `AsyncScope` 与 `StateMachine` 没有项目侧调用点，`GameTimer` 只在测试里被用；`await_coroutine` 超时**不会掐死**协程，只停止等待。

## 文件结构

```
Core/  （48 个 .gd）
├─ Def/     Def.gd EntityDef.gd Tag/TagDef.gd
├─ Entity/  Entity.gd Entity2D.gd Entity3D.gd Modifier.gd ModifierValue.gd StateMachine.gd
├─ Tool/    24 个全静态工具：日志 / 存档 / 时间 / tick / 输入 / 池 / 性能 / 文件 / 变体…
├─ Pool/    Pool.gd PoolTool.gd
├─ Async/   AsyncTool.gd AsyncScope.gd
└─ Editor/  EditorScriptMenuTool.gd + DefTable/ + Generate/ + Setup/
```

`Editor/` 下写 `extends EditorScript` 的脚本会被 `EditorScriptMenuTool` 挂进**项目 → 工具**菜单（`plugin.gd` 接线），`DefTableView` 则由 `plugin.gd` 挂成编辑器主屏 Tab；Tool 只放无实例状态的静态方法，要每帧批量调度的写 `XxxSystem`。
`Generation`（进程内世代）是运行时类却放在 `Editor/Generate/` 下，`AsyncScope` 的世代用的就是它——找它别只翻 `Async/`。

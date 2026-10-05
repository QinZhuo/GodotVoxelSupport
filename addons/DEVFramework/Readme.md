# DEVFramework 使用说明

DEVFramework 是一套面向 Godot 4 的数据驱动开发框架，通过「Def（静态数据）→ Entity（运行时实体）→ View（显示视图）」的分层架构，配合一批通用工具类，让游戏内容的配置、运行与界面展示解耦，实现「改数据不改代码」的开发模式。

---

## 目录

1. [快速开始](#一快速开始)
2. [整体架构](#二整体架构)
3. [Def 数据定义层](#三def-数据定义层)
4. [Entity 实体层](#四entity-实体层)
5. [Tool 工具层](#五tool-工具层)
6. [View 视图层](#六view-视图层)
7. [MCP 调试服务器](#七mcp-调试服务器)
8. [典型使用流程](#八典型使用流程)
9. [已知引擎陷阱](#九已知引擎陷阱必读)
10. [FAQ](#十faq)

---

## 一、快速开始

1. 将 `addons/DEVFramework` 目录复制到项目的 `addons/` 下。
2. 在 Godot 编辑器：`项目设置 → 插件 → 启用 DEVFramework`。
3. 通过菜单 **项目 → 工具 → 创建 DEV 项目结构...** 一键生成框架约定的目录骨架：

```
res://Assets/
├── Def/              # 静态数据资源（*.tres）
│   ├── Attribute/    # 属性定义
│   ├── Buff/         # Buff 定义
│   ├── Signal/       # 信号定义
│   └── Tag/          # 标签定义
└── Translation/      # 翻译 CSV（中文配置表）
res://Scenes/         # 场景
res://Scripts/        # 游戏脚本
├── Def/              # Def 子类脚本（按类目分子目录）
├── Entity/           # 实体脚本
└── View/             # 视图脚本
```

4. 在代码中直接使用全局类名（`LogTool`、`SaveTool`、`UITool`、`AsyncTool` 等），无需额外引入。

---

## 二、整体架构

框架遵循三层结构：

```
┌─────────────────────────────────────────────┐
│  View 视图层    UITool / UIPanel / ArrayView ... │
├─────────────────────────────────────────────┤
│  Entity 实体层  Modifier / Task / StateMachine / ECS桥接 │
├─────────────────────────────────────────────┤
│  Def 定义层     EntityDef / EffectDef / ValueDef │   ← 策划可配置的 *.tres 资源
└─────────────────────────────────────────────┘
```

**设计原则：**
- **框架 = 机制，项目 = 内容**：框架只保留换一款游戏仍成立的数学/协议/管线（Modifier、Task、EffectDef 协议等）；具体游戏语义（Buff、属性容器、伤害效果）放项目 `Scripts/` 继承实现。边界规则见 [`LAYERS.md`](LAYERS.md)。
- **Def 只描述静态配置**，不保存运行时状态（见 `Def.gd` 注释）。任何运行时数据都存放在外部上下文（Entity / Component / 场景节点）中。
- **Entity 是运行时数据载体**，由 `EntityDef` 驱动，可序列化。
- **View 负责显示**，通过 `data` 属性与数据解耦，数据变化驱动刷新。

### 项目设置项（插件注册时自动写入）

| 设置项 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `dev_framework/log/enabled` | bool | true | 日志总开关 |
| `dev_framework/log/show_timestamps` | bool | false | 是否显示时间戳 |
| `dev_framework/log/ignored_tags` | PackedStringArray | `[]` | 被忽略的日志标签 |
| `dev_framework/save_tool/encrypt_salt` | String | 项目名 | 存档加密盐（备用） |
| `dev_framework/mcp/ignored_error_patterns` | PackedStringArray | `[]` | 运行期错误的过滤子串（如 `"对象池"`），命中即不随结果返回。追加在内置模式之后——内置已含 `Unrecognized UID`（编辑器重启后 UID 缓存重建期的无害噪音）。对 eval 附带错误与通用工具诊断两条上报路径同时生效 |

---

## 三、Def 数据定义层

### 3.1 Def 基类（`Def.gd`）

所有定义的基类，继承自 `Resource`。核心能力：

| 成员 | 说明 |
|---|---|
| `name` | 资源名。内置（built-in）资源取脚本 `class_name`，文件资源取文件名，自动兼容 |
| `_to_string()` | 显示为 `tr(name)`，支持翻译 |
| `get_desc(data)` | 描述文本（可携带上下文），静态调用见 `Def.get_def_desc(def, data)` |
| `save_data()` / `load_data(path)` | 存档短路径（相对 `res://Assets/Def/`）与还原，文件缺失返回 null 并打日志 |
| `_get_zh / _set_zh` | 中文配置读写，自动对接 `res://Assets/Translation/*.csv` |
| `get_root_def()` | 获取外层根 Def（用于 built-in 子资源回写翻译） |
| `_init_def` | 若子类定义了此方法，在属性校验时自动调用（常用于初始化默认导出） |

**Def 中文翻译约定：** 在编辑器里通过 `zh_name` / `tr_desc` / `zh_desc` 等导出的中文属性修改，会自动保存到对应 CSV（列名为 `zh`），运行期 `tr()` 生效。

### 3.2 定义类族谱

```
Def
├── EntityDef            # 通用实体定义（中文名、图标、主题色、效果、强度值）
│   ├── TagDef           # 标签定义（tag 匹配判断）
│   ├── TipDef           # 提示/图鉴定义
│   └── TaskDef          # 任务定义（抽象）
│       ├── SignalTaskDef   # 信号驱动任务
│       └── GroupTaskDef    # 分组任务（顺序/任意/任一完成）
├── ConditionDef         # 条件（抽象）→ is_met(context)
│   └── ValueConditionDef  # 数值比较条件（=、!=、>、<、>=、<=）
├── EffectDef            # 效果（抽象）→ apply(context) / revert(context)
│   ├── EffectsDef       # 效果组合（依次执行）
│   └── SystemEffectDef # 内置文本效果（占位，仅描述）
├── ValueDef             # 数值表达式（抽象）→ get_float / get_int
│   ├── IntValueDef / FloatValueDef        # 常量
│   ├── AddValueDef / SubtractValueDef     # 加减
│   ├── MultiplyValueDef / DivideValueDef  # 乘除
│   ├── PercentValueDef                     # 百分比（10 取整）
│   ├── FractionValueDef                    # 分数
│   └── MaxValueDef / MinValueDef           # 最大/最小
└── SignalDef            # 信号定义（抽象）→ connect/disconnect_signal(data, callable)
    └── ConditionSignalDef  # 带条件的信号包装

# 项目层扩展示例（本仓库，见 LAYERS.md 分层约定）
EntityDef ├── AttributeDef（属性）/ BuffDef（Buff）/ AttributeTagDef / BuffTagDef
```

### 3.3 扩展一个新的 Def

以实际项目中的 `DamageEffectDef` 为例：

```gdscript
@tool
class_name DamageEffectDef extends EffectDef

@export var value: ValueDef
@export var damage_type: DamageTagDef

func apply(data: GameContext):
	if not value:
		return
	data.damage = ceili(data.get_value(value))
	data.damage_type = damage_type
	await data.user.fight.deal_damage(data)

func get_desc(data) -> String:
	return tr("DamageEffect").format({value = get_def_desc(value, data)})

func _to_string():
	return tr("DamageEffect").format({value = value})
```

要点：
- 定义类声明 `@tool`，方便编辑器实时刷新。
- `@export` 组合其他 Def（`ValueDef`、`TagDef`…）即可在编辑器中可视化配置数值表达式与标签。
- 需要重写 `apply()`（效果执行）、`_to_string()`（调试/配置面板展示）、`get_desc()`（玩家可见描述，通常使用 `tr()` + 翻译键）。
- 需要恢复时重写 `revert()`。

### 3.4 任务（Task）体系

`TaskDef` 定义任务，`Task` 负责运行时推进。状态机：`INACTIVE → ACTIVE → COMPLETED / FAILED / CANCELLED`。

| 子类 | 行为 |
|---|---|
| `SignalTaskDef` / `SignalTask` | 任一信号触发即完成 |
| `CountTaskDef` / `CountTask` | 计数目标：信号累加到 `required` 即完成（进度型） |
| `GroupTaskDef` / `GroupTask` | 三种模式：`SEQUENTIAL`（顺序）、`ANY_ORDER`（任意顺序全部）、`COMPLETE_ANY`（任一完成即结束） |

```gdscript
var task := Task.create(task_def)  # 通过工厂创建实体
task.activate(data)
task.completed.connect(_on_task_done)
task.get_progress()                # Vector2i(已完成数, 总数)
```

任务实体支持 `save_data()` / `load_data()` 与 `Task.restore()` 存档还原；`TaskTool` 提供活动列表/按 Def 查找/聚合存读档。详见 [`Task/Readme.md`](Task/Readme.md)。

---

## 四、Entity 实体层

### 4.1 Entity 基类（`Entity.gd`）

运行时实体基类（`RefCounted`）。提供了 `entity_changed` 信号、统一的 `def` 驱动模式与 `get_desc()`。

### 4.2 Buff（`Buff.gd`，项目层）

> 本仓库已将 Buff 下沉到项目 `Scripts/Entity/Buff.gd`（含业务语义：层数触发效果、联机策略），框架不再内置。以下用法不变，仅位置在项目层。

带层数（stacks）的实体：

```gdscript
var buff = Buff.new(buff_def)
buff.data = context                    # 效果执行的上下文
buff.stacks += 2                       # 加层 → 触发 def.effect.apply(data)
buff.stacks -= 1                       # 减层 → 0 跨边界触发 effect.revert(data)
buff.stacks_changed.connect(func(offset): ...)
```

**关键逻辑：** `stacks` 从 0→正数时执行 `def.effect.apply(data)`；从正数→0 时执行 `revert(data)`。层数最小为 0。

### 4.3 Modifier 与 ModifierValue（属性修饰系统）

`ModifierValue` 是带基础值 + 修饰器链的数值：

```gdscript
var attr := ModifierValue.new(attr_def)
attr.base_value = 100
attr.add_modifier(Modifier.new(source, 20))                       # +20 → 120
attr.add_modifier(Modifier.new(source, 50, Modifier.Mode.PERCENT)) # ×50% → 60
attr.remove_modifiers(source)     # 移除某来源的所有修饰
attr.value_changed.connect(func(modifier): ...)
```

- `base_value`：基础值，可直接赋值。
- `value`：只读，禁止直接修改（赋值会报错）。
- `Modifier.Mode.VALUE`：加/减固定值；`Modifier.Mode.PERCENT`：乘百分比。

### 4.4 Component（节点组件）

组件继承 `Component`（本质是 `Node`），挂载到场景节点上。框架只提供 `Component` 基类（宿主查找 + ECS 桥接）；业务容器属项目层，如本仓库的：

| 组件（项目层） | 职责 | 关键 API |
|---|---|---|
| `AttributeComponent` | 管理一组属性 | `get_attribute(name)`、`add_modifier(attr, mod, immediate)`、`remove_modifiers(source)`、`clear()`、`save_data()` |
| `BuffComponent` | 管理 Buff 层数 | `get_buff(name)`、`add_stacks(name, n)`、`remove_stacks(name, n)`、`clear_stacks(name)`、`save_data()` |

```gdscript
# BuffComponent 支持上下文提供者
buff_component.context_provider = func(buff): return GameContext.new(...)
```

`AttributeComponent` / `BuffComponent` 均实现了 `game_ready()`（清空）与 `save_data()` / `load_data()`，配合 `ActorTool` 可一键接入存档流程。

### 4.5 StateMachine（状态机）

通用流程级状态机（`RefCounted`）：

```gdscript
var sm = StateMachine.new(State.Start)
sm.add_transition(State.Start, State.Shop)
sm.on_guard(State.Shop, _can_enter_shop)   # 守卫，返回 false 阻止转换
sm.on_enter(State.Shop, _on_enter_shop)    # 进入回调（支持 async）
sm.on_exit(State.Shop, _on_exit_shop)      # 退出回调
await sm.transition(State.Shop)            # 异步转换（会 await guard/exit/enter）
sm.force_set(State.Start)                  # 强制设置，不触发回调
sm.allow_self_transition(true)
```

> 注意：`transition()` 是异步函数；适用于流程级状态管理，不用于海量短生命周期对象。

### 4.6 ECS 高性能实体组件系统（`ECS/`）

框架内置一套 **C++ 原生高性能 ECS**（SoA 列存储、签名增量视图、规则 DSL 批量运算、系统并行调度、生命周期钩子、Prefab / 序列化等），用于海量实体的数值逻辑与数据处理。与 Godot 场景节点配合：海量实体渲染直读、关键实体用 `Component` 桥接。

```gdscript
var world := ECSWorld.new()
world.register_component(HealthComponent)
var e := world.create_entity()
world.add_component(e, HealthComponent)
world.register_system(HealSystem.new())
world.tick(delta)
```

**完整使用说明见 [`ECS/Readme.md`](ECS/Readme.md)**。

### 4.6b 框架级共享原生库（`Native/`）

整个 DEVFramework 的 C++ 原生能力集中在**唯一一个共享扩展**：
`res://addons/DEVFramework/Native/dev.gdextension`（编译产物也在该目录）。任何模块的原生类都注册在这一个库里，共用一份二进制。当前已注册：
- `ECSCore` — ECS 高性能实体组件系统

> 已编译产物 `dev.gdextension` 内**仍注册着已移除模块的原生类**：6 个 PCG 原生类（`PCGWFC3D` / `PCGCave3D` /
> `PCGWFC` / `PCGWFCAnimator` / `PCGErode` / `PCGLSystem`）与 `AudioSynthEngine`。它们的 C++ 源码已随之移除，
> 但**没有任何 GDScript 调用方**，故不阻塞运行；下次重编译 `dev.gdextension` 时会自动消失。

由 **`FrameworkNative`**（`Native/FrameworkNative.gd`）统一懒加载与校验：
- `FrameworkNative.get_native(&"ECSCore", required_methods)` — 按类名取共享实例（缓存 + 方法集版本校验）
- `FrameworkNative.instantiate_script(script)` — 稳定的脚本实例化（规避全局类注册时序问题）
- `FrameworkNative.refresh(...)` — 清缓存（库热重载/测试）

新增模块原生能力时：把 C++ 类注册进 `dev.gdextension`（需源码重编译），GDScript 侧通过 `FrameworkNative.get_native(&"你的类名", [...])` 访问，不要各自维护一份 ClassDB 检测逻辑。

### 4.8 Camera 虚拟机位（`Camera/`）

3D 镜头管理模块，思路对齐 Unity Cinemachine：场景里摆若干**机位**（`VirtualCamera3D`，只描述取景意图），
由场景中唯一的**大脑**（`CameraBrain3D`，真实 `Camera3D`）每帧挑出生效机位并平滑混合过去。

```gdscript
vcam.set_active(true)        # 参与竞争(面板信号可直连 set_active(bind true/false))
vcam.activate(0.5)           # 代码切换, 本次过渡 0.5 秒
vcam.deactivate()            # 退出竞争, 自动回落到上一个机位
CameraTool.get_camera()      # 真实渲染相机(无 Brain 时退回视口相机)
CameraTool.snap()            # 立即对齐当前机位(传送/场景切换)
```

- **竞争规则**：`priority` 大者胜，同级取最后激活者 → 「开面板激活机位 / 关面板取消激活」天然构成机位栈；生效机位带缓存，不每帧遍历。
- **混合**：固定时长 + Tween 曲线（每个机位可单独配 `blend_time/trans/ease`）；位置可选 **直线 / 球面 / 柱面** 轨迹（绕枢纽点绕行，不会切过目标内部）；`lens_fov` 一并插值；混合结束后持续跟随机位。需要 **A→B 专属过渡** 或按来源/目标统一过渡时，在 Brain 的 `blends` 挂 [过渡规则](Camera/Readme.md#过渡规则表blends)（按机位名匹配、支持通配、精确者胜）。
- **机位能力**：默认固定取景（Inspector 极简）；需要动态取景时挂 [行为资源](Camera/Readme.md#三行为资源camerabehaviordef)——内置 `FollowBehaviorDef`（跟随 + 按轴阻尼 + **死区/软区**）、`LookAtBehaviorDef`（瞄准 + 可配 up）、`NoiseBehaviorDef`（常驻手持抖动，噪声源用 Godot 原生 `Noise`），也可继承 `CameraBehaviorDef` 自定义；另有 `lens_fov`（覆盖视场角）。
- **不重复造轮子**：碰撞回避用 `SpringArm3D`、路径运镜用 `PathFollow3D`、物理插值用引擎设置——见 [用 Godot 原生能力组合高级机位](Camera/Readme.md#五用-godot-原生能力组合高级机位)。
- **待机策略**：`standby_update` 三档（ALWAYS / ROUND_ROBIN / NEVER），未生效机位不白跑；上台瞬间自动对齐姿态。
- **冲击与震屏**：`CameraTool.impulse(pos, strength, radius, duration)` 定向冲击（传播延迟 + 距离衰减）、`CameraTool.shake(strength)` 无方向震屏。
- **叠加偏移层**：常态特效/鼠标跟随一律写 Brain 的 `position_offset` / `rotation_offset`，与机位混合互不争写 transform（`TweenShake` 把 `property` 指向 `:position_offset` 即可）。
- **编辑器**：机位有视锥 gizmo（插件注册，生效中显示橙色）与「对齐到编辑器视角」按钮；底部面板 **Camera Viewfinder** 可实时预览机位画面（共享编辑器 3D 视口的 World3D，带三分线构图辅助与 Solo）。

**完整使用说明见 [`Camera/Readme.md`](Camera/Readme.md)**。

---

## 五、Tool 工具层

全部为静态类，随处可调用。

### 5.1 LogTool — 日志

```gdscript
LogTool.log("战斗", "造成伤害:", 10)        # 彩色标签日志
LogTool.warn("战斗", "数值异常")            # 黄色
LogTool.error("战斗", "严重错误")           # 红色
LogTool.timer("加载", "加载卡池").stop()   # 计时器，stop() 时输出耗时

LogTool.set_enabled(false)                # 全局开关
LogTool.disable_tag("战斗")               # 忽略某个标签
```

### 5.2 SaveTool — 存档

- `SaveTool.save_data(path, data, Mode.JSON/GZIP)`
- `SaveTool.load_data(path, mode)`：主档损坏自动三级 `.bak` 回退。
- `SaveTool.save_async()` / `load_async()`：异步保存（同路径连续请求只保留最新数据）。
- `SaveTool.merge_data(local, cloud, rules)`：本地/云端合并（用于云存档冲突处理）。
- `SaveTool.check_version(data, version, defaults)`：版本迁移 + 缺失字段补齐。
- `SaveTool.load_defs(dir, filter)`：递归扫描目录加载 Def 资源（兼容导出后的 `.remap`）。

```gdscript
# 合并规则示例
SaveTool.merge_data(local, cloud, {
	name = SaveTool.MergeMode.NON_EMPTY,     # 非空才覆盖
	gold = SaveTool.MergeMode.MAX,           # 取大值
	inventory = [SaveTool.MergeMode.ARRAY_UNION, "id", 50],  # 按 id 去重并截断
})
```

### 5.3 AsyncTool — 异步

```gdscript
await AsyncTool.load_resource_async("res://big_tex.png")       # 后台加载资源
var result = await AsyncTool.thread_call(work_callable)        # 后台线程执行
await AsyncTool.await_until(func(): return _flag)              # 每帧轮询
await AsyncTool.await_signals(sig_a, sig_b)                    # 等待多个信号各触发一次
await AsyncTool.call_in_frames(items, 30, process_fn)          # 分帧批量处理，防掉帧
await AsyncTool.await_with_timeout(action, 5000, "取名")       # 等待到完成，超时只告警（看门狗）
AsyncTool.await_emit(sig, args...)                             # 手动触发信号并同步 await 回调
```

### 5.4 InputTool — 输入管理

```gdscript
InputTool.set_input_mode(InputTool.Mode.NAVIGATION)   # 切换指针/导航模式
InputTool.detect_mode(event)                          # 自动识别输入设备
InputTool.register_focus_group([btn1, btn2, btn3])    # 注册焦点组（2D 自动导航 / 3D 手动）
InputTool.handle_input(event)                         # 统一入口（游戏循环里调用）

# InputMap 操作与持久化
InputTool.register_action(&"jump", [InputTool.key_event(KEY_SPACE)])
InputTool.save() / InputTool.load()                   # 键位存档
InputTool.bind_shortcut(button, &"open_menu", KEY_ESCAPE)
```

### 5.5 TimeTool — 时间缩放

```gdscript
TimeTool.set_base_speed(1.5)        # 基础游戏速度
TimeTool.set_modifier("slow_mo", 0.3)  # 按 key 叠加倍率修改器
TimeTool.pause() / TimeTool.resume()
TimeTool.get_current_scale()        # 当前最终 time_scale
```

**步进队列（`TickTool` + `GameTimer`）** —— 让"同一物理 tick 内多个等待恢复的先后"可复现：

```gdscript
TickTool.defer(order_key, action)   # 登记"本 tick 末尾按序执行"的动作
```

宿主每物理 tick 末尾调用一次 `TickTool.tick()`（须在角色 `_physics_process` 之后）。派发按
`order_key` 升序、同 key 按登记先后（FIFO）⇒ 顺序是队列内容的**纯函数**，与场景树顺序、启动时机、
帧率都无关；`order_key` 的含义由项目决定（框架不解释）。未调用过 `tick()` 时 `defer` 立即执行 ——
行为与不使用本工具一致，不会因未接线而挂住等待。`GameTimer` 是它的计时器载体：到期/提前停止都进
同一队列，计时基准为物理 tick。

### 5.6 TranslationTool — 翻译

```gdscript
TranslationTool.initialize()                     # 扫描 + 按系统语言加载
TranslationTool.set_locale("zh_CN")              # 切换语言
TranslationTool.get_locales() / get_display_name("zh_CN")
```

### 5.7 ActorTool — 生命周期编排

按约定在场景节点上实现 `game_init()`、`game_ready()`、`save_data()`、`load_data()` 方法，由父节点统一调度：

```gdscript
await ActorTool.game_ready(root)      # 遍历子节点调用 game_ready
var data = await ActorTool.save_data(root)
await ActorTool.load_data(root, data)
```

### 5.8 通用音频管理（AudioTool）

> 程序化音频合成（Def 驱动的逐采样合成、C++ `AudioSynthEngine` 内核、风格/编曲模板与示例音效库）
> 已于 2026-10 从本仓移除。AudioTool 现在只做**通用音频管理**：播放任意 `AudioStream`、总线效果、
> WAV 保存、流查询、效果录音。

```gdscript
AudioTool.play_stream(stream, -6.0, "SFX")          # 播放任意音频流(播放结束自动释放)
AudioTool.get_stream_info(stream)                   # 查询时长/采样率/声道/循环
AudioTool.save_wav(stream, "res://out/sfx.wav")      # 导出标准立体声 WAV
AudioTool.save_resource(stream, "res://out/sfx.tres")# 存为 Godot 音频资源(可直接拖入播放器)
AudioTool.setup_audio_buses()                       # 一键生成 Master/SFX/BGM/UI 标准总线布局
```

**音频处理全部交给 Godot 内置能力，框架不做任何逐采样合成**：

| 能力 | 实现 | 说明 |
|---|---|---|
| 播放 / 循环 | **Godot 内置 `AudioStreamPlayer`** | `play_stream()` 播放结束自动释放；循环用 `AudioStreamWAV.loop_mode` |
| 混响 / 延迟 / 失真 / 限幅 / 压缩 / EQ | **Godot 内置 `AudioEffect`** | 播放时路由到带效果的总线；`create_fx(name)` 取标准预设、`fxs_from_names([...])` 批量构建 |
| 总线布局 | **Godot 内置 `AudioServer` / `AudioBusLayout`** | `setup_audio_buses()` 生成布局并写入项目设置；`ensure_bus()` 幂等建任意效果总线 |
| 效果录音 | 内置 `AudioEffectRecord` | `render_with_fx(stream, fx)` 真实播放 + 录音固化效果链（需可用音频设备） |
| WAV 写盘 | 自写 44 字节标准 PCM 头 | 见下方说明 |

标准预设名：`reverb` / `reverb_hall` / `delay` / `distortion` / `limiter` / `compressor` / `eq_lowpass` / `eq_highpass` / `eq_bandpass` / `spectrum`。

- `resolve_bus(bus, fx)`：`fx` 非空时自动建 `FX_<bus>` 效果总线，`play_stream()` 内部自动调用。
- WAV 写盘说明：4.7.1 内置 `AudioStreamWAV.save_to_wav()` 会把 16bit 立体声写成 mono 头（数据仍交错），Godot 重导入后声道/时长错乱，故 `save_wav()` 自写标准头。

### 5.9 其他工具

| 工具 | 用途 |
|---|---|
| `CSVDataAccess` | CSV 读写（`get_csv_value` / `set_csv_value` 等） |
| `ArrayViewTool` | 数组视图通用逻辑：`get_item_name` / `create_view` / `free_view`（配合对象池） |
| `TweenViewTool` | Tween 显隐控制与释放：`update_visible` / `finish_and_free` |

| `CameraTool` | Camera 模块统一入口：`get_brain` / `get_camera` / `get_current` / `activate` / `deactivate` / `find` / `snap` |
| `DevProjectSetup` | 一键创建项目目录结构（编辑器菜单触发） |
| `SpriteFramesToAnimationLibrary` | `EditorScript`：将选中的 SpriteFrames 生成 AnimationLibrary |

### 5.10 更新日志（ChangelogTool）

面向玩家的「版本更新提示」：框架只负责**版本判定 / 条目过滤 / 已见状态记录**，**UI 由项目自行实现**。

- 当前版本：Godot 内置项目设置 `application/config/version`（项目设置 → Application → Config → Version，发布时修改；未配置时回退到日志 Def 中的最高版本）。
- 内容：在 `Assets/Def/` 下建 `ChangelogDef` 的 .tres，每个 `ChangelogEntryDef` 介绍**一个**功能更新（`version / date / category / text / player_visible`）；`target` 可指向任意资源（配置 Def / 图片 / 模型等），如何展示由项目决定。示例见 `Assets/Def/Changelog/ChangelogExample.tres`。
- 已见版本：**不单独存储文件**，由项目并入自己的游戏存档持久化（读 `get_seen_version()`，写入用 `mark_seen()`/`load_seen_version()`）；不并入则视为首次运行，不弹窗。

```gdscript
# 读档（游戏启动加载存档后、判断更新前）
ChangelogTool.load_seen_version(save_data.get("changelog_version", ""))
if ChangelogTool.has_update():
    var entries: Array = ChangelogTool.get_pending_entries()  # 待展示条目（新→旧）
    changelog_popup.show_entries(entries)  # 项目自建弹窗
    ChangelogTool.mark_seen()              # 展示后记录已见版本
# 存档时
save_data["changelog_version"] = ChangelogTool.get_seen_version()
```

---

## 六、View 视图层

### 6.1 UI 管理（UITool + UIPanel / UIPanel3D）

**UITool** 是纯栈管理器，将 UI 分为 6 层：

| 层级 | 值 | 行为 |
|---|---|---|
| `BACKGROUND` | 0 | 常驻背景，入栈、最低优先级 |
| `HUD` | 100 | 抬头显示，多元素共存，不参与返回键 |
| `PANEL` | 200 | 主界面，入栈、可共存、参与返回键 |
| `DIALOG` | 300 | 对话框，同层互斥（开新的自动关旧的） |
| `TOOLTIP` | 400 | 提示，不入栈、单实例 |
| `TOP` | 500 | 系统顶层（Loading/通知），覆盖一切 |

面板继承 `UIPanel`（2D `Control`）或 `UIPanel3D`（3D `Node3D`），二者 API 完全对齐：

```gdscript
panel.open()              # 注册到 UITool 并播放进入动画
panel.close()             # 播放离开动画并从栈注销
panel.toggle()
panel.popup()             # 弹窗式：打开后 await on_closed
await panel.await_closed()  # 等待关闭（可检测是否被重新打开）

# 生命周期信号
on_open / on_opened / on_close / on_closed

# 返回键：可重写 _back()，默认调用 close()
# 焦点：可重写 _focus_enter() / _focus_exit()

UITool.back()          # 返回键处理（优先 DIALOG，其次 PANEL）
UITool.close_all()     # 关闭全部
UITool.is_focus(panel)
```

> 遵循项目规范：UI 一律通过场景（`.tscn`）搭建，UIPanel 挂在 Canvas 下，不做纯代码 UI。

### 6.2 数组视图

| 类 | 用途 |
|---|---|
| `ArrayView` | 通用数组视图（`FlowContainer`），数据变化即重建，支持分帧生成 |
| `SlotArrayView2D/3D` | 固定插槽视图，数据逐项填充到预先排布的插槽 |
| `OffsetArrayView2D/3D` | 按 `offset` 间距自动排列的插槽视图（拖拽排序场景） |

```gdscript
array_view.data = my_items          # 赋值即自动刷新
array_view.refresh_item(item)       # 局部刷新
array_view.remove_item(item)
```

视图子节点约定：`data` 属性接收数据项，`get_view_name()`（或 Def 名）作为唯一标识；配合 `BakedPool` / `BakedPoolManager` 可实现对象池复用。

### 6.3 按钮 / 交互

| 类 | 说明 |
|---|---|
| `ButtonView` | 2D 按钮（`Button`），连接 `TweenAnimation` 显隐，可重写 `_mouse_enter/_mouse_exit` |
| `ButtonView3D` | 3D 按钮（`Area3D`），悬停/按下 Tween + 描边 + 音效，支持手柄激活 |
| `DragView3D` | 3D 拖拽视图，内置拖拽/排序生命周期（`_on_drag_started/_on_drag_move/_on_drag_ended` 可重写） |

### 6.4 特效与渲染

| 类 | 说明 |
|---|---|
| `TweenView / 2D / 3D` | 通过 `tween_visible` 布尔驱动 Tween 显隐 |
| `OutlineEffect` | 多实例后处理描边（一个实例 = 一种描边，在 Compositor 资源里配置颜色/宽度/标记通道）。项目侧 @export 直接引用实例资源，调用实例的 `set_marked(true, mesh)` 开关；框架内部悬停走静态快捷方式 `OutlineEffect.set_outlined(true, mesh)`（固定通道 0）。颜色动画由项目侧每帧改实例的 `outline_color` 驱动 |
| `GLSLShaderEffect` | 可编程后处理（填 `define_code` / `main_code` 实时编译） |
| `Trail3D` | 拖尾网格 |
| `BakedPool / BakedPoolManager` | 烘焙对象池（编辑器一键生成池子，运行时 `pool_get`/`pool_push`） |
| `ScreenshotCapture` | 延迟自动截图（`auto_capture_delay`，默认 3 秒；启动后自动截一张，无手动触发入口。默认不透明背景，需抠图时勾 `transparent_background`；含抖动量化） |
| `SubView3D` | 3D 子视口（把 2D UI 投影到 3D 表面） |
| `Background` | 视差滚动背景 |
| `SwingFollow2D` | 摆动跟随动画 |
| `GimbalView` | 反相缩放/旋转的“云台”控件（2D UI 始终面向相机） |
| `ShaderProgressBar` | 通过 shader 参数驱动的进度条（`Range` 子类） |
| `Sprite3dLight` | Sprite3D 光效播放（Tween 进出场） |
| `OptionSelector` | 选项选择器（SPINNER / TOGGLE 两种模式，支持键盘导航） |

---

## 七、MCP 调试服务器

DEV Framework 内置一个 **MCP（Model Context Protocol）调试服务器**，由**编辑器插件**持有，随插件启用/停用而开启/关闭，让 AI 助手（opencode / Claude Code / Cursor 等）直接连接正在打开的编辑器，辅助编辑场景、校验脚本、诊断错误。

### 7.1 原理与架构

```
AI 助手 ──MCP Streamable HTTP──▶ http://127.0.0.1:8931/mcp  (Godot 编辑器内嵌)
```

- Godot 编辑器内部用 `TCPServer` 实现了一个轻量 HTTP 服务器（`MCPTcpHttpServer`）。
- 由 `plugin.gd` 在**启用插件时启动**、**停用时关闭**，不依赖 autoload、不污染导出构建。
- 通过 `MCPDevServer`（`RefCounted`）持有；通过继承 Godot 4.5+ 的 `Logger`（`MCPLogger`）**捕获编辑器控制台输出与错误（含 GDScript 栈追踪）**，线程安全。
- 每帧由 `plugin.gd::_process` 驱动服务器处理请求。

### 2. 启用与配置

- 编辑器启用 `DEV Framework` 插件即自动开启 MCP 服务器（`_enter_tree`）。
- 配置项（`项目设置 → DEV Framework` 或直接改 `project.godot`）：

| 设置项 | 默认值 | 说明 |
|---|---|---|
| `dev_framework/mcp/enabled` | `true` | MCP 服务器总开关 |
| `dev_framework/mcp/port` | `8931` | 监听端口（仅本机 `127.0.0.1`）|
| `dev_framework/mcp/log_tool_results` | `false` | 是否把**每次工具调用**（入参 + 返回摘要）打进 Godot 输出面板。默认关闭：日志捕获器挂在引擎 `print` 通道上，MCP 自己的回声会被 `get_logs` 原样返回给 AI，白占上下文并淹没项目日志。工具**报错**始终以 error 级别输出，不受此开关影响 |

### 3. AI 助手连接配置

DEV Framework 的 MCP 使用 **Streamable HTTP** 传输，端点为 `http://127.0.0.1:8931/mcp`（仅本机，需先启用插件）。下面按**配置文件格式**分组给出各工具接入方式。

#### A. opencode / Claude Code 等 CLI 工具

**opencode**（`opencode.json` / `opencode.jsonc`，`mcp` 直接按服务器名作 key）：

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "devframework-godot-mcp": {
      "type": "remote",
      "url": "http://127.0.0.1:8931/mcp",
      "enabled": true
    }
  }
}
```

**Claude Code**（命令行，无需手写 JSON）：

```bash
claude mcp add --transport http devframework-godot-mcp http://127.0.0.1:8931/mcp
claude mcp list        # 查看已配置
```

#### B. `mcpServers` 格式（Cline / Roo Code / TRAE / Cherry Studio / 通义灵码 / VS Code 等）

这类工具共用 `mcpServers` 对象结构，把 `devframework-godot-mcp` 加入即可：

```jsonc
{
  "mcpServers": {
    "devframework-godot-mcp": {
      "url": "http://127.0.0.1:8931/mcp"
    }
  }
}
```

各工具放置位置与字段差异：

| 工具 | 配置位置 | 说明 |
|---|---|---|
| **Cline** | `~/.cline/mcp.json`，或 MCP Servers → Configure → 编辑 JSON | `type` 写 `streamableHttp` |
| **Roo Code** | 扩展设置 `settings.json` → `mcpServers` | `type` 必须写 `streamable-http` |
| **TRAE** | 项目级 `.trae/mcp.json`，或 设置 → MCP → 手动添加 | 仅需 `url`，`type` 可省略 |
| **Cherry Studio** | 设置 → MCP 服务器 → 添加 / 从 JSON 导入 | `type` 写 `streamableHttp` |
| **通义灵码** | 个人设置 → MCP 服务 → 配置文件添加 | 也支持界面手动添加（见下）|
| **VS Code** | `.vscode/mcp.json` | 顶层为 `servers`，字段以官方文档为准 |

#### C. 界面手动添加（无需 JSON，Cursor / 通义灵码 / 豆包 MarsCode 等）

| 工具 | 操作路径 | 填写内容 |
|---|---|---|
| **Cursor** | Settings → MCP → Add | 类型选 remote/HTTP，URL 填 `http://127.0.0.1:8931/mcp` |
| **通义灵码** | 个人设置 → MCP 服务 → `+` → 手动添加 | 类型选 SSE/HTTP，服务地址填 `http://127.0.0.1:8931/mcp` |
| **豆包 MarsCode** | 设置 → MCP → 添加 | 类型选 HTTP，URL 填 `http://127.0.0.1:8931/mcp` |
| **腾讯云 AI 代码助手** | 设置 → MCP → 添加 | URL 填 `http://127.0.0.1:8931/mcp` |

> 若工具界面没有"远程/HTTP"类型选项，可改用 `mcpServers` JSON 方式（见 B 组）。
>
> 注意：必须先启用 `DEV Framework` 插件，该 MCP 才会监听端口。

### 4. 内置工具清单

| 工具名 | 作用 |
|---|---|
| `validate` | **统一验证入口**（`kind=script/resource`）。script: 校验 GDScript 语法/可编译性（传 `path` 或 `code`，兼容非 `@tool`/纯工具类脚本）；resource: 校验资源/场景能否被引擎加载 |
| `list_dir` | 列出目录内容（支持递归）|
| `classdb_query` | 查询 Godot 类的 API（方法/属性/信号签名）或按关键字搜索类名，供 AI 写脚本前确认原生 API |
| `get_logs` | **编辑器侧**日志/警告/错误获取：`kind=log/warning/error`、增量游标、重复合并。恒读编辑器进程缓冲 |
| `clear_logs` | 清空**编辑器侧**日志/错误缓冲（`scope=all/logs/errors`）|
| `get_game_logs` | **游戏进程侧**日志（print/printerr），增量游标、重复合并。编辑器调用时经调试线转发 |
| `get_game_errors` | **游戏进程侧**错误（脚本错误/assert/push_error，含文件/行号/栈追踪）。游戏断点暂停时仍可安全调用 |
| `clear_game_logs` / `clear_game_errors` | 清空**游戏进程侧**缓冲（`scope=all/logs/errors`）|

> 日志类工具的进程归属**只由工具名决定**：不带 `game_` 的读本进程缓冲，带 `game_` 的读游戏进程缓冲。
> 早期 `get_logs` 另有 `source=auto/editor/game` 三档，其中 `auto` 会在游戏运行时静默改读游戏缓冲——
> 查编辑器自己的错误却拿到游戏的错误，且调用方无从察觉。故已删除该参数，跨进程只保留一条通路。
| `take_screenshot` | 截图四模式：text（节点布局文本化）/ game / editor / scene |
| `get_scene_tree` | 获取当前编辑场景的节点树结构 |
| `get_node_info` | 读取编辑场景中指定节点属性列表及当前值 |
| `set_node_property` | 修改编辑场景中节点属性（UndoRedo 可撤销；保存才写回 .tscn）。含 position/rotation/scale 等 transform 属性（Vector 可传 `'1,2'` 字符串）|
| `call_node_method` | 触发编辑场景中节点方法 |
| `add_node` / `remove_node` / `duplicate_node` | 添加 / 删除 / 复制场景节点（UndoRedo 可撤销）|
| `connect_signal` | 连接场景节点信号到方法（随场景保存）|
| `create_resource` | 创建 .tres 资源配置（指定脚本 + 属性字典，配置驱动开发用）|
| `get_resource_info` | 读取 .tres/.tscn 资源完整属性树（递归，理解配置结构）|
| `get_editor_activity` | 感知编辑器当前状态（打开场景/选中节点/运行中游戏），用于 AI 与人类协作不踩踏 |
| `get_project_info` | 项目信息统一入口：`section=basic`(默认)/`settings`(主场景/autoload/输入映射)/`classes`(全局类清单) |
| `game_control` | 游戏运行控制：`action=start`(支持 uid:// 场景；已在运行时自动接管重启)/`stop` |
| `restart_editor` | **重启编辑器**：修改框架代码后调用以统一全局类脚本代次让新逻辑生效（原重扫逻辑已由编辑器自动处理）；**总会先保存全部已打开的场景**（封装 `EditorInterface.restart_editor(true)`）；`delay_sec` 延迟触发；重启期间 MCP 断开、回来自动恢复 |
| `eval_code` | 在编辑器内执行一段 GDScript 代码并返回结果。**支持 await**：代码含 `await` 时等待协程完成后回传最终返回值（`timeout_ms` 默认 8000/上限 15000，超时协程继续后台执行、实例自动延迟回收）|
| `open_scene` | 在编辑器打开指定场景 |
| `set_main_scene` | 设置项目主场景并保存 |
| `project_setting` | 读/写任意 ProjectSettings 项：`value` 缺省=读取，提供=写入保存（数组/对象自动还原 Variant）|
| `save_all` | 保存全部场景与项目设置 |
| `reimport` | 重新导入指定资源（重建导入缓存）|
| `search_symbols` | 跨脚本/场景/资源搜索符号（函数/变量/类定义与引用，支持节点名与资源路径）|
| `find_resource_users` | **双向依赖查询**：`users`=谁引用该资源（反向），`deps`=该资源依赖谁（正向，带类型标签）。目标为带全局类名的脚本时额外扫描类名在其它 .gd 中的词边界使用点（kind=class_ref，覆盖 @onready/类型注解/静态调用等无路径引用场景）。改/删资源前查完整影响面 |
| `auto_verify` | **自动验证闭环**：启动场景后按操作序列模拟玩家行为（wait/click/drag/key/eval/poll/screenshot），每步后增量查错。支持 hard/soft 模式、flaky 重试、依赖变化检测。游戏已在运行时自动接管（停止旧实例后重跑） |
| `verify_fix` | **有状态验证修复会话**：记住验证配置，AI 改完代码后 `continue` 即重跑（省去重传操作序列），支持多会话并行 |
| `run_tests` | 运行项目单元测试（`Scripts/Test/`，extends TestCase，test_ 开头方法自动发现；支持协程用例）。返回统计与失败明细 |
| `refresh_tools` | 手动重建 MCP 工具注册表：改框架脚本后调用，客户端重拉 tools/list 即生效（免重启） |

> **提示**：修改插件代码（`MCPDevServer.gd` 等）后，新工具需**重启编辑器**才会注册（脚本热重载不会重建工具注册表）。可调用 `restart_editor` 工具一键重启（保存后重启），或改完后调 `refresh_tools` 重建注册表。

### 5. 典型 AI 调试流程

1. 打开项目并启用 `DEV Framework` 插件，连接 http://127.0.0.1:8931/mcp。
2. AI `list_dir` / `validate` 排查脚本与资源问题。
3. AI `get_scene_tree` / `get_node_info` 理解当前编辑场景的节点与属性。
4. AI 用 `set_node_property` / `call_node_method` 快速验证逻辑，`get_logs`(kind=error) 定位报错。
5. `take_screenshot` 查看编辑器画面实际表现。

### 5.1 自动验证闭环（auto_verify / verify_fix）

`auto_verify` 把"启动游戏 → 模拟操作 → 逐帧查错 → 停止游戏"串成**一次工具调用**，专门捕获**操作触发的运行时错误**（点击崩溃、走到某处报错、动画播完炸）。适合 AI 改完代码后的回归验证。

**操作序列**（`operations` 数组，按序执行，操作间可任意延迟）：

```json
[
  {"action": "wait", "ms": 800},
  {"action": "click", "x": 100, "y": 200},
  {"action": "wait", "ms": 500},
  {"action": "poll", "code": "return get_node(\"/root/...\").visible", "timeout_ms": 3000},
  {"action": "key", "key": "space"},
  {"action": "screenshot", "capture_type": "text"}
]
```

| 操作 | 参数 | 说明 |
|---|---|---|
| `wait` | `ms` | 显式延迟（操作间间隔）|
| `click` | `x, y` | 模拟点击（复用 `simulate_click`）|
| `drag` | `from_x, from_y, to_x, to_y` | 模拟拖拽 |
| `key` | `key` | 模拟按键 |
| `eval` | `code` | 执行 GDScript，结果记入 step |
| `poll` | `code, timeout_ms, interval_ms` | **轮询直到条件满足**（等异步/动画结果，探测期 eval 错误不计入验证）|
| `screenshot` | `capture_type` | 截图（结果含路径）|

**判定与模式**：
- `verdict=pass/fail`；`first_error_step` 指向出错操作下标，`steps[i].status/errors` 给出定位。
- `stop_on_error=true`（hard）任一步出错立即停；`false`（soft）跑完全部步骤再汇总。
- `retries>0` 失败自动重启场景重跑（排除 flaky）；**曾失败但最终通过会标 `was_flaky=true`**（警惕被时序掩盖的潜在 bug），返回 `retry_history`。
- `prev_snapshot`（由上次返回的 `scene_deps` 提供）可检测**场景依赖（脚本/配置/图片/音频等）是否变化**，结果含 `deps_changed`。

**verify_fix 修复循环**（有状态会话，省 token）：

```
verify_fix {action:"start", scene, operations}   # 存配置 + 跑第 1 轮
# → AI 读错误 → 改代码 →
verify_fix {action:"continue"}                    # 复用配置重跑（无需重传 operations）
verify_fix {action:"status"}                       # 查轮次历史
verify_fix {action:"abort"}                        # 结束会话
```

- `session_id` 可并行多个验证任务；`continue` 时 `deps_changed=false` 表示自上次以来依赖未变，重跑结果大概率相同。
- 典型工作流：`start`（验出 fail）→ 改代码 → `continue`（重验）→ 直到 `pass` → `abort`。

### 6. AI 开发规范（AI 助手必读）

本框架让 AI 不仅能读项目，还能按**项目既有规范**安全地修改场景与脚本。请遵循以下规则，保证 AI 的改动符合"正常游戏开发规范"且不会破坏用户的工作。

**架构与目录约定**
- 项目遵循 **Def（静态数据 .tres）→ Entity（运行时实体）→ View（显示）** 三层架构，配合 `Tool/*` 静态工具类。
- 代码按类目放到 `Scripts/Def/`、`Scripts/Entity/`、`Scripts/View/`，不要把所有脚本塞进单个场景脚本。
- **UI 等可显示内容一律用场景（.tscn）搭建，不要用代码 `new`**（见框架 `View/*` 与 `UITool`）。改动 UI 优先在场景里调整节点属性，而非写代码生成。
- 优先**配置驱动**：能通过 `.tres` 资源配置的数据（数值、效果、标签、GOAP 行动/目标）就用资源，不硬编码在脚本里。
- **3D 程序化生成已拆为独立插件**：原 `addons/DEVFramework/PCG/`（3D 栅格 / 分块世界 / 生成管线 / `SdfField` 双投影 / 造型与摆放双契约 / seed 可复现）已于 2026-10 移出本仓库，改为独立插件项目 `d:\Work\GodotProject\PCG`（插件名 `pcg`，零 autoload、零 `.tres` 依赖）。需要 3D 生成能力时装入该插件并遵循其 Readme；本框架不再内置任何生成器。
- 写脚本时使用显式类型标注（`func foo(x: int) -> void`）、`@onready` 获取节点引用、`@export` 暴露可调参数，与 `Scenes/AI/GoapDemo.gd` 等示例风格一致。

**MCP 工具使用规范**
- 改任何场景节点前，先用 `get_scene_tree` / `get_node_info` 看清结构与当前属性，再动手。
- **不确定 Godot 原生 API 的用法时，先用 `classdb_query` 查询**（方法/属性/信号签名），再写代码，避免臆造 API。
- `set_node_property` 与 `add_node` 已接入 UndoRedo，AI 的修改用户可按 **Ctrl+Z 撤销**——请放心使用，但也不要反复试探性乱改，尽量一次改对。
- 修改场景节点或新建脚本/资源后，记得 `save_scene`（新 class_name 全局类识别依赖重启/扫描，见陷阱1）。
- 长任务（重编译、导出）会占用编辑器，且单次 MCP 调用有超时，**拆成小步骤**完成，不要一次塞超长指令。
- 排查脚本问题时：先 `validate` 验证语法，再 `get_logs`(kind=error) 看运行期错误（含栈追踪），配合 `get_logs` 定位。

**安全边界**
- 编辑器 **运行游戏时**（`get_editor_activity` 显示 game_running=true），应避免对编辑场景做结构性改动；如需改结构先 `game_control`(action=stop)。
- `eval_code` / `game_eval` 可执行任意 GDScript，是**可信开发者工具**，AI 应最小权限使用：只读/求解优先，改动场景尽量走 `set_node_property` 等专门工具而非 eval。
- `write_file` / `delete_file` 会直接读写磁盘，先确认路径无误，避免越界到已知目标文件之外。

**协作约定**
- 动手前先 `get_editor_activity` 看用户在编辑器里做了什么（打开哪个场景/选中哪个节点/是否在运行游戏），避免与用户正在进行的操作踩踏。

---

## 八、典型使用流程

### 场景一：新增一种卡牌效果

1. 在 `Scripts/Def/Effect/` 新建脚本继承 `EffectDef`，实现 `apply()`（和可选 `revert()`）。
2. 在 `Assets/Def/` 下创建 `.tres` 资源，编辑器里组合 `ValueDef` 表达式与标签。
3. 在 Def 资源上配置 `zh_name` / 描述，自动写入翻译 CSV。
4. 运行时由对应组件（如 BuffComponent、技能系统）触发 `def.effect.apply(data)`。

### 场景二：做一个带属性/Buff 的角色

1. 定义 `AttributeDef` / `BuffDef` 资源。
2. 场景节点挂 `AttributeComponent` + `BuffComponent`。
3. 代码中 `add_modifier` / `add_stacks` 驱动数值与效果。
4. 节点实现 `game_ready()` / `save_data()` / `load_data()`，由 `ActorTool` 统一调度存档。

### 场景三：弹出一个设置面板

1. 场景中搭建面板，根节点挂 `UIPanel`（选好 `layer`，如 `PANEL`/`DIALOG`）。
2. 连接 `on_open/on_closed` 处理动画或数据刷新。
3. 代码 `panel.open()`；返回键由 `UITool.back()` 统一接管。

### 场景四：日志与存档接入

```gdscript
# 初始化
LogTool.set_enabled(OS.is_debug_build())
TranslationTool.initialize()

# 存档
var err = await SaveTool.save_async("user://save.json", game_data, SaveTool.Mode.JSON)
var data = await SaveTool.load_async("user://save.json", SaveTool.Mode.JSON)
```

---

## 九、已知引擎陷阱（与框架协作必读）

以下均为 Godot 4.7 实测行为，无报错、难排查，编写/修改框架及使用协程时务必知晓：

### 陷阱1：改框架代码后必须重启编辑器
运行中的编辑器对**已注册全局类脚本**的 `reload()` 静默无效——磁盘是新代码，运行实例永远执行旧逻辑，且无任何提示。
- 症状：新加的方法调用报 "Nonexistent function"、行为与源码不符
- 根因：GDScriptCache 命中缓存时不校验文件 mtime（引擎 issue #49298）；外部编辑器的改动依赖编辑器窗口聚焦时的 mtime 比对（issue #72825）
- **自动化路径（推荐）**：MCP 工具 `restart_editor` —— 直接封装 `EditorInterface.restart_editor(true)`，AI 改完框架代码后自主调用，延迟 1 秒触发（先送达确认响应再重启），引擎先保存全部已打开的场景再重启、MCP 自动回连，用户零操作
- 缓解：`refresh_tools` 可重建工具注册表（仅工具清单，不解决类逻辑）
- 辅助：开启编辑器设置 `text_editor/behavior/files/auto_reload_scripts_on_external_change` 后，普通项目脚本的外部修改会自动重载（历史版本有 bug，4.4+ 基本可用）

### 陷阱2：await 已完成的协程句柄会永久挂起
对已执行完毕的 `GDScriptFunctionState` 再 `await`，协程永不恢复且零报错。
典型场景：先 emit 信号唤醒子协程、再 await 其句柄——唤醒瞬间链条已完成，随后的 await 即死锁。
- 正确姿势：保持"先挂起、后触发、再等待"的顺序；或用 `AsyncTool.await_state_safe(fs)`（内部经 `is_valid()` 判定，失效句柄立即返回 null）

### 陷阱3：跨编译代次的类型化赋值静默失败
脚本被 reload 后产生新的类代次，此时 `var x: OldClass = new_obj` 若两侧代次不同，赋值结果为 **null 且不报错**。
- 正确姿势：框架内部跨 reload 边界传递对象用无类型变量；怀疑时用 `is` 断言代替信任类型标注

### 陷阱4：can_instantiate() 对 RefCounted 脚本可能误报 false
`extends RefCounted` 的全局类脚本 `can_instantiate()` 返回 false 但实际可正常 `new()`。
- 正确姿势：直接 `new()` 并判空，不要依赖该判定

---

## 十、FAQ

**Q1：Def 能否存运行时数据？**
不能。Def 是纯配置（`Resource`），运行时状态应放 Entity / Component / 场景节点，通过外部上下文（如 `GameContext`）传入。

**Q2：为什么我的中文配置没写进 CSV？**
Def 需声明 `@tool`，且在编辑器打开资源时通过 `zh_name` / `tr_desc` 等 `zh_*` 属性修改才会写入对应 CSV；运行期 `tr()` 读取翻译。

**Q3：`ModifierValue.value` 赋值为什么报错？**
该属性只读，请通过 `base_value` 或 `add_modifier/apply_modifier` 修改，保证修饰链与信号正常。

**Q4：对象池取不到对象？**
`pool_get()` 在池子为空时返回 null 并打印「对象池不足」。请确保 `BakedPoolManager` 已生成足够数量的池成员，或在代码中兜底创建。

**Q5：`UITool.back()` 没反应？**
`back()` 只处理 `DIALOG` 与 `PANEL` 层级；请检查面板的 `layer` 属性与栈状态（`UITool.debug()` 可查看当前栈）。

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
9. [FAQ](#九faq)

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
│  Entity 实体层  Buff / Modifier / Task / Component │
├─────────────────────────────────────────────┤
│  Def 定义层     EntityDef / EffectDef / ValueDef │   ← 策划可配置的 *.tres 资源
└─────────────────────────────────────────────┘
```

**设计原则：**
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
│   ├── AttributeDef     # 属性定义（tags）
│   ├── BuffDef          # Buff 定义（tags）
│   ├── TagDef           # 标签定义（tag 匹配判断）
│   │   ├── AttributeTagDef
│   │   └── BuffTagDef
│   ├── TipDef           # 提示/图鉴定义
│   └── TaskDef          # 任务定义（抽象）
│       ├── SignalTaskDef   # 信号驱动任务
│       └── GroupTaskDef    # 分组任务（顺序/任意/任一完成）
├── ConditionDef         # 条件（抽象）→ is_met(context)
│   └── ValueConditionDef  # 数值比较条件（=、!=、>、<、>=、<=）
├── EffectDef            # 效果（抽象）→ apply(context) / revert(context)
│   ├── EffectsDef       # 效果组合（依次执行）
│   └── BuiltinEffectDef # 内置文本效果（占位，仅描述）
├── ValueDef             # 数值表达式（抽象）→ get_float / get_int
│   ├── IntValueDef / FloatValueDef        # 常量
│   ├── AddValueDef / SubtractValueDef     # 加减
│   ├── MultiplyValueDef / DivideValueDef  # 乘除
│   ├── PercentValueDef                     # 百分比（10 取整）
│   ├── FractionValueDef                    # 分数
│   └── MaxValueDef / MinValueDef           # 最大/最小
└── SignalDef            # 信号定义（抽象）→ connect/disconnect_signal(data, callable)
    └── ConditionSignalDef  # 带条件的信号包装
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

`TaskDef` 定义任务，`Task` 负责运行时推进：

| 子类 | 行为 |
|---|---|
| `SignalTaskDef` / `SignalTask` | 任一信号触发即完成 |
| `GroupTaskDef` / `GroupTask` | 三种模式：`SEQUENTIAL`（顺序）、`ANY_ORDER`（任意顺序全部）、`COMPLETE_ANY`（任一完成即结束） |

```gdscript
var task := Task.create(task_def)  # 通过工厂创建实体
task.activate(data)
task.completed.connect(_on_task_done)
```

任务实体支持 `save_data()` / `load_data()`，可用于任务系统存档。

---

## 四、Entity 实体层

### 4.1 Entity 基类（`Entity.gd`）

运行时实体基类（`RefCounted`）。提供了 `entity_changed` 信号、统一的 `def` 驱动模式与 `get_desc()`。

### 4.2 Buff（`Buff.gd`）

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

组件继承 `Component`（本质是 `Node`），挂载到场景节点上：

| 组件 | 职责 | 关键 API |
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
`res://addons/DEVFramework/Native/devecs.gdextension`（编译产物也在该目录）。任何模块的原生类都注册在这一个库里，共用一份二进制。当前已注册：
- `ECSCore` — ECS 高性能实体组件系统
- `PCGErode` — PCG 高度图侵蚀加速（C++ 水力粒子液滴含悬崖/沉积参数 + 热侵蚀平滑坡面）
- `PCGWFC` / `PCGWFC3D` — PCG 2D/3D 波函数坍缩加速（大图快 ~30 倍）
- `PCGWFCAnimator` — PCG WFC 过程动画器（有状态逐步推进，可视化生成过程）
- `PCGLSystem` — PCG L-System 生长展开加速（大迭代快数十倍）
- `PCGCave3D` — PCG 3D 细胞洞穴加速（26 邻域平滑，快数百倍）

由 **`FrameworkNative`**（`Native/FrameworkNative.gd`）统一懒加载与校验：
- `FrameworkNative.get_native(&"ECSCore", required_methods)` — 按类名取共享实例（缓存 + 方法集版本校验）
- `FrameworkNative.get_native(&"PCGErode", [&"erode"])` / `&"PCGWFC"` / `&"PCGLSystem"` — PCG 算法加速
- `FrameworkNative.instantiate_script(script)` — 稳定的脚本实例化（规避全局类注册时序问题）
- `FrameworkNative.refresh(...)` — 清缓存（库热重载/测试）

新增模块原生能力时：把 C++ 类注册进 `devecs.gdextension`（需源码重编译），GDScript 侧通过 `FrameworkNative.get_native(&"你的类名", [...])` 访问，不要各自维护一份 ClassDB 检测逻辑。

### 4.7 PCG 程序化内容生成（`PCG/`）

框架内置一套 **程序化内容生成** 模块，遵循 Def → Entity → Tool 三层模式：
所有生成参数都是 `.tres` 资源（策划可配），同一 `seed` 必然复现，支持 2D/3D、配置管线与 seed 增量存档。

```gdscript
# 单步：网格生成
var def: GridGenDef = load("res://Assets/Def/PCG/Grid_Cave.tres")
var grid := PCGTool.generate_grid(def, PCGTool.make_rng(seed))

# 管线：地形→群系→河流→道路→资源点→战利品 一条龙
var out: Dictionary = PCGTool.generate(pipeline_def, seed)
```

**能力一览**：8 种 2D 网格算法（噪声地形/细胞洞穴/迷宫/随机游走/BSP/WFC/Voronoi/模板拼接）、
3D 体素（地表/3D 洞穴/3D WFC）、生物群系、河流/道路、散布（2D/3D）、内容生成（加权/名字/马尔可夫/词缀）、
2D/3D 分块世界、WFC 高级（固定格/回溯/重试/过程动画）、异步生成、seed+增量存档。

**完整使用说明见 [`PCG/Readme.md`](PCG/Readme.md)**。

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
await AsyncTool.await_with_timeout(action, 5000, "取名")       # 带超时保护
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

### 5.8 程序化音频生成（AudioTool）

用 `AudioSynthDef` 描述声音，一键生成 3A 级音效 / BGM / 氛围 / 循环音乐，无需外部音频素材：

```gdscript
# 一行播放示例音效 / 无限循环 BGM(全链路: 自动总线、自动释放)
AudioTool.play_example("SFX_Laser")            # 音效一行
var bgm := AudioTool.play_loop(load("res://Assets/Def/Audio/Examples/BGM_Loop_Adventure.tres"))  # 无限循环 BGM

# 完整控制
var def: AudioSynthDef = AudioTool.example_def("SFX_Laser")     # 加载示例定义
var stream := AudioTool.generate_and_save(def, "res://out/sfx.wav")  # 生成并导出 .wav
AudioTool.play(def)                            # 生成并播放(自动路由到定义的总线)
AudioTool.get_stream_info(stream)              # 查询时长/采样率/循环信息
AudioTool.list_examples()                      # 列出全部示例
```

- **渲染管线**：`Def → AudioSequence（展开事件）→ AudioVoice（逐音符渲染）→ AudioTool（混合/归一化/软削波）`。
- **合成内核自研**（现已并入 `AudioTool`）：PolyBLEP 抗锯齿振荡器、SVF 滤波器（低/带/高通）、ADSR 包络（支持曲线）、`midi_to_freq`、鼓合成（KICK / SNARE / HAT / HAT_OPEN / TOM / CLAP）。这些是 Godot 不提供的数据级合成 API，故自研；**其余通用能力一律用 Godot 已有功能**。
- **自动编曲**（`AudioMusicDef`）：音阶音池 + 加权随机游走旋律 + 和弦进行 + 鼓节奏音型。
- **实时无限循环**：`AudioLivePlayer` 基于 Godot 内置 `AudioStreamGenerator` 逐块渲染，BGM 不占内存、无限循环。
- **后台线程**：`AudioTool.generate_async(def)` 放 worker 线程渲染，避免阻塞主线程。

**只自研"无法用内置实现"的部分，其余全部用 Godot 已有功能：**

| 能力 | 实现 | 说明 |
|---|---|---|
| 振荡/滤波/包络/鼓 | 自研（并入 `AudioTool`）| Godot 无逐采样合成 API，必须自研 |
| 混响 / 延迟 / 失真 / 限幅 / 压缩 / EQ | **Godot 内置 `AudioEffect`** | 播放时经 `AudioSynthDef.bus` + `fx_chain` 路由到带效果的总线；**离线烘焙同样支持**——用内置 `AudioEffectRecord` 录音法把效果链固化进 .wav（`bake_wav(..., bake_fx=true)`，默认开启）|
| WAV 写盘 | 自写 44 字节标准 PCM 头 | 4.7.1 内置 `save_to_wav()` 会把 16bit 立体声写成 mono 头（数据仍交错），Godot 重导入后声道/时长错乱，故自写标准头 |
| 实时循环播放 | **Godot 内置 `AudioStreamGenerator`** | `AudioLivePlayer` 包装使用 |
| 总线布局 | **Godot 内置 `AudioServer` / `AudioBusLayout`** | `AudioTool.setup_audio_buses()` 一键生成 Master/SFX/BGM/UI 布局并写入项目设置 |

- `AudioTool.ensure_bus()` 按需幂等创建任意效果总线；`resolve_bus()` 为带 `fx_chain` 的定义自动建 `FX_<bus>` 效果总线。
- `AudioTool.play_stream()` 播放结束后自动释放节点；`AudioLivePlayer` 自动挂到定义的总线。

| 类 | 说明 |
|---|---|
| `AudioSynthDef` | 根定义：类别（SFX/BGM/AMBIENT/LOOP）、采样率、主音量、软削波、`bus` + `fx_chain`（总线效果链）、循环/淡出 |
| `AudioVoiceDef` | 声部（Tone/DRUM），含振荡器组、滤波器、ADSR、声像、音量 |
| `AudioMusicDef` | 自动编曲配方；`AudioPatternDef` 显式四分音符节拍 |
| `AudioSequence` / `AudioVoice` | 事件展开 / 音符渲染（Entity 层内部实现，不直接使用） |
| `AudioLivePlayer` | 实时无限循环 BGM 播放器（一般用 `AudioTool.play_loop()` 创建） |
| `AudioTool` / `DevAudioExamples` | **统一入口**：渲染/生成/播放/保存/总线/示例 全部集成 / 一键生成示例定义 |

`AudioTool` 是音频功能的**唯一对外入口**，内部再分为：合成内核（`osc`/`poly_blep`/`SVFilter`/`ADSR`/`soft_clip`/`midi_to_freq`/`Wave`）、合成渲染（`render_data`/`build_stream`/`render`）、生成（`generate`/`generate_async`）、播放（`play`/`play_stream`/`play_loop`/`play_example`）、保存（`save_wav`/`save_resource`/`generate_and_save`/`bake_wav`）、查询（`get_stream_info`/`list_examples`/`example_def`）、总线管理（`ensure_bus`/`resolve_bus`/`create_fx`/`setup_audio_buses`）、编辑器预览（`play_editor_preview`/`stop_editor_preview`）。

### Inspector 预览与烘焙

每个 `AudioSynthDef` 资源自带两个内建按钮（`@export_tool_button`，无需任何插件代码）：

- `▶ 播放 ／ ■ 停止`：**切换式**按钮——空闲时后台生成并按 `bus`/`fx_chain` 试听（BGM 自动循环），生成中或播放中再点则停止。
- `随机生成音效` / `微调变体`：sfxr 灵感一键工具——**随机生成**全参数重随机（默认 `random_preserve_wave` 保持波形/声部基础，`mutate_locked` 中列出的顶层属性不被改动）；**微调变体**在现有参数上小幅扰动并重新掷编曲种子，快速批量产出"相似但不同"的候选，点完自动试听。结构（声部数/振荡器数）恒保持，空定义会自动补默认结构保证出声。
- `烘焙 WAV...`：异步后台生成并写出标准立体声 WAV 到约定目录 `res://Assets/Audio/Baked/<Def名>.wav`，**默认把 `fx_chain` 效果链一起烘焙进文件**（内置 `AudioEffectRecord` 录音法，`AudioTool.bake_wav(def, path, bake_fx=false)` 可关闭），完成后自动刷新资源面板。**长 BGM 建议烘焙成 wav 资源供游戏直接加载**（引擎导入后为 QOA 压缩，播放开销极小）。

`fx_chain` 为 **Godot 原生 `Array[AudioEffect]` 资源数组**——直接在 Inspector 里从音频效果资源列表选取并展开调参（混响 / 延迟 / 失真 / 限幅 / 压缩 / EQ 等任意内置效果）；代码侧可用 `AudioTool.create_fx("reverb")` 取标准预设、`AudioTool.fxs_from_names(["reverb", "delay"])` 批量构建。标准预设名：`reverb` / `reverb_hall` / `delay` / `distortion` / `limiter` / `compressor` / `eq_lowpass` / `eq_highpass` / `eq_bandpass` / `spectrum`。

> 生成较重的 BGM（16 秒）约需 2 倍实时（后台线程），建议一次性烘焙成 `.wav` 资源供游戏加载；实时循环交给 `AudioLivePlayer`。

**人性化随机**：`AudioMusicDef` / `AudioPatternDef` 上新增 `pitch_jitter_cents`（每音符音高 ±音分抖动）与 `timing_jitter_ms`（每音符触发时间 ±毫秒抖动），消除重复旋律/打击乐的机械感；`AudioPatternDef.random_seed` 控制抖动变体。

**淡入淡出**：`AudioSynthDef.fade_in`（头部淡入，离线烘焙与 `AudioLivePlayer` 实时播放均生效，仅首轮）与 `fade_out`（尾部淡出）。

**示例音效库**（共 13 个）：激光/爆炸/金币/受击/跳跃/UI 点击/能量拾取/脚步声/翻滚/魔法/重击 + 冒险循环 BGM/环境循环 BGM。

### 5.9 其他工具

| 工具 | 用途 |
|---|---|
| `CSVDataAccess` | CSV 读写（`get_csv_value` / `set_csv_value` 等） |
| `ArrayViewTool` | 数组视图通用逻辑：`get_item_name` / `create_view` / `free_view`（配合对象池） |
| `TweenViewTool` | Tween 显隐控制与释放：`update_visible` / `finish_and_free` |
| `PCGTool` | PCG 统一入口：噪声/网格(2D/3D)/群系/散布/内容/河流道路/分块世界/管线/异步/序列化 |
| `DevProjectSetup` | 一键创建项目目录结构（编辑器菜单触发） |
| `SpriteFramesToAnimationLibrary` | `EditorScript`：将选中的 SpriteFrames 生成 AnimationLibrary |

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
| `OutlineEffect` | 后处理描边：`OutlineEffect.set_outlined(true, mesh)` |
| `GLSLShaderEffect` | 可编程后处理（填 `define_code` / `main_code` 实时编译） |
| `Trail3D` | 拖尾网格 |
| `BakedPool / BakedPoolManager` | 烘焙对象池（编辑器一键生成池子，运行时 `pool_get`/`pool_push`） |
| `ScreenshotCapture` | 双击截图（支持透明背景 + 抖动量化） |
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
| `validate_script` | 校验 GDScript 语法/可编译性（传 `path` 或 `code`，兼容非 `@tool`/纯工具类脚本）|
| `validate_resource` | 校验资源/场景能否被引擎加载 |
| `list_dir` | 列出目录内容（支持递归）|
| `classdb_query` | 查询 Godot 类的 API（方法/属性/信号签名）或按关键字搜索类名，供 AI 写脚本前确认原生 API |
| `get_logs` | 读取编辑器控制台日志（增量/关键字/截断）|
| `get_errors` | 读取捕获的错误（含来源文件、行号、**GDScript 栈追踪**）|
| `clear_errors` | 清空错误缓冲区 |
| `take_screenshot` | 捕获编辑器当前窗口画面（存到 `user://mcp_screenshots/`）|
| `get_scene_tree` | 获取当前编辑场景的节点树结构 |
| `get_node_info` | 读取编辑场景中指定节点属性列表及当前值 |
| `set_node_property` | 修改编辑场景中节点属性（经 UndoRedo 提交，可 Ctrl+Z 撤销；保存才写回 .tscn）|
| `call_node_method` | 触发编辑场景中节点方法 |
| `add_node` | 向编辑场景添加节点/实例化子场景（UndoRedo 可撤销）|
| `remove_node` / `duplicate_node` | 删除 / 复制场景节点（含子树，UndoRedo 可撤销）|
| `set_node_transform` | 设置节点位置/旋转/缩放（2D/3D）|
| `connect_signal` | 连接场景节点信号到方法（随场景保存）|
| `create_resource` | 创建 .tres 资源配置（指定脚本 + 属性字典，配置驱动开发用）|
| `get_resource_info` | 读取 .tres/.tscn 资源完整属性树（递归，理解配置结构）|
| `get_editor_activity` | 感知编辑器当前状态（打开场景/选中节点/运行中游戏），用于 AI 与人类协作不踩踏 |
| `get_project_info` | 项目/版本/当前编辑场景等环境信息 |
| `get_project_settings` | 主场景/autoload/输入映射/图层命名等关键配置 |
| `run_game` / `stop_game` | 独立进程启动/停止游戏（日志并入 `get_logs`）|
| `reload_project` | **重载项目**：重建全局类缓存（新 `class_name` 立即注册）+ 重扫资源；可选重载当前场景 |
| `eval_code` | 在编辑器内执行一段 GDScript 代码并返回结果（print 进 `get_logs`）|
| `get_global_classes` | 列出已注册的全部全局类（含路径/基类）|
| `open_scene` | 在编辑器打开指定场景 |
| `set_main_scene` | 设置项目主场景并保存 |
| `get_project_setting` / `set_project_setting` | 读/写任意 ProjectSettings 项（可即时保存）|
| `save_all` | 保存全部场景与项目设置 |
| `reimport` | 重新导入指定资源（重建导入缓存）|
| `search_symbols` | 跨脚本/场景/资源搜索符号（函数/变量/类定义与引用，支持节点名与资源路径）|
| `find_resource_users` | **双向依赖查询**：`users`=谁引用该资源（反向），`deps`=该资源依赖谁（正向，带类型标签）。改/删资源前查完整影响面 |
| `auto_verify` | **自动验证闭环**：启动场景后按操作序列模拟玩家行为（wait/click/drag/key/eval/poll/screenshot），每步后增量查错。支持 hard/soft 模式、flaky 重试、依赖变化检测 |
| `verify_fix` | **有状态验证修复会话**：记住验证配置，AI 改完代码后 `continue` 即重跑（省去重传操作序列），支持多会话并行 |

> **提示**：修改插件代码（`MCPDevServer.gd` 等）后，新工具需**重启编辑器**才会注册（脚本热重载不会重建工具注册表）。

### 5. 典型 AI 调试流程

1. 打开项目并启用 `DEV Framework` 插件，连接 http://127.0.0.1:8931/mcp。
2. AI `list_dir` / `validate_script` / `validate_resource` 排查脚本与资源问题。
3. AI `get_scene_tree` / `get_node_info` 理解当前编辑场景的节点与属性。
4. AI 用 `set_node_property` / `call_node_method` 快速验证逻辑，`get_errors` 定位报错。
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
- **程序化生成走 PCG 模块**：涉及地形/地牢/内容/群系等生成，一律用 `addons/DEVFramework/PCG/`（`PCGTool` + `*Def` 资源 + seed 可复现），不要手写生成算法；参数放 `.tres`，见 [`PCG/Readme.md`](PCG/Readme.md)。
- 写脚本时使用显式类型标注（`func foo(x: int) -> void`）、`@onready` 获取节点引用、`@export` 暴露可调参数，与 `Scenes/AI/GoapDemo.gd` 等示例风格一致。

**MCP 工具使用规范**
- 改任何场景节点前，先用 `get_scene_tree` / `get_node_info` 看清结构与当前属性，再动手。
- **不确定 Godot 原生 API 的用法时，先用 `classdb_query` 查询**（方法/属性/信号签名），再写代码，避免臆造 API。
- `set_node_property` 与 `add_node` 已接入 UndoRedo，AI 的修改用户可按 **Ctrl+Z 撤销**——请放心使用，但也不要反复试探性乱改，尽量一次改对。
- 修改场景节点或新建脚本/资源后，记得 `save_scene` / `reload_project`，否则改动不会持久化或全局类不生效。
- 长任务（重编译、生成音频、导出）会占用编辑器，且单次 MCP 调用有超时，**拆成小步骤**完成，不要一次塞超长指令。
- 排查脚本问题时：先 `validate_script` 验证语法，再 `get_errors` 看运行期错误（含栈追踪），配合 `get_logs` 定位。

**安全边界**
- 编辑器 **运行游戏时**（`get_editor_activity` 显示 game_running=true），应避免对编辑场景做结构性改动；如需改结构先 `stop_game`。
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

## 九、FAQ

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

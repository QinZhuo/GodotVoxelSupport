# DEVFramework

Godot 4.7 数据驱动框架：`Def`（静态配置）→ `Entity`（运行时）→ `View`（显示），配一批静态 Tool 与一个内置 MCP 调试服务器。

- **框架 = 机制，项目 = 内容**：换一款游戏仍成立的进框架，玩法语义留在项目。边界规则见 [LAYERS.md](LAYERS.md)。
- **Def 只描述配置**，不存运行时状态；运行时数据在 Entity / Component / 节点上。

## 设计语言

**四角色**（新代码必属其一，没有第五种）

| 角色 | 是什么 | 判别 |
|---|---|---|
| `Def` | 编辑器可配的静态数据，路径即身份 | 策划要在检查器里改？ |
| `Entity` | 运行时状态载体，不被看见 | 跑起来才有、且有状态？ |
| `View` | 投影，只读 `data` | 玩家看得见 / 要交互？ |
| `Tool` | 横切机制，全 static，状态放 `static var` | 换游戏仍成立、不要实例？ |

**两条流向**：`Def → Entity → View` 单向，不回溯；Tool 被调用，不持有调用者。

**五律**

1. **数据不下行**：View 不写 Entity，Entity 不写 Def；要反馈就抛信号或 `Callable`。
2. **一个角色一个基类**：不为同类问题开第二个基类。
3. **静态优先**：无实例状态一律 `static`。允许 `static var`，当且仅当它属于当前游戏会话且能被 `ResetTool.all()` 清空；否则进 Entity 或存档。进程级缓存在类头标 `## Reset: 进程级`。
4. **删除测试**：删掉整个文件或模块目录，框架仍能编译运行。唯一例外是编辑器面板接线，且只在 `plugin.gd` 出现。
5. **简单 · 易用 · 易拓展**：**简单** = 一条路径做完一件事，没有可选分支、没有中间层；**易用** = 常用调用一行写完，零注册、零初始化，默认值就是最佳实践；**易拓展** = 加新能力只加文件，不改调用方。三条缺一，就是还没设计完。

**语法**

| 形 | 义 |
|---|---|
| `_foo()` | 宿主 / 引擎回调，我被动被调 |
| `on_xxx` | 信号，过去式 = 完成态（`on_opened`） |
| `get_` / `is_` / `has_` | 纯读与谓词，无副作用 |
| `apply` / `revert` | 可逆效果，必须成对 |
| `defer` | 延后到本 tick / 帧末 |
| `await_*` | 协程，返回结果或 `false`，禁止 `void` |
| `XxxTool` / `XxxDef` / `XxxSystem` | 机制 / 配置 / 被调度逻辑 |

返回约定：`bool` = 是否生效；`void` = 已受理；`Error` = 仅 IO；`null` = 查询未命中。

单例状态一律 `Tool` + `static var`，没有 `XxxService`；真需要多份实例且要 dispose 时才新增该后缀。

每个基类文件头写三行 `## 契约`：**谁调我 / 我保证 / 我禁止**。归属与形态判定见 [LAYERS.md](LAYERS.md)。

## 目录结构

**一条规则**：目录名 = 能力名。找不到对应能力，就是那个能力还没有名字 —— 先起名，再建目录。

```
addons/DEVFramework/
├─ Core/          跨能力复用、无业务语义
│   ├─ Def/       Def、EntityDef、Tag/（通用数据基类）
│   ├─ Entity/    Entity、Entity2D/3D、Modifier、ModifierValue、StateMachine
│   ├─ Tool/      通用无状态工具：Log / Input / Pointer / Math / File / CSV /
│   │             Save / Time / GameTimer / Tick / Display / NodeTree / Tip /
│   │             UI / Steam / Prewarm / Reset / Debug / Variant
│   ├─ Async/     AsyncTool、AsyncScope
│   ├─ Pool/      Pool、PoolTool
│   └─ Editor/    仅编辑器/构建期：Setup/、Generate/、DefTable/、EditorScriptMenuTool
│
├─ 能力模块（各自内部按需分层）
│   ├─ Dialogue/  Def Entity View Tool   ← 对话/气泡
│   ├─ Task/      Def Entity View Tool   ← 任务/教程
│   ├─ AI/        Def Entity Tool        ← GOAP
│   ├─ Camera/    Def Editor Tool        ← 相机
│   ├─ ECS/       Component Def System World
│   ├─ Tween/     Entity Tool View
│   ├─ ArrayView/ 流式/槽位/偏移 列表视图
│   ├─ UI/        UIPanel、OptionSelector、ButtonView、DragView3D…
│   ├─ Focus/     FocusMask、FocusMaskSpotlight、FocusMaskTool
│   ├─ Render/    OutlineEffect、GLSLShaderEffect、Trail3D、Lightmap/、Screenshot/
│   ├─ Value/ Effect/ Signal/            数值表达式 / 效果 / 信号
│   ├─ Audio/ Translation/ Changelog/ GameCommand/ Test/
│   └─ MCP/       扁平（见下）
│
├─ Native/        原生库与 dev.gdextension（**不要移动**：含二进制，路径被 .gdextension 写死）
├─ plugin.cfg / plugin.gd / Readme.md / LAYERS.md     插件入口与文档
```

**内部层名固定五个**：`Def`（数据）/ `Entity`（运行时）/ `View`（展示）/ `Tool`（静态入口）/ `Editor`（仅编辑器）。
文件少于 3 个就不要建子目录，扁平即可。

### 什么时候独立成目录

| 条件 | 归属 |
|---|---|
| ≥2 个脚本，或已有 Def+Entity+Tool 多层 | 独立目录（如 `Focus/`） |
| 只被一个模块使用 | 放进那个模块内部 |
| 被 3+ 模块依赖、无业务语义 | `Core/` |
| 纯视觉控件、无状态逻辑 | 对应能力模块的 `View/` 或 `UI/` |

### 两个例外（都有明确理由）

| 模块 | 形态 | 原因 |
|---|---|---|
| `MCP/` | **扁平**，29 个脚本不分层 | 内部是 `preload` 硬编码网 + `autoload`（`project.godot` 里的 `DevMCP`）。分层只会让每次移动都要改多处路径字符串，收益为零 |
| `Native/` | 保持顶层 | 含 `.dll/.dylib/.so` 与 `dev.gdextension`；`dev.gdextension` 里的库路径是写死的相对路径，移动后原生库直接加载失败 |

### 改目录时必须做的三件事

1. 用 `git mv` 移动（保留历史），`.gd` 与同名 `.uid` 一起移；
2. **替换所有引用**，注意扩展名不止 `.gd` —— `plugin.gd` 里就有 `.tscn` / `.png`，`.godot` 里还有 autoload 路径；
3. 跑 `run_tests test_framework_compile`：其中 `test_all_framework_paths_exist` 会扫描所有 `res://addons/DEVFramework/...` 字符串并断言文件存在，漏改会直接红。

## 安装

1. 复制 `addons/DEVFramework/` 到项目 `addons/`，在插件面板启用。
2. 菜单 **项目 → 工具 → 创建 DEV 项目结构** 生成 `Assets/Def/`、`Scenes/`、`Scripts/{Def,Entity,View}/` 骨架。

C++ 原生能力（ECS）需编译，见 [gdextension/README](../../gdextension/README.md)。

## 三层

| 层 | 基类 | 职责 |
|---|---|---|
| Def | `Def`(Resource) | 策划配置的 `.tres`：名称 / 翻译 / 存档路径 |
| Entity | `Entity`(RefCounted)、`Entity2D`/`Entity3D`(Node) | 运行时数据载体，由 Def 驱动 |
| View | `UIPanel` / `ArrayView` / … | 只负责显示，`data` 变化即刷新 |

**Def 家族**：`EntityDef`、`ConditionDef`、`EffectDef`（`apply`/`revert`）、`ValueDef`（`get_float`）、`SignalDef`（`connect/disconnect`）。组合这些就能在编辑器里搭出效果与数值表达式。

```gdscript
@tool
class_name DamageEffectDef extends EffectDef
@export var value: ValueDef
func apply(ctx) -> void:
	ctx.damage = value.get_int(ctx)
```

**Entity 家族**：`Modifier` / `ModifierValue`（base + 修饰链，`value` 只读，改 `base_value` 或 `add_modifier`）、`StateMachine`（异步转换、guard/enter/exit）。

挂在实体下的逻辑用**普通 Node**（需要实体就 `@export var entity: Entity2D` 或 `get_parent() as Entity2D`），框架不再提供"节点组件"基类。

`def` 是鸭子约定：子类自己声明 `var def: XxxDef`，`Entity.new(some_def)` 才能注入。

## Tool（全部静态类）

| 分类 | 类 |
|---|---|
| 日志 / 存档 | `LogTool`（标签 + 计时）、`SaveTool`（JSON/GZIP、`.bak` 回退、merge、版本迁移、`load_defs`） |
| 异步 | `AsyncTool`（`load_resource_async` / `thread_call` / `await_until` / `call_in_frames` / `await_with_timeout` / `await_coroutine`） |
| 输入 / 时间 | `InputTool`（模式切换、焦点组、InputMap 持久化）、`TimeTool`（基础速度 + keyed 倍率 + 暂停） |
| 步进 | `TickTool.defer(order_key, action)` + 宿主每物理帧末 `tick()`；`GameTimer` |
| 文本 | `TranslationTool` / `CSVDataAccess` / `TipTool` |
| 生命周期 | `NodeTreeTool`（按约定调 `game_init` / `game_ready` / `save_data` / `load_data`） |
| 音频 | `AudioTool`（常驻复音通道、3D 定位）、`AudioMixerTool`（效果预设 + 总线）、`AudioBakeTool`（录音 + WAV） |
| UI | `UITool`（6 层栈）、`UIPanelTool`（2D/3D 共用状态机）、`FocusMaskTool`（焦点遮罩）、`ArrayViewTool` |
| 其它 | `CameraTool` / `ChangelogTool` / `DisplayTool` / `FileTool` / `PointerTool` / `PrewarmTool` / `ScreenshotTool` |

项目设置项（插件注册时写入）：`dev_framework/log/*`（开关、时间戳、忽略标签）、`save_tool/encrypt_salt`、`lightmap/scan_dir`、`mcp/*`（见下文 MCP 一节）。

## View

- `UIPanel` / `UIPanel3D`：`open` / `close` / `toggle` / `popup` / `await_closed`，信号 `on_open` / `on_opened` / `on_close` / `on_closed`，可覆写 `_back()` / `_focus_enter()` / `_focus_exit()`。
- `UITool` 六层：`BACKGROUND` / `HUD` / `PANEL` / `DIALOG`（同层互斥）/ `TOOLTIP`（单实例）/ `TOP`；`back()` 只处理 DIALOG 与 PANEL。
- 数组视图：`ArrayView`（流式）、`SlotArrayView2D/3D`（固定槽）、`OffsetArrayView2D/3D`（按 offset 排列）。填 `pool_key` + `pool_size` 走对象池（`Pool` / `PoolTool`），归还时自己清 `data`、断信号。
- 焦点遮罩：`FocusMask`（全场变暗，只有目标保持原样可交互；3D 目标单独重渲染到暗区之上，2D 目标提升绘制顺序），入口 `FocusMaskTool`（全局唯一，自动挂最高层 CanvasLayer）。
- 渲染：`OutlineEffect`、`GLSLShaderEffect`、`Trail3D`、`BakedMeshInstance3D`（资源级光照贴图）、`SubView3D`、`ShaderProgressBar`。

**约定：UI 一律用 `.tscn` 搭，不代码生成。**

## 模块

| 模块 | 文档 |
|---|---|
| ECS（C++ 列存储 + 系统 + 查询链 DSL） | [ECS/Readme.md](ECS/Readme.md) |
| 3D 镜头（机位竞争 + 混合 + 冲击） | [Camera/Readme.md](Camera/Readme.md) |
| 任务 / 教程 | [Task/Readme.md](Task/Readme.md) |
| 对话 / 气泡 | [Dialogue/Readme.md](Dialogue/Readme.md) |
| GOAP AI | [AI/Readme.md](AI/Readme.md) |
| 命令回放 | [GameCommand/Readme.md](GameCommand/Readme.md) |

## MCP 调试服务器

插件启用即监听 `http://127.0.0.1:9988/mcp`（所有项目共用这一个端口）。

- 同时开多个项目时先 `list_instances`，用 `use_instance` 选默认目标，或给单次调用带 `instance`。
- 默认目标跨重启保留；目标不在线时直接报错，不会改到别的项目。
- 每条工具结果末尾会带一行 `[target: 项目@哈希 (路径)]`，用来确认这次究竟落在哪个项目。
- 常用工具：`validate`、`get_logs`、`eval_code`、`get_scene_tree`、`set_node_property`、`create_resource`、`run_tests`、`game_control`、`restart_editor`。
- 导出包默认不带 MCP 入口（`dev_framework/mcp/runtime_enabled = false`）。

## 引擎陷阱

1. **改框架代码后必须重启编辑器**（`restart_editor`）：已注册的全局类不会真正 reload，行为与源码不符且无提示。
2. `await` 已完成的协程句柄会永久挂起 → 用 `AsyncTool.await_coroutine`。
3. 脚本 reload 后，跨编译代次的类型化赋值可能静默得到 null → 跨边界传对象用无类型变量。
4. `can_instantiate()` 对 `RefCounted` 全局类可能误报 false → 直接 `new()` 判空。

## 存档与翻译

- Def 存档只存**相对 `res://Assets/Def/` 的路径**，DLC 靠同路径覆盖资源；纪律见 [LAYERS.md](LAYERS.md) §七。
- 在编辑器改 `tr_name` 等属性会自动写回 `Assets/Translation/*.csv`（Def 子类需 `@tool`）。

# DEVFramework

Godot 4.7 数据驱动框架：`Def`（配置）→ `Entity`（运行时）→ `View`（显示），配一批静态 `Tool` 与内置 MCP 调试服务器。

**框架 = 机制，项目 = 内容。** 判定见 [LAYERS.md](LAYERS.md)。

## 一、四角色

| 角色 | 是什么 | 判别 |
|---|---|---|
| `Def` | 编辑器可配的静态数据（`Resource`） | 策划要在检查器里改？ |
| `Entity` | 运行时状态载体（`RefCounted` / `Node`） | 跑起来才有、且有状态？ |
| `View` | 投影，只读数据 | 玩家看得见 / 要交互？ |
| `Tool` | 横切机制，全 `static` | 换游戏仍成立、不要实例？ |

数据单向流动：`Def → Entity → View`，不回溯。Tool 被调用，不持有调用者。

## 二、三条硬规则

1. **数据不下行**：View 不写 Entity，Entity 不写 Def。要反馈就发信号或 `Callable`。
2. **一个角色一个基类**：不为同类问题开第二个基类。
3. **依赖方向**：能力模块可引用 `Core`，`Core` 不引用能力模块（`plugin.gd` 只做编辑器接线）。
   现有 9 个 Core 文件沿 33 处反向引用 8 个能力模块，清单与理由见 [LAYERS.md](LAYERS.md)「七、已知例外」；新代码不要加重这层环。

## 三、目录

```
addons/DEVFramework/
├─ Core/          Def/ Entity/ Tool/ Async/ Pool/ Editor/   ← 跨能力复用
├─ <能力>/         Dialogue Task AI Camera ECS Tween UI Focus Render
│                 ArrayView Value Effect Signal Audio Translation
│                 Changelog GameCommand Test
├─ MCP/           扁平（preload 硬编码网，分层无收益）
└─ Native/        原生库 + devframework.gdextension（禁止移动）
```

**目录名 = 能力名**；模块内按 `Def / Entity / View / Tool / Editor` 分层，少于 3 个文件就扁平。
`ECS/` 用 `Component / System / World / Timer / Render`，`Render/` 下分 `Lightmap / Screenshot`。
命名、归属、搬迁纪律全在 [LAYERS.md](LAYERS.md)。

## 四、安装

1. 复制 `addons/DEVFramework/` 到项目 `addons/`，插件面板启用。
2. 菜单 **项目 → 工具 → 创建 DEV 项目结构** 生成 `Assets/Def/`、`Scenes/`、`Scripts/` 骨架。

C++ 原生能力（ECS）需编译，见 [gdextension/README](../../gdextension/README.md)。

## 五、模块文档

每个模块有自己的 Readme：定位、怎么用、坑。MCP 无模块 Readme，见下节。

| 模块 | 文档 | 可运行示例 |
|---|---|---|
| 基础（Def / Entity / Tool / Async / Pool） | [Core/Readme.md](Core/Readme.md) | — |
| ECS（列存储 + 系统 + 查询链） | [ECS/Readme.md](ECS/Readme.md) | `Scenes/ECS/ECSDemo.tscn` |
| 对话 / 气泡 | [Dialogue/Readme.md](Dialogue/Readme.md) | `Scenes/Dialogue/DialogueDemo.tscn` |
| 任务 / 教程 | [Task/Readme.md](Task/Readme.md) | `Scenes/Tutorial/TutorialDemo.tscn` |
| GOAP AI | [AI/Readme.md](AI/Readme.md) | `Scenes/AI/GoapDemo.tscn` |
| 相机（机位竞争 + 混合） | [Camera/Readme.md](Camera/Readme.md) | — |
| 命令回放 | [GameCommand/Readme.md](GameCommand/Readme.md) | `Scenes/GameCommand/GameCommandDemo.tscn` |
| UI（面板 / 层级 / 拖拽） | [UI/Readme.md](UI/Readme.md) | — |
| 渲染（后处理 / 光照贴图 / 截图） | [Render/Readme.md](Render/Readme.md) | — |
| 补间（动画资产） | [Tween/Readme.md](Tween/Readme.md) | — |
| 数组视图（虚拟滚动列表） | [ArrayView/Readme.md](ArrayView/Readme.md) | — |
| 焦点 / 轮廓遮罩 | [Focus/Readme.md](Focus/Readme.md) | — |
| 数值（ValueDef 树） | [Value/Readme.md](Value/Readme.md) | — |
| 信号与条件 | [Signal/Readme.md](Signal/Readme.md) | — |
| 效果（可叠可逆） | [Effect/Readme.md](Effect/Readme.md) | — |
| 音频 | [Audio/Readme.md](Audio/Readme.md) | — |
| 多语言 | [Translation/Readme.md](Translation/Readme.md) | — |
| 更新日志 | [Changelog/Readme.md](Changelog/Readme.md) | — |
| 测试 | [Test/Readme.md](Test/Readme.md) | — |
| 原生（C++ 扩展） | [Native/Readme.md](Native/Readme.md) | — |

其余场景见 [Scenes/README.md](../../Scenes/README.md)。

## 六、改完必跑

```
run_tests process=editor script=test_framework_compile   # 全量编译 + 路径存在性
godot --headless --path . -s res://addons/DEVFramework/Test/run_headless.gd -- --script all
```

`run_tests` 是 job 模型：`wait_sec` 内跑完直接给汇总，否则返回 `{job_id, running:true}`，此后只调 `job_wait(job_id)` 续等（不重跑）。
0 个用例或脚本解析失败一律判失败。断言与用例写法见 [Test/Readme.md](Test/Readme.md)。

## 七、MCP 调试服务器

### 7.1 连接

插件启用即监听 `http://127.0.0.1:9988/mcp`（多项目共用一个端口）。长说明按需读 `resources/list` 的 `devframework://docs/*`，不常驻 `tools/list`。

### 7.2 常用工具与自定义 provider

- 常用：`validate` / `get_logs` / `eval_code` / `run_tests` / `perf` / `build_native` / `game_control` / `restart_editor`。
- 场景批量改动：`apply_scene_edits`（一次事务，失败整体回滚）+ `undo_redo`；文件改名用 `move_file`。
- 点完等结果用 `wait_for`，别写死 sleep。
- 项目自定义工具：`dev_framework/mcp/providers` 列脚本路径，脚本写 `static func register(add_tool: Callable, ctx: Dictionary = {})`；
  `ctx.schema` / `ctx.result` 是契约工厂，`ctx.tool_kinds` 为真时可自报分类（`read_only` / `non_destructive` / `destructive`）。
- MCP 域脚本热重载：`refresh_tools` 按磁盘源码重编译，所以域文件**不能声明 `class_name`**（动态副本会与已注册全局类重名），
  身份靠路径 + 文件名，域间引用走 `const X := preload(...)`。域内 preload 的**叶子**不随域换代，
  `refresh_tools` 用 `stale_leaves` 回报"磁盘已改但仍是旧版"的叶子；改名或移位域文件后必须 `restart_editor`。
- 改 `addons/<插件>/Native/src/**` 后必须 `build_native`（`action=status` 查过期 → `action=build`），否则测试跑的是旧库且全绿。
- 目录约定：插件的 C++ 放 `addons/<插件>/Native/src`（随插件分发），构建区与 godot-cpp 在项目根 `gdextension/`。
- 导出包默认不带入口（`dev_framework/mcp/runtime_enabled = false`）。

### 7.3 多实例鉴权

- 多项目并存：`list_instances` → `use_instance` 选默认，或单次调用带 `instance`。
- 各实例若配了 `dev_framework/mcp/token`，必须是同一个值。

## 八、引擎陷阱

1. **改框架代码后必须重启编辑器**：已注册的全局类不会真正 reload，行为与源码不符且无提示。`TestRunner` 会拒绝跑与磁盘不一致的脚本；headless 每次全新进程，不受影响。
2. `await` 已完成的协程句柄会永久挂起 → 用 `AsyncTool.await_coroutine`。
3. 脚本 reload 后跨编译代次的类型化赋值可能静默得到 null → 跨边界传对象用无类型变量。
4. **别把已释放的节点赋给类型化变量**：`var n: Node = arr.pop_back()` 在实例已 `queue_free` 时抛 "Trying to assign invalid previously freed instance"，先用 `Variant` 接住再判空。
5. 注释/提示文本里的 `res://` 不算路径引用，批量替换路径时正则别改坏文案。
6. **`Entity2D/3D` 的 ECS 世界字段叫 `ecs_world`**（`world` 留给项目自己的世界对象）。
7. **static 缓存不会随热重载消失**：缓存数据的 Tool/Def 用 `ScriptEpochTool.register_cache(&"模块", 清缓存回调)` 登记，测试轮次开始时统一清一次。

## 九、性能测量

| 目标 | 手段 |
|---|---|
| 测一段逻辑多快 | `PerfTool.measure(callable)` / `bench(callable, iters, warmup, setup)` / `bench_auto(callable, 预算ms)` |
| 测环境帧率 / 稳定性 | `PerfTool.sample_frames(帧数, 预热帧)` 或 MCP `perf action=fps process=game` |

- **预热丢弃**：`warmup` 次样本不进统计。
- **看分位与 `cv`，不看平均**：给 `avg / p50 / p95 / p99 / min / max / std_ms / cv`，`cv > 10%` 记 `noisy: true`。
- **迭代自适应**：`bench_auto` 先把 batch 翻倍到测得出来，再按预算定样本数；单次计时会被 1µs 精度量化成 0（`bench` 置 `below_resolution`）。
- **准备与计时分离**：`setup` 每次样本前执行但不计时。
- **帧率口径**：`fps_p50 / fps_p95 / fps_1pct_low`；卡顿阈值 `max(中位帧时间×2, 16.7ms)` 并回传 `stutter_ms`；结果附 `env`（GPU/CPU/max_fps/vsync/窗口/焦点），`env` 不同的数字互不可比。
- 编辑器进程采样会被空闲节流压到 ~10fps，测真实性能必须 `process=game`。
- 引擎 Monitor 面板已有 FPS / 绘制调用（`Performance.TIME_FPS`、`RENDER_TOTAL_DRAW_CALLS_IN_FRAME`），框架不再注册同名 `Perf/*`。
- 基线条目多了用 `perf action=history key=test:` 过滤；进程级共享、跨轮次复用，`perf action=reset` 清空。

```gdscript
extends TestCase

func test_query_cost() -> void:
    assert_under_ms(5.0, func(): world.query(...).count())     # 硬上限
    measure_ms("ecs/query", func(): world.query(...).count())  # 只记基线，不判失败

func test_frame_rate() -> void:
    await assert_fps_at_least(55.0, 120, 30)                   # 需游戏进程
```

# DEVFramework

Godot 4.7 数据驱动框架：`Def`（配置）→ `Entity`（运行时）→ `View`（显示），配一批静态 `Tool` 与内置 MCP 调试服务器。

**框架 = 机制，项目 = 内容。** 换一款游戏仍成立的进框架，玩法语义留项目。判定见 [LAYERS.md](LAYERS.md)。

## 四角色

新代码必属其一，没有第五种：

| 角色 | 是什么 | 判别 |
|---|---|---|
| `Def` | 编辑器可配的静态数据（`Resource`） | 策划要在检查器里改？ |
| `Entity` | 运行时状态载体（`RefCounted` / `Node`） | 跑起来才有、且有状态？ |
| `View` | 投影，只读数据 | 玩家看得见 / 要交互？ |
| `Tool` | 横切机制，全 `static` | 换游戏仍成立、不要实例？ |

数据单向流动：`Def → Entity → View`，不回溯。Tool 被调用，不持有调用者。

## 三条硬规则

1. **数据不下行**：View 不写 Entity，Entity 不写 Def。要反馈就发信号或 `Callable`。
2. **一个角色一个基类**：不为同类问题开第二个基类。
3. **依赖方向**：能力模块可引用 `Core`，`Core` 不引用能力模块（`plugin.gd` 只做编辑器接线）。

   现状**未**达标：`Core` 里 9 个文件仍沿 33 处反向引用 8 个能力模块（ECS / Translation / Camera / Tween / Focus / Task / Dialogue / Audio），
   清单与理由见 [LAYERS.md](LAYERS.md) 第七节。新增代码不要加重这层环，动这些点前先读清单。

## 目录

```
addons/DEVFramework/
├─ Core/          Def/ Entity/ Tool/ Async/ Pool/ Editor/   ← 跨能力复用
├─ <能力>/         Dialogue Task AI Camera ECS Tween UI Focus Render
│                 ArrayView Value Effect Signal Audio Translation
│                 Changelog GameCommand Test
├─ MCP/           扁平（preload 硬编码网，分层无收益）
└─ Native/        原生库 + dev.gdextension（禁止移动）
```

规则：**目录名 = 能力名**；模块内按 `Def / Entity / View / Tool / Editor` 分层，少于 3 个文件就扁平。

两处按内容命名（比五层贴切，保留）：`ECS/` 用 `Component / System / World / Timer / Render`（列存储 + 调度），
`Render/` 下分 `Lightmap / Screenshot` 两个子能力。单一角色的模块（`Value/ Signal/ UI/ Audio/` 等）保持扁平。

命名、归属、搬迁纪律全在 [LAYERS.md](LAYERS.md)。

## 安装

1. 复制 `addons/DEVFramework/` 到项目 `addons/`，插件面板启用。
2. 菜单 **项目 → 工具 → 创建 DEV 项目结构** 生成 `Assets/Def/`、`Scenes/`、`Scripts/` 骨架。

C++ 原生能力（ECS）需编译，见 [gdextension/README](../../gdextension/README.md)。

## 模块文档

每个模块都有自己的 Readme，写清定位、怎么用、坑与文件结构。MCP 没有模块 Readme，它写在下方
[MCP 调试服务器](#mcp-调试服务器)一节（对使用者更重要）。

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

## MCP 调试服务器

插件启用即监听 `http://127.0.0.1:9988/mcp`（多项目共用一个端口）。

- 多项目并存：`list_instances` → `use_instance` 选默认，或单次调用带 `instance`
- 常用：`validate` / `get_logs` / `eval_code` / `run_tests` / `perf` / `build_native` / `game_control` / `restart_editor`
- 场景批量改动：`apply_scene_edits`（一次事务，失败整体回滚；复制节点/连信号也是它的 op）+ `undo_redo`；文件改名 `move_file`
- 点完等结果：`wait_for`（轮询到条件成立，超时带"实际观察值"）；别写死 sleep
- 长说明不在 `tools/list` 里（常驻开销），按需读 `resources/list` 的 `devframework://docs/*`
- 项目自定义工具：`dev_framework/mcp/providers` 里列脚本路径，脚本写 `static func register(add_tool: Callable, ctx: Dictionary = {})`。
  `ctx.schema` / `ctx.result` 是契约工厂（不用再自己 `load` 框架文件），`ctx.tool_kinds` 为真时
  `add_tool` 可带第 5 个参数自报分类（`read_only` / `non_destructive` / `destructive`，不自报按破坏性兜底）。
  只收 `add_tool` 一个参数的旧写法仍可用；provider 注册出 0 个工具会 `push_warning`，不再静默从 `tools/list` 消失
- 改 `addons/DEVFramework/Native/src/**` 后**必须** `build_native`（`action=status` 查过期 → `action=build` 构建 → 重载生效），否则测试跑的是旧库且全绿
- 目录约定：**插件自己的 C++ 放 `addons/<插件>/Native/src`**（随插件分发）；构建区与第三方（godot-cpp）在项目根 `gdextension/`。多个插件各有 `Native/src` 时各编一个库、共用一份 godot-cpp
- 导出包默认不带入口（`dev_framework/mcp/runtime_enabled = false`）

## 引擎陷阱

1. **改框架代码后必须重启编辑器**：已注册的全局类不会真正 reload，行为与源码不符且无提示。
   `TestRunner` 会检测“磁盘 vs 已加载”并拒绝跑旧代码；headless 每次都是全新进程，不受影响。
2. `await` 已完成的协程句柄会永久挂起 → 用 `AsyncTool.await_coroutine`。
3. 脚本 reload 后，跨编译代次的类型化赋值可能静默得到 null → 跨边界传对象用无类型变量。
4. **别把已释放的节点赋给类型化变量**：`var n: Node = arr.pop_back()` 在实例已 `queue_free` 时会抛
   "Trying to assign invalid previously freed instance"（赋值先于 `is_instance_valid` 检查）。
   先用 `Variant` 接住再判空。
5. **注释/提示文本里的 `res://` 不算路径引用**：批量替换路径时若正则太宽，会把提示文案也改坏。
6. **`Entity2D/3D` 的 ECS 世界字段叫 `ecs_world`**（不是 `world`）。`world` 留给项目自己的世界对象；
   旧代码里的 `entity.world` 需改成 `entity.ecs_world`。
7. **static 缓存不会随热重载消失**：会缓存数据的 Tool/Def 应调用
   `ScriptEpochTool.register_cache(&"模块", 清缓存回调)`，测试轮次开始时会统一清一次；
   否则新旧脚本结构混代（地形索引/页缓存踩过）。

## 改完必跑

```
run_tests  process=editor script=test_framework_compile   # 全量编译 + 路径存在性
run_tests  process=editor script=test_tutorial            # 遮罩/气泡回归
run_tests  process=editor script=test_dialogue            # 对话链路

# headless / CI：注意是 Godot 的 -s（不是 --script）
godot --headless --path . -s res://addons/DEVFramework/Test/run_headless.gd -- --script all
```

**`run_tests` 是 job 模型**（长任务标准做法）：

| 调用 | 作用 |
|---|---|
| `run_tests(process, script, wait_sec)` | 启动任务。`wait_sec` 默认 5（0=立即返回）；窗口内跑完直接给完整汇总，否则返回 `{job_id, running:true, ...}` |
| `job_wait(job_id)` | 轮询同一个 job（固定等 28s，完成返回结果，**不重跑**）；`job` 状态在启动它的进程里 |
| `job_list()` | 不知道 `job_id`（比如上一次响应被客户端超时丢掉）时列出还记着的 job；`job_id` 省略时 `job_wait` 也会回落最近那个 |

慢测试（回放类常 100s+）不要反复启动 —— 拿到 `job_id` 后只调 `job_wait`。
**0 个用例 / 脚本解析失败现在一律判失败**：CI 里“没跑”与“跑了全过”必须可区分。
编辑器进程若检测到磁盘脚本与已加载版本不一致，会拒绝开跑并提示重启（或改用 headless）。

headless 默认还会挂一个 `LogCaptureTool`，把运行期 **script/shader/engine error** 算进失败（GUT 的 failure_error_types 语义；warning/printerr 不算，避免误伤故意制造告警的用例）。
- `-- --allow-errors`：关闭运行期错误统计（给“故意触发错误”的旧用例兜底）。
- `-- --freshness=strict|warn|off`：编辑器新鲜度策略；默认 strict，也可用项目设置 `dev_framework/test/freshness` 配置。

**进度与 ETA 是内建的**：`total` 在开跑前就按"确认会执行的方法数"算好，`eta_ms` 由最近 3 秒的进度速率外推；
进度不可用（总数未知/还没推进）时退化到**同类任务的历史用时**（`user://.dev_framework/perf_history.json`）。
测试轮次还会在正文里给出"用时 X（预估 Y，偏差 Z%）"，预估来自各用例方法的历史 EMA。
**进程首轮不计入基线**：冷缓存实测能慢一倍，记进去会让以后每轮的预估系统性偏高。

## 性能测量

两件事分开做，不要混：

| 目标 | 手段 |
|---|---|
| 测一段逻辑多快 | `PerfTool.measure(callable)` / `PerfTool.bench(callable, iters, warmup)` / `bench_auto(callable, 预算ms)` |
| 测环境帧率/稳定性 | `PerfTool.sample_frames(帧数, 预热帧)` 或 MCP `perf action=fps process=game` |

方法论对齐业界微基准库（Google Benchmark / nanobench / Catch2）的四条硬规则：

- **预热丢弃**：`warmup` 次的样本不进统计（首次 load / 着色器编译高出一个量级）。
- **统计口径**：给 `avg / p50 / p95 / p99 / min / max` + `std_ms` + `cv`。
  **看分位不看平均**（长尾才是卡顿），**看 cv 判断这次测量是否可信**（>10% 记 `noisy: true`）。
- **迭代自适应**：`bench_auto` 先把 batch 翻倍到"一批能测得出"，再按预算定样本数。
  直接单次计时会被 1µs 精度量化成 0（`bench` 会置 `below_resolution: true` 提醒你换它）。
- **准备与计时分离**：`bench(action, iters, warmup, setup)` 的 `setup` 每次样本前执行但**不计时**
  —— 造数据/重置状态不能算进被测代码的账上。

帧率侧的额外口径：

- `sample_frames` 给 `fps_p50 / fps_p95 / fps_1pct_low`（1% low = 最差 1% 帧的等效帧率，行业通用的"手感差"指标）。
- 卡顿阈值是 `max(中位帧时间×2, 16.7ms)` 并回传 `stutter_ms` —— 写死绝对值在 144Hz 或半速场景都会判错。
- 结果附带 `env`（GPU/CPU/max_fps/vsync/窗口/是否聚焦）：开关 vsync 或改 `max_fps` 后的数字互不可比。
- 在编辑器进程采样会带回 `note`：编辑器空闲节流会把帧率压到 10fps 左右，测真实性能必须 `process=game`。
- **不重复造引擎已有的监视器**：FPS / 绘制调用在 Debugger→Monitors 面板里本来就有（`Performance.TIME_FPS`、
  `RENDER_TOTAL_DRAW_CALLS_IN_FRAME`），框架不再注册同名的 `Perf/*` 自定义监视器。
- 基线条目多了以后用 `perf action=history key=test:` 过滤，别整份拉回来看。
- 用例里直接断言，把阈值写进 CI：

```gdscript
extends TestCase

func test_query_cost() -> void:
    assert_under_ms(5.0, func(): world.query(...).count())            # 硬上限
    assert_under_ms(0.01, func(): bitop(...))                         # 亚微秒也照写: 测不出来会自动分批
    measure_ms("ecs/query", func(): world.query(...).count())         # 只记基线, 不判失败

func test_frame_rate() -> void:
    await assert_fps_at_least(55.0, 120, 30)                  # 需游戏进程
```

- `PerfTool.Rolling` 是通用定长窗口（O(1) 写入、分位数/峰值/超阈值计数），
  替代各处手写 `Array + pop_front`（ECS 演示与调试面板已统一到它）。
- 历史基线进程级共享、跨轮次复用；`perf action=reset` 清空重来，不要写完就删文件。

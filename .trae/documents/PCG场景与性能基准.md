# PCG × 体素框架结合评估 · 综合场景 · 性能基准 · 实施计划

## Context（为什么做）

PCG 子系统（SDF 栈 + PcgModel 栈）已完成，但目前只有两个"能力清单式"demo
（`pcg_models_demo` 四个 SDF 模型并排、`pcg_operators_demo` 四个算子并排）。
两件事没被回答，本计划回答它们：

1. **PCG 与框架的结合是否优雅合理** —— 逐层核对契约与缺陷（下节给出结论）。
2. **PCG 能到什么水平、以及单场景大量 `VoxelRenderer` 的性能边界** —— 用综合场景 +
   单技法场景证明能力上限，用交互式 + 无头双轨基准测出拐点。

用户已确认四项范围选择：**综合场景与单技法场景都要**、**交互式与无头基准都要**、
**修掉 `PcgModelGenerator` 并发缺陷**、**综合场景包含可交互破坏**。

---

## 一、结合评估结论

### 优雅的部分（不需要动）

- **契约分层干净**：`VoxelGenerator` 只声明"按 key 造数"（`_generate_chunk` /
  `_generate_chunk_lod`）与"可生成范围"，不碰 I/O、不持有在途状态。有界模型是
  [VoxelGenerator.gd](file:///d:/Work/GodotProject/GodotVoxelSupport/addons/VoxelSupport/Runtime/VoxelGenerator.gd#L25-L28)
  明文认可的一等用法（注释原话"有限模板生成器，如建筑蓝图"）。
- **两条 PCG 栈与两种契约形态一一对应**：逐点采样
  [PcgSdfGenerator.gd](file:///d:/Work/GodotProject/GodotVoxelSupport/addons/VoxelSupport/PCG/PcgSdfGenerator.gd)
  ↔ `Sdf`；整体产出
  [PcgModelGenerator.gd](file:///d:/Work/GodotProject/GodotVoxelSupport/addons/VoxelSupport/PCG/PcgModelGenerator.gd)
  ↔ `PcgModel`。后者是全项目**唯一**的"整体 → 按 chunk 切片"适配器，所以加一种算子
  只需写一个 `build()`。
- **并发被收在一处**：异步编排（在途账本、去重、限流、回填、代次失效）全部在
  `VoxelAsyncLoader`，PCG 作者只写同步纯函数，不必理解线程。
- **有界范围零成本**：`VoxelData.generator` setter → `_sync_generator_bounds()` →
  `generator.set_grid_size()`，PCG 侧不含任何裁剪逻辑。
- **产出即享全链路**：因为一个模型就是"普通 `VoxelData` + `VoxelRenderer` 节点"，
  编辑 / 破坏 / 物理 / 碰撞 / LOD 全部自动可用，无需任何特殊分支。
  `VoxelData` 还会自动补 `VoxelMemoryStream` 作为编辑落脚点。

### 缺陷清单（按严重度）

| # | 问题 | 位置 | 处置 |
|---|---|---|---|
| 1 | **`_ensure_volume()` 无锁**：模型 >1 chunk（`grid_size > 32`）时首帧多个 worker 并发 `build()`。对 `PcgWfcOverlap` 是**正确性 bug**（`_learn()` 写实例成员 `_patterns/_weights/_allow/_n`，并发会读到"新 `_allow` + 半个 `_patterns`"）；对 L-系统 / 元胞 / WFC 只是 N× 浪费算力 | [PcgModelGenerator.gd#L87-L94](file:///d:/Work/GodotProject/GodotVoxelSupport/addons/VoxelSupport/PCG/PcgModelGenerator.gd#L87-L94) | **本计划修复（Step 1）** |
| 2 | **空 chunk 复活**：`_maybe_erase_empty_chunk()` 在体素归零时移除 chunk，而两个流都把"空"当"不存在"，生成器的 `is_in_generation_bounds()` 又恒真 → 该 chunk 被重新生成，打空的方块会回来 | [VoxelData.gd#L569-L578](file:///d:/Work/GodotProject/GodotVoxelSupport/addons/VoxelSupport/Runtime/VoxelData.gd#L569-L578) | **本次不修**（牵着 stream 墓碑语义，宜单独立项）。demo 侧规避：破坏目标选多 chunk 模型、不暴露"一键清空" |
| 3 | `SdfTransform` 在 `sample()` 热路径惰性改写 `_dirty/_inverse/_scale`，多 chunk 并行首采有竞态 | [SdfTransform.gd](file:///d:/Work/GodotProject/GodotVoxelSupport/addons/VoxelSupport/SDF/SdfTransform.gd#L46-L63) | **不修**：`_refresh_cache()` 幂等（两线程算出同一结果），最坏是重复一次矩阵求逆，非正确性 bug |
| 4 | `PcgModelGenerator` 永久保留一份密集 `_volume`（32³=128 KiB，128×48×128=3 MiB） | 同上 | 不修，但要测出来。实践上可让多个 `VoxelData` **共享同一 generator 实例**（尺寸需一致）把内存压到 1 份 |
| 5 | **幻影脏 chunk 集**（Step 8 实测发现并修复）：`_process_chunk_level` 的"`loaded_chunks` 为空"兜底分支以**相机**为心枚举 `(2·_r_ck+1)³` 立方体，对其中每个 chunk 无条件 `mark_chunk_dirty`，**不检查该 chunk 是否在数据可生成范围内**。有界程序化模型（32³ 只有 1 个 chunk）会因此被塞进 2 万+ 幻影键；又因 `_update_mesh_async` 超 `_rebuild_batch_limit` 就把余量放回 dirty，脏集**永不排空** → 每帧白转 2 万+ 键、真正有几何的 chunk 淹没在幻影里永不建网格 | [VoxelRenderer.gd#L1321-L1341](file:///d:/Work/GodotProject/GodotVoxelSupport/addons/VoxelSupport/Runtime/VoxelRenderer.gd#L1321-L1341) | **已修复**：加与 `_process_streaming` 同款的 `data.can_supply_chunk(ck)` 前置剪枝 |

---

## 二、实施步骤

### Step 1 — 修 `PcgModelGenerator` 并发构建（一切的前置）

**改** [PcgModelGenerator.gd](file:///d:/Work/GodotProject/GodotVoxelSupport/addons/VoxelSupport/PCG/PcgModelGenerator.gd)：

- 新增 `var _build_mutex := Mutex.new()`（与 `VoxelAsyncLoader.gd:48` 的既有用法一致）。
- `_ensure_volume()`：免锁快路径 `if _built: return true` → 锁内 `if not _built:` 构建，
  并把结果先存局部、**提交前校验 `_grid_size` 未变**再写 `_volume/_built`。
  尺寸校验是为了吞掉"构建期间主线程 `set_grid_size()` 改了尺寸"的过期结果
  （setter 不能取锁，否则主线程被在途构建阻塞）。
- `_generate_chunk` / `_generate_chunk_lod` / `_sample_cell` 先把 `var vol := _volume`
  捕获成局部再索引（`PackedInt32Array` 是 CoW，局部句柄即使期间重建也安全）。
- **`PcgSdfGenerator` 不加锁**（无缓存，逐格心纯采样）。

**验证**：在既有 [test_voxel_fix_regressions.gd](file:///d:/Work/GodotProject/GodotVoxelSupport/Scripts/Test/test_voxel_fix_regressions.gd)
（该文件定位就是"锁定已修复的失效模式"，且已含 `WorkerThreadPool` 用例）加一条回归：
用 `WorkerThreadPool.add_task` 并发对多个 `chunk_key` 调 `gen.generate()`，
`wait_for_task_completion` 后断言 `build_calls == 1` 且各切片与串行结果逐体素一致。
**必须反证一次**：临时去掉锁跑同一用例应失败，否则不知道测试是否在测东西。

### Step 2 — 共享组装工具 `PcgSceneKit`

**新建** `demo/pcg_scene_kit.gd`（`class_name PcgSceneKit extends RefCounted`）：
静态 `materials()` / `add_model(name, pos, generator, grid_size, materials, destructible := false)`
/ `wfc_tile(...)` / `overlap_sample(...)`。

理由：现有两个 demo 各有一份同构的 `_add_model` / `_material` / `_wfc_tile` /
`_overlap_sample`，再加 5 个场景就是 5 份拷贝。这是**唯一值得新建的 helper**。
（既有两个 demo 保持不动，避免动已验证可用物。）

### Step 3 — 综合场景 `demo/pcg_world_demo.gd` / `.tscn`

`@tool extends Node3D`；`.tscn` 逐字复刻 `pcg_operators_demo.tscn` 的
`WorldEnvironment`（ProceduralSkyMaterial + `ambient_light_source=3` / `reflected_light_source=3`
/ `tonemap_mode=2` / `fog_enabled=true`）、`DirectionalLight3D`（`light_energy=1.2`、
`shadow_enabled=true`）、`Camera3D`。`voxel_scale = 0.2`（1 chunk = 6.4 世界单位）。

| 层 | 生成器 | grid_size | 数量 | 说明 |
|---|---|---|---|---|
| 基底 | 手写 SDF：`Plane ∪ SmoothUnion{Box 台地, Sphere/Cone 经 Transform}` ⊖ `Sphere` 洞 | 128×48×128 | 1 | 单一渲染器装 32 个 chunk |
| 植被 | `PcgLsystem` | 32³ | 6~10 | 按台地高度摆放 |
| 洞穴 | `PcgCellular`（`fill_ratio=0.50` / `shell_is_solid=false` / `iterations=4`） | 64×32×64 | 1 | 嵌入岛体侧面 |
| 遗迹 | `PcgWfc`（4³ tile：open/rock/floor/pillar） | 32×48×32 | 2~3 | 台地平台 |
| 有机墙 | `PcgWfcOverlap` | 32³ | 1 | 遗迹一侧 |
| **可破坏** | `PcgWfc` 塔，节点类换成 **`VoxelDestructible`** | 32×48×32 | 1 | 相机正前方 |

合计 ~12–16 个 `VoxelRenderer`、~50–60 chunk。破坏接线复刻
[destruction_demo.gd](file:///d:/Work/GodotProject/GodotVoxelSupport/demo/destruction_demo.gd)
（`_mouse_to_voxel`、`damage_sphere`、`_setup_ground`、手写 `_prev_*` 边沿检测）。
**在屏上写明**："破坏目标节点只是把 `VoxelRenderer.new()` 换成 `VoxelDestructible.new()`，
其余组装代码一行未改"——这是"PCG 产出复用同一条链路"的最强证据。

注意两条硬约束（写进 demo 注释，避免后人踩）：
- **生成器无法按位置给多材质**（`PcgLsystem.material_id` / `PcgWfcTile.material_id` /
  SDF 各原语 `material_id` 都是每模型一个主色），布局时要接受。
- `PcgModel` 栈**没有 overlay**：`build()` 一次写满，后写覆盖先写。真正的"叠加/挖空"
  只在 SDF 栈（组合算子）里存在。

### Step 4 — 四个单技法场景

全部 `@tool extends Node3D`，`.tscn` 照 Step 3 模板，组装走 `PcgSceneKit`：

- `demo/pcg_forest_demo.gd/.tscn` —— L-系统成林。**形态差异只能靠
  `iterations/step/thickness/angle_degrees/rules/material_id`**（`PcgLsystem` 无 `seed`）。
- `demo/pcg_ruins_demo.gd/.tscn` —— `PcgWfc`（socket 约束）与 `PcgWfcOverlap`（有机墙）对照。
- `demo/pcg_cave_demo.gd/.tscn` —— `PcgCellular` + SDF 挖洞。
- `demo/pcg_porous_demo.gd/.tscn` —— SDF overlay 多孔岩：
  `SdfSubtract(SdfBox, SdfRepeat(SdfSphere, spacing≈3~4))`。

### Step 5 — 交互式性能基准 `demo/pcg_bench_demo.gd` / `.tscn`

- N ∈ {25, 100, 400, 900} 的 ⌈√N⌉×⌈√N⌉ 阵列，**全部共享同一个 `PcgModelGenerator` 实例**
  （隔离"渲染器数量"这个变量，同时把 `_volume` 压到 1 份）；模型统一 32³ → 1 chunk →
  1 `MeshInstance3D`，使 draw call ≈ 渲染器数。
- HUD 降频 0.5s 刷新：
  - 自算帧时 **avg / median / p99**（p99 才能暴露 `visibility_check_interval=8` 的周期性尖峰）
  - `Engine.get_frames_per_second()`（仓库既有风格；注意每秒只更新一次，仅作参考）
  - `RenderingServer.get_rendering_info(RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)`（仓库既有用法）
  - `Performance.get_monitor()`：`TIME_PROCESS` / `OBJECT_NODE_COUNT` /
    `OBJECT_RESOURCE_COUNT` / `RENDER_TOTAL_PRIMITIVES_IN_FRAME` / `MEMORY_STATIC` /
    `RENDER_TEXTURE_MEM_USED`（注意 `MEMORY_STATIC` 在 release 导出恒 0；`TIME_FPS` 每秒才更新）
  - 业务量：已建 chunk 数、mesh 节点数、`_snapshot_readers`
- 键位：`1/2/3/4` 换 N、`V` 切 `visibility_mode`、`H` 切阴影、`L` 切 `lod_count`、`R` 重置。
- 自动序列：**T_load 与 F_steady 分开报，永不混谈**。就绪判据用"已建 chunk 数 ==
  `grid_size` 推出的期望值，且连续 30 帧不变"（不要照 `test_world_demo.gd` 固定 180 帧——
  900 渲染器下整段都可能还在构建期，测到的是加载曲线）。

### Step 6 — 无头基准

**新建** `demo/pcg_bench.gd`（`class_name PcgModelBench extends RefCounted`，`static func run()`）
+ `demo/pcg_bench_headless.gd`（11 行，仿
[qvox_bench_headless.gd](file:///d:/Work/GodotProject/GodotVoxelSupport/demo/qvox_bench_headless.gd)：
`extends SceneTree`，`_initialize()` 调 `run()` 后 `quit()`）。实现只有一份。

调用：`godot --headless --path <proj> --script res://demo/pcg_bench_headless.gd`

**headless 只测"造/存"流水线**（渲染驱动是 dummy，draw call / 显存恒为 0，无意义）：
各模型构建耗时、切片吞吐、端到端 chunk 就绪时间、`_volume` 内存、确定性哈希、
**以及 `build_calls == 1`（Step 1 的无头证据）**。每行 `[BENCH] key=value`，
便于 `Select-String '\[BENCH\]'` 过滤掉 `print_fps` 噪声后逐行 diff。

---

## 三、验证

1. `mcp_devframework_validate` 全部新增/改动脚本无解析错误。
2. `mcp_devframework_run_tests` 全绿（含 Step 1 新增的并发回归）。
3. 逐个运行 6 个新场景：`get_game_errors` 为 0；截图确认 6 个场景各自出图。
4. 综合场景：左键在遗迹塔打出洞、碎块落在地面不穿地；HUD 的已建 chunk 数 == 期望值。
5. 基准：每档都打出 T_load + F_steady(avg/median/p99)；同档连测两次数字接近；
   `V` 切模式后必须**重新等收敛再测**（切 FULL 会全量标脏重建，立刻测等于测重建尖峰）。

---

## 四、已知风险与明确不做

- **`visibility_mode = FULL` + 大 `view_distance` 会表现为"卡死"**：数据未就绪的首帧窗口里，
  `_process_chunk_level` 会按半径做立方枚举（`view_distance=200` → 单渲染器约 (69)³ ≈ 31 万次
  GDScript 迭代）。既有 demo 靠默认 `view_distance=40` 规避。基准里 FULL 档要限定
  `view_distance` 并诚实报"期望 chunk 数 vs 实际建出数"。
- **预期瓶颈未必是 draw call**：每渲染器每帧固定开销（`_process` → `get_camera_3d()` ×2 →
  `poll_all_ready()` 进 Mutex → `_check_origin_shift()`）+ 每 8 帧一次含 `distance_to`（开方）的
  三重扫描。基准要能直接判定"主线程 GDScript 先到顶"还是"draw call 先到顶"（看 `TIME_PROCESS`
  与 draw call 谁先饱和）。
- **空 chunk 复活（缺陷 #2）本次不修**，仅靠 demo 选型规避。若演示中必须"一次清空整块"，
  需先单独立项修 VoxelData 的空块账 + stream 墓碑语义。
- **不改几何/渲染内核**，不重构既有两个 demo（保持已验证可用物不动）。

---

## 五、实测结果（Step 8 验证产出）

### 5.1 验证通过项

| 项 | 结果 |
|---|---|
| `validate`（6 个新脚本 + 改动的 VoxelRenderer） | 全部 `valid=true`，无解析错误 |
| `run_tests` | **87 通过 / 0 失败 / 1 跳过**（跳过项为需游戏进程的 smoke） |
| 6 个新场景逐个实跑 | **全部 `get_game_errors` = 0**，且均出图 |
| 综合场景交互破坏 | 单击左键 → 直接移除 **151** 体素、连带崩塌后共 **331**；HUD `已建 chunk 51/51`、`FPS 128` |
| 无头基准（`pcg_bench.gd`） | 四个算子确定性哈希稳定、`concurrent.build_calls=1`（Step 1 修复有无头证据） |

**修复记录**：Step 8 实测暴露并修掉三处（都不是"新增功能"，是让既有链路真正跑对）：

1. **幻影脏 chunk 集**（缺陷 #5，见上表）——框架级 bug，症状是"大量 VoxelRenderer + 大
   `view_distance` 时场景卡在 3 FPS 且一个网格都不出"。修复后同一场景从 **FPS 3 → 80**、
   `T_load` 从 **14268ms → 3144ms**、`mesh 节点 0 → 25`。
2. **`pcg_bench_demo._rebuild()` 的 `remove_child` → `queue_free`**：`remove_child` 让渲染器
   立刻离开场景树，而它本帧已排入的 `_process` 仍执行，其中的 `global_position` 在树外取值，
   每次换档刷 500 条 `!is_inside_tree()`。改为只 `queue_free()`（留树内到帧末）。
3. **`pcg_porous_demo` 竖井未贯通**：减集用的圆柱 `height=44 / center=0` 只覆盖 y∈[-22,22]，
   而石台顶面在 y=31，顶部 9 体素仍是实心 → 顶面看不到孔。改为 `center=(0,16,0) / height=60`。
4. **`test_voxel_fix_regressions` 的并发回归是"假绿"**：`got = [[], []]` 内层空数组上做
   `got[slot][0] = ...` 是越界写，任务静默失败后所有断言都不再执行 → 测试通过但什么都没验证。
   改为 `[[null], [null]]` 后该用例真正跑起来（18/18 通过，`build_calls == 1`、`reentered == false`）。

### 5.2 大量 VoxelRenderer 的性能曲线（交互式基准，N 档 = 25 / 100 / 400 / 900）

测量口述：`view_distance` 全档恒定 118，阵列恒定压在 68×68 世界单位内（隔离"渲染器数量"
这一个自变量）；每档等"已建 chunk 数连续 30 帧不变"进入 STEADY 后才采样。
**注意**：数据采自**挂调试器的 Debug 版**，绝对值会高于 release；看趋势与比值。

| N | T_load (ms) | F_steady avg | median | p99 | draw calls | primitives | mesh 节点 |
|---|---|---|---|---|---|---|---|
| 25 | 3 084 / 3 110（两次） | 20.9 / 21.4 | 3.2 / 4.0 | 146 / 150 | 120 | 157 k | 25 |
| 100 | 12 034 | 22.9 | 7.1 | 143 | 300 | 642 k | 100 |
| 400 | 50 984 | 27.1 | 11.1 | 150 | 1 026 | 2.60 M | 400 |
| 900 | 104 682 | 37.3 | 25.0 | 130 | 2 192 | 5.74 M | 900 |

读法与结论：

1. **T_load 严格线性**：25→100→400→900 每渲染器约 **116–127 ms**（≈120ms 常数）。
   该项是"生成 chunk 数据 + halo 快照 + 原生网格 + GPU 上传"的串行总账被
   `_rebuild_batch_limit` / `_stream_load_per_frame` 摊平后的结果，**与 N 无关**，
   所以总时间随 N 线性。→ 单场景想上 900+ 渲染器，瓶颈在**加载阶段**，且只能靠
   降低单模型成本（更小 grid / 更粗 LOD）或提高每帧预算来改善，改不改并发无关。
2. **稳态 median 次线性、随后抬头**：3.2 → 7.1 → 11.1 → 25.0 ms。
   25→400（16×）只涨 3.5×（因为每渲染器固定开销里含 `get_camera_3d()` ×2、
   `poll_all_ready()` 进 Mutex、`_check_origin_shift()`，这些在 N 大时被
   缓存/分支预测摊薄）；400→900（2.25×）涨 2.25× → 这一档开始**线性**。
   换算每渲染器稳态成本 ≈ **0.025–0.028 ms**，即 **单核约能带 900 个 32³ VoxelRenderer
   在 40 FPS**，或 **~250 个在 144 FPS**。
3. **draw call 线性、且是第二道墙**：120 → 300 → 1 026 → 2 192。900 档 2192 draw calls
   已属偏高（每渲染器 1–2 个 chunk mesh + 编辑器/HUD），这是 GPU 侧最先饱和的量；
   若模型是多 chunk（如综合场景的 128×48×128 = 51 chunks / 14 节点），draw call 会比
   渲染器数**涨得更快**。
4. **primitives 也随 N 线性**（157 k → 5.74 M，≈6.4k × N）：基准刻意把阵列压在固定
   面积内，N 大时几何互相穿插，所以三角面**不**恒定。要评估"纯 draw call 墙"应把间距
   随 N 一起放大（代价是要同时放大 `view_distance`，两个变量就纠缠了——这正是本基准选择
   固定面积的原因）。
5. **p99 ≈ 130–150 ms，且几乎不随 N 变化**：说明这个尖峰**不是**渲染器数量引起的。
   它来自两处每 8 帧一次的定时工作（`_process_streaming` 的距离扫描 + `_process_lod`）
   与本 demo 自身的 HUD 采集（`_update_hud` 每 0.5s 调多次 `Performance.get_monitor`
   与 `RenderingServer.get_rendering_info`，这类调用在 Godot 里本身昂贵）。**p99 是量具
   引入的**，读稳态性能请看 median。

### 5.3 "结合是否优雅合理" 的最终结论

- **结论：契约层面优雅，落地层面有两处需要作者认知的硬约束。**
- 优雅（实测证实）：一个 PCG 模型 = 一个普通 `VoxelData` + 一个 `VoxelRenderer` 节点。
  综合场景里 14 个模型（SDF 岛体、L-系统林、元胞洞穴、两种 WFC）与 1 个
  `VoxelDestructible` 塔**共用同一段组装代码**，破坏/物理/碰撞/LOD 全部自动可用，
  框架侧零 PCG 分支。这是"产出即享全链路"的直接证据。
- 约束一（**相机 × `view_distance` 是硬绑定的**）：有界程序化数据也走"按相机距离加载"
  （`data.generator != null` 即恒开流式驱动），超出 `view_distance` 的 LOD0 网格会被主动移除。
  所以相机必须让**所有**模型的 chunk 落在 `view_distance` 内，否则远处模型"建了又删"。
  这是布局约束，不是 bug，但必须写进作者心智模型。
- 约束二（**没有 overlay**）：`PcgModel` 栈的 `build()` 一次写满、后写覆盖先写，不存在
  "叠加/挖空"；真正的组合算子只在 `Sdf` 栈（`SdfSubtract` / `SdfSmoothUnion` / `SdfRepeat`）。
  想"雕凿"就用 SDF，想"生长/迭代"就用 `PcgModel`——两条栈的分工正是按这个划分的。
- 本轮新发现的一条**框架级缺陷（#5）**已在修复后消除，说明"有界模型"这一等用法此前只在
  `view_distance` 较小（≤40）的既有 demo 里被验证过；`view_distance` 一大就会踩到
  立方枚举的幻影脏集。修复后 900 渲染器可正常收敛，这条用法才算真正被验证覆盖。

### 5.4 未做 / 明确不做

- **不改 `VoxelAsyncLoader` 的"发射后不管"**：无头脚本退出时的 access violation
  （exit `-1073741819`）已定位为**引擎退出顺序**问题（线程池析构晚于 GDScript 虚拟机关闭，
  `add_task` 的 Callable 若引用 GDScript 对象且未 `wait_for_task_completion` 回收即触发），
  与体素 / PCG 逻辑无关，普通游戏退出同样会触发。遵守"不添加未要求修改"，仅在
  `pcg_bench_headless.gd` 注释中如实记录，未改动运行时。
- **缺陷 #2（空 chunk 复活）** 仍未修，靠 demo 选型规避。
- 未提交任何改动（用户要求"先不提交"）。

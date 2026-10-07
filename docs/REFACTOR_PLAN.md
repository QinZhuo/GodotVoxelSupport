# 体素插件重构计划

> 优先事项：**先把 `addons/VoxelSupport` 重构干净**，再在其上做建模软件 **QVoxelier**。
> 建模软件只决定"如何显示、如何操作"，核心能力全部由插件提供；原生工程文件格式就是 **QVox**，
> 顶层容器概念叫**世界（World）**。
>
> 本计划基于一次全量代码审计（13,700 行 GDScript + `gdextension/` C++）。

---

## 1. 四层职责模型（后面所有决策都从这里推）

```
┌───────────────────────────────────────────────────────────────┐
│ QVoxelier（建模软件，后置）                                      │
│   显示：视口、工具箱、链面板、调色板、状态栏                      │
│   操作：把用户动作翻译成内核调用 + 撤销栈（只记录"做了什么"）       │
│   ❌ 不含：体素算法、网格化、编解码、步骤求值                     │
├───────────────────────────────────────────────────────────────┤
│ 有限内核（插件的核心，本次重构对象）                              │
│   数据：分块稀疏体素存储、脏区域账本、连通性                       │
│   算法：SDF、PCG 修改器链、编辑内核（雕刻/填充/替换）、网格化       │
│   格式：QVox 读写（← 工程文件就是它）                             │
│   能力：一组稳定、可无头调用的 API                                │
├───────────────────────────────────────────────────────────────┤
│ 可选·无限层（从内核抽离，独立功能）                               │
│   LOD 分带、流式加载/卸载、视锥剔除、原点漂移、异步块供需           │
│   依赖方向：无限层 → 内核（单向，内核不知道它的存在）              │
├───────────────────────────────────────────────────────────────┤
│ 可选·游戏表现层（从内核抽离，独立功能）                           │
│   粒子碎片、掉落物理、健康度、级联崩塌、碰撞体                     │
├───────────────────────────────────────────────────────────────┤
│ C++ GDExtension                                                 │
│   几何内核：贪婪合并、dense 面生成、halo、LOD 降采样、QVox 块编解码 │
└───────────────────────────────────────────────────────────────┘
```

**两条关键结论**：

1. 现在的插件把"内核能力"与"渲染节点 / 游戏表现 / 无限世界调度"混在一起了。
   重构主线就是**把这四层切开**，切开之后建模软件才可能只做显示与操作。
2. **切分边界与"有限 / 无限"边界重合**。QVoxelier 处理的是有界有限模型（MagicaVoxel 语义），
   而无限的视点相关调度恰恰是耦合与冲突的主要来源 —— 一次切分同时解决两个问题。

---

## 2. 审计结论

### 2.1 四个 God 类占了 42% 的代码

| 文件 | 行数 | 承担的全部职责 |
|---|---|---|
| `Runtime/VoxelRenderer.gd` | 1615 | LOD 分带调度、mesh 异步构建管线、流式加载/卸载、视锥剔除、原点重定位、per-chunk 碰撞体、材质缓存与快照、线程派发、性能统计、编辑器行为 |
| `Runtime/VoxelData.gd` | 1504 | 体素存储、chunk 账本、LOD block 存储、损坏缓冲、异步加载协调、脏账本、体素计数、QVox/字典序列化、连通性与崩塌、材质管理 |
| `Runtime/VoxelDestructible.gd` | 1285 | 破坏/雕刻、压力传播、连通性分块、掉落物理、粒子碎片、健康度、级联崩塌、mesh 组装、碰撞更新 |
| `Runtime/QVoxFile.gd` | 1090 | 块框架、parse/serialize、增量写、校验、场景图构建、CACH 编码 |

### 2.2 同一概念被拆成多份账本（重构风险最高的部分）

| 概念 | 份数 | 位置 |
|---|---|---|
| 材质 | **3** | `_materials_cache` R283 / `_materials_snapshot` R327 / `_lod_materials` R143，清空点分散在 5 处 |
| 脏 chunk | **3** | `VoxelData._dirty_chunks` D372（写盘）/ `_dirty_mesh_chunks` D116（渲染）/ `_lod_dirty_region` D228（降采样） |
| LOD 失效 | **2** | `_lod_invalidated` D179 / `_coarse_modified` D346 — `erase_lod_block` D1171 必须同时清，注释 D1161-1170 自陈是隐患 |
| 体素计数 | **2** | `_voxel_count` 全局 / `_chunk_voxel_counts` 每 chunk，3 处手工同步 |
| 更新请求 | **4** | `_dirty` / `_pending_retrigger` / `_batch_complete_pending` / `_update_counter` |
| "是否流式" | **2** | `visibility_mode == STREAMING` 与 `_streaming_enabled`（R64 手工同步） |

> 这是"漏清一处就产生幽灵状态"的结构性来源。**收敛账本是本次重构收益最大的一项。**

### 2.3 生成流水线只有一个片段是可插拔的

- ✅ 已经是可插拔有序链：`PCG/PcgModelGenerator.gd` 的 `details` 数组（R26、R143-145），
  按顺序调用 `PcgDetail.apply()`。但**只覆盖细节层**（仅 2 个算子：`PcgSurfaceTint`、`PcgWeather`）。
- ❌ 生成层不可插拔：`field` 是单个变量，整块产出（`PcgTerrain`/`PcgCellular`/`PcgLsystem`/`PcgWfc`）。
- ❌ **重复实现**：`PCG/PcgSdfGenerator.gd` 内联了一整套表面处理（R30、R32、R41-82），
  与 `PcgSurfaceTint`/`PcgWeather` 功能重叠，且**两者不能组合** —— 该文件 R19-26 的注释
  自陈："`details` 那条链需要完整邻域，与 SDF 惰性按 chunk 生成不兼容"。
- ⚠️ 天然不适合进链的：`PcgWfcOverlap`（全局传播收敛 + 可变实例状态，需互斥锁
  `PcgModelGenerator.gd:48-51`）、`PcgScatter`（世界坐标语义，不产体积）。

### 2.4 C++ 边界已经很好，残留热路径集中在两处

**已全部下沉 C++**（`NativeLoader.REQUIRED_METHODS`）：贪婪合并、dense 面生成、halo 构建、
LOD 降采样、方块生成、破坏形状、压力传播、QVox 块编解码。✅ 这部分不必动。

**仍留在 GDScript 的热路径**：

| 位置 | 问题 |
|---|---|
| `VoxelDestructible._process` R1672 | 整条帧尾管线（级联分帧 R1681、掉落体生成 R1691、mesh 组装 R1693）主线程 |
| `VoxelDestructible._after_removal` R466 | 主线程同步 BFS + 分组（`VoxelData.partition_connected` R484） |
| `VoxelMeshGenerator._shift_index_array` R233 | 每 chunk `new PackedInt32Array` + 逐元素拷贝 |
| `VoxelMeshGenerator.generate_arrays_from_chunks` R193 | 自陈 Packed*Array COW 下 append 有 O(n²) 风险（注释 R209-210） |
| `VoxelRenderer._lod_materials[i].duplicate()` R1481 | 每次派发全量深拷贝材质数组 |
| `VoxelRenderer._process_chunk_level` R1322-1342 | 三重循环全量枚举相机周围 cube |
| `VoxelRenderer._lod_mark_null_or_retry` R1550-1560 | 三重循环 `span³` 判空 |
| `VoxelRenderer._shift_render` R966-1020 | 对 10+ 个字典逐个重建 + 遍历 |
| `VoxelData.flood_fill` R2121-2153 | 纯 GDScript 字典 BFS，每节点 `in result` + `has_voxel` |

### 2.5 常量双份（漂移点）

`QVOX_CHANNEL_BYTES` 在 `gdextension/src/voxel_native.cpp:1967` 与 `Runtime/QVoxSpec.gd:159`
各写一份。C++ 里 R1961-1962 的注释还声称"GDScript 有参考实现"，实际已不存在（陈旧注释）。

### 2.6 可拆分的天然边界（已审计出具体函数清单）

`VoxelRenderer` → 5 个新类：`VoxelLodScheduler`、`VoxelMeshBuildPipeline`、
`VoxelStreamingDirector`、`VoxelCollisionBuilder`、`VoxelMaterialCache`。
`VoxelData` → 3 个：`VoxelDamageStore`、`VoxelPayloadCodec`、`VoxelConnectivity`。
（每个新类应搬走哪些函数已在审计中有逐条清单。）

---

## 3. 重构分期

### P0 —— 一致性收敛（**先做，零行为变更，收益最大**）

| # | 动作 | 理由 | 涉及 |
|---|---|---|---|
| P0-1 | 材质 3 份 → 1 份 `VoxelMaterialCache` | 5 处清空点，漏一处就显示旧材质 | `VoxelRenderer` R283/R327/R143 |
| P0-2 | 脏账本 3 本 → 1 个 `ChunkDirtyLedger`（带"为何脏"的位标记） | `clear()` R1449-1465 现在要手写三处 | `VoxelData` D372/D116/D228 |
| P0-3 | LOD 失效 2 本 → 合并到 P0-2 的位标记 | 注释 D1161-1170 自陈的隐患 | `VoxelData` D179/D346 |
| P0-4 | 体素计数 2 份 → 单一权威 + 派生查询 | 3 处手工同步 | `VoxelData` D376/D366 |
| P0-5 | 常量单源：C++ 从一份清单派生，删陈旧注释 | 漂移已存在 | `QVoxSpec.gd` / `voxel_native.cpp` |
| P0-6 | 建一个**无头回归测试**：固定种子生成 → 网格 → 快照哈希（含逐字节体积哈希） | **P1/P2 拆分的安全网，没有它不能动 P1** | `Scripts/Test/` |
| P0-7 | 给"视点相关"代码打标记（`# [INF]`），精确统计 §4.1 估算的 2,100 行 | P2-1 的施工图 | `VoxelRenderer` / `VoxelData` |

### P1 —— 拆 God 类（行为等价，纯搬迁）

| # | 动作 | 拆出 |
|---|---|---|
| P1-1 | `VoxelRenderer` 拆 5 类 | LOD 调度 / mesh 构建管线 / 流式 / 碰撞 / 材质缓存 |
| P1-2 | `VoxelData` 拆 3 类 | 损坏存储 / 序列化编解码 / 连通性 |
| P1-3 | `VoxelDestructible` 按"内核 vs 表现"纵切（见 P2-1） | 编辑内核 / 表现层 |

判据：P1 全部做完后，`VoxelRenderer` / `VoxelData` 应各自降到 400~600 行，
且**跑 P0-6 的快照哈希逐字节一致**。

### P2 —— 边界重划：有限内核 + 可选的无限层与表现层（**建模软件的前提**）

| # | 动作 | 理由 |
|---|---|---|
| P2-1 | 把 LOD 分带、流式加载/卸载、视锥剔除、原点漂移、异步块供需**抽离**为独立的"无限层"（单独插件/组件），依赖单向：无限层 → 内核 | 这是耦合与冲突的主要来源。内核不需要知道相机、LOD、流式、原点的存在。**见 §4** |
| P2-2 | 内核 API 保持**按 chunk 索引 + 脏区域事件**的形态，供无限层套在外层 | 这是"抽离"能成立的前提；若内核 API 是"整块重算"式的，无限层挂不上去 |
| P2-3 | 把粒子碎片 / 掉落物理 / 健康度 / 级联崩塌抽离为独立的"表现层"组件 | 几何内核已在 C++，但**表现逻辑与编辑逻辑在同一函数里交织**（`_process` R1672 一条链里既有级联也有 mesh 组装） |
| P2-4 | 抽出 `VoxelEditKernel`（无场景节点、无 `_process`、可无头调用） | 建模软件的"画笔"直接调它，不需要一个 `VoxelDestructible` 节点 |
| P2-5 | 热路径下移：`_shift_index_array`、`generate_arrays_from_chunks`、`_translate_native_verts` 进 C++ | 每 chunk 全量 `PackedInt32Array` 拷贝，是网格化的固定开销 |
| P2-6 | `flood_fill` / `partition_connected` / `find_unsupported` 进 C++ 或改原生实现 | 现在每节点 `in result` 的 GDScript BFS，破坏一堵墙就卡帧 |
| P2-7 | 编辑路径改为**脏区域增量重建**（抽走 LOD 之后仍必须保留） | 见 §4，这是"有限内核"唯一真正的性能风险 |

### P3 —— 统一生成流水线（把三个硬编码步骤变成一条链）

| # | 动作 | 理由 |
|---|---|---|
| P3-1 | 定义修改器的两类契约：**生产者**（`build(grid_size) -> PackedInt32Array`）与**改写者**（`apply(volume, grid_size, seed)`） | 现有 `PcgDetail.apply` 已是改写者契约，直接升华；`PcgModel.build` 已是生产者契约。**不需要改任何已有算子** |
| P3-2 | 消除 `PcgSdfGenerator` 内联表面层，改为"先生成完整体积，再进链" | 让 (a)(b) 两条路合并成一条。这是本计划最重要的**架构**收益 |
| P3-3 | 生成层也纳入链（生产者步骤可多个，按顺序覆盖/合成） | 让"地形 + 洞穴 + 建筑"可组合，而不是只有一个 `field` 变量 |
| P3-4 | `PcgWfcOverlap` / `PcgScatter` 显式标为"链外节点"（需要全局信息或非体积语义） | 审计已确认它们不适合线性链，强行塞入会引入错误语义 |
| P3-5 | 手绘基础体素（`blocks`）作为链的**输入/种子**接入（手绘是链的输入，**不是**链上的一环，见 `QVoxelier/DESIGN.md` §5.2） | 让"手绘 + 程序化"可组合 —— 这正是建模软件需要的 |

> P3 的产物就是"核心能力 API"：**一条有序、可插拔、可旁通、可无头求值的修改器链**。
> 建模软件只是给它画一个面板，并把用户动作翻译成对链的操作。

### P4 —— 格式与 API 面收口

| # | 动作 |
|---|---|
| P4-1 | QVox 已是原生格式：支持多模型（`VOX0`，`model_id` uint16 → 最多 65536）、场景图（`NODE`：节点树 / 变换 / 图层名 / 动画）、文件级调色板（`MATE`）、稀疏分块（空块零字节）、4 种块内编解码 |
| P4-2 | **未知块会被跳过且重写时原样保留**（`QVoxFile.gd:362-367` + `:1068-1071`）→ 加工程数据块对旧解析器天然安全；块类型是 4×ASCII，空间充足 |
| P4-3 | 为工程数据补**字段**（**不新增块类型**，见 §5）：逐对象修改器链 → `NODE.nodes[].steps`、图层属性 → `NODE.layers`、相机书签 → `NODE.cameras`、世界级 `voxel_size` → `HEAD.world`。只动 GDScript（`QVoxSpec` 常量、`QVoxFile` parse/serialize/validate、`QVoxWorld`），**不需要动 C++** |
| P4-4 | 把"能力 API"标注稳定等级（公开 / 实验 / 内部），并让内部协议（`get_chunk_buffers`、`snapshot_*`、`accept_chunk_buffer` 等）不再对内核外可见 |

### 顺序理由

P0 是"把地雷清掉"，P1 是"搬家"，**这两步不改变任何行为**，风险最低而收益立竿见影
（4 个文件从 5,494 行降到约 2,000 行）。P2 决定"建模软件能不能薄"，P3 决定"功能能不能组合"，
P4 决定"能不能对外稳定"。**没有 P0 的安全网就做 P1，是在给自己埋雷。**

---

## 4. 关于"移除无限距离逻辑"：结论与性能分析

**结论：方向正确，但准确表述是"抽离"而非"移除"，且要区分两样东西。**

### 4.1 该移走的是"视点相关调度"，不该动的是"分块稀疏存储"

| 项 | 归属 | 理由 |
|---|---|---|
| LOD 分带/块调度、流式加载卸载、视锥剔除、原点漂移、异步块供需 | **移出内核** | 全部依赖相机/视点，有限模型一条都用不上；且它们是耦合主因 |
| **分块稀疏存储**（空块零字节）、脏区域账本 | **留在内核** | 这是内存命脉，不是视点逻辑。MagicaVoxel 内部同样分块 |
| **脏区域增量重建** | **留在内核，且必须保留** | 见 4.2 |

把"分块存储"也一起删掉是唯一会真正踩坑的做法：有限模型全量 O(N³) 常驻是有上限的
（256³ = 1670 万格 × int32 = 67 MB；512³ = 5.37 亿格 = 537 MB），而"空块零字节"正是让
"一个大而稀疏的世界"可行的原因。

### 4.2 性能：会变快，但风险在另一处

**移走无限层是净收益** —— 省掉的都是每帧/高频开销，审计已给出行号：

- `_process_lod` 每帧对 `loaded_chunks` 全表扫一遍求范围（R1061-1063）→ 消失
- `_process_chunk_level` 三重循环枚举相机周围 cube（R1322-1342）→ 消失
- `_lod_mark_null_or_retry` 三重循环 `span³` 判空（R1550-1560）→ 消失
- `_shift_render` 对 10+ 个字典逐个重建（R966-1020）→ 消失
- 每次派发 `_lod_materials[i].duplicate()` 全量深拷贝（R1481）→ 消失
- LOD 失效双账本、`_coarse_*` 账本、块快照协议 → 消失
- 修改器链只需**求值一次**（完整体积），不再需要"惰性路径 + 完整路径"两套代码

**真正的性能风险是另一件事**：有限模型 + 朴素实现 = **每次落笔全量重算 / 全量重建网格**。
256³ 每笔重算 1670 万格，比省下的开销大得多。所以必须保留：

1. 脏区域（chunk 或 AABB）粒度的**增量网格重建**；
2. 编辑只改**变化的块**，计数/包围盒/连通性增量维护；
3. 修改器链的**逐修改器缓存**：程序化修改器只在自身参数变化时重算（这天然属于 §5 的 `steps` 模型）。

只要这三条在，有限内核在**编辑响应**上会明显快于现状；若只做第 1 条而忽略第 3 条，
改一个参数就会卡住整个模型。

### 4.3 附带收益：切分边界与"有限/无限"边界重合

移走无限层后四层边界一次性对齐。**原来"插件的流式架构"与"建模软件的有界模型"之间的
冲突（见 2.3）随之消失** —— `PcgSdfGenerator` 注释自陈的"风化吃不到"问题，
本质就是惰性按 chunk 生成导致的，有限内核把整块体积常驻内存即可根治。

---

## 5. QVox 世界结构（qvox 3，不兼容改版）

QVox 已经把"结构"与"数据"分开，这正是它适合当工程格式的原因：

| 块 | 现在承载 | 世界结构需要它承载什么 |
|---|---|---|
| `HEAD` (JSON) | `qvox` / `channels` / `up_axis` / `block_size` / `bounds` / `require` | 加世界级设置（名称、`voxel_size`、作者…） |
| `MATE` | 文件级调色板（≤1 个，12 字节/条：rgba + metal/rough/hardness/mass + 自发光） | 不变（材质名作为可选追加字段） |
| `VOX0` | 每 `model_id` 一份稀疏分块体素（4 种块内编解码） | = **对象的基础体素**（手工编辑结果） |
| `NODE` (JSON) | `nodes` 树 / `layers`（仅名字表）/ `animations` | = **世界结构**：对象、层级、图层属性、**修改器链**、相机书签 |
| `CACH` | 派生数据（LOD 等，按 kind 区分，可删） | 加 `kind="EVAL"`（修改器链求值缓存）、缩略图 |

**不需要新增块类型**：`NODE` 与 `HEAD` 本来就是 JSON，扩展它们是零机械成本、零 C++ 改动。
（这正是"未知块跳过 + 重写保留"之外的另一个好消息：工程数据基本不需要新块。）

### 5.1 结构草案

```json
// HEAD
{ "qvox": 3,
  "channels": [ { "name": "material", "bpp": 16 } ],
  "up_axis": "y", "block_size": 32,
  "bounds": { "min": [0,0,0], "max": [256,256,256] } }
```

```json
// NODE —— 世界结构块
{ "world": { "name": "chair", "voxel_size": 0.1 },
  "layers": [ { "name": "default", "visible": true,  "locked": false },
              { "name": "detail",  "visible": true,  "locked": false } ],
  "cameras": [ { "name": "front", "projection": "ortho", "size": 128,
                 "transform": { "t": [0,0,0], "r": [0,0,0,1] } } ],
  "nodes": [
    { "name": "root", "kind": "group", "children": [1, 2] },
    { "name": "body",  "kind": "model", "model_id": 0, "layer": 0,
      "transform": { "t": [0,0,0], "r": [0,0,0,1], "s": [1,1,1] },
      "steps": [ { "kind": "volume", "type": "PcgSurfaceTint", "combine": 0, "blend": 2.0, "seed": 7 },
                 { "kind": "volume", "type": "PcgWeather", "combine": 0, "blend": 2.0, "seed": 0, "enabled": false } ] },
    { "name": "wheel", "kind": "model", "model_id": 1, "layer": 1,
      "transform": { "t": [4,0,0], "r": [0,0,0,1], "s": [1,1,1] } }
  ],
  "animations": [ /* 同现状 */ ] }
```

与原结构的差异只有四处：

1. 顶层加 `world`（世界级设置，含 `voxel_size`）。
2. `layers` 从"名字字符串数组"变成"对象数组"（可见/锁定/顺序/颜色）。
3. 节点加 `layer`（图层下标，缺省 0）与 `steps`（有序修改器链，缺省空）。
4. 加 `cameras`（相机书签，缺省空）。

### 5.2 求值语义（这是非破坏建模的核心）

- `steps` **有序**，每项 `{ kind, type, params?, combine, blend, seed, enabled? }`；`kind` 决定读盘
  时造哪个修改器子类（`sdf` / `model` / `volume`），`type` 是**算子**类名，算子参数摊平进 `params`。
- 求值：`base` → 依次 `apply` 每个 enabled 修改器 → 得到显示体积。
- **`VOX0[model_id]` = 该对象的 `base`**，即手工编辑结果，是**真值**；
  若链首是生产者修改器且从未手绘，`VOX0` 可以为空（零块）。
- 求值结果**不作为真值落盘**；需要加速时写 `CACH(kind="EVAL")`，可随时删。
- `enabled: false` = 旁通（保留配置但不生效），对应建模软件面板上的"眼睛开关"。
- **烘焙**（破坏性）是显式动作：把求值结果写回 `VOX0` 并清空 `steps`。
- **逐步骤判脏**：改某步骤参数 → 只从该步骤起重算，前面的结果复用（对应 §4.2 第 3 条）。

### 5.3 版本策略

`qvox: 3`。**不读 qvox 2 文件**（仍在开发阶段，无外部使用，用户已确认不需要兼容）。
换来的好处是可以把结构一次做对，而不是靠 `VSDS` 之类的补丁块堆出来。

---

## 6. 命名与决议

**软件名：`QVoxelier`**（QVox + atelier，与 `.qvox` 格式同名咬合）。
**类名前缀统一为 `QVox*`**（原 `Vs*` 前缀作废，因为品牌与格式都是 QVox）。
**顶层概念：世界（World）**，替代原"文档（Document）"的提法。

| 旧名 | 新名 | 说明 |
|---|---|---|
| `VsDocument` | `QVoxWorld` | 一个 `.qvox` 文件 = 一个世界 |
| `VsObject` / `VsSlot` / `VsDomain` / `VsEvalContext` | `QVoxObject` / `QVoxModifier` / `QVoxDomain` / `QVoxEvalContext` | 已落地，位于 `addons/VoxelSupport/Modifier/` |
| `VsCommand` | `QVoxCommand`（+ `QVoxUndoStack` / `QVoxVoxelEditCommand`） | 已落地，但位于 **`QVoxelier/Core/`**（应用层，`extends GameCommand`/`CommandHistory`，见 §6.1） |
| `VsRasterizer` | （无） | 已**折叠**进 `PcgSdfGenerator.rasterize_field()`，不再单独存在 |
| 文档级 `voxel_size` | 世界级 `voxel_size` | 存在 `HEAD.world` |
| 文档调色板 | 世界调色板 | 存在 `MATE`（单块，文件级） |

**已决议并已执行**：

1. 软件名 `QVoxelier`；插件内核改名（如 `VoxelCore`），`plugin.cfg` 描述同步更新 —— **待做（P4-3）**。
2. 分期按 P0 → P1 → P2 → P3 → P4 推进。
3. 世界结构（对象模型 + 修改器链）**落在插件内核内**（`addons/VoxelSupport/Modifier/`），并
   **原生进入 QVox**（§5）；QVoxelier 只做显示与操作翻译。**撤销命令例外**：它位于
   `QVoxelier/Core/`（见 §6.1 第 4 条）。
4. **已完成**：`VoxelStudio/` → `QVoxelier/`；原 `Core/*.gd` 的对象模型文件移入
   `addons/VoxelSupport/Modifier/` 并按 `QVox*` 前缀改名（后又按域拆分为 `Sdf/` 与 `Model/`，
   并依次去掉 `Operators/` 中间层与 `Volume/`、`Generator/` 薄目录）。这一步顺带消掉了一个反向依赖：
   光栅化原本在插件外引用 `VoxelGenerator` / `VoxelChunk` / `PcgModel`。
5. **QVoxelier 是独立仓库**的可运行独立场景，按输入合理调用插件能力（不实现算法）；
   `QVoxelier/DESIGN.md` 已按其前提修正。

### 6.1 一致性与存储收敛（2026-10-08 执行）

在世界结构进插件落地后，审计出四处重复/背离，已一并收敛：

| # | 问题 | 处置 |
|---|---|---|
| 1 | `QVoxWorld` 与 `QVoxFile.QVoxDocument` 都能代表一份工程 → **双真值** | `QVoxWorld` 为**唯一常驻真值**；`QVoxDocument` 降为"读写那一瞬"的传输结构，两者由 `to_document()` / `from_document()` 一对显式转换连接，**不允许同时常驻** |
| 2 | `QVoxObject` 的基础体素是 dense 数组 → 与"分块稀疏"内核原则相悖（512³ dense = 537 MB） | 改为**分块稀疏** `blocks: Dictionary`（块坐标 → `PackedInt32Array(B³)`，0 = 空、空块缺失），块布局权威统一到 `QVoxSpec`；并与 `VOX0` 落盘同形，读写零转换 |
| 3 | `QVoxRasterizer` 与 `PcgSdfGenerator` 各有一份"FIELD 域 → 体素"的光栅化 | 删 `QVoxRasterizer`，折叠为 `PcgSdfGenerator.rasterize_field()`（内部 `to_volume(grid_size)` + `_blit_chunk()` 走 `VoxelChunk.CHUNK_SIZE`） |
| 4 | `QVoxCommand` 放在插件内 → 一旦复用框架 `GameCommand` 就会逼出插件交叉引用 | `QVoxCommand` / `QVoxUndoStack` / `QVoxVoxelEditCommand` 移入 **`QVoxelier/Core/`**（`extends GameCommand` / `CommandHistory`）。两插件保持**互不引用** |

**仍未做**：`QVoxEvalEngine`（求值引擎）与 `QVoxPropertyCommand` / `QVoxMacroCommand` 仍停留在
设计（`QVoxelier/DESIGN.md` §6.1/§6.2），代码里尚无实现。

**待确认**：

- 无限层与表现层抽离后放在哪里：同仓库独立插件，还是独立仓库。
- 插件内核改名的具体名字（`VoxelCore` 只是建议）。

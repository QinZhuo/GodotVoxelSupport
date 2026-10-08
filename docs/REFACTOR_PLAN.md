# 体素插件重构计划

> 优先事项：**先把 `addons/VoxelSupport` 重构干净**，再在其上做建模软件 **QVoxelier**。
> 建模软件只决定"如何显示、如何操作"，核心能力全部由插件提供；原生工程文件格式就是 **QVox**，
> 顶层容器概念叫**世界（World）**。
>
> 本计划基于一次全量代码审计（13,700 行 GDScript + `gdextension/` C++）。
>
> **进度（2026-10-08）：P0 → P4 五个阶段全部完成。** 施工记录与验证证据见 §3 各阶段表
> （P0 安全网 / P1 搬家 / P2 抽离与内核契约 / P3 统一生成流水线 / P4 格式与 API 面收口）。
> 最新一次全量验证：编辑器 **130/130** + 游戏进程 **9/9**。
> **两项开放项均已收口（2026-10-08）**：内核名保持 `VoxelSupport`（否决改名为 `VoxelCore`）；
> 无限层与表现层**留在插件内**（不拆独立插件、不拆独立仓库）—— 见 §6 待确认。

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
| P0-1 ✅ | 材质 3 份 → 1 份 `VoxelMaterialCache` | 5 处清空点，漏一处就显示旧材质 | `VoxelRenderer` R283/R327/R143 |
| P0-2 ✅ | 脏账本 3 本 → 1 个 `VoxelDirtyLedger`（带"为何脏"的位标记） | `clear()` R1449-1465 现在要手写三处 | `VoxelData` D372/D116/D228 |
| P0-3 ✅ | LOD 失效 2 本 → 合并到 P0-2 的位标记 | 注释 D1161-1170 自陈的隐患 | `VoxelData` D179/D346 |
| P0-4 ✅ | 体素计数 2 份 → 单一权威 + 派生查询 | 3 处手工同步 | `VoxelData` D376/D366 |
| P0-5 ✅ | 常量单源：C++ 从一份清单派生，删陈旧注释 | 漂移已存在 | `QVoxSpec.gd` / `voxel_native.cpp` |
| P0-6 ✅ | 建一个**无头回归测试**：固定种子生成 → 网格 → 快照哈希（含逐字节体积哈希） | **P1/P2 拆分的安全网，没有它不能动 P1** | `Scripts/Test/` |
| P0-7 ✅ | 给"视点相关"代码打标记（`# [INF]`），精确统计 §4.1 估算的 2,100 行 | P2-1 的施工图 | `VoxelRenderer` / `VoxelData` |

#### P0 执行记录

| # | 结论 |
|---|---|
| P0-1 | 新增 `VoxelMaterialCache`（`addons/VoxelSupport/Runtime/VoxelMaterialCache.gd`），三份派生（snapshot 深拷贝 / surfaces 运行时 Material / 各层 aligned）收在一处，权威仍是 `VoxelData.materials`。失效只有 `invalidate()`（内容变）与 `invalidate_aligned()`（block 账本整清）两个入口，另有"源引用比对"自动通道兜住换 `data.materials` 的情况。`VoxelRenderer` 的 `_materials := VoxelMaterialCache.new()`（R321）替换了原先散落的清空点（R38/R562 改调 `invalidate()`）；`VoxelDestructible` 不再自建缓存，掉落块材质直接复用父类 `_materials.surfaces()`（R1133-1136）。 |
| P0-2 | 新增 `VoxelDirtyLedger`（`addons/VoxelSupport/Runtime/VoxelDirtyLedger.gd`，计划里的 `ChunkDirtyLedger` 落地为此名），"为何脏"用位标记而非三本独立账本；`VoxelData` 内 54 处调用点统一走它，整表清理只剩一个入口。 |
| P0-3 | LOD 失效并入 P0-2 的位标记（`VoxelDirtyLedger` 内区分 mesh / LOD 失效位），原先"注释自陈的隐患"（两本账本手工同步）消失。 |
| P0-4 | 体素计数收敛为唯一权威 `_chunk_voxel_counts`（`VoxelData` R356），写入口只有 `_count_delta` / `_count_set`，全局总数由 `get_voxel_count()`（R1453）求和派生，不再有第二份可漂移的存储。 |
| P0-5 | C++ 侧不另立真值：`voxel_native.cpp` R1963-1968 的注释改为指向**行为反证**用例 `test_qvox_format.gd::test_native_codec_id_mirror`（把 `QVoxSpec.CODEC_*`/`CHANNEL_BYTES` 送进原生接口，用返回行为断言一致），删掉了"GDScript 有参考实现"的陈旧注释。 |
| P0-6 | 落地 `Scripts/Test/test_voxel_snapshot_baseline.gd`（编辑器侧，纯数据 + 几何内核，无需场景树）。口径：`PcgModelGenerator(PcgTerrain, seed=12345)` 生成 48³（跨 8 个 chunk）→ `VoxelData.accept_chunk_buffer` 回填 → **按 chunk key 排序**后拼接 `PackedInt32Array.to_byte_array()` 取 FNV-1a 32 位哈希；网格走 `VoxelMeshGenerator.generate_arrays_from_chunks`（= `build_halo_from_buffers` + `generate_chunk_dense`，与 `VoxelRenderer` 逐 chunk 同一内核）。**基线（2026-10-08）**：体积 `1837387656`、网格 `1739196767`、体素 11548、chunk 8、三角 5790。另含"同 seed 逐字节一致 + 换 seed 必变"两条防假绿断言。自实现 FNV 而非用 `PackedByteArray.hash()`，使基线不随引擎哈希算法变化而飘。 |
| P0-7 | 标记口径：`# [INF] 视点相关（P2-1 迁出）` 紧贴成员 `##` 文档块上方；一个成员的区间 = 标记行起，至下一个顶格非空行止（含标记行）。**实测（2026-10-08）**：`VoxelRenderer` 79 处覆盖 **1315 / 2349 行（56.0%）**；`VoxelData` 52 处覆盖 **497 / 2261 行（22.0%）**；合计 **1812 行**，低于 §4.1 估算的 2,100 行（差值即"视点编排入口"本身留在内核：`_process` 与 `_record_perf_stats`）。误插 0（无标记落在文档块与声明之间）。约定文字随两文件头部的 `# 【INF】` 注释块走。 |
| P0-7 归宿 | **两文件的标记已在 P2-1 期 4 收尾时全部处置完（2026-10-08）**：`VoxelRenderer` 79 处 → 迁移完成，剩 **11 处**（留在节点的 `@export` 旋钮 + 1 个 deferred 委托壳），文件 2349 → **1253 行**；`VoxelData` 52 处 → **全部改判为「留内核（数据层）」并删除标记**（2261 → **2061 行**）—— 逐条判定后无一处含相机 / 视锥 / 距离判定，全是**存储 / 账本 / 算法**（粗层 `_coarse_buffers` 与 `_chunk_buffers` 同族、LOD 脏账写入、降采样调度、流式读写机制、取数编排、`shift_origin` 的数据侧）。详见 `VoxelData.gd` 头部「INF 标记的改判」。**教训：P0-7 的标记是按关键词命中的产物（`lod`/`stream`/`chunk` 命中即标），归属必须逐条看依赖方向与数据所有权。** |

### P1 —— 拆 God 类（行为等价，纯搬迁）

| # | 动作 | 拆出 |
|---|---|---|
| P1-1 | ~~`VoxelRenderer` 拆 5 类~~ → **并入 P2-1**（见下方决议） | LOD 调度 / mesh 构建管线 / 流式 / 碰撞 / 材质缓存 |
| P1-2 ✅ | `VoxelData` 拆 3 类 | 损坏存储 ✅ / 序列化编解码 ✅ / 连通性 ✅ |
| P1-3 | `VoxelDestructible` 按"内核 vs 表现"纵切（见 P2-1） | 编辑内核 / 表现层 |

判据：P1 全部做完后，`VoxelRenderer` / `VoxelData` 应各自降到 400~600 行，
且**跑 P0-6 的快照哈希逐字节一致**。

> **P1-2 完成后的实测（2026-10-08）**：`VoxelData` 2261 → **2113 行**（P1-2 三块共移出 148 行），
> 离 400~600 很远。原因是 P1-2 的目标只是"把**不属数据层**的三块收口"，它本身不是行数主力：
> `VoxelData` 的 INF 视点相关部分实测也只有 497 行（≈23%），而 P1-2 移出的三块合计 295 行。
> 故 400~600 这条判据应视为 **P2 结束**时才可能达成（需连同"存储 / 查询 / 快照 / LOD 数据层"一起再分层），
> **P1 结束时不要用它验收**，否则会误判为失败。

#### 决议（2026-10-08）：P1-1 与 P2-1 合并

`VoxelRenderer` 的四个待拆类（LOD 调度 / 流式 / 碰撞 / mesh 管线）与 P2-1 的"无限层"
**是同一批代码**。若按原计划先"插件内拆类"、再"抽成独立模块"，同一批代码要搬两次
（第二次还得重做依赖方向）。故合并为一步：**直接按 P2-1 的无限层边界抽离**，
`VoxelRenderer` 只留有限内核（`_process` 编排入口 + mesh 组装 + 材质采样）。
材质缓存不受影响（P0-1 已提前完成，且它属内核）。
`VoxelData` 的 P1-2 不变 —— 损坏存储 / 编解码 / 连通性与视点无关，先拆干净。

#### P1 执行记录

| # | 结论 |
|---|---|
| P1-2① | 抽出 `VoxelConnectivity`（`addons/VoxelSupport/Runtime/VoxelConnectivity.gd`，155 行）：`flood_fill` / `find_connected` / `connectivity` / `neighbors` / `partition_connected` / `find_unsupported` / `find_unsupported_around` 七个算法 + `NEIGHBORS_6` 真值。**不反向依赖 `VoxelData`**：实体素判据与全量位置枚举以 `Callable` 传入（`is_solid` / `all_positions`）；热路径（`partition_connected` / `find_unsupported_around`）完全在原生 C++，不经 Callable。`VoxelData` 留 7 个**薄转发**以不破坏公开 API（`VoxelDestructible` 仍按 `VoxelData.partition_connected` 静态调用；`find_connected` / `connectivity` / `neighbors` 全项目零调用但属插件公开 API，不在 P1 删 —— 留给 P4 的 API 收口）。`NEIGHBORS_6` 在 `VoxelData` 降为指向新类真值的别名，不再有第二份。**行数：`VoxelData` 2261 → 2166**（标记数与覆盖行数不变：连通性区块本就无 `# [INF]` 标记）。验证：`validate` 通过；全量测试 **90/90 通过**（1 项需游戏进程按设计跳过），其中 **P0-6 快照哈希逐字节未变**（体积 `1837387656` / 网格 `1739196767`）→ 搬迁行为等价。附带收益：P2-6（连通性下移 C++）从此有唯一落点。 |
| P1-2② | 抽出 `VoxelDamageStore`（`addons/VoxelSupport/Runtime/VoxelDamageStore.gd`，80 行）：伤害账本体 `chunk_key → PackedFloat32Array(CHUNK_VOLUME)` + `buffers` / `write_back` / `get_chunk` / `erase_chunk` / `clear_all` / `is_empty` / `shift` / `clear_at` / `clear_at_bulk`。坐标换算复用 `VoxelChunk.chunk_of` / `origin_of` / `buf_index` / `shift_key_dict`，**零反向依赖**。`VoxelData` 留 6 个公开转发（`get_damage_buffers` / `set_damage_buffers` / `get_damage` / `clear_damage` / `clear_damage_bulk` / `clear_all_damage` —— 外部调用方零改动），6 处内部生命周期点（写时清零 / 空 chunk 回收 / chunk 卸载 / origin shift / 世界清空 / 载荷重建）改为调存储方法，删掉私有的 `_clear_damage_at`。与 P0-2 的 `VoxelDirtyLedger` 同一模式：状态 + 生命周期规则内聚到一处。 |
| P1-2③ | 抽出 `VoxelPayloadCodec`（`addons/VoxelSupport/Runtime/VoxelPayloadCodec.gd`，60 行）：帧格式（`"GZIP"` 魔数 + GZIP + base64）与版本校验的唯一实现；`MAGIC` / `VERSION` 随之下移，`VoxelData.PAYLOAD_MAGIC` / `PAYLOAD_VERSION` 删除。**有意的不对称**：`encode` 只过帧（处理可信内存状态，不写版本号），`decode` 过帧 + 校验（面对磁盘/场景文件的不可信输入，必须校验）—— 这样测试也能用同一个 `encode` 造"版本不符"载荷。`VoxelData` 留 `_encode_payload`（组装内容，VoxelData 特有）/ `_decode_payload`（一行转发）。**顺带消除重复**：`Scripts/Test/test_qvox_import.gd` 原先手工复制了一份帧格式（`_encode_payload` 辅助函数）来构造异常输入，现改用 `VoxelPayloadCodec.encode` 并删掉该重复实现。**未复用 `DEVFramework.SaveTool.gzip_encode`**：帧格式确实同款，但 `VoxelSupport` 对框架零代码依赖（可独立拖入任意项目），为 8 行帧封装反向依赖框架会破坏这条边界 —— 已在类注释写明这是**有意重复**，不是漏看。 |
| P1-2 收口 | 三块合计移出 **295 行**（连通性 155 + 伤害账 80 + 编解码 60，其中 `VoxelData` 净减 148 行：2261 → **2113**）。`VoxelData` 的 `# [INF]` 标记仍为 **52 处**（三块本就无标记，覆盖行数不变）。验证：4 个脚本 `validate` 全通过；全量测试 **90/90 通过**，**P0-6 快照哈希逐字节未变**（体积 `1837387656` / 网格 `1739196767`）。 |

#### P2-1 施工分期（2026-10-08 起）

P2-1 要搬约 **1300 行**视点调度代码（`VoxelRenderer` 79 处 `# [INF]` 标记），
**而这批代码此前零自动化覆盖** —— 唯一相关的冒烟测试只用 `VisibilityMode.FULL`
（其原注释："不依赖相机，全量构建"），等于 LOD 分带 / 视锥剔除 / 流式加载卸载 /
原点漂移四块**从没被任何断言碰过**。所以顺序是：先补网，再动刀；每期独立可验证、随时可停。

| 期 | 动作 | 验收 |
|---|---|---|
| **0. 安全网** ✅ | 新增 `Scripts/Test/test_voxel_infinite_layer.gd`（`needs_game_process`，5 例）：① LOD 分带公式（n=1..4 取值表 + 层平行数组长度一致）② 视锥剔除（锥内保留 / 锥外剔除并登记 `_deferred_chunks`）③ 近处 LOD0 区不参与视锥剔除 ④ 原点漂移（数据 key / mesh key 与节点位置 / 相机补偿**三者同步**）⑤ 流式距离过滤 | 游戏进程 **9/9 通过**（新 5 例 + 既有 smoke 4 例） |
| **1. 几何数学** ✅ | 新增 `VoxelLodGrid`（77 行）：`block_of_chunk` / `block_edge_world` / `block_center` / `block_dist` / `margin` / `preload_extent` / `bands`。**无状态纯静态** —— 这是它能被两侧共享而不把视点信息拖进内核的前提。`VoxelRenderer` 留 7 个同名转发壳 + `_recompute_lod_bands` 委托；`LOD_GRID` 降为指向 `VoxelLodGrid.GRID` 的别名 | `validate` 通过；编辑器 **90/90**、游戏进程 **9/9**；`VoxelRenderer` 2349 → **2333** 行，79 处标记不变 |
| **2. 剔除 + 流式调度** ✅ | 新增 `VoxelInfiniteLayer`（`class_name` + `RefCounted`，持内核单向引用，404 行）：`set_visibility_mode` / `unload_d` / `lod0_data_unload_d` / `is_world_visible` / `is_deferred` / `deferred_is_empty` / `on_mesh_removed` / `shift_keys` / `clear_deferred` / `sync_cam_pos` / `filter_visible_chunks` / `process_deferred_chunks` / `process_streaming`，连同延迟队列 / 强制构建标记 / 扫描 tick / 上次相机位置四个账本一并迁入。内核切除 6 个视点方法 + 6 个视点状态成员，`_process` / `_ready` / `visibility_mode` setter / `remove_chunk_mesh` / `_update_mesh_async` / `_shift_render` / `_clear_lod_meshes` 全部改为委托；另新增 `current_camera` / `has_chunk_mesh` / `lod_level_count` / `lod_outer` 四个只读访问器（收编内核里 4 处散落的相机直取）。`VoxelDestructible` 的 4 处 `is_world_visible` 调用改走 `infinite_layer` | `validate` 全通过；编辑器 **90/90**、游戏进程 **9/9**；`VoxelRenderer` 2333 → **2029** 行（−304），`# [INF]` 标记 79 → **69** 处 |
| **3. 原点漂移** ✅ | `_origin_chunk` / `ORIGIN_SHIFT_THRESHOLD` / `check_origin_shift` 收进无限层（判定"何时平移"+"相机反向补偿"）；**`_shift_render` 未整体迁入**，改名为内核公开 API `shift_render(shift, chunk_size_world)` 由无限层调用（理由见下），`_on_origin_shift` 同时去掉前导下划线成为公开覆盖点 `on_origin_shift`。新增 `origin_chunk()` 访问器（HUD/调试/测试读取，替代直取私有字段） | ① ② ③ ④ ⑤ 保持绿：编辑器 **90/90**、游戏进程 **9/9**、`validate` 全通过；`VoxelRenderer` 2029 → **1992** 行（−37），`# [INF]` 标记 69 → **64** 处 |
| **4. LOD 分带调度 + 异步供需** ✅ | 分带表 `_lod_outer` + 全部调度账本（`_lod_pending_tasks` / `_lod_rebuild` / `_lod_null_retries` / `_lod_block_gen` / `_data_chunk_min/max` / `_cull_check_counter` / `_lod_build_this_frame` / `_lod_submit_this_frame` / `_coarse_task_ids` / `_exiting` / `_lod_mesh_apply_queue` / `_lod_mesh_apply_scheduled`）连同决策 / 构建 / worker 全部方法（`process_lod` / `_process_lod_level` / `_process_chunk_level` / `_chunk_render_level` / `_level_finer_ready` / `_lod_rebuilding` / `_lod_load_priority` / `_build_lod_block` / `_build_lod_data_only` / `_lod_worker_*` / `_lod_mark_null_or_retry` / `_on_lod_data_ready` / `_on_lod_thread_result` / `process_lod_mesh_apply_queue` / `remove_lod_block` / `_clear_block_state`）迁入无限层。**`_lod_meshes` 有意留内核**（网格账本，见执行记录）；`VoxelData` 的粗层数据未动（`has_lod_block` 等按层访问已是内核 API，搬它无收益）。`configure_lod` 成为 4 张调度表 + 内核网格账本长度的**唯一维护点** | ① ④ + 网格内核用例保持绿：`validate` **3/3**；编辑器 **53/53**、游戏进程 **9/9**；`VoxelRenderer` 1992 → **1253** 行（−739），`# [INF]` 标记 64 → **11** 处（余下 11 处全是留在节点的 `@export` 旋钮 + 1 个 `_flush_lod_mesh_apply_queue` 委托壳） |

**边界实测（期 1 动刀前先量过，不靠猜）**：LOD 数学的 50 处使用点里 **49 处在 `# [INF]` 成员内，
只有 1 处在内核** —— `_build_lod_from_arrays`（L1714）需要"该层 block 的世界边长"来摆节点位置。
这条实测就是 §4 接口的形状：**内核只要几何数值，不要视点状态**。因此 `VoxelLodGrid` 定位是
**两侧共享的纯数学模块**，不是无限层的一部分；内核调它不构成"内核 → 无限层"的反向依赖。

**期 2 执行记录（2026-10-08）**：
- **内核接口面（P2-2 的雏形）**：内核对外收敛为 `request_update` / `remove_chunk_mesh` /
  `has_chunk_mesh` / `lod_level_count` / `lod_outer` / `current_camera`
  \+ `data` / `voxel_scale` / `global_position`。无限层**只读**这些，不回写内核状态。
  （`check_origin_shift` 当时还在内核，**期 3 已移出**；期 3 另加 `shift_render` / `on_origin_shift`。）
- **`infinite_layer` 用惰性 getter 而非 `_init` 里建**：实测脚本热重载**不会**对既有节点实例
  重跑 `_init` —— 若在 `_init` 建层，编辑器里已打开的 demo 场景实例会持续报
  `Nonexistent function 'process_deferred_chunks' in base 'Nil'`（实测 23 条/轮，清日志后复现）。
  getter 版本可自愈，且清日志后 30 帧零运行期错误。
- **新增 4 个访问器而非让无限层直取私有成员**：`current_camera()` 同时收编了内核里 4 处
  一模一样的 `get_viewport().get_camera_3d() if is_inside_tree() else null`；`has_chunk_mesh`
  对 `_lod_meshes` 为空加了保护（原代码直取 `_lod_meshes[0]`，无保护）；`lod_outer()` 返回
  分带表引用，**期 4 已随 LOD 调度迁出**（`_lod_outer` 归无限层，`lod_outer()` 改为无限层公开
  方法）。
- **配置仍暂挂内核**：`_stream_load_per_frame` / `_stream_unload_per_frame` 是 `@export_range`
  的检视面板参数，期 4 随组件一起搬；无限层暂时读 `kernel._stream_*`。`_cull_check_counter`
  （LOD 检查降频计数）同理留内核，属期 4。
  ——**期 4 修正**：① `_cull_check_counter` 已随 LOD 调度迁入无限层；② `_stream_*` / `_lod_build_*`
  等 `@export` 旋钮**不再搬**（无限层是 `RefCounted`，挂不了 `@export`），无限层继续读
  `kernel._stream_*` / `kernel._lod_build_per_frame`，见「期 4 执行记录」。
- **一处易漏点**：`is_world_visible` 被 `VoxelDestructible` 以"隐式 self 调用"用了 4 次，
  按名字搜"视点方法"时不会命中（它不以 `_` 开头、也不在 `VoxelRenderer` 里出现），
  靠**运行期错误日志**才发现。搬迁后应把子类调用点一并纳入检索名单。

**期 3 执行记录（2026-10-08）**：

- **对原计划的一处有意偏离：`_shift_render` 没有整体搬进无限层**。原文写的是"`_shift_render` 收进
  无限层"，但动刀前实测它的函数体**没有一个字节的视点逻辑** —— 它只是在平移内核自己的 10+ 个
  渲染层私有账本（`_lod_meshes` 各层节点与位置 / `_chunk_collisions` 键与节点位置与名字 /
  `_mesh_build_queue` / `_collision_rebuild_queue` / `_lod_pending_tasks` / `_lod_rebuild` /
  `_lod_block_gen` / `_lod_null_retries` / `_lod_mesh_apply_queue`）。真按原计划搬，无限层就得
  逐个去摸这些私有成员 —— 那要么加 10+ 个访问器（比一个整体入口更宽的接口），要么直接破坏
  封装。故改为：**决策（何时平移 + 平移多少 + 相机反向补偿）归无限层，机械平移归内核**，
  内核只多开一个 `shift_render(shift, chunk_size_world)`。这与期 1 的 `VoxelLodGrid` 是同一个
  判据 —— **按"是视点逻辑还是机械操作"切，不按"在哪个函数里"切**。
- **`on_origin_shift` 保留在内核并去掉前导下划线**：它是给 `VoxelDestructible` 平移体素坐标
  在途队列的覆盖点（待移除 / 硬化 / 级联 / 掉落体），宿主必须是节点子类，不能搬到 `RefCounted`
  的无限层。去掉下划线是因为它已从"内部钩子"变成**公开覆盖点**（`test_voxel_fix_regressions`
  现在直接调 `r.on_origin_shift(shift)`）。
- **`shift_keys` 的调用位置从内核挪到无限层**：原 `_shift_render` 尾部有一行
  `infinite_layer.shift_keys(shift)`（内核伸手改无限层的账本）。期 3 把它挪到无限层的
  `check_origin_shift` 里 —— 平移内核与平移自己各自收口，内核不再触碰无限层的字典。
- **`origin_chunk()` 访问器**：`streaming_demo` 的 HUD 与安全网测试原先直取 `_target._origin_chunk`
  私有字段，现统一走 `infinite_layer.origin_chunk()`。
- **`_chunk_from_world` 转发壳保留**：它曾被 `check_origin_shift` 使用，移出后内核另有 2 处
  （`_process_lod` 的块映射、LOD 分带）仍在用，故不删；无限层改用 `VoxelWorldUtil.chunk_from_world`
  直调，不反向依赖内核私有辅助函数。
- **热重载窗口再次制造假象（与期 2 同一类）**：改完脚本后立刻用 `eval_code` 探针读编辑器里
  已打开的 demo 场景实例，`origin_chunk()` 一度返回 `Nil`（`typeof` 报 TYPE_NIL），而
  `has_method("shift_render")` 已为 true —— 即内核脚本已换、被惰性 getter 缓存的无限层对象
  还没换。等重载传播后再读即正常（新建实例当场就正常）。**判定顺序：先看新建实例，再看活实例，
  最后才怀疑逻辑**。

**期 4 执行记录（2026-10-08）**：

- **对原计划的一处有意偏离：`_lod_meshes` 留在内核，不搬**。原计划写"`_lod_meshes` 收进无限层"，
  但动刀前实测它有 **11 个使用点**：内核自身 5 处（`remove_chunk_mesh` / `_update_chunk_collision`
  / `has_chunk_mesh` / `shift_render` / `_clear_lod_meshes`）+ 外部 6 处（`demo/test_world_demo`、
  `demo/streaming_demo`、`demo/destruction_demo` 的 HUD 直接读它统计 chunk 数，smoke 测试亦然）。
  搬走它，内核就得反向伸手到无限层取"本节点挂了哪些 mesh" —— 恰好破坏单向依赖。判据与期 3 的
  `_shift_render` 同源：**按"是视点决策还是机械账本"切**。`_lod_meshes` 是"本节点挂了什么"的账本，
  归内核；`_lod_outer` / `_lod_pending_tasks` / `_lod_rebuild` 等是"何时该建、建什么"的调度，
  归无限层。**分带表 `_lod_outer` 与网格账本同长**，故 `configure_lod(count, view_distance)` 是
  两者长度的唯一维护点（一次 `while` 循环里 resize 4 张调度表 + `kernel.set_lod_level_count(n)`）。
- **`@export` 配置旋钮仍留节点，不随逻辑迁出**：无限层是 `RefCounted`，**挂不了 `@export`**
  （Inspector 不显示、无法存进场景）。故 `lod_count` / `view_distance` / `unload_distance` /
  `_lod_build_per_frame` / `_lod_preload_blocks` / `_lod_build_budget_ms` / `_lod_submit_per_frame`
  留内核节点，无限层按需读（`kernel.view_distance` 走公开属性，`kernel._lod_build_per_frame` 等
  仍是私有旋钮 —— 这是**既有约定**，期 2 的 `kernel._stream_load_per_frame` 已如此）。
- **新开 8 个窄访问器而非暴露整表**：`has_lod_mesh` / `lod_mesh` / `lod_mesh_keys` /
  `mark_lod_block_empty` / `mount_lod_mesh` / `clear_lod_mesh` / `is_mesh_build_queued` /
  `lod_materials`，外加 `set_lod_level_count` / `clear_lod_level`。无限层**只通过这些按键接口**
  摸网格账本，拿不到整张 `_lod_meshes`（避免"两个类共同维护一张表"的隐性耦合）。
- **deferred 排期的归属拆成两半**：排期标记 `_lod_mesh_apply_scheduled` 归无限层（与队列
  `_lod_mesh_apply_queue` 同处，决策内聚）；但 `call_deferred` 的**目标必须是内核节点**
  （`RefCounted` 没有节点释放保护，节点 `_exit_tree` 时 deferred 调用会打到野对象）。故无限层只
  置标记、由内核 `_process` 调 `take_lod_mesh_flush_request()` 后 `call_deferred` 自己。
- **迁移动刀时漏掉的 `data`（原内核成员）—— 由 `validate` 抓出**：`_process_lod_level` /
  `_process_chunk_level` / `_level_finer_ready` / `_lod_mark_null_or_retry` 四处在原内核里直接引用
  成员 `data`，迁到无限层后成了**未声明标识符**（`validate` 报 19 处 `Identifier "data" not
  declared`）。修法是各函数首行补 `var data := kernel.data`（与期 2 迁入的
  `filter_visible_chunks` / `process_streaming` 写法一致）。**教训：搬函数体时，"隐式 self 成员"
  是静默断点**（期 3 的 `is_world_visible` 也是同一类）。
- **内核 ↔ 无限层互持引用构成类型环，`:=` 推导会失败**：`VoxelRenderer._apply_built_chunk` 里
  `var lod_outer := infinite_layer.lod_outer()` 报 `Cannot infer the type`（`VoxelInfiniteLayer`
  与 `VoxelRenderer` 互相 `class_name` 引用，返回类型推导不出）。修法：**显式标注**
  `var lod_outer: Array[float] = ...`。这是该类型环下唯一稳定的写法。
- **安全网测试的 3 处私有字段直取改到新归属**：`test_voxel_infinite_layer` 的 LOD 分带用例原读
  `r._lod_outer` / `r._lod_pending_tasks` / `r._lod_rebuild`，现改读 `r.infinite_layer._lod_*`
  （该文件本就直读 `infinite_layer._deferred_chunks`，风格一致）；内核 `r._lod_meshes` 的断言不动。
  demo 侧无任何已迁字段的访问点（HUD 只读 `_lod_meshes`，它没搬）。

### P2 —— 边界重划：有限内核 + 可选的无限层与表现层（**建模软件的前提**）

| # | 动作 | 理由 |
|---|---|---|
| P2-1 ✅ | 把 LOD 分带、流式加载/卸载、视锥剔除、原点漂移、异步块供需**抽离**为独立的"无限层"（单独插件/组件），依赖单向：无限层 → 内核 | 这是耦合与冲突的主要来源。内核不需要知道相机、LOD、流式、原点的存在。**见 §4**。**已并入 P1-1**：`VoxelRenderer` 不再先做"插件内拆类"，直接按本边界一次抽离（见 §3 决议）。**施工分期见 §3「P2-1 施工分期」**（期 0 安全网 ✅ / 期 1 几何数学 ✅ / 期 2 剔除+流式 ✅ / 期 3 原点漂移 ✅ / 期 4 LOD 调度 ✅）。**期 4 收尾时一并处置了 `VoxelData` 的 52 处 `# [INF]` 标记：逐条判定为「留内核（数据层）」，标记删除**（见 §3 P0-7 归宿）。**已决（2026-10-08）**：无限层与表现层的落点是**留在 `addons/VoxelSupport/` 内**（同插件、同仓库）—— 见 §6 待确认。"抽离"指抽离出**内核的视点职责**，不是拆成第二个插件。 |
| P2-2 ✅ | 内核 API 保持**按 chunk 索引 + 脏区域事件**的形态，供无限层套在外层 | 这是"抽离"能成立的前提；若内核 API 是"整块重算"式的，无限层挂不上去。**已落地**：① `VoxelRenderer.gd` 顶部新增权威的"内核对外契约（P2-2）"块，把公开面固化为 A 脏区域事件 / B 按 chunk 写 / C 按 chunk 查 / D 只读环境 / E 生命周期覆盖点 / F 兼容别名（P4 收口），并写明"不在契约内"（相机、LOD 分带、流式、剔除、原点漂移、异步供需全在无限层）与**双向依赖边界**（无限层 → 内核走公开面 + 5 个 `@export` 私有旋钮；内核 → 无限层只走其公开方法，不碰私有字段）。② 新增契约锁定测试 `Scripts/Test/test_voxel_kernel_contract.gd`：公开方法清单与契约表一一对应（多一个少一个都失败，`get_script_method_list()` 逐条比对），并断言脏区域粒度——内部点编辑恰好 1 个脏 chunk、chunk 角点恰好 4 个（自身 + 3 个负向邻块），**永不**退化为"全部 chunk"（"按 chunk 索引"的可观测反证）。核验 `request_update()` 并非"整块重算"，只是"下一帧重建"唤醒位，粒度始终由 `VoxelData` 脏账本（`get_dirty_chunks()`）决定。3/3 通过。 |
| P2-3 ✅ | 把粒子碎片 / 掉落物理 / 健康度 / 级联崩塌抽离为独立的"表现层"组件 | 几何内核已在 C++，但**表现逻辑与编辑逻辑在同一函数里交织**（`_process` R1672 一条链里既有级联也有 mesh 组装）。**已落地（抽出真·表现层双子系统，分离目标达成）**：新增 `addons/VoxelSupport/Runtime/VoxelDestructionPresenter.gd`（`class_name` + `Node3D`，由宿主惰性挂为 identity 变换的子节点 → `global_position` 即宿主世界位置）。抽出：① **碎片粒子**（GPU 粒子池 / 淡出渐变 / 网格缓存；`ensure_debris_root` / `spawn_debris_with_materials` / `spawn_chunk_break_debris` / `spawn_chunk_break_at_body`）；② **掉落物理**（`RigidBody3D` 对象池 + 代次防串号、在途 mesh worker 任务、待生成/待组装分帧队列、超时与数量上限清理、落地冻结、origin shift 队列平移、退出前 join）。宿主只保留 `@export` 旋钮（唯一真值），每帧经 `configure(...)` 单向推给表现层；表现层**只读**宿主公开面（`host.data` / `host.voxel_scale` / `host.infinite_layer` / `host.diag_enabled` / 新增 `host.surface_materials()`），**不碰宿主私有成员**。为让表现层取到与渲染**同一份** Material 对象，内核 `VoxelRenderer` 新增公开查询 `surface_materials()`（走唯一材质缓存 `_materials.surfaces()`），契约表与 `test_voxel_kernel_contract` 方法清单同步登记；origin shift 的位置列表平移下沉为 `VoxelChunk.shift_positions()`（与既有 `shift_key_dict` 并列，消除"宿主与表现层各写一份"）。**健康度 / 级联崩塌刻意留在宿主**：二者都要写 `VoxelData`（移除体素）并发射宿主信号（`voxels_about_to_collapse` / `voxel_damaged`），按 P2-2/P2-4 冻结的内核边界属**编辑侧**而非表现侧；塞进只读宿主的表现层会破坏"表现层不写数据"的契约。**分离已达成**：级联/破坏管道只调 `_presenter.spawn_falling_chunks_from_groups(...)`，`_process` 帧尾只调 `_presenter.process_pending_falling_groups/process_pending_mesh_results/freeze_sleeping_chunks()`。验证：**编辑器 100/100 + 游戏进程 9/9 全通过**；另在游戏内直驱探针确认掉落物理端到端（100 体素组 → `spawned=1`、`_falling_chunk_root` 确为表现层子节点、body 入池 `pool_total=1`、mesh 数帧内组装完 `pending_mesh=0`）。 |
| P2-4 ✅ | 抽出 `VoxelEditKernel`（无场景节点、无 `_process`、可无头调用） | 建模软件的"画笔"直接调它，不需要一个 `VoxelDestructible` 节点。**已落地**：新增 `addons/VoxelSupport/Runtime/VoxelEditKernel.gd`（`RefCounted`）承载**纯编辑数学**——`apply_damage`（伤害结算：范围 → 材质 → 硬度比较 → 累伤 / 判移除，含伤害缓冲回写与硬化反馈产出）、`propagate_stress`（裂纹扩散）、`find_unstable`（悬空检测）、`hardness_table` / `strength_table`（材质查表，索引 = 材质ID，表长下界 `MAX_MATERIAL_ID` 防原生越界读）。**无 Node / 无场景树 / 无物理 / 无粒子 / 无信号**，因此服务端与建模工具只需 `VoxelEditKernel.new()` + 一个 `VoxelData` 即可算完破坏，**不需要挂 `VoxelDestructible`**。三条边界写进类头文档：① **配置旋钮不在内核里**（`RefCounted` 挂不了 `@export`，`damage_per_voxel` / `use_voxel_health` / 应力三参数一律按参数传入，旋钮留在节点）；② **表现层职责不在内核里**（粒子碎片、掉落刚体、级联分帧调度、信号发射、帧尾合并、诊断输出全留节点）；③ **内核只产出"发生了什么"**——`apply_damage` 返回 `{removed, hardened, hardened_dirty}` 但**不自行移除体素**，何时落地由调用方决定。**无状态**：逐体素累伤账归 `VoxelData`（经 `get_damage_buffers()` / `set_damage_buffers()` 读写），故内核实例可长期复用、可跨多个 `VoxelData`。`VoxelDestructible` 改为持有 `_edit := VoxelEditKernel.new()` 并全部委托（删除本地 `_hardness_table` / `_build_strength_table`；`_apply_damage_native` 只保留"硬化反馈并入帧尾缓冲 + 置脏"与 `last_damage_count`；`_find_unstable_voxels` 只保留诊断输出）——**数学只有一份**，不存在第二套 GDScript 实现。验证：`test_voxel_kernel_contract.gd` 扩为 7 项（新增：内核非 Node 且不实现任何帧/生命周期回调、公开方法清单 = 契约、无头伤害结算、无头应力 + 失稳、节点与内核直调给出**同一批**被摧毁体素），**编辑器 98/98 + 游戏进程 9/9 全通过**（含 `test_voxel_runtime_smoke` 的破坏 / 碎片 / 崩塌端到端）。 |
| P2-5 ✅ | 热路径下移：`_shift_index_array`、`generate_arrays_from_chunks`、`_translate_native_verts` 进 C++ | 每 chunk 全量 `PackedInt32Array` 拷贝，是网格化的固定开销。**已落地**：新增原生 `generate_arrays_from_chunks_native`（逐 chunk `build_halo_from_buffers` + `generate_chunk_dense` + 复用 `append_arrays_native` 合并/索引偏移，全 C++），生产路径（`start_generate_mesh_from_chunks` / `start_generate_mesh_from_qvox`）改调它；`generate_spheres_native` 增 `offset` 参数（体素单位、内部乘 scale），删除 `_translate_native_verts` 事后遍历。GDScript 版 `generate_arrays_from_chunks` + `_shift_index_array` 保留为**测试 oracle**（`test_voxel_snapshot_baseline` 逐位对照，两处需同步改）。已核验：块级网格与 oracle 逐字节一致（三角 5790 命中基线）；球体路径与原"事后平移"仅差 ≤3e-7 相对误差（浮点结合律，非行为变更）。`NativeLoader.REQUIRED_METHODS` 同步新增该方法。 |
| P2-6 ✅ | `flood_fill` / `partition_connected` / `find_unsupported` 进 C++ 或改原生实现（**落点已就位：`VoxelConnectivity`，见 §3 P1-2①**） | 现在每节点 `in result` 的 GDScript BFS，破坏一堵墙就卡帧。**已落地**：新增原生 `flood_fill_positions(seeds, allowed)`——集合受限（restrict 非空）分支全 C++（`std::unordered_set<uint64_t>` + 64 位 `grid_vkey`，负坐标安全）；`VoxelConnectivity.flood_fill` 据此分流：restrict 非空 → 原生，restrict 为空 → 保留 GDScript（判据是 Callable，`has_voxel` 可能触发磁盘 chunk 流式载入，无法脱离宿主语言）。`partition_connected` / `find_unsupported`（全量）此前已在原生，其**子集路径**（`find_unsupported(voxels_set)`）现也自动走原生泛洪。`NativeLoader.REQUIRED_METHODS` 补上此前漏列的 `find_unsupported_positions` + 新增 `flood_fill_positions`。验证：新增交叉断言（`test_flood_fill_restrict_branch_matches_predicate_oracle`）——restrict = 实体素全集时两分支结果必须逐体素一致，并覆盖负坐标、种子越界、子集悬空检测；全量 **54/54 通过**。 |
| P2-7 ✅ | 编辑路径改为**脏区域增量重建**（抽走 LOD 之后仍必须保留） | 见 §4，这是"有限内核"唯一真正的性能风险。**已落地（机制在位 + 本次补上锁定断言）**：§4.2 的三条里，第 1、2 条已由 P2-1 的脏账本与计数账本实现，本次逐条核实并写成断言——① **增量网格重建**：编辑只写 `VoxelDirtyLedger` 的 chunk 级 MESH 脏位，渲染器每帧 `VoxelData.get_dirty_chunks()` **take 一次**重建，粒度是脏 chunk 而非全量（内部点恰好 1 个、chunk 角点恰好 4 个，见 P2-2 断言）；② **只改变化的块 + 计数增量维护**：`_chunk_voxel_counts` 是体素数的**唯一权威**，`get_voxel_count()` 由它派生（不重扫体积），`_maybe_erase_empty_chunk` 用计数归零 O(1) 擦除，**替代了原先的 4096 全量扫描**；`is_empty()` 与"总数为 0"由不变式保证等价且 O(1)。新增断言（`test_voxel_kernel_contract.gd` P2-7 段）：单点编辑只脏 1 chunk、脏账**读取即消费**（第二次读取必空，否则会重复重建）、增量计数与**全量重数恒等**（证明不存在第二份可漂移的存储）、变空的 chunk 被擦除后**仍留 mesh 脏标记**（否则渲染器不会重建来清掉旧网格）。**未做成增量的两处及其判定**：`get_aabb()` 走原生 `collect_bounds` 全扫、连通性走原生 `find_unsupported` 按需计算——两者都**不在每次落笔的同步路径上**（前者按需调用、后者本就只在破坏后触发），且做成增量会引入"只扩不缩"的过近似语义（边界/连通性变宽松会静默改变消费者行为）。故按"够用即可"保留按需计算，§4.2 第 3 条（修改器链逐修改器缓存）属 §5 `steps` 模型，不在此项。全量 **9/9 通过**。 |

### P3 —— 统一生成流水线（把三个硬编码步骤变成一条链）

| # | 动作 | 理由 |
|---|---|---|
| P3-1 ✅ | 定义修改器的两类契约：**生产者**（`build(grid_size) -> PackedInt32Array`）与**改写者**（`apply(volume, grid_size, seed)`） | 现有 `PcgDetail.apply` 已是改写者契约，直接升华；`PcgModel.build` 已是生产者契约。**不需要改任何已有算子**。**已落地**：契约由 `QVoxModifier` 的子类表达（`QVoxSdfModifier` / `QVoxModelModifier` 是生产者核，`QVoxVolumeModifier` 是改写者核），`is_source()` 判据 = 白名单（`KIND_SDF` / `KIND_MODEL`）；`QVoxEvalEngine` 按域分派 `op.build(gs)` / `op.apply(...)`，**一行已有算子都没改**。 |
| P3-2 ✅ | 消除 `PcgSdfGenerator` 内联表面层，改为"先生成完整体积，再进链" | 让 (a)(b) 两条路合并成一条。这是本计划最重要的**架构**收益。**已落地**：`rasterize_field()` 已纯几何化（内联表面层删除），表面效果改由链上的通用算子承担；`demo/pcg_world_demo.gd` 的岛体即为迁移样板 `SDF → 风化(PcgWeather, up_only) → 苔藓(PcgSurfaceTint, up_only) → 岩石色阶(1→[10,11,12]) → 苔原色阶(2→[13,14,15])`，链种子 `SURFACE_SEED`。游戏内实测：128³×48 网格出 328,230 实心格、材质分布含全部 5 段产物。 |
| P3-3 ✅ | 生成层也纳入链（生产者步骤可多个，按顺序覆盖/合成） | 让"地形 + 洞穴 + 建筑"可组合，而不是只有一个 `field` 变量。**已落地**：`QVoxModelModifier` 让生产者成为链条目，`QVoxEvalEngine` 按 `combine`（REPLACE / UNION / SUBTRACT / INTERSECT / SMOOTH_UNION）依次合成体积；体积深度不足时与手绘体素同一条 `_combine_volume` 路径。新增适配器 `QVoxObjectGenerator`（`VoxelGenerator` 子类）把链产出**逐 32³ chunk** 切片喂渲染管线，并支持 LOD 块。链的入口收口为 `PcgModelGenerator._has_source()` / `_build_volume()` 两个可覆写钩子，"空体积"也照常提交（不再有"两条生成路径"）。 |
| P3-4 ✅ | `PcgWfcOverlap` / `PcgScatter` 显式标为"链外节点"（需要全局信息或非体积语义） | 审计已确认它们不适合线性链，强行塞入会引入错误语义。**已落地**：新增能力查询 `PcgModel.chainable()` / `PcgDetail.chainable()`（默认 `true`，编辑器据此把链外算子从"可加入链"候选里灰掉）；`PcgWfcOverlap.chainable() = false`（要全局迭代收敛 + 内部可变学习缓存）；`PcgScatter` 连链条目基类都不是（`extends RefCounted`）——它的输入输出是"世界坐标 + 变换"，属链**之后**的摆放阶段，故对它调 `chainable()` 是 `Nonexistent function`，判据是"它根本不是链上类型"。 |
| P3-5 ✅ | 手绘基础体素（`blocks`）作为链的**输入/种子**接入（手绘是链的输入，**不是**链上的一环，见 `QVoxelier/DESIGN.md` §5.2） | 让"手绘 + 程序化"可组合 —— 这正是建模软件需要的。**已落地**：`obj.to_volume()` 作为链的种子，**链首那条的 `combine` 决定"链产出如何与手绘相合"**（REPLACE 作废手绘 / UNION 并 / SUBTRACT 挖洞 / INTERSECT 当裁刀 / SMOOTH_UNION 退化并，见 `QVoxEvalEngine` 文件头）；空数组语义 = "还没有既有体积"，但它**不等于"链首没有左操作数"**：链首那条的 `combine` 要作用在**手绘体素**上，故引擎合并前显式取一次 `obj.to_volume()` 当左操作数（`QVoxEvalEngine._left_operand`）—— 否则 UNION 会退化成 REPLACE（手绘石料凭空消失）、SUBTRACT 会退化成"挖不动"，恰恰是"手绘 + 程序化混着用"的两种用法（**这是本次补上的 bug**：原先只有场域链首走了这条规则，体素域链首漏了，见 P3-6 的回归测试）。**链首直接是体素算子且手绘为空**时补一块全零整块（`PcgModel.empty_volume`）—— 否则所有 `PcgDetail` 的 `for x in grid_size.x` 遍历一律按下标越界。 |
| P3-6 ✅ | 修改器链**逐步骤判脏**：改链尾一条 → 只从该条起重算，前面的结果复用（§5.2 末条 / §4.2 第 3 条） | 只缓存"最终体积"时，复用只发生在"整链一字未改"的场合；改链尾一条仍要从前到后重跑整条链，而链首往往恰好是最贵的一条（程序化生成整块体积）。**已落地**：`QVoxEvalResult.states` 存**逐步骤检查点**（`states[i]` = 跑完前 i 条，`states[0]` = 链的输入；FIELD 段的检查点只持一棵 Sdf 树、零体积开销，VOXEL 段各持一份体积副本，32³ = 128 KB / 256³ = 67 MB 已在文档里记账），签名拆成 `inputs_key`（链之前的输入）+ `step_signatures`（逐条），`_resume_index` 取**最长公共前缀**当起点续跑（链首直接是场算子时连折叠都不重跑）。三条安全约束都钉了断言：① 检查点体积必须 `duplicate()` —— `PackedInt32Array` 赋值是**共享缓冲**，`PcgDetail.apply` 是就地改写型算子，不复制就会把检查点改成"后来的状态"；② epoch 不同、或链之前的输入（手绘版本号 / 网格 / 种子 / 块大小）变了 → 全部检查点作废；③ 取消求值 → 清空轨迹与逐条签名，截断的结果不得冒充完整结果（否则下一次会被当缓存命中）。回归测试：`test_step_dirty_only_recomputes_the_tail`（数 `build()` 次数证明链首**没**被重跑，并比对"复用来的前缀"与"全量重算的前缀"逐格一致）、`test_cancelled_result_is_never_reused`、`test_voxel_source_head_also_meets_hand_drawn`（P3-5 那条 bug 的钉子）。 |

> 新增契约测试 `Scripts/Test/test_qvox_eval_engine.gd`（14 项，钉死五条硬承诺：手绘为链输入（含**体素域链首**）/ 域单向降级 + 链校验 / 无状态纯函数 + 输入签名复用 / **逐步骤判脏**（P3-6）/ 链产出逐 chunk 与整块体积逐格一致）。
> **验证：编辑器 133/133 全通过**（另 2 项需游戏进程）；P3 落地时曾在游戏内直读 `Base_Island` 的 `QVoxObjectGenerator` 核对体积与材质分布。

> P3 的产物就是"核心能力 API"：**一条有序、可插拔、可旁通、可无头求值的修改器链**。
> 建模软件只是给它画一个面板，并把用户动作翻译成对链的操作。

### P4 —— 格式与 API 面收口

| # | 动作 |
|---|---|
| P4-1 ✅ | QVox 已是原生格式：支持多模型（`VOX0`，`model_id` uint16 → 最多 65536）、场景图（`NODE`：节点树 / 变换 / 图层名 / 动画）、文件级调色板（`MATE`）、稀疏分块（空块零字节）、4 种块内编解码。**已核验并顺手贯彻"长度前置"到 VOX0 内部**：`VOX0` 模型头 6 → 10 字节，新增 `uint32 payload_length`（`QVoxSpec` 记 v2），使"模型负载的精确边界"成为头内事实，读取端不必再靠"顶层块尾填充 0–3 字节"模糊判断解析终点。 |
| P4-2 ✅ | **未知块会被跳过且重写时原样保留**（`QVoxFile.gd:368-373` 读侧留字节 + `:1142-1145` 全量写侧回写 + `:1281-1282` 增量写侧搬运）→ 加工程数据块对旧解析器天然安全；块类型是 4×ASCII，空间充足。**未知 JSON 键同理**（`HEAD` / `NODE` 未解释的键在重写时原样保留）。`HEAD.require` 是 glTF `extensionsRequired` 式的**硬门**：列在其中的块类型读者必须理解，否则整文件拒绝——与"未知块安全跳过"分工明确（见 `_check_capabilities`）。 |
| P4-3 ✅ | 为工程数据补**字段**（**不新增块类型**，见 §5）：逐对象修改器链 → `NODE.nodes[].steps`（`QVoxModifierSerializer` 序列化，`QVoxObject.modifiers` 承载，撤销走 `QVoxPropertyCommand`）、图层属性 → `NODE.layers`（对象数组 `{name, visible, locked}` + `nodes[].layer` 索引）、相机书签 → `NODE.cameras`（`{name, projection, transform}`，projection 白名单 `persp`/`ortho`）、世界级 `voxel_size` → `HEAD.world`（`QVoxWorld.voxel_size`）。只动 GDScript（`QVoxSpec` 常量、`QVoxFile` parse/serialize/validate、`QVoxWorld`），**未动 C++**。 |
| P4-4 ✅ | 把"能力 API"标注稳定等级（公开 / 实验 / 内部），并让内部协议（`get_chunk_buffers`、`snapshot_*`、`accept_chunk_buffer` 等）不再对内核外可见。**已落地**：① `VoxelData.gd` 顶部新增权威的"API 稳定等级（P4-4）"块，把 **87 个公开方法**逐条钉进【公开】47 /【实验】40 两级；② 11 个内部协议降为 `_` 前缀（`_chunk_buffers_view` / `_lod_buffers_view` / `_damage_buffers_view` / `_set_damage_buffers` / `_accept_chunk_buffer` / `_chunk_halo` / `_snapshot_chunks_halo` / `_snapshot_lod_block_chunks` / `_snapshot_lod_block_chunks_readonly` / `_snapshot_lod_block_data` / `_can_mesh_lod_block_standalone`），旧公开名一律不得复活；③ 为内核外补两个**封装后的公开入口**，把"绕过封装"的两条主路彻底堵死——`patch_lod_block(level, bk)`（把"取源缓冲 → 重算脏大格 → 写回"收进数据层，无限层不再触碰 `get_chunk_buffers` / `get_lod_buffers` 整表）与 `apply_ready_results(max_count)`（poll + accept 一步到位，无限层 / bench 不再自行拼半截异步协议）。④ 契约锁定测试 `test_voxel_kernel_contract.gd` 新增 `VOXEL_DATA_PUBLIC_API` / `VOXEL_DATA_EXPERIMENTAL_API` / `VOXEL_DATA_INTERNAL_PROTOCOLS` 三表与两条用例：**数据层不带 `_` 的公开方法 = 公开 ∪ 实验**（多一个少一个都失败），且 11 个内部协议只以 `_` 前缀存在、旧公开名不得出现。 |

> **验证：编辑器 130/130 + 游戏进程 9/9 全通过**（编辑器侧 2 项、游戏侧 13 项按设计互跳）；
> 契约测试 `test_voxel_kernel_contract` 单跑 **11/11**（P2-2 的 3 条 + P4-4 的 2 条 + 其余内核契约断言），
> 即"公开面被钉死"这件事本身也有回归保护。
>
> **文档同步**：`docs/QVOX_FORMAT.md` §3.1 补 `HEAD.world`（世界名 / `voxel_size`），
> §7 补 `layers` / `nodes[].layer` / `cameras` 的字段、隐含缺省层规则与宽容度，
> 并写明"格式层不解释 `steps`，只原样回写"——文档与实现之间不再有未记录的字段。
>
> P4 的产物是"**对外可承诺的面**"：格式层只做结构切分（未知块 / 未知键原样保留），
> 数据层把公开面逐条钉死、把内部协议收进 `_` 前缀。于是"改动什么才算破坏兼容"
> 成为一份**可枚举**的清单，而不是靠感觉。

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
- `shift_render`（原 `_shift_render`）对 10+ 个字典逐个重建（R966-1020）：**期 3 判定它留在内核**
  （见 §3 期 3 执行记录）—— 它是 origin shift 的**一次性**开销（相机跨越 256 chunk 才触发），
  不在每帧路径上，所以"随无限层移走"既不成立也不必要；真正的优化落点是 P2-7 的脏区域增量重建
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

## 5. QVox 世界结构（已并入 `qvox: 2`，见 §5.3）

QVox 已经把"结构"与"数据"分开，这正是它适合当工程格式的原因：

| 块 | 现在承载 | 世界结构需要它承载什么 |
|---|---|---|
| `HEAD` (JSON) | `qvox` / `channels` / `up_axis` / `block_size` / `bounds` / `require` | 加世界级设置（名称、`voxel_size`、作者…） → **已落地为 `HEAD.world`** |
| `MATE` | 文件级调色板（≤1 个，12 字节/条：rgba + metal/rough/hardness/mass + 自发光） | 不变（材质名作为可选追加字段） |
| `VOX0` | 每 `model_id` 一份稀疏分块体素（4 种块内编解码） | = **对象的基础体素**（手工编辑结果）**✅ 已落地** |
| `NODE` (JSON) | `nodes` 树 / `layers`（仅名字表）/ `animations` | = **世界结构**：对象、层级、图层属性、**修改器链**、相机书签 → **✅ 全部已落地** |
| `CACH` | 派生数据（LOD 等，按 kind 区分，可删） | 加 `kind="EVAL"`（修改器链求值缓存）、缩略图 —— 仍是**设计保留位**：现有唯一写入方是 `QVoxStream` 的 `kind="LODS"` |

**不需要新增块类型**：`NODE` 与 `HEAD` 本来就是 JSON，扩展它们是零机械成本、零 C++ 改动。
**这一判断已被实践证实**：P4-3 的四个字段（`HEAD.world` / `layers` / `nodes[].layer` / `cameras`）
落地时**一行 C++ 都没动**。
（这正是"未知块跳过 + 重写保留"之外的另一个好消息：工程数据基本不需要新块。）

### 5.1 结构草案

```json
// HEAD
{ "qvox": 2,
  "channels": [ { "name": "material", "bpp": 16 } ],
  "up_axis": "y", "block_size": 32,
  "bounds": { "min": [0,0,0], "max": [256,256,256] },
  "world": { "name": "chair", "voxel_size": 0.1 } }
```

```json
// NODE —— 世界结构块（世界级设置不放这里，见上：它属 HEAD）
{ "layers": [ { "name": "default", "visible": true,  "locked": false },
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

与原结构的差异只有四处（**均已落地，见 P4-3**）：

1. `HEAD` 加 `world`（世界级设置，含 `name` / `voxel_size`）。**放在 `HEAD` 而不是 `NODE`**：
   它是**标量级**的工程参数，而 `NODE` 描述的是**场景图**（可增删的对象、图层、相机）；
   "一个世界叫什么名字"与"场景里有几个物体"是两件事，混在一处会让只想读场景图的读者
   先穿过一层世界设置。
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

**已按事实收敛为 `qvox: 2`**（`QVoxSpec.VERSION`），本计划原先写的 `qvox: 3` 不成立——
两处结构改动（"长度前置"贯彻到 `VOX0` 内部，即模型头的 `payload_length`；以及本节的世界结构字段）
**一并落在 v2**。理由：v1 与 v2 之间**从未有文件落盘**，所以"不兼容改版"这件事本身是零成本的
——既然没有旧文件要与新文件区分，就没有必要为纯理论上的"上一版"占掉一个版本号。
读者遇到更高版本拒绝（宁可不解，不可误读）；v1 **不提供兼容读取路径**
（格式尚在设计阶段，无外部使用，用户已确认不需要兼容）。
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
| `VsCommand` | `QVoxCommand`（+ `QVoxUndoStack` / `QVoxVoxelEditCommand`） | 已落地，但位于 **`QVoxelier/Command/`**（应用层，`extends GameCommand`/`CommandHistory`，见 §6.1） |
| `VsRasterizer` | （无） | 已**折叠**进 `PcgSdfGenerator.rasterize_field()`，不再单独存在 |
| 文档级 `voxel_size` | 世界级 `voxel_size` | 存在 `HEAD.world` |
| 文档调色板 | 世界调色板 | 存在 `MATE`（单块，文件级） |

**已决议并已执行**：

1. 软件名 `QVoxelier` **已完成**（`VoxelStudio/` → `QVoxelier/`，见下第 4 条）。
   插件内核的**物理改名不做**（原先写着"如 `VoxelCore`"，那只是个提议名）：`addons/VoxelSupport/`
   这个目录名已经烙进**原生构建**，不是纯路径——`Native/voxelnative.gdextension`（6 处库路径）、
   `gdextension/CMakeLists.txt`（5 处）、`gdextension/src/voxel_native.cpp`、`project.godot`（插件启用项），
   外加 `plugin.gd` 的 4 条 `preload` 与 5 个 demo 场景的 `ext_resource`，共 21 个文件。
   为一次纯审美的改名去动 C++ 构建系统，收益为零而风险不为零（`preload` 路径与 `.gdextension`
   库路径都会当场失效）——故**决定保持 `VoxelSupport`**。
   **2026-10-08 的往返（记在案）**：本条先记为"不改名"；用户随后要求"该做也得做，C++ 也无所谓"，
   于是照做 —— `git mv addons/VoxelSupport addons/VoxelCore` 被**运行中的编辑器**当场拒绝
   （`fatal: renaming 'addons/VoxelSupport' failed: Permission denied`）。实测排除了"DLL 被占用"的猜测：
   单独改 `Native/*.dll` 的文件名**可以**通过，卡点是**目录句柄**本身，即必须先关编辑器。
   用户随即改判"`VoxelSupport` 挺好，`VoxelCore` 才奇怪" → **维持原名，工作区零改动**
   （`addons/VoxelCore` 不存在、代码内零处 `VoxelCore`、`git status` 无改名痕迹）。
   结论：**提议名不该成为施工理由**；目录一旦烙进原生构建，改名就是"施工"而非"整理"。`plugin.cfg` 的 `description` 已同步更新为
   如实描述三层能力（原生 `.qvox` 格式 / 稀疏分块运行时与 LOD 流式 / 破坏物理，另含 `.vox` 导入），
   不再只有"MagicaVoxel importer"一句。
2. 分期按 P0 → P1 → P2 → P3 → P4 推进。
3. 世界结构（对象模型 + 修改器链）**落在插件内核内**（`addons/VoxelSupport/Modifier/`），并
   **原生进入 QVox**（§5）；QVoxelier 只做显示与操作翻译。**撤销命令例外**：它位于
   `QVoxelier/Command/`（见 §6.1 第 4 条）。
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
| 4 | `QVoxCommand` 放在插件内 → 一旦复用框架 `GameCommand` 就会逼出插件交叉引用 | `QVoxCommand` / `QVoxUndoStack` / `QVoxVoxelEditCommand` 移入 **`QVoxelier/Command/`**（`extends GameCommand` / `CommandHistory`）。两插件保持**互不引用** |

**已落地**：`QVoxEvalEngine`（求值引擎，见 P3）与 `QVoxPropertyCommand` / `QVoxMacroCommand`
（`QVoxelier/DESIGN.md` §6.1/§6.2）均已实现，不再停留在设计：

- `QVoxEvalEngine` 见 P3 那节；契约测试 `Scripts/Test/test_qvox_eval_engine.gd`。
- `QVoxPropertyCommand`（`QVoxelier/Command/`）：一次属性赋值的 O(1) 撤销，**顺带覆盖链的增删重排** ——
  `modifiers` 本来就是对象上的一个属性，加/删/排都是它的前后两份数组，因此不需要第二个命令类。
  它同时负责给宿主对象补发 `content_changed`（`Resource` 参数不会自动发信号）。
- `QVoxMacroCommand` + `QVoxUndoStack.begin_macro()` / `end_macro()`：多步折叠成一条撤销单位，
  支持嵌套、空宏不入栈。契约测试 `Scripts/Test/test_qvox_commands.gd`。

**验证（2026-10-08，P4 收尾时复跑）**：编辑器 **130/130** + 游戏进程 **9/9** 全通过。

**待确认**：**两项均已收口（2026-10-08）**。

- ~~无限层与表现层抽离后放在哪里：同仓库独立插件，还是独立仓库~~ —— **已决：都留在 `addons/VoxelSupport/` 内**
  （同插件、同仓库）。这里的"抽离"指**抽离出内核的视点相关职责**（P2-1 ✅ 已成独立组件
  `VoxelInfiniteLayer` / `VoxelDestructionPresenter`），**不是**拆成第二个插件或第二个仓库：
  插件本身就是"有限内核 + 可选的无限层 / 表现层"一个整体，装上即用；拆仓库只会把 `.gdextension`
  与 `project.godot` 的启用项切成两份，而换不到边界收益（边界已由 P2-2 的内核契约测试钉死）。
- ~~插件内核改名的具体名字（`VoxelCore` 只是建议）~~ —— **已决：不改名**，往返经过与理由见 §6 第 1 条。

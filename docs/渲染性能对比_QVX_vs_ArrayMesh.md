# VoxelRenderer ⇄ 导入 ArrayMesh 渲染性能实测

> 2026-11-18 · Godot 4.7.2-stable (steam) · Intel Core Ultra 5 125H + Intel Arc(TM) iGPU · 1920×1080 · vsync 关 · max_fps = 0 · 窗口置顶
> 基准场景 [`demo/voxel_render_bench.tscn`](../demo/voxel_render_bench.tscn)（脚本 [`demo/voxel_render_bench.gd`](../demo/voxel_render_bench.gd)）
> 原始数据由基准场景自动写到 `user://voxel_render_bench_results.json`（每次跑覆盖）

## 0. 结论（重构前 vs 重构后）

### 0.1 重构后的现状

QVX 现在有两条绘制路径（`VoxelRenderer.DrawMode`），**静态模型已经与导入 ArrayMesh 完全持平**：

| 负载 | 导入 ArrayMesh | `DrawMode.STATIC` | `DrawMode.DYNAMIC`（per-chunk） |
|---|---|---|---|
| deer ×100 | 4 draw / 6.99 ms | **4 draw / 6.61 ms** | 400 draw（重构前形态） |
| deer ×1000 | 11 draw / 2.31 ms | **11 draw / 2.15 ms** | 4010 draw / 10.67 ms |
| cars ×240 | 8 draw / 2.21 ms | **7 draw / 1.80 ms** | 5046 draw / 12.17 ms |
| teapot1 ×16 | 7 draw / 1.58 ms | **7 draw / 1.61 ms** | 2534 draw / 6.68 ms |
| teapot1 ×16 + 阴影 | 16 draw / 3.00 ms | **16 draw / 3.10 ms** | 10134 draw / 10.48 ms |

**`STATIC` 的 draw call 与帧时间都与导入 mesh 逐档相同**（deer ×1000 甚至更快）。
`DYNAMIC` 保留每 chunk 一个绘制单元（可编辑性），差距 3~5 倍 —— 这是刻意的取舍，不是缺陷。

### 0.2 下面的数据说明了什么

本文下面的全部测量是在**重构前**做的，用来回答一个具体问题：
**"QVX 比导入 mesh 慢，到底是体素几何更贵，还是渲染组织方式不同？"**

答案：**几何内核完全相同（逐三角形一致），差距 100% 来自 draw call 数量**，
随"实例数 × chunk 数"线性放大。把同一份几何合并成 1 个 mesh 并共享给所有实例后
（= 现在 `DrawMode.STATIC` 做的事），帧率与导入 ArrayMesh 完全持平。

这份数据是**重构的目标与验收依据**，所以保留 —— 它记录了"为什么要把 `STATIC` 做成默认"。

| 负载 | 导入 ArrayMesh | VoxelRenderer（重构前） | 差距 | 合并 + 共享（= 现在的 STATIC） |
|---|---|---|---|---|
| deer ×1 | 0.93 ms / 1076 fps | 1.04 ms / 965 fps | 地板内 | 0.88 ms |
| cars ×1 | 1.28 ms / 782 fps | 1.31 ms / 763 fps | 地板内 | **0.91 ms** |
| teapot1 ×1（158 chunk） | 1.49 ms | 1.04 ms | 地板内 | 1.03 ms |
| teapot2 ×1（382 chunk） | 1.17 ms | 1.17 ms | **1.00×** | 1.13 ms |
| deer ×100 | 1.14 ms / 880 fps | 1.43 ms / 700 fps | 1.25× | **1.13 ms** |
| deer ×1000 | 2.31 ms / 432 fps | 10.67 ms / 94 fps | **4.62×** | **2.15 ms / 464 fps** |
| cars ×240 | 2.21 ms / 452 fps | 12.17 ms / 82 fps | **5.51×** | **1.80 ms / 555 fps** |
| teapot1 ×16 | 1.58 ms / 633 fps | 6.68 ms / 150 fps | **4.23×** | **1.61 ms / 623 fps** |
| teapot1 ×16 + 阴影 | 3.00 ms / 334 fps | 10.48 ms / 95 fps | **3.49×** | **3.10 ms / 322 fps** |

（p50 帧时间；空场景地板 0.96 ms / 1045 fps。单模型那几行两侧都贴着地板，差异属测量噪声。）

---

## 1. 为什么单模型没有差距：两侧几何是同一份 C++ 产出

- 导入路径：`VoxelMeshGenerator.generate_mesh` → `NativeLoader.generate_arrays_native`
- 运行时路径：`VoxelRenderer._generate_chunk_worker` → `VoxelChunkGenerator.generate_single_chunk_dense` → `NativeLoader.generate_chunk_dense`
- 两者最终都进 `voxel_native.cpp` 的 `generate_dense_impl`：6 向可见性 + 每 slice `merge_slice` 贪婪合并 + `std::map<VertexKey,int>` 顶点去重

实测同一模型两侧三角形数**逐面相同**：

| 模型 | 体素数 | chunk 数 | 导入 mesh tri | 运行时 tri |
|---|---|---|---|---|
| deer.vox | 355 | 4 | 1344 | 1344 |
| cars.vox | 19 359 | 13 | 4638 | 4638 |
| teapot1.vox | 394 251 | 158 | 39 648 | 39 648 |
| teapot2.vox | 1 392 907 | 382 | 66 470 | 66 470 |

几何一样、顶点一样、材质一样 → 渲染成本一样。**在 1 ms 的帧时间地板附近，两者没有可测差异。**

> ⚠️ 必须知道的坑：`demo/deer.vox` 的导入设置是 `mesh/shape=1`（**球体**），导入产物 5300 tri；
> 而 QVX 运行时路径走方块面（1344 tri）。直接 `preload("deer.vox")` 去比 QVX 是**拿球比方块**。
> 基准因此两侧都走 `VoxelMeshGenerator.generate_mesh`（cube / scale=0.1 / world_origin），
> 与导入器同一入口同一参数。cars / teapot1 / teapot2 的导入设置本来就是 cube，
> 实测 `ResourceLoader.load()` 出来的 tri 数与基准产物完全一致，可直接对照。

---

## 2. 大量实例：差距就是 draw call

### 2.1 两侧的绘制单元数

| 负载 | ArrayMesh 侧 draw | VoxelRenderer 侧 draw |
|---|---|---|
| deer ×1 | 1 | 4 |
| teapot1 ×1 | 7 | 164 |
| teapot2 ×1 | 7 | 388 |
| deer ×100 | 7 | 406 |
| deer ×1000 | **11** | **4010** |
| cars ×240 | 8 | 5046 |
| teapot1 ×16 | 7 | 2534 |
| teapot1 ×16 + 阴影 | 16 | **10 134** |

ArrayMesh 侧 draw call **几乎不随实例数增长**：Godot 4 会把「同一份 mesh 资源 + 同一材质」的多个
MeshInstance3D 自动合批（deer ×1000 = 1000 个实例只花 11 个 draw call）。

VoxelRenderer 侧拿不到这个红利：**每个 chunk 都是独立 `ArrayMesh` 资源**
（`_apply_built_chunk` 每次 `VoxelChunkGenerator.build_mesh_from_arrays(arr)` 新建），
资源不同 → 不可合批 → **draw call ≈ 实例数 × chunk 数**。

### 2.2 纯 draw call 成本曲线（排除合批）

同样几何（1344 tri）但**每实例一份独立 ArrayMesh**，只增加实例数：

| draw call | 420 | 820 | 1020 | 2020 | 4020 |
|---|---|---|---|---|---|
| p50 | — | — | 5.56 ms | 8.47 ms | 20.45 ms |

再用 12 tri 的 BoxMesh（扫掉三角形数影响）：420 → 0.90 ms，820 → 1.04 ms，1620 → 3.31 ms，3220 → 8.53 ms。
扣掉 0.96 ms 地板后斜率约 **2.6 µs / draw call**（12 tri）到 **4.9 µs / draw call**（1344 tri）——
每 draw call 有一个固定提交成本，**与三角形数关系不大**。

### 2.3 三层对照：同几何、只改渲染组织

teapot1 ×16（634 368 tri）——几何一个顶点都没改，只改"怎么挂"：

| 形态 | draw | p50 | 相对现状 |
|---|---|---|---|
| 每 chunk 一个节点一份资源（现状） | 2534 | 6.68 ms | 1.00× |
| 每实例合并成 1 份 mesh（各实例仍各自一份） | 22 | 3.03 ms | **2.21×** |
| 合并后**所有实例共享同一份 mesh** | 7 | 1.61 ms | **4.15×** |

**两步才回本：先减少 draw call 总数（2534→22），再让资源可共享触发合批（22→7）。**
只做第一步只回本 2.2×，因为"每实例一份唯一资源"仍然无法合批。

### 2.4 决定性对照

| 负载 | 导入 mesh | VoxelRenderer | QVX 几何+合并 | QVX 几何+合并+共享 |
|---|---|---|---|---|
| deer ×1000 | 2.31 ms / 11 draw | 10.67 ms / 4010 draw | 4.56 ms / 1010 draw | **2.15 ms / 11 draw** |
| cars ×240 | 2.21 ms / 8 draw | 12.17 ms / 5046 draw | 4.95 ms / 246 draw | **1.80 ms / 7 draw** |
| teapot1 ×16 | 1.58 ms / 7 draw | 6.68 ms / 2534 draw | 3.03 ms / 22 draw | **1.61 ms / 7 draw** |
| teapot1 ×16 +阴影 | 3.00 ms / 16 draw | 10.48 ms / 10 134 draw | 5.65 ms / 74 draw | **3.10 ms / 16 draw** |

**同一份体素几何，换成"一份资源 + 共享实例"的渲染形态后，与导入 mesh 完全持平（cars 甚至更快）。**

### 2.5 阴影放大差距

`teapot1 ×16`：无阴影 2534 → 有阴影 10 134 draw（**×4.0**），而 mesh 侧 7 → 16（×2.3）。
每多一个 pass 就多付一遍"每 draw call 固定开销"。

---

## 3. 每帧 CPU 调度成本（第二份差距，小一个数量级）

`VoxelRenderer._process` 每帧跑 `process_lod`（LOD 分带/补建）+ `process_streaming`（流式扫描）
+ `process_deferred_chunks`（视锥补建）+ GPU 上传限流。采完样把 `_process` 关掉再采一次：

| 负载 | chunk 节点 | 开 _process | 关 _process | 纯调度 |
|---|---|---|---|---|
| deer ×100 | 400 | 1.43 ms | 1.47 ms | ~0（噪声内） |
| deer ×1000 | 4000 | 10.67 ms | 7.26 ms | **3.41 ms** |
| cars ×240 | 3369 | 12.17 ms | 11.71 ms | 0.46 ms |
| teapot1 ×16 | 2534 | 6.68 ms | 6.60 ms | 0.08 ms（已 GPU 饱和） |

≈ **0.6~0.85 µs / chunk 节点 / 帧**，与 draw call 同量级但小 4~8 倍。
大量实例时它是"额外 30~50%"，**不是主因**；chunk 数少时（cars×240，每实例 13 chunk 但只有 240 实例）
它几乎不可测。

---

## 4. 双方各自的优势（不是单向吊打）

- **单模型：完全平手**（`teapot2 ×1` 两侧都是 1.17 ms；`teapot1 ×1` QVX 1.04 vs mesh 1.49，
  但那行 mesh 侧的 GPU 耗时读数有抖动，视为地板内）。QVX 甚至可能略优：拆成小块的视锥/背面剔除
  粒度更细、顶点缓存局部性更好。
- **QVX 独有能力**（mesh 路径根本没有）：运行时逐体素编辑 / 破坏 / 水模拟 / LOD / 流式加载 / 无限世界。
  这份"性能税"买的就是这些。
- **内存**：单模型 QVX 略高（teapot2 显存 130.5 vs 126.7 MB）；大量实例差距拉大
  （deer ×1000：`RENDER_VIDEO_MEM_USED` 328.7 vs 126.7 MB）——每 chunk 一份 ArrayMesh + buffer 的固定占用。

---

## 5. 怎么把差距压下去（按性价比）

1. **新增"静态合并"渲染模式**（收益最大，实测回本 4~6×）。
   现状 `_lod_meshes[0]` 是 `{chunk_key: MeshInstance3D}`，每块一个节点一份资源。
   对**只读数据**（不破坏、不逐体素编辑）的模型，一次把所有 chunk surface 合并进一个 `ArrayMesh`，
   挂一个 `MeshInstance3D`，draw call 从 `chunk 数` 降到 `1~2`。动态破坏类仍保留 per-chunk。
2. **相同模型大量重复 → 合并 + 共享 + MultiMesh**。
   实测 `deer ×1000`：合并 + 共享 = 2.15 ms，与导入 mesh 的 2.31 ms 持平。
   需要每实例独立变换时可直接上 `MultiMeshInstance3D`（1 draw call 画 N 份）。
3. **静态道具干脆走导入 ArrayMesh 路径**。插件本来就有 `VoxelMeshGenerator.generate_mesh`；
   不破坏、不逐体素编辑的模型没有理由付 chunk 拆分的账。
4. **减少投影实例数**：阴影 pass 让 draw call 翻 4 倍。给远处的 VoxelRenderer 关 `cast_shadow`，
   或用 `visibility_range` 限制投影距离。
5. **LOD**：`lod_count > 1` 时远处由粗层 block 覆盖，draw call = `近处 chunk 数 + 粗块数`，
   比全量 LOD0 少一个数量级。基准为了公平对比统一用 `lod_count = 1` + `visibility_mode = FULL`
   （否则 QVX 侧会因视锥剔除"看起来更快"，但画面上少了东西）。

---

## 6. 复现

```gdscript
# 编辑器里跑（会弹窗口，依赖 GPU）
game_control(action = "start", scene = "res://demo/voxel_render_bench.tscn")
```

每个 stage：清场 → 建对象 → **等所有 VoxelRenderer 的 chunk 网格全部就绪** → 预热 30 帧 →
采样 240 帧（`PerfTool.sample_frames`：p50/p95/p99 + 1% low + CV）。
`gpu_ms` 取 `RenderingServer.viewport_get_measured_render_time_gpu`，把 CPU 组织成本与 GPU 光栅成本分开。

改负载不改代码：写 `user://voxel_render_bench_plan.json`，字段见脚本 `_default_plan()`
（`model / count / size / shadows / frames / unique / label`）。

### 踩过的两个坑（不修就得到假数据）

1. **`view_distance` 会静默吞掉 chunk。**
   `_apply_built_chunk` 有一道带外校验：chunk 中心到相机 > `lod_outer[0] + 半块` 就丢弃不挂。
   `lod_count = 1` 时 `lod_outer[0] == view_distance`（默认 40）——于是**即使 `visibility_mode = FULL`**，
   离相机 40 单位以外的 chunk 也不会出现。基准里相机为了取景必须退远，
   不显式放大 `view_distance` 就会看到"网格永远建不完、draw call 凭空少一半"
   （实测 deer ×400 只挂上 418/1600 个 chunk，还白等 180 秒超时）。
2. **窗口被遮挡会让引擎把呈现节流。**
   这台机器实测地板从 **0.95 ms 变成 6.90 ms（145 fps）**，且**与窗口大小、GPU 耗时无关**
   （1280×720 / 480×270 都是 6.9 ms，GPU 耗时只有 0.14 ms）。
   那种状态下所有 stage 都被压在同一个地板上，横向对比全是废数据。
   基准因此 `window_set_flag(WINDOW_FLAG_ALWAYS_ON_TOP, true)` 置顶运行。

---

## 7. 完整原始数据

| 负载 | 变体 | p50 ms | fps | 1% low | draw | prims | gpu ms |
|---|---|---|---|---|---|---|---|
| baseline | 空场景 | 0.96 | 1045 | 72 | 0 | 0 | 0.33 |
| deer ×1 | mesh | 0.93 | 1076 | 100 | 1 | 1344 | 8.99\* |
| deer ×1 | qvox | 1.04 | 965 | 87 | 4 | 1344 | 0.48 |
| deer ×1 | qvox 关调度 | 0.88 | 1139 | 100 | 4 | 1344 | 0.42 |
| deer ×1 | qvox 合并 | 0.89 | 1127 | 120 | 1 | 1344 | 0.42 |
| deer ×1 | qvox 合并+共享 | 0.88 | 1140 | 88 | 1 | 1344 | 7.91\* |
| cars ×1 | mesh | 1.28 | 782 | 73 | 8 | 4710 | 0.82 |
| cars ×1 | qvox | 1.31 | 763 | 60 | 27 | 4710 | 0.81 |
| cars ×1 | qvox 关调度 | 1.46 | 684 | 66 | 27 | 4710 | 0.83 |
| cars ×1 | qvox 合并 | 0.90 | 1116 | 72 | 7 | 4710 | 0.43 |
| cars ×1 | qvox 合并+共享 | 0.91 | 1094 | 102 | 7 | 4710 | 0.45 |
| teapot1 ×1 | mesh | 1.49 | 671 | 64 | 7 | 39 720 | 0.56 |
| teapot1 ×1 | qvox | 1.04 | 963 | 128 | 164 | 39 720 | 0.55 |
| teapot1 ×1 | qvox 关调度 | 1.02 | 980 | 356 | 164 | 39 720 | 0.56 |
| teapot1 ×1 | qvox 合并 | 1.04 | 964 | 89 | 7 | 39 720 | 0.56 |
| teapot1 ×1 | qvox 合并+共享 | 1.03 | 971 | 82 | 7 | 39 720 | 0.55 |
| teapot2 ×1 | mesh | 1.17 | 858 | 50 | 7 | 66 554 | 0.67 |
| teapot2 ×1 | qvox | 1.17 | 858 | 129 | 388 | 66 554 | 0.70 |
| teapot2 ×1 | qvox 关调度 | 1.14 | 876 | 53 | 388 | 66 554 | 0.69 |
| teapot2 ×1 | qvox 合并 | 1.12 | 894 | 65 | 7 | 66 554 | 0.67 |
| teapot2 ×1 | qvox 合并+共享 | 1.13 | 884 | 77 | 7 | 66 554 | 0.66 |
| deer ×100 | mesh | 1.14 | 880 | 76 | 7 | 134 484 | 0.69 |
| deer ×100 | qvox | 1.43 | 700 | 54 | 406 | 134 484 | 0.95 |
| deer ×100 | qvox 关调度 | 1.47 | 680 | 49 | 406 | 134 484 | 0.93 |
| deer ×100 | qvox 合并 | 1.27 | 786 | 60 | 106 | 134 484 | 0.81 |
| deer ×100 | qvox 合并+共享 | 1.13 | 884 | 50 | 7 | 134 484 | 0.67 |
| deer ×100 | mesh 独立mesh | 1.22 | 818 | 62 | 106 | 134 480 | 0.76 |
| deer ×100 | qvox（同上档） | 1.47 | 681 | 53 | 406 | 134 480 | 0.92 |
| deer ×100 | qvox 合并（同上档） | 1.30 | 768 | 51 | 106 | 134 480 | 0.84 |
| deer ×1000 | mesh | 2.31 | 432 | 44 | 11 | 1 344 104 | 1.65 |
| deer ×1000 | qvox | 10.67 | 94 | 41 | 4010 | 1 344 104 | 4.37 |
| deer ×1000 | qvox 关调度 | 7.26 | 138 | 39 | 4010 | 1 344 104 | 4.26 |
| deer ×1000 | qvox 合并 | 4.56 | 219 | 46 | 1010 | 1 344 104 | 3.23 |
| deer ×1000 | qvox 合并+共享 | 2.15 | 464 | 49 | 11 | 1 344 104 | 1.64 |
| cars ×240 | mesh | 2.21 | 452 | 48 | 8 | 1 113 204 | 2.17 |
| cars ×240 | qvox | 12.17 | 82 | 45 | 5046 | 1 113 204 | 3.27 |
| cars ×240 | qvox 关调度 | 11.71 | 85 | 43 | 5046 | 1 113 204 | 3.53 |
| cars ×240 | qvox 合并 | 4.95 | 202 | 44 | 246 | 1 113 204 | 4.82 |
| cars ×240 | qvox 合并+共享 | 1.80 | 555 | 49 | 7 | 1 113 204 | 1.31 |
| teapot1 ×16 | mesh | 1.58 | 633 | 50 | 7 | 634 448 | 1.11 |
| teapot1 ×16 | qvox | 6.68 | 150 | 44 | 2534 | 634 448 | 2.48 |
| teapot1 ×16 | qvox 关调度 | 6.60 | 151 | 37 | 2534 | 634 448 | 2.32 |
| teapot1 ×16 | qvox 合并 | 3.03 | 330 | 46 | 22 | 634 448 | 2.40 |
| teapot1 ×16 | qvox 合并+共享 | 1.61 | 623 | 67 | 7 | 634 448 | 1.62 |
| teapot1 ×16 +阴影 | mesh | 3.00 | 334 | 47 | 16 | 2 696 156 | 2.40 |
| teapot1 ×16 +阴影 | qvox | 10.48 | 95 | 41 | 10 134 | 2 562 092 | 4.91 |
| teapot1 ×16 +阴影 | qvox 关调度 | 10.27 | 97 | 38 | 10 134 | 2 562 092 | 4.27 |
| teapot1 ×16 +阴影 | qvox 合并 | 5.65 | 177 | 44 | 74 | 2 696 156 | 5.60 |
| teapot1 ×16 +阴影 | qvox 合并+共享 | 3.10 | 322 | 47 | 16 | 2 696 156 | 2.43 |

\* 这两格 GPU 读数（8.99 / 7.91 ms）与 p50（0.93 / 0.88 ms）矛盾，是渲染耗时测量在
"几乎无内容"帧上的瞬时抖动，不代表真实 GPU 开销；同 stage 其它行为 0.42~0.48 ms。

### 资源准备耗时（一次性，不计入帧率）

| 模型 | 导入 mesh 生成 | `QVoxelSource.from_voxel_data` | QVX 建全部 chunk 网格 |
|---|---|---|---|
| deer（4 chunk） | 21~50 ms | 2~4 ms | 3~6 ms |
| cars（13 chunk） | 39~60 ms | 52~59 ms | 8~12 ms |
| teapot1（158 chunk） | 1.24 s | 1.59 s | 80~104 ms |
| teapot2（382 chunk） | 4.5 s | 6.0 s | 190~226 ms |

QVX 的**网格化**比整模型导入快一个数量级（分 chunk 并行 + 增量），
但 `QVoxelSource` 构造（逐体素写密集缓冲）是当前启动瓶颈——加载时间问题，与本文帧率无关，但同样值得优化。

# VoxelSupport 必要优化记录（2026-11-18）

> 在 GodotVoxelSupport 原项目实测、修改与验证；未改 Xian 的项目侧代码。

## 1. 实测基线

- `Scripts/Test` 原有 34 个测试文件 + 本次新增 1 个回归文件；headless（editor 段）**344 项，通过 344，失败 0，跳过 5**。
- 必须加 `--allow-errors`：这套测试有约 10 处**故意触发** `push_error` 来断言“坏输入必须被拒绝”，
  而 DEVFramework 新加的 strict headless logger 会把它们当失败；`--allow-errors` 是现有等价开关。
- 修正了一处过期测试：`SaveTool` 当前只有单份 `.bak`（没有 `MAX_BACKUPS`/`.1.bak`），
  `test_qvoxelier_project.gd` 已按现有 API 更新。
- **进程退出时 `0xC0000005`（access violation）是既有问题**：把本次 Voxel 两处源码改动 stash 后
  跑全量，仍是同样退出码；用例本身全部通过。属独立问题，未混入本次优化。

## 2. 做了什么（只改 P0 通用契约）

### 2.1 程序化源不再要求手写四个判定 + 手动 configure

- `QVoxelSource._init()` 自动 `_async.configure(self)`：构造即把异步编排器指向自己。
  原来只在 `node`/`stream` setter 里 configure，程序化源（两者都为空）会 `source=null` → 请求被静默撤销。
- 新增 `addons/VoxelSupport/Dynamic/ProceduralVoxelSource.gd`：
  默认 `is_streaming() = true`、`can_generate_chunk() = true`、`is_in_node_bounds() = true`；
  子类**只实现 `generate(key, lod)`**。`infinite` 不自动置 true（origin shift 是使用方式，不是生成事实）。
- 渲染器 gate 从 `data.node != null` 改为 `data.is_streaming()`：程序化源默认 `FRUSTUM` 也能取数，
  不再必须依赖“把 visibility_mode 调成 STREAMING”这个隐含知识。

### 2.2 碰撞重建的时间预算

- 新增公开字段 `VoxelRenderer.collision_rebuild_budget_ms`（默认 4ms，0=只按块数）。
- 原实现每帧最多重建 12 块，单块 `ConcavePolygonShape3D` 约 10~15ms → 一帧可堆到百毫秒级；
  现在至少建 1 块，之后按时间预算截断，避免“块数没超但帧时间爆掉”。
- 这是**缓解**，不是终态：单块仍可能超过预算；真正的异步/HeightMap 快路径仍是后续项。

### 2.3 新回归测试

- `Scripts/Test/test_voxel_procedural_source.gd` + `Scripts/Test/fixtures/procedural_source_probe.gd`：
  - 子类只实现 `generate`，`is_streaming/can_generate/is_in_node_bounds` 成立；
  - `new()` 后 `_async` 的 source 已指向自身（VX-01 的构造契约）。
- README 的“Procedural infinite world”示例改为 `extends ProceduralVoxelSource` + `generate()`，
  原示例写的是 `_generate_chunk()`（私有切片入口），照抄仍然会空白。

## 3. 验证

```powershell
godot --headless --path . -s res://addons/DEVFramework/Test/run_headless.gd -- --script all --allow-errors
```

结果：**344 项 / 通过 344 / 失败 0 / 跳过 5**（5 个原本就 game-only）；进程退出码的 AV 见 §1。
新测试单跑：2/2 通过；`QVoxelSource`/`VoxelRenderer`/新类均通过 MCP `validate`。
Xian 回归：**74/74 通过**；游戏烟测正常（赵澈出生、10 栋建筑、on_floor、约 118fps）。

## 4. 仍未做（按优先级）

1. **VX-04 终态**：碰撞真正异步，或 HeightMapShape3D/「只有 LOD0 带碰撞」模式；当前只做了时间预算。
2. **VX-09/10**：异步 loader 的 `stats()`（submitted/resolved/dropped{reason}）与 `explain(chunk)` 诊断。
3. **VX-07/08**：程序化绝对坐标的卸载语义、LOD0 缓冲降采样的原生路径。
4. **VX-05/06**：全局 Palette + 公开 VoxelMeshFactory（静态模型/合批）。
5. **VX-11**：其余私有预算字段 profile 化。

> 本次遵循“通用机制进插件，项目特化留项目”的边界；没有把 Xian 的地形/调色板逻辑搬进 VoxelSupport。
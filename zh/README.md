# Godot Voxel Support
[English](https://github.com/QinZhuo/GodotVoxelSupport/blob/main/README.md) | [中文](https://github.com/QinZhuo/GodotVoxelSupport/blob/main/zh/README.md)

[Github](https://github.com/QinZhuo/GodotVoxelSupport) • [资产库](https://godotengine.org/asset-library/asset/4480) 

> MagicaVoxel大型体素模型支持，更快的导入速度，自动材质贴图

- 合并模型 
- 多线程生成Mesh
- 自动生成 金属 粗糙 自发光 等贴图
- 解决导入大于256x256x256的.vox模型过慢导致卡死的问题

![alt text](Showdown_of_Luck.png)

[《Showdown of Luck》](https://store.steampowered.com/app/4666770/?utm_source=github)这个游戏中可以看到使用插件导入的体素模型渲染效果 是现在我正在制作的独立游戏 一款融合卡牌与老虎机的异步联机PVP自走棋游戏 感兴趣可以加一个愿望单
> 如果您的游戏使用了这个插件 跟我说一下我会很开心 我也愿意通过我的方式帮你宣传一下
![](/images/cards.png)
![](/images/teapot.png)

## 体素运行时使用方法

### 架构
- **VoxelData** — 体素数据存储与修改（材质、chunk 缓冲）
- **VoxelStream**（`@abstract`）— 持久化后端（chunk 级读写）
  - `VoxelFileStream` — 磁盘 region 流式存储（体素世界存档）
  - `VoxelProceduralStream`（`@abstract`）— 程序化无限世界；子类覆写 `_generate_chunk()`
- **VoxelRenderer** — 网格生成、LOD、流式加载、碰撞
- **VoxelDestructible** — 继承 `VoxelRenderer`：破坏、崩塌、碎片

### 程序化无限世界

```gdscript
class_name MyWorld
extends VoxelProceduralStream

## 覆写基类 @abstract 方法：返回 16³ PackedInt32Array（值 = 材质ID，0 = 空）。
## 必须确定性：同 chunk_key → 同地形。
func _generate_chunk(chunk_key: Vector3i) -> PackedInt32Array:
	# ... 生成算法

# 使用
var stream := MyWorld.new()
stream.persist_directory = "user://world_edits"   # 可选：持久化用户修改
var data := VoxelData.new()
data.stream = stream
# ... 赋值给 VoxelRenderer.data
```

特性：
- 确定性生成，chunk 边界与 origin shift 后世界连续
- **动态原点重定位（origin shift）**：相机远移自动平移世界基准，保持坐标小（float32 精度安全）
- **修改持久化**：用户修改的 chunk 写入 `persist_directory`，重启保留
- **异步生成**：chunk 生成在后台线程（`WorkerThreadPool`）

### 流式 demo
`res://demo/streaming_demo.tscn` — 按键 **0** 在 磁盘文件流 与 程序化无限世界 间切换。
操作：WASD 移动、Q/E 升降、空格加速、1 流式开关、2 视锥剔除开关。

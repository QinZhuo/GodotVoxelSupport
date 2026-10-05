# `.qvox` 样例文件

这里放着**实际存在的** `.qvox` 文件——与 `demo/*.vox` 同级，是能直接打开、
hexdump、观察结构、并作为**项目资产**被编辑器导入的体素模型文件。

## `.qvox` 的定位：一等模型资产，不是中间产物

`.qvox` 是与 `.vox` **同级的体素模型容器**，不是"烘焙中间产物"或临时文件：

- **它是源资产**：放在项目里、进版本库，由编辑器按扩展名导入（见下）。
- **它是自描述的**：一个文件自带材质（`MATE`）、体素（`VOX0`）、可选场景图
  （`NODE`）与元数据（`HEAD`）；删掉 `CACH` 也不损失语义。
- 同一个容器**也**能承载"整个世界存档"（`QVoxStream` 的用法，落在 `user://`）——
  那是它的一种使用场景，不是它的身份。

> 派生物是 `.godot/imported/…` 下的导入产物；`.qvox` 本身是源。

## 编辑器导入

`addons/VoxelSupport/Importers/` 下的导入器**同时识别 `.vox` 与 `.qvox`**
（统一入口 `VoxData.from_asset()`），因此 `.qvox` 在 Godot 里与 `.vox` 一样，
可在导入面板选择产物形式：

| 导入器 | 产物 | 用途 |
|---|---|---|
| Voxel Data Resource | `VoxelData` (.res) | 运行时体素数据（可破坏 / 动态修改） |
| Voxel Mesh | `ArrayMesh` (.mesh) | 静态网格 |
| Voxel MeshLibrary | `MeshLibrary` (.res) | 网格库（by model / node / frame） |
| Voxel No Import | 空 `Resource` | 只要原始文件、不做导入 |

## 文件

| 文件 | 来源 | 大小 | 结构 |
|---|---|---|---|
| `deer.qvox` | `demo/deer.vox` | 4.3 KB | HEAD + MATE(256) + VOX0(1 块) |
| `cars.qvox` | `demo/cars.vox` | 23.9 KB | HEAD + MATE(256) + VOX0(11 块) |
| `teapot1.qvox` | `demo/teapot1.vox` | 291 KB | HEAD + MATE(256) + VOX0(133 块) |

## 结构速查

```
89 51 56 4F 58 0D 0A 1A          ← 8 字节签名（0x89 'Q' 'V' 'O' 'X' CR LF 0x1A）

[HEAD]  length | "HEAD" | crc32 | JSON     ← 唯一必填块，必须第一
[MATE]  length | "MATE" | crc32 | 条目表     ← 材质（每项 12 字节）
[VOX0]  length | "VOX0" | crc32 | 模型负载   ← 每个 model 一个块
          └ 模型头 10 字节：uint16 model_id + uint32 block_count + uint32 payload_length
            └ 块内块头 17 字节：3×int32 坐标 + uint8 codec + uint32 payload_length
```

顶层块头 = 12 字节（`length` 4 + `type` 4 + `crc32` 4），`length` 含尾部填充、
恒为 4 的倍数。完整的字段定义见 `docs/QVOX_FORMAT.md`。

## 用 Python 快速看一眼结构

```python
import struct
d = open("deer.qvox", "rb").read()
off = 8
while off < len(d):
    ln  = struct.unpack_from("<I", d, off)[0]
    ty  = d[off+4:off+8].decode("latin1")
    crc = struct.unpack_from("<I", d, off+8)[0]
    print(f"[{ty}] len={ln} crc={crc:08x}")
    if ty == "HEAD":
        print("   ", d[off+12:off+12+ln].rstrip(b"\x00").decode())
    if ty == "VOX0":
        p = d[off+12:off+12+ln]
        print("    model_id=%d block_count=%d payload_length=%d"
              % (struct.unpack_from("<H", p, 0)[0],
                 struct.unpack_from("<I", p, 2)[0],
                 struct.unpack_from("<I", p, 6)[0]))
    off += 12 + ln
```

## 重新烘焙

样例由 `demo/qvox_vs_mesh_compare.tscn` / `demo/qvox_model_viewer.tscn` 的烘焙流程
生成。要刷新本目录，在编辑器里加载模型后把 `user://qvox_viewer/*.qvox` 拷回这里，
或新建一个 `QVoxStream`，把 `file_path` 直接指向 `res://demo/samples/`（§8 的读取
流程与 §10 的编码约定对任何路径一视同仁）。

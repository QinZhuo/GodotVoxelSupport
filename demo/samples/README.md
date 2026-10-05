# `.qvox` 样例文件

这里放着**实际存在的** `.qvox` 文件——和 `demo/*.vox` 一样是能直接打开、hexdump、
观察结构的真实文件，而不是"只存在于运行时"的东西。

## 为什么之前"看不到 .qvox 文件"

`.qvox` 是**运行时烘焙产物**，默认写进 Godot 的 `user://`，不是项目目录：

```
Windows:  %APPDATA%\Godot\app_userdata\Voxel Support\
macOS:    ~/Library/Application Support/Godot/app_userdata/Voxel Support/
Linux:    ~/.local/share/godot/app_userdata/Voxel Support/
```

这与 `.vox` 的角色不同：`.vox` 通常是**源资产**（放在项目里、进版本库），
`.qvox` 由导入/烘焙流程从 `.vox` 生成、可随时重建，所以运行时产物不进项目目录。
本目录就是"把烘焙结果也放一份进项目"的样例，方便直接观察与文档引用。

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
或直接调用 `QVoxStream` 写入 `res://demo/samples/`（见 `docs/QVOX_FORMAT.md` §13）。

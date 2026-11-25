# gdextension — VoxelSupport 原生核心构建目录

本目录**只放构建脚手架**（CMake 脚本、godot-cpp submodule、绑定快照），**不放假源码**。
C++ 源码与产物都不在这里：

| 东西 | 真实位置 |
|------|----------|
| C++ 源码 | `addons/VoxelSupport/Native/src/`（`register_types.cpp/.h`、`voxel_native.cpp/.h`） |
| CMake 脚本 | `gdextension/CMakeLists.txt`（本目录） |
| 源文件清单 | `gdextension/generated/voxelsupport_sources.cmake`（由 DEVFramework 生成，路径指向上面那份 src） |
| godot-cpp | `gdextension/godot-cpp/`（git submodule，未 init 时是空目录） |
| 产物（动态库） | `addons/VoxelSupport/Native/` |
| 加载声明 | `addons/VoxelSupport/Native/voxelsupport.gdextension` |

CMake target 名是 `voxelsupport`（`generated/voxelsupport_sources.cmake` 与部署工具的
target→插件映射都依赖它，**不要改**）。

## 怎么构建（推荐：编辑器内一键）

在本项目的 Godot 编辑器里用 DEVFramework 的 GDExtension 一键构建：

- 菜单入口：`GDExtensionRebuild`（EditorScript），
- 或 MCP 工具 `build_native`：`status` 只比时间戳（零等待），`build` 执行完整构建。

这条路径做完了全部四件事：配置 CMake → 编译 → 把产物**改名成规范名** → 回写
`*.gdextension` 的 `[libraries]`。**手工改过 C++ 之后就走它**，不要手搓 cmake。

## 怎么构建（手工，排障用）

前提：`git submodule update --init --recursive` 已拉下 godot-cpp；MinGW Makefiles 或
Unix Makefiles + CMake ≥ 3.17 在 PATH 里。

```bash
# Windows (MinGW Makefiles)
cmake -S gdextension -B gdextension/build-win -G "MinGW Makefiles" \
      -DCMAKE_BUILD_TYPE=Release -DGODOTCPP_API_VERSION=4.7
cmake --build gdextension/build-win --parallel

# Linux / macOS（macOS 交叉构建靠 -DCMAKE_OSX_ARCHITECTURES=<arm64|x86_64>）
cmake -S gdextension -B gdextension/build-unix -G "Unix Makefiles" \
      -DCMAKE_BUILD_TYPE=Release -DGODOTCPP_API_VERSION=4.7
cmake --build gdextension/build-unix --parallel
```

`-DGODOTCPP_API_VERSION` 可省略（CMakeLists 里默认 4.7）；仅当 `godot-cpp` 本地没有对应
绑定快照时才需要显式指定引擎实际版本。

构建缓存目录 `gdextension/build*/` 已被 `.gitignore` 忽略。

## 产物命名：默认名 → 规范名

CMake 的 `*_OUTPUT_DIRECTORY` 已把库直接输出到 `addons/VoxelSupport/Native/`，
但**链接器直出的名字是默认名**（带平台默认前后缀）：

| 平台 | 链接器直出（默认名） | 规范名（`.gdextension` 声明的名字） |
|------|----------------------|--------------------------------------|
| Windows | `libvoxelsupport.dll` | `libvoxelsupport.windows.release.x86_64.dll` |
| macOS | `libvoxelsupport.dylib` | `libvoxelsupport.macos.release.universal.dylib` |
| Linux | `libvoxelsupport.so` | `libvoxelsupport.linux.release.x86_64.so` |

规范名规则：`lib<target>.<平台>.<debug|release>.<架构>.<ext>`。
`lib` 前缀是**必须有**的：GDExtension 对文件名没有硬性要求，唯一硬约束是
`.gdextension` 的 `[libraries]` 与磁盘上的文件名**一字不差**，而这份声明用的就是带
`lib` 的规范名。

编辑器内一键构建会自动完成改名。手工构建则要自己改（以 Windows release 为例）：

```powershell
cd addons/VoxelSupport/Native
Move-Item libvoxelsupport.dll libvoxelsupport.windows.release.x86_64.dll -Force
```

**注意：不要在 CMakeLists 里加 `OUTPUT_NAME` 去"直接产出规范名"。** 部署工具是靠
"默认名 + 本次链接时间"识别新产物的，改了 `OUTPUT_NAME` 会让这条探测失效。

## 没构建 / 构建了没改名 会怎样

这两种情况下引擎都只是**加载不到新库**，不会崩，但也**不会报"你忘了重建"**：

- 完全没库 → `VoxelSupportNative` 类不存在，所有走 `NativeLoader` 的路径返回空值。
- 有库但是**旧的** → 方法全都存在，能力校验（`REQUIRED_METHODS`）全过，行为却是老的。

第二种才是真正的坑。所以原生库导出 `api_version()` / `build_id()`，GDScript 侧
`NativeLoader.gd` 的 `EXPECTED_API_VERSION` 与之比对，不一致就明确
`push_error("原生库与 GDScript 版本不匹配，请重新构建")`。

**改过 `addons/VoxelSupport/Native/src/` 下的 C++ 之后，记得重建并重启编辑器** —
只有重启才会让引擎卸载旧的动态库。

## 已提交的预编译产物

仓库当前只提交了两个平台的库，都是 **release** 构建：

- `libvoxelsupport.windows.release.x86_64.dll`（Windows x86_64）
- `libvoxelsupport.macos.release.universal.dylib`（macOS universal：arm64 + x86_64）

`voxelsupport.gdextension` 里的 `debug` 条目复用这两份 release 库；
`linux` 条目保留但**没有对应的预编译 `.so`** —— 想在 Linux 上跑就自己按上面命令构建。

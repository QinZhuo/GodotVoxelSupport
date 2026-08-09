# gdextension — VoxelSupport 原生核心 (C++ / GDExtension)

体素插件原生核心：体素数据访问 / 网格生成等高性能逻辑的 C++ 实现，
与 `addons/VoxelSupport/Runtime/` 的 GDScript 逻辑配合。

## 目录结构

```
gdextension/
├── CMakeLists.txt      # CMake 构建脚本
├── src/
│   ├── register_types.cpp/.h   # GDExtension 入口注册
│   └── voxel_native.cpp/.h     # 体素原生核心逻辑
godot-cpp/              # git submodule (固定 commit，克隆后需 init)
```

## 产物分发目录

构建产物输出到 `addons/VoxelSupport/Native/`，文件名与 `voxelnative.gdextension`
中的 8 个平台条目严格对应：

| 平台 | Debug | Release |
|------|-------|---------|
| Windows x86_64 | `voxelnative.windows.debug.x86_64.dll` | `voxelnative.windows.release.x86_64.dll` |
| Linux x86_64 | `libvoxelnative.linux.debug.x86_64.so` | `libvoxelnative.linux.release.x86_64.so` |
| macOS arm64 | `libvoxelnative.macos.debug.arm64.dylib` | `libvoxelnative.macos.release.arm64.dylib` |
| macOS x86_64 | `libvoxelnative.macos.debug.x86_64.dylib` | `libvoxelnative.macos.release.x86_64.dylib` |

## 本地构建 (Windows + MinGW 示例)

```bash
# 首次克隆后初始化 godot-cpp submodule
git submodule update --init --recursive

# 准备工具链 (以 w64devkit 便携版为例)
export PATH="/path/to/w64devkit/bin:$PATH"

# Debug 构建 (CMake 自动输出 voxelnative.windows.debug.x86_64.dll)
cmake -S gdextension -B gdextension/build-win -G Ninja \
      -DGODOTCPP_API_VERSION=4.7 -DCMAKE_BUILD_TYPE=Debug
cmake --build gdextension/build-win

# MinGW 会多出 lib 前缀 (libvoxelnative.windows.debug.x86_64.dll)，
# 需复制为 .gdextension 期望的无 lib 前缀名
cd addons/VoxelSupport/Native
cp libvoxelnative.windows.debug.x86_64.dll voxelnative.windows.debug.x86_64.dll
```

构建缓存目录 `gdextension/build*/` 已在 `.gitignore` 中忽略。

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

> CMakeLists 对 Debug 配置自动设置带平台后缀的输出名；Release 配置输出无后缀名，
> 由 CI 重命名步骤统一处理。

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

## CI 自动构建 (GitHub Actions)

工作流文件：`.github/workflows/build.yml`

**触发条件**（以下任一满足时全平台构建）：
- push 到 `main` 分支且改动命中：`gdextension/src/**`、`gdextension/CMakeLists.txt`、
  `.gitmodules`、`godot-cpp/**`、`.github/workflows/build.yml`
- 推送 `v*` 格式的 tag
- Actions 页面手动 `Run workflow`

**执行流程**：
1. **build 作业**（4 平台矩阵）：Windows x86_64 / Linux x86_64 / macOS arm64 / macOS x86_64
2. **package 作业**：汇总各平台二进制 + 完整插件目录，打包为 `voxel-support-addon`
3. **Release**：推送 tag 时自动发布 GitHub Release（完整插件包）

> 该 workflow 采用"打包 + 发布"模式（不是回写提交模式）：产物通过 GitHub Release
> 分发，使用者下载插件包即可，无需自己编译。

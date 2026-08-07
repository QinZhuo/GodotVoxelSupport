cmake_minimum_required(VERSION 3.17)

# 体素插件原生核心 (GDExtension)
# 多平台构建：godot-cpp 官方模板同款 CMake 方案
# 用法：
#   cmake -S . -B build -DGODOTCPP_API_VERSION=4.7 -DCMAKE_BUILD_TYPE=Release
#   cmake --build build --config Release
# 平台支持：macOS(arm64/x86_64) / Windows(x86_64) / Linux(x86_64)
#   通过 CMake 内置 -DCMAKE_OSX_ARCHITECTURES / 交叉工具链 / GitHub Actions 矩阵实现

project(voxelnative LANGUAGES CXX)

# godot-cpp 需要 gdextension API 文件：默认 master(v10) 自带 4.3~4.7 的 api 文件
# 若想自定义，可设置 GODOTCPP_GDEXTENSION_DIR 指向自定义扩展 API 目录
if(NOT DEFINED GODOTCPP_API_VERSION)
    set(GODOTCPP_API_VERSION "4.7")
endif()

# 引入 godot-cpp（其 CMake 通过 GODOTCPP_API_VERSION 选择对应 extension_api.json）
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../godot-cpp ${CMAKE_CURRENT_BINARY_DIR}/godot-cpp)

add_library(voxelnative SHARED
    src/register_types.cpp
    src/voxel_native.cpp
)

# 链接 godot-cpp（godot-cpp 目标名为 godot-cpp）
target_link_libraries(voxelnative PRIVATE godot-cpp)

# godot-cpp 要求 C++17（其头文件使用 is_base_of_v 等 C++17 特性）
set_target_properties(voxelnative PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON)

# macOS: 允许在子目录中构建动态库
if(APPLE)
    set_target_properties(voxelnative PROPERTIES
        MACOSX_RPATH ON
    )
endif()

# 将编译产物直接输出到插件分发目录 addons/VoxelSupport/Native/
# （.gdextension 引用路径为 res://addons/VoxelSupport/Native/xxx，编译完即就位，无需手动复制）
# 发布时需按 .gdextension 声明的文件名重命名（如 macos.debug.arm64 后缀）：
#   macOS:    libvoxelnative.macos.debug.arm64.dylib / .release.arm64.dylib
#   Windows:  voxelnative.windows.debug.x86_64.dll
#   Linux:    libvoxelnative.linux.debug.x86_64.so
set_target_properties(voxelnative PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../addons/VoxelSupport/Native
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../addons/VoxelSupport/Native
    ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../addons/VoxelSupport/Native
)

cmake_minimum_required(VERSION 3.17)

# 体素插件原生核心 (GDExtension)
# 多平台构建：godot-cpp 官方模板同款 CMake 方案
# 用法：
#   Debug   （编辑器/F5 调试运行时加载 debug 命名的库）：
#     cmake -S . -B build -DGODOTCPP_API_VERSION=4.7 -DCMAKE_BUILD_TYPE=Debug
#     cmake --build build
#   Release （导出游戏运行时加载 release 命名的库）：
#     cmake -S . -B build-release -DGODOTCPP_API_VERSION=4.7 -DCMAKE_BUILD_TYPE=Release
#     cmake --build build-release
# 平台支持：macOS(arm64/x86_64) / Windows(x86_64) / Linux(x86_64)
#   通过 CMake 内置 -DCMAKE_OSX_ARCHITECTURES / 交叉工具链实现

project(voxelnative LANGUAGES CXX)

# godot-cpp 需要 gdextension API 文件：默认 master(v10) 自带 4.3~4.7 的 api 文件
# 若想自定义，可设置 GODOTCPP_GDEXTENSION_DIR 指向自定义扩展 API 目录
if(NOT DEFINED GODOTCPP_API_VERSION)
    set(GODOTCPP_API_VERSION "4.7")
endif()

# godot-cpp 用 GODOTCPP_TARGET（而非 CMAKE_BUILD_TYPE）决定 debug/release 特性
# （DEBUG_ENABLED 宏等）。根据 CMAKE_BUILD_TYPE 自动对齐，否则 Release 构建
# 仍会以 template_debug 特性编译（带调试断言/日志），库与 .gdextension 的
# release 条目语义不符：
#   CMAKE_BUILD_TYPE=Debug   → GODOTCPP_TARGET=template_debug
#   CMAKE_BUILD_TYPE=Release → GODOTCPP_TARGET=template_release
if(NOT DEFINED GODOTCPP_TARGET)
    if(CMAKE_BUILD_TYPE STREQUAL "Release")
        set(GODOTCPP_TARGET "template_release")
    else()
        set(GODOTCPP_TARGET "template_debug")
    endif()
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
# 输出名与 .gdextension 声明的文件名严格一致，避免运行期加载到旧库（签名不匹配崩溃）：
#   macOS debug:   libvoxelnative.macos.debug.arm64.dylib
#   Linux debug:   libvoxelnative.linux.debug.x86_64.so
#   Windows debug: voxelnative.windows.debug.x86_64.dll
# 注意：macOS/Linux 需保留默认 "lib" 前缀（与 .gdextension 条目匹配），
#       故不设置 PREFIX ""；Windows 平台 CMake 默认无前缀，输出名已与条目一致。
set_target_properties(voxelnative PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../addons/VoxelSupport/Native
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../addons/VoxelSupport/Native
    ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../addons/VoxelSupport/Native
)
if(APPLE AND CMAKE_BUILD_TYPE STREQUAL "Debug")
    set_target_properties(voxelnative PROPERTIES OUTPUT_NAME "voxelnative.macos.debug.arm64")
elseif(APPLE AND CMAKE_BUILD_TYPE STREQUAL "Release")
    set_target_properties(voxelnative PROPERTIES OUTPUT_NAME "voxelnative.macos.release.arm64")
elseif(WIN32 AND CMAKE_BUILD_TYPE STREQUAL "Debug")
    set_target_properties(voxelnative PROPERTIES OUTPUT_NAME "voxelnative.windows.debug.x86_64")
elseif(WIN32 AND CMAKE_BUILD_TYPE STREQUAL "Release")
    set_target_properties(voxelnative PROPERTIES OUTPUT_NAME "voxelnative.windows.release.x86_64")
elseif(UNIX AND NOT APPLE AND CMAKE_BUILD_TYPE STREQUAL "Debug")
    set_target_properties(voxelnative PROPERTIES OUTPUT_NAME "voxelnative.linux.debug.x86_64")
elseif(UNIX AND NOT APPLE AND CMAKE_BUILD_TYPE STREQUAL "Release")
    set_target_properties(voxelnative PROPERTIES OUTPUT_NAME "voxelnative.linux.release.x86_64")
endif()

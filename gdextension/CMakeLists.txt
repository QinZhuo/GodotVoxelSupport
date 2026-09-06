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

# 符号可见性: GDExtension 只需导出入口函数(GDE_EXPORT 已标记 default 可见性)。
# 隐藏其余符号 —— 必须放在 add_subdirectory(godot-cpp) 之前:
# godot-cpp 是静态库, 符号可见性在编译期烙进 .o, 目录级变量会被子目录继承。
# 若不隐藏, godot-cpp 的内联 weak 符号(如 DefaultAllocator::alloc)会被多个
# 扩展 dylib 各自导出, macOS 动态链接器做符号抢占(interposing):
# 某个扩展加载失败(入口符号缺失等)后, 其未初始化的副本会抢占后续扩展的符号,
# 导致后者调用到空函数指针(EXC_BAD_ACCESS at 0x0, 崩在 _bind_methods 分配内存处)。
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

# 引入 godot-cpp（其 CMake 通过 GODOTCPP_API_VERSION 选择对应 extension_api.json）
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/godot-cpp ${CMAKE_CURRENT_BINARY_DIR}/godot-cpp)

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
# （.gdextension 引用路径为 res://addons/VoxelSupport/Native/xxx，产物落盘即到位，无需手动复制）
# 产物命名交给 GDExtensionRebuild(项目→工具)统一改名为 .gdextension 声明的规范名
# (<名>.<平台>.<类型>.<架构>.<ext>)；CMake 只负责直出默认名：
#   Windows: voxelnative.dll / macOS: libvoxelnative.dylib / Linux: libvoxelnative.so
# 注意：不经工具的裸 cmake 构建，产物名未经规范命名，交付前需跑一次工具（或手动改名）。
# Windows 必须显式去前缀：MSVC 默认无前缀，但 MinGW/GCC 的 CMake 会默认加 "lib"
# （CMAKE_SHARED_LIBRARY_PREFIX=lib），直出 libvoxelnative.dll 与工具约定的默认名
# voxelnative.dll 不符 → 部署分支误判（旧库被当新产物、新产物被当残留清理）。
# macOS/Linux 需保留默认 "lib" 前缀（与 .gdextension 条目匹配），故不设置 PREFIX ""。
if(WIN32)
    set_target_properties(voxelnative PROPERTIES PREFIX "")
endif()
set_target_properties(voxelnative PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../addons/VoxelSupport/Native
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../addons/VoxelSupport/Native
    ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../addons/VoxelSupport/Native
)
# 由 DEVFramework 生成: 每个原生插件一个 target, 共用一份 godot-cpp 构建
cmake_minimum_required(VERSION 3.17)

project(dev_native LANGUAGES CXX)

if(NOT DEFINED GODOTCPP_API_VERSION)
	set(GODOTCPP_API_VERSION "4.7")
endif()

# 多扩展同进程加载: 必须隐藏非入口符号, 否则 godot-cpp 的 inline weak 符号会互相抢占
# (interposing), 表现为某个扩展把另一个扩展的函数指针覆盖成空 → 崩在 _bind_methods。
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

# 性能: 本机构建开 -march=native(允许自动向量化); fp 融合关掉, 保证与 GDScript 结果 bit 级一致
if(NOT MSVC)
	add_compile_options(-ffp-contract=off)
	if(NOT CMAKE_OSX_ARCHITECTURES MATCHES ";")
		add_compile_options(-march=native)
	endif()
endif()

add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/godot-cpp ${CMAKE_CURRENT_BINARY_DIR}/godot-cpp)

# ---- devframework ----
include(${CMAKE_CURRENT_SOURCE_DIR}/generated/devframework_sources.cmake)
# 工程自带 register_types.cpp, 入口由它提供
add_library(devframework SHARED ${DEVFRAMEWORK_SOURCES})
target_link_libraries(devframework PRIVATE godot-cpp)
set_target_properties(devframework PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON)
if(NOT MSVC)
	target_compile_options(devframework PRIVATE -ffp-contract=off)
endif()
# 产物直出到该插件自己的 Native 目录(声明就在旁边, 引擎直接加载)
set_target_properties(devframework PROPERTIES
	LIBRARY_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../addons/DEVFramework/Native
	RUNTIME_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../addons/DEVFramework/Native
	ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../addons/DEVFramework/Native
)

# ---- voxelsupport ----
include(${CMAKE_CURRENT_SOURCE_DIR}/generated/voxelsupport_sources.cmake)
# 工程自带 register_types.cpp, 入口由它提供
add_library(voxelsupport SHARED ${VOXELSUPPORT_SOURCES})
target_link_libraries(voxelsupport PRIVATE godot-cpp)
set_target_properties(voxelsupport PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON)
if(NOT MSVC)
	target_compile_options(voxelsupport PRIVATE -ffp-contract=off)
endif()
# 产物直出到该插件自己的 Native 目录(声明就在旁边, 引擎直接加载)
set_target_properties(voxelsupport PROPERTIES
	LIBRARY_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../addons/VoxelSupport/Native
	RUNTIME_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../addons/VoxelSupport/Native
	ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../addons/VoxelSupport/Native
)


@tool
class_name NativeScaffold
extends RefCounted

## 原生工程骨架自动生成 —— 目标是"项目里只要有 gdextension/src/*.cpp, 构建脚本就能跑起来"。
##
## 自动补齐四样东西(缺什么补什么, 从不覆盖用户已有文件):
##   1. godot-cpp          : 优先 git submodule, 退化浅克隆
##   2. CMakeLists.txt     : 与官方模板同款的 add_subdirectory + add_library
##   3. generated/*        : sources.cmake(源文件清单) + register_types.cpp(扫描 GDCLASS 自动注册)
##   4. *.gdextension      : [libraries] 按平台/架构写好, entry_symbol 指向生成的入口
##
## 生成的每个文件都带 "由 DEVFramework 生成" 标记: 删掉它下次构建会重新生成;
## 手写过 CMakeLists.txt 的项目(没这个标记)完全不受影响 —— 这一步只补缺失项。
##
## 为什么必须生成 register_types.cpp: GDExtension 的入口要求显式 `GDREGISTER_CLASS(X)`,
## 引擎不会自动发现类。扫描源码里的 `GDCLASS(X, ...)` 生成注册表, 是"零配置"唯一可行路径。

const MARKER := "由 DEVFramework 生成"
const GEN_DIR := "generated"


# ============================================================
# 纯渲染函数(无副作用, 可单测)
# ============================================================

## 列出的源文件 -> generated/sources.cmake
static func render_sources_cmake(rel_paths: PackedStringArray) -> String:
	var out := "# %s: gdextension/src 下的全部 C++ 源文件(每次构建刷新, 请勿手改)\n" % MARKER
	out += "set(DEV_SOURCES\n"
	for p in rel_paths:
		out += "\t\"${CMAKE_CURRENT_SOURCE_DIR}/%s\"\n" % p
	out += ")\n"
	return out


## 扫描到的类 -> generated/register_types.cpp
## [param classes] 每项 {name, header(相对 gdextension/ 的路径, 可为空)}
## [param target] 目标名, 入口符号为 `<target>_library_init`(与 .gdextension 的 entry_symbol 对应)
static func render_register_types(classes: Array, target: String, api_hint := "") -> String:
	var out := "// %s: 扫描 src/** 里的 GDCLASS(...) 自动注册(构建时刷新, 请勿手改)\n" % MARKER
	if api_hint != "":
		out += "// godot-cpp API: %s\n" % api_hint
	out += "#include <godot_cpp/core/class_db.hpp>\n#include <godot_cpp/godot.hpp>\n\n"
	var included := {}
	for c in classes:
		var header := String(c.get("header", ""))
		if header != "" and not included.has(header):
			included[header] = true
			out += "#include \"%s\"\n" % header
	out += "\nusing namespace godot;\n\n"
	out += "static void %s_initialize(ModuleInitializationLevel p_level) {\n" % target
	out += "\tif (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {\n\t\treturn;\n\t}\n"
	if classes.is_empty():
		out += "\t// 没有扫描到任何 GDCLASS(...): 库可以构建, 但不会向引擎注册任何类\n"
	for c in classes:
		out += "\tGDREGISTER_CLASS(%s);\n" % String(c.get("name", ""))
	out += "}\n\n"
	out += "static void %s_uninitialize(ModuleInitializationLevel p_level) {\n" % target
	out += "\tif (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {\n\t\treturn;\n\t}\n}\n\n"
	out += "extern \"C\" {\n"
	out += "GDExtensionBool GDE_EXPORT %s_library_init(\n" % target
	out += "\t\tGDExtensionInterfaceGetProcAddress p_get_proc_address, GDExtensionClassLibraryPtr p_library,\n"
	out += "\t\tGDExtensionInitialization *r_initialization) {\n"
	out += "\tgodot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);\n"
	out += "\tinit_obj.register_initializer(%s_initialize);\n" % target
	out += "\tinit_obj.register_terminator(%s_uninitialize);\n" % target
	out += "\tinit_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);\n"
	out += "\treturn init_obj.init();\n}\n}\n"
	return out


## 生成的 CMakeLists.txt: 与官方模板同款结构, 只做"编成共享库并直出到 Native 目录"。
## [param with_generated_entry] false 表示用户自带 src/register_types.cpp, 不再挂生成的入口。
static func render_cmake(target: String, api_default: String, with_generated_entry := true) -> String:
	var up := target.to_upper()
	var out := "# %s: 本文件缺失时自动重建; 想完全接管构建, 删掉这行注释即可(不会再被覆盖)\n" % MARKER
	out += "cmake_minimum_required(VERSION 3.17)\n\n"
	out += "project(%s LANGUAGES CXX)\n\n" % target
	out += "if(NOT DEFINED GODOTCPP_API_VERSION)\n\tset(GODOTCPP_API_VERSION \"%s\")\nendif()\n\n" % api_default
	out += "add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/godot-cpp ${CMAKE_CURRENT_BINARY_DIR}/godot-cpp)\n\n"
	out += "include(${CMAKE_CURRENT_SOURCE_DIR}/%s/sources.cmake)\n" % GEN_DIR
	if with_generated_entry:
		out += "add_library(%s SHARED ${DEV_SOURCES} ${CMAKE_CURRENT_SOURCE_DIR}/%s/register_types.cpp)\n\n" % [target, GEN_DIR]
	else:
		out += "# 工程自带 src/register_types.cpp, 入口由它提供\n"
		out += "add_library(%s SHARED ${DEV_SOURCES})\n\n" % target
	out += "target_link_libraries(%s PRIVATE godot-cpp)\n" % target
	out += "set_target_properties(%s PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON)\n\n" % target
	out += "# 浮点语义与引擎一致(引擎未开 FMA 融合), 保证 C++ 与 GDScript 结果对齐\n"
	out += "if(NOT MSVC)\n\ttarget_compile_options(%s PRIVATE -ffp-contract=off)\nendif()\n\n" % target
	out += "# 产物直出到框架的 Native 目录(部署/声明同步都基于这个目录)\n"
	out += "# 本文件在 addons/DEVFramework/NativeSrc/ 下, 所以产物目录是 ../../Native\n"
	out += "set_target_properties(%s PROPERTIES\n" % target
	out += "\tLIBRARY_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../../Native\n"
	out += "\tRUNTIME_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../../Native\n"
	out += "\tARCHIVE_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../../Native\n)\n"
	return out


## 单组件多插件: 一个 CMakeLists 里**每个插件一个 target**, 共用一次 godot-cpp 构建。
## 这就是"项目里有多个插件都带 C++"的模型:
##   addons/A/Native/src -> libA + A.gdextension
##   addons/B/Native/src -> libB + B.gdextension
## godot-cpp 只 add_subdirectory 一次(编一次), N 个 target 链同一个库。
## [param plugins] 每项 {target, src_res, native_res}(res:// 绝对路径)
static func render_cmake_multi(plugins: Array, api_default: String) -> String:
	var out := "# %s: 每个原生插件一个 target, 共用一份 godot-cpp 构建\n" % MARKER
	out += "cmake_minimum_required(VERSION 3.17)\n\n"
	out += "project(dev_native LANGUAGES CXX)\n\n"
	out += "if(NOT DEFINED GODOTCPP_API_VERSION)\n\tset(GODOTCPP_API_VERSION \"%s\")\nendif()\n\n" % api_default
	out += "# 多扩展同进程加载: 必须隐藏非入口符号, 否则 godot-cpp 的 inline weak 符号会互相抢占\n"
	out += "# (interposing), 表现为某个扩展把另一个扩展的函数指针覆盖成空 → 崩在 _bind_methods。\n"
	out += "set(CMAKE_CXX_VISIBILITY_PRESET hidden)\nset(CMAKE_VISIBILITY_INLINES_HIDDEN ON)\n\n"
	out += "# 性能: 本机构建开 -march=native(允许自动向量化); fp 融合关掉, 保证与 GDScript 结果 bit 级一致\n"
	out += "if(NOT MSVC)\n"
	out += "\tadd_compile_options(-ffp-contract=off)\n"
	out += "\tif(NOT CMAKE_OSX_ARCHITECTURES MATCHES \";\")\n\t\tadd_compile_options(-march=native)\n\tendif()\n"
	out += "endif()\n\n"
	out += "add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/godot-cpp ${CMAKE_CURRENT_BINARY_DIR}/godot-cpp)\n\n"
	for p in plugins:
		var t := String(p.get("target", ""))
		if t == "":
			continue
		var src_res := String(p.get("src_res", ""))
		var native_res := String(p.get("native_res", ""))
		out += "# ---- %s ----\n" % t
		out += "include(${CMAKE_CURRENT_SOURCE_DIR}/%s/%s_sources.cmake)\n" % [GEN_DIR, t]
		out += "add_library(%s SHARED ${%s_SOURCES} ${CMAKE_CURRENT_SOURCE_DIR}/%s/%s_register_types.cpp)\n" % [t, t.to_upper(), GEN_DIR, t]
		out += "target_link_libraries(%s PRIVATE godot-cpp)\n" % t
		out += "set_target_properties(%s PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON)\n" % t
		out += "if(NOT MSVC)\n\ttarget_compile_options(%s PRIVATE -ffp-contract=off)\nendif()\n" % t
		out += "if(WIN32)\n\tset_target_properties(%s PROPERTIES PREFIX \"\")\nendif()\n" % t
		out += "# 产物直出到该插件自己的 Native 目录(声明就在旁边, 引擎直接加载)\n"
		out += "set_target_properties(%s PROPERTIES\n" % t
		for kind in ["LIBRARY", "RUNTIME", "ARCHIVE"]:
			out += "\t%s_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/..%s\n" % [kind, native_res]
		out += ")\n\n"
		if src_res == "":
			out += "# 警告: 该插件未提供源码目录\n\n"
	return out


## 单个插件的源清单: 本文件在 gdextension/generated/, 所以用 ../<插件 Native/src> 定位。
static func render_plugin_sources(target: String, rel_paths: PackedStringArray, src_res: String) -> String:
	var out := "# %s: %s 的源文件清单(每次构建刷新, 请勿手改)\n" % [MARKER, target]
	out += "set(%s_SOURCES\n" % target.to_upper()
	for p in rel_paths:
		out += "\t\"${CMAKE_CURRENT_SOURCE_DIR}/..%s/%s\"\n" % [src_res, p]
	return out + ")\n"


## 跨插件类名冲突: 两个 GDCLASS 同名会让引擎在加载时报难以定位的错, 这里提前判出。
## 返回 [{name, targets: [a, b]}]
static func find_class_conflicts(plugins: Array) -> Array:
	var by_class := {}
	for p in plugins:
		for c in p.get("classes", []):
			var cn := String(c.get("name", ""))
			if cn == "":
				continue
			if not by_class.has(cn):
				by_class[cn] = []
			by_class[cn].append(String(p.get("target", "")))
	var out: Array = []
	for cn in by_class:
		var owners: Array = by_class[cn]
		if owners.size() > 1:
			out.append({"name": cn, "targets": owners})
	return out


## 生成的 .gdextension: 三个平台的 [libraries] 都按规范名写好, 没构建的平台键暂时指向不存在的文件。
static func render_gdextension(target: String) -> String:
	var out := "; %s\n\n[configuration]\n\n" % MARKER
	out += "entry_symbol = \"%s_library_init\"\n" % target
	out += "compatibility_minimum = \"4.3\"\n\n[libraries]\n\n"
	out += "macos.debug = \"res://addons/DEVFramework/Native/lib%s.macos.debug.universal.dylib\"\n" % target
	out += "macos.release = \"res://addons/DEVFramework/Native/lib%s.macos.release.universal.dylib\"\n" % target
	out += "windows.debug.x86_64 = \"res://addons/DEVFramework/Native/%s.windows.debug.x86_64.dll\"\n" % target
	out += "windows.release.x86_64 = \"res://addons/DEVFramework/Native/%s.windows.release.x86_64.dll\"\n" % target
	out += "linux.debug.x86_64 = \"res://addons/DEVFramework/Native/lib%s.linux.debug.x86_64.so\"\n" % target
	out += "linux.release.x86_64 = \"res://addons/DEVFramework/Native/lib%s.linux.release.x86_64.so\"\n" % target
	return out


# ============================================================
# 扫描
# ============================================================

## 递归列出指定后缀的文件(相对 root_abs 的路径, 用 / 分隔)。
## ⚠ 顶层必须跳过这几类目录:
##   - generated/ : 自动生成的源, 扫进来会让 register_types.cpp 编译两次, 且清单永远不幂等;
##   - godot-cpp/ : 绑定库自己的源码(实测 36 个 .cpp / 14 个 GDCLASS), 扫进来会一起编进我们的库;
##   - build/ bin/ : 构建产物目录。
const SKIP_TOP_DIRS := ["generated", "godot-cpp", "build", "bin"]

static func scan_files(root_abs: String, exts: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	var stack: Array[String] = [root_abs]
	while not stack.is_empty():
		var dir_path: String = stack.pop_back()
		var d := DirAccess.open(dir_path)
		if d == null:
			continue
		d.list_dir_begin()
		var name := d.get_next()
		while name != "":
			if name.begins_with(".") or (dir_path == root_abs and SKIP_TOP_DIRS.has(name)):
				name = d.get_next()
				continue
			var full := dir_path.path_join(name)
			if d.current_is_dir():
				stack.append(full)
			elif exts.has(name.get_extension()):
				out.append(full.substr(root_abs.length() + 1).replace("\\", "/"))
			name = d.get_next()
		d.list_dir_end()
	out.sort()
	return out


## 只列源文件(.cpp/.cc/.cxx) —— 参与编译的那些
static func scan_sources(root_abs: String) -> PackedStringArray:
	return scan_files(root_abs, PackedStringArray(["cpp", "cc", "cxx"]))


## 扫描文件里的 `GDCLASS(Name, Base)` -> [{name, header, file}]
## header 优先取同目录同名 .h/.hpp(Godot 约定: GDCLASS 写在类声明头文件里)
static func scan_gdclasses(root_abs: String, rel_files: PackedStringArray) -> Array:
	var re := RegEx.new()
	re.compile("GDCLASS\\s*\\(\\s*([A-Za-z_][A-Za-z0-9_]*)")
	var out: Array = []
	var seen := {}
	for rel in rel_files:
		var text := FileAccess.get_file_as_string(root_abs.path_join(rel))
		if text.is_empty():
			continue
		for m in re.search_all(text):
			var cname := m.get_string(1)
			if seen.has(cname):
				continue
			seen[cname] = true
			out.append({"name": cname, "header": _header_for(root_abs, rel), "file": rel})
	return out


static func _header_for(root_abs: String, rel: String) -> String:
	var dir := rel.get_base_dir()
	var base := rel.get_file().get_basename()
	for ext: String in ["h", "hpp"]:
		var cand: String = rel.get_basename() + "." + ext
		if FileAccess.file_exists(root_abs.path_join(cand)):
			return cand
	# 类声明常在同名头文件里; 也接受同目录唯一的头
	var d := DirAccess.open(root_abs.path_join(dir))
	if d == null:
		return ""
	var headers := PackedStringArray()
	for f in d.get_files():
		if f.get_extension() in ["h", "hpp"]:
			headers.append(dir.path_join(f))
	if headers.size() == 1:
		return headers[0]
	return ""


# ============================================================
# 落地(只补缺失项)
# ============================================================

## 确保 [param root_abs](gdextension/ 的绝对路径) 具备可构建骨架。
## 返回 {created: Array[String], skipped: Array[String], sources: int, classes: int}
static func ensure(root_abs: String, target: String, api_default: String,
		fetch_deps := true, log_fn := Callable()) -> Dictionary:
	var created: Array[String] = []
	var skipped: Array[String] = []
	var src_dir := root_abs.path_join("src")
	if not DirAccess.dir_exists_absolute(src_dir):
		return {"created": created, "skipped": ["no src/"], "sources": 0, "classes": 0}
	var sources := scan_sources(root_abs)
	if sources.is_empty():
		return {"created": created, "skipped": ["no cpp"], "sources": 0, "classes": 0}
	# GDCLASS 写在类声明头文件里, 所以扫描要连头文件一起(只把 .cpp 传进去会一个类都找不到)
	var scan_targets := scan_files(root_abs, PackedStringArray(["cpp", "cc", "cxx", "h", "hpp"]))

	if fetch_deps:
		if FileAccess.file_exists(root_abs.path_join("godot-cpp/SConstruct")):
			skipped.append("godot-cpp")
		elif _fetch_godot_cpp(root_abs, log_fn):
			created.append("godot-cpp")
		else:
			skipped.append("godot-cpp(失败)")

	var classes := scan_gdclasses(root_abs, scan_targets)
	# 用户自带入口(手写 src/register_types.cpp)时不再生成, 否则同一入口符号定义两次
	var gen_entry := not FileAccess.file_exists(root_abs.path_join("src/register_types.cpp"))

	# CMakeLists: 只有"完全没有"或"是本工具生成的"才写 —— 手写的一律不动
	var cmake_path := root_abs.path_join("CMakeLists.txt")
	var write_cmake := true
	if FileAccess.file_exists(cmake_path):
		write_cmake = FileAccess.get_file_as_string(cmake_path).contains(MARKER)
	if write_cmake:
		if _write_if_changed(cmake_path, render_cmake(target, api_default, gen_entry)):
			created.append("CMakeLists.txt")
		# generated/* 只服务于"我们接管了构建"的工程: 手写 CMakeLists 的项目不产生无用文件
		var gen_dir := root_abs.path_join(GEN_DIR)
		DirAccess.make_dir_recursive_absolute(gen_dir)
		if _write_if_changed(gen_dir.path_join("sources.cmake"), render_sources_cmake(sources)):
			created.append(GEN_DIR + "/sources.cmake")
		if gen_entry and _write_if_changed(gen_dir.path_join("register_types.cpp"), render_register_types(classes, target, api_default)):
			created.append(GEN_DIR + "/register_types.cpp")
	else:
		skipped.append("CMakeLists.txt(手写, 不接管)")
	return {"created": created, "skipped": skipped, "sources": sources.size(), "classes": classes.size()}


## 发现项目里**所有**带原生源码的插件: addons/<Plugin>/Native/src/**.cpp
## target 名取插件内已有 *.gdextension 的文件名(它是入口符号与产物名的来源), 没有则用小写插件名。
static func discover_plugins(project_abs: String) -> Array:
	var out: Array = []
	var d := DirAccess.open(project_abs.path_join("addons"))
	if d == null:
		return out
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if d.current_is_dir() and not name.begins_with("."):
			var native_abs := project_abs.path_join("addons").path_join(name).path_join("Native")
			var src_abs := native_abs.path_join("src")
			if DirAccess.dir_exists_absolute(src_abs) and not scan_sources(src_abs).is_empty():
				out.append({
					"plugin": name,
					"target": _plugin_target(native_abs, name),
					"src_abs": src_abs,
					"native_abs": native_abs,
				})
		name = d.get_next()
	d.list_dir_end()
	return out


static func _plugin_target(native_abs: String, plugin: String) -> String:
	var d := DirAccess.open(native_abs)
	if d != null:
		d.list_dir_begin()
		var f := d.get_next()
		while f != "":
			if not d.current_is_dir() and f.get_extension() == "gdextension":
				var t := f.get_basename()
				d.list_dir_end()
				return t
			f = d.get_next()
		d.list_dir_end()
	var clean := ""
	for ch in plugin.to_lower():
		clean += ch if ch.is_valid_identifier() or ch.is_valid_int() else "_"
	return clean if clean != "" else "native"


## 多插件工程落地: gdextension/(godot-cpp + 生成的 CMakeLists) + 每插件一份 generated/* 与 *.gdextension。
## 插件源码始终留在各插件的 Native/src(随插件分发), 构建区与第三方留在项目根。
static func ensure_project(project_abs: String, api_default: String, fetch_deps := true,
		log_fn := Callable()) -> Dictionary:
	var plugins := discover_plugins(project_abs)
	var created: Array[String] = []
	if plugins.is_empty():
		return {"created": created, "plugins": [], "conflicts": []}
	var build_abs := project_abs.path_join("gdextension")
	if fetch_deps and not FileAccess.file_exists(build_abs.path_join("godot-cpp/SConstruct")):
		if _fetch_godot_cpp(build_abs, log_fn):
			created.append("gdextension/godot-cpp")
	# CMakeLists 只接管"我们自己生成的"那一份: 手写的构建配置一律不动(也就不生成配套的 generated/*)
	var cmake_path := build_abs.path_join("CMakeLists.txt")
	var own := true
	if FileAccess.file_exists(cmake_path):
		own = FileAccess.get_file_as_string(cmake_path).contains(MARKER)
	var gen_abs := build_abs.path_join(GEN_DIR)
	if own:
		DirAccess.make_dir_recursive_absolute(gen_abs)

	var cmake_plugins: Array = []
	for p in plugins:
		var target := String(p["target"])
		var src_abs := String(p["src_abs"])
		var native_abs := String(p["native_abs"])
		var src_res := _res_rel(project_abs, src_abs)
		var native_res := _res_rel(project_abs, native_abs)
		var classes := scan_gdclasses(src_abs,
				scan_files(src_abs, PackedStringArray(["cpp", "cc", "cxx", "h", "hpp"])))
		p["classes"] = classes
		p["src_res"] = src_res
		p["native_res"] = native_res
		if own:
			if _write_if_changed(gen_abs.path_join("%s_sources.cmake" % target),
					render_plugin_sources(target, scan_sources(src_abs), src_res)):
				created.append("%s/%s_sources.cmake" % [GEN_DIR, target])
			if _write_if_changed(gen_abs.path_join("%s_register_types.cpp" % target),
					render_register_types(classes, target, api_default)):
				created.append("%s/%s_register_types.cpp" % [GEN_DIR, target])
		# src/ 加 .gdignore: 源码不必进编辑器面板(也不该被当资源扫)。注意只能加在 src/ 子目录,
		# Native/ 本身不能加 —— .gdextension 与 dll 就在那里, 编辑器忽略后引擎可能加载不到扩展。
		var gi := src_abs.path_join(".gdignore")
		if not FileAccess.file_exists(gi):
			var gf := FileAccess.open(gi, FileAccess.WRITE)
			if gf != null:
				gf.close()
				created.append("%s/Native/src/.gdignore" % String(p["plugin"]))
		if ensure_gdextension(native_abs, target):
			created.append("%s/Native/%s.gdextension" % [String(p["plugin"]), target])
		cmake_plugins.append({"target": target, "src_res": src_res, "native_res": native_res})

	if own and _write_if_changed(cmake_path, render_cmake_multi(cmake_plugins, api_default)):
		created.append("gdextension/CMakeLists.txt")
	return {"created": created, "plugins": plugins, "conflicts": find_class_conflicts(plugins)}


## 绝对路径 -> "/addons/X/Native/src" 形式(供 CMake 用 ${CMAKE_CURRENT_SOURCE_DIR}/.. 拼)
static func _res_rel(project_abs: String, abs_path: String) -> String:
	return "/" + abs_path.replace(project_abs, "").replace("\\", "/").trim_prefix("/")


## 部署目录里的 *.gdextension: 缺失时按规范名生成(已有文件不碰, 由构建工具负责同步)
static func ensure_gdextension(native_abs: String, target: String) -> bool:
	var path := native_abs.path_join(target + ".gdextension")
	if FileAccess.file_exists(path):
		return false
	DirAccess.make_dir_recursive_absolute(native_abs)
	return _write_if_changed(path, render_gdextension(target))


static func _write_if_changed(path: String, text: String) -> bool:
	# FileTool.atomic_write_text 会保留编码, 避免中文注释被写坏
	if FileAccess.file_exists(path) and FileAccess.get_file_as_string(path) == text:
		return false
	FileTool.atomic_write_text(path, text)
	return true


## godot-cpp 获取: 先试 submodule(不动用户工作树), 退化浅克隆(需要 git + 网络)
static func _fetch_godot_cpp(root_abs: String, log_fn: Callable) -> bool:
	var gcpp := root_abs.path_join("godot-cpp")
	var out: Array = []
	_note(log_fn, "godot-cpp 未就绪, 尝试 git submodule …")
	# 子模块路径要相对**项目根**(git 的 cwd), 不是相对 gdextension 目录
	var proj_root := ProjectSettings.globalize_path("res://").simplify_path()
	var rel := root_abs.simplify_path().replace(proj_root, "").trim_prefix("/").path_join("godot-cpp")
	if OS.execute("git", ["-C", proj_root, "submodule", "update",
			"--init", "--recursive", rel], out) == 0 \
			and FileAccess.file_exists(gcpp.path_join("SConstruct")):
		_note(log_fn, "已通过 git submodule 获取 godot-cpp。")
		return true
	if DirAccess.dir_exists_absolute(gcpp) and DirAccess.open(gcpp) != null and DirAccess.open(gcpp).get_files().is_empty():
		DirAccess.remove_absolute(gcpp)   # 空目录挡路: 清掉再克隆
	_note(log_fn, "回退为浅克隆 godot-cpp(需要网络)…")
	if OS.execute("git", ["clone", "--depth", "1", "https://github.com/godotengine/godot-cpp", gcpp], out) != 0:
		_note(log_fn, "自动获取失败: 请手动 `git submodule add https://github.com/godotengine/godot-cpp gdextension/godot-cpp`。")
		for line in out:
			_note(log_fn, String(line))
		return false
	_note(log_fn, "已克隆 godot-cpp(浅克隆, 后续由构建工具对齐版本)。")
	return true


static func _note(log_fn: Callable, msg: String) -> void:
	if log_fn.is_valid():
		log_fn.call(msg)

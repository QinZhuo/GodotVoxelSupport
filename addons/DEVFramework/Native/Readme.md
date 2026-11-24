# Native C++ 原生扩展与共享库

整个框架的 C++ 能力集中在一个共享扩展（`devframework`）里：GDScript 侧统一经 `FrameworkNative` 懒加载、校验方法齐备，再拿原生对象。
缺库、缺方法、实例化失败一律 `push_error` 并返回 null，没有静默回退——框架强依赖这个二进制。

## 怎么用

| 路径 | 职责 |
|---|---|
| `Native/FrameworkNative.gd` | 唯一的 GDScript 入口：懒加载、类/方法存在性校验、实例缓存 |
| `Native/devframework.gdextension` | 扩展描述：`entry_symbol` 与各平台产物路径 |
| `Native/src/register_types.cpp` | 注册原生类（`GDREGISTER_CLASS`），只在 SCENE 初始化层生效 |
| `Native/src/ecs_core.h` | `ECSCore` 的 C++ 实现（SoA 列存储） |
| `gdextension/` | 构建区：CMakeLists、godot-cpp、`generated/`；源码目录是各插件的 `<plugin>/Native/src` |

```gdscript
if not FrameworkNative.is_extension_loaded(&"ECSCore"):
	return null

var core := FrameworkNative.get_native(&"ECSCore", [
	&"create_entity", &"add_component", &"query_rows",
])                                              # 缺库/缺方法都会 push_error 并返回 null
if core == null:
	return null                                 # 别在这里继续调方法

FrameworkNative.refresh(&"ECSCore")             # 只清掉某个类的缓存
FrameworkNative.refresh_all()                   # 换库 / 重编后全清
```

```gdscript
var obj: Variant = FrameworkNative.instantiate_script(some_script)   # 规避全局类注册时序
```

构建链：编辑器侧会用 `NativeScaffold` 补齐四件套（godot-cpp 浅克隆、`CMakeLists.txt`、`generated/*`、`*.gdextension`），`GDExtensionRebuild` 负责真编译并把产物部署回插件自己的 `Native/` 目录。生成文件都带"由 DEVFramework 生成"标记、从不覆盖用户文件；项目设置键都在 `dev_framework/gdextension_build/` 下（`auto_update_submodule` / `auto_reload_editor` / `sync_gdextension` / `cross_archs` / `stall_auto_kill` / `hard_timeout_sec` / `build_jobs` / `build_types`）。

## 坑

1. `Native/` 目录禁止移动或改名：`.gdextension` 的 `[libraries]` 是相对它的 `res://` 绝对路径，`FrameworkNative.NATIVE_EXTENSION_PATH` 也硬编码为 `res://addons/DEVFramework/Native/devframework.gdextension`。
2. 改完 `Native/src/**` 必须重新构建，否则跑的是旧库而且不会报任何错；Windows 上编辑器进程会锁住 dll，部署会退化成改写 `.gdextension` 指向新产物，必须重载编辑器才真正生效。
3. 别手动清 `Native/` 里以 `~` 开头的文件当垃圾：`~lib...` 是引擎运行期把扩展库复制成 `~原名` 再加载的产物，被进程占用删不掉，清理逻辑把它判为非垃圾、不算失败，重启编辑器后可清；枚举这类残留必须开 `dir.include_hidden = true`（Windows 的 ReplaceFile 残留带 hidden 属性，默认枚举看不到）。目录里现有的 `~libdevframework.windows.release.x86_64.dll` 与一批 `~RF*.TMP` 就属这类。
4. `debug` 条目实际指向 release 产物（`windows.debug` / `macos.debug` 都写的是 release 文件名），所以用 debug 模板跑也拿不到带调试符号的库；`linux` 两个条目已声明，但目录里没有对应 `.so`。
5. 失败是 `push_error` 而不是警告：检查 `compatibility_minimum`（4.3）、`entry_symbol`（`devframework_library_init`）与产物是否匹配当前平台/架构，别用"能不能调通"来试错。
6. 类名与方法名是硬契约：GDScript 侧靠 `required_methods` 列表校验，改 C++ 方法签名不更新这份清单会在运行时炸；新增类必须写进 `register_types.cpp` 的 `GDREGISTER_CLASS`，否则 `ClassDB` 里根本没有。另外 `register_types.h` 里还留着旧入口声明 `initialize_dev_module`（与实际入口名不符），`gdextension/README.md` 描述的是旧布局，一律以源码和实际文件名为准。

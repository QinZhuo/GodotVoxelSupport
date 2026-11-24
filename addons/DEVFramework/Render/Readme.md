# Render 渲染特效与画面辅助

基于 `CompositorEffect` 的两个全屏后处理：`OutlineEffect` 做单色描边，`GLSLShaderEffect` 用一段 GLSL 改写颜色/深度。
场景侧提供 `SubView3D`（子视口贴到 3D 面并转发输入）、`Trail3D`（逐帧拖尾）、`DefMeshView`（Def 驱动网格）。
`Lightmap/` 负责烘焙光照的导出与运行时挂载，`Screenshot/` 是唯一的画面捕获管线。

## 怎么用

| 类 | 职责 |
|---|---|
| `OutlineEffect` | `set_outlined(on, ...meshes)`（固定槽位 0）/ `set_marked(on, ...meshes)`；`outline_color`、`outline_width`、`marker_slot` |
| `GLSLShaderEffect` | `define_code` + `main_code` 拼成计算着色器，逐像素改 `color` |
| `SubView3D` | `viewport` + `area`；`viewport_rect_to_screen(rect)` 把子视口矩形映射到屏幕 |
| `Trail3D` | `lifetime`、`min_vertex_distance`、`width_curve`、`color_gradient`、`alignment`、`texture_mode` |
| `AssetLightmapStage` | 编辑器烘焙舞台：收集网格、同步副本、`export_all()` 产出 `*_lightmap_set.res` |
| `AssetLightmapSet` | `current` / `attach` / `bind_to(mi)`；`BakedMeshInstance3D` 进树自动挂光 |
| `ScreenshotTool` | `capture(viewport, opts)` 取图→缩放→颜色归一→PNG，返回结果字典 |
| `ScreenshotCapture` | 窗口就绪后延迟自动截图的节点 |

```gdscript
# 描边：Compositor 上挂 OutlineEffect 实例（最多 3 个，marker_slot 不能重复）
OutlineEffect.set_outlined(true, $Body)   # 静态入口固定走槽位 0
$OutlineEffect.set_marked(false, $Body)   # 多实例时用实例入口

# 子视口贴面：把子视口里的 UI 矩形换算成屏幕矩形（4 角投影包围盒）
var screen_rect: Rect2 = $SubView3D.viewport_rect_to_screen(
	Rect2(Vector2.ZERO, Vector2($SubView3D.viewport.size)))
```

```gdscript
# 烘焙光：场景加载时换库，之后实例自己挂
AssetLightmapSet.current = load("res://some_lightmap_set.res")
$BakedMesh.apply_lightmap()
AssetLightmapSet.current.bind_to($OtherMesh)
BakedMeshInstance3D.set_strength(0.8)     # 运行中整体调亮度，不必重烘
```

```gdscript
var res: Dictionary = await ScreenshotTool.capture(get_viewport(), {
	"exact_size": Vector2i(1280, 720),
	"path": "user://shot.png",
})
if res.get("ok", false):
	print(res["path"], " ", res["color_mode"])
```

## 坑

1. `OutlineEffect` 只在被 `Compositor` 引用时才工作：`set_outlined()` 去找 `marker_slot == 0` 的实例，找不到直接 `push_error`。最多 3 个实例（`MARKER_ALPHAS`），槽位必须互不相同；描边开启中改 `marker_slot` 不会迁移已标记网格，只告警。
2. 描边靠 `material_overlay` 写 alpha 标记，视口没跑这个效果时标记会污染画面，框架会拒绝标记该网格。`Compositor` 资源通常被多个视口共用，实例状态跟着资源走，不同需求要各配一份。
3. `GLSLShaderEffect` 的 `main_code` 直接拼进计算着色器，可用的只有模板里已声明的符号：`color`、`depth`、`uv_norm`、`texel_size`、`get_normal_roughness(uv_norm)`；模板没有声明 `get_motion_vector()`，也没有绑定运动向量纹理，`needs_motion_vectors` 仅是声明标志。两个 `needs_*` 按 `define_code + main_code` 里是否出现对应函数名做子串匹配，只决定渲染器是否产出缓冲；写了模板没声明的函数会编译失败（`LogTool.error` 打出错误与源码），不会静默拿到空缓冲。`normal_roughness` 只在 forward_clustered / mobile / gl_compatibility 存在，取不到上下文时整段回调直接 `return`。
4. 烘焙光只处理不透明面且必须带 UV2：透明面、无材质面直接跳过（无材质会告警一次）。挂光方式是复制基材质并覆盖 `next_pass`，基材质自带的 `next_pass` 会被替换；`ShaderMaterial` 只按 `albedo_tex` / `albedo_tint` 两个约定 uniform 取色，取不到就用白。
5. 烘焙必须在编辑器里完成：灯要设为 `BAKE_STATIC`；`LightmapGI` 的 `Bake Directional` 会在导出时被自动打开（SH 叠加层需要方向数据）。导出靠模拟按检查器里的 `Bake Lightmaps` 按钮，headless 下没有按钮，无法烘焙。舞台副本的节点名就是资源键（文件名），改名等于换键。
6. `ScreenshotTool.grab()` 默认等 `RenderingServer.frame_post_draw`，可能让窗口短暂无响应或渲染停帧；编辑器入口改用 `await_draw: false` 并等 `process_frame`。`color_mode` 的 auto 按读回格式判定，8 位缓冲已是显示值，再补 sRGB 就是二次编码，不要手动给 `srgb: true`。

## 文件结构

Render/ 根目录是后处理与场景辅助；Lightmap/ 是编辑器烘焙 + 运行时挂光（Set 数据 / Region 图集位置 / Binder 材质副本 / BakedMeshInstance3D 自动挂载）；
Screenshot/ 只做捕获与落盘，`ScreenshotCapture` 是节点入口。

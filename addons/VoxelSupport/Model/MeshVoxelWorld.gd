@tool
class_name MeshVoxelWorld
extends RefCounted
## 网格快照 → `QVoxelWorld`。与 `VoxAssetWorld.to_world`（.vox → 世界）完全对位：
## 外部模型导入的产物就是一个**普通世界**，于是撤销 / 保存 .qvx / 导出 glTF / 编辑全部免费。
## 【为什么整个场景烘成一个模型】体素栅格只认一套坐标系；拆成多个模型就得各自归一化，
## 相对位置随即丢失。MagicaVoxel 的"一个对象 = 一块有界体素"也正是这个语义。
## 【多帧 = 体素帧动画】glTF 自带动画按帧采样后逐帧体素化，写进同一个模型的帧序列，
## 时间轴 / 播放预览 / 存盘全部复用现成的那条链。

## 场景 → 世界。`resolution` = 最长边的体素数；`fill` = true 实心 / false 只留表面壳。
## **协程**：多帧时每帧让出一帧（否则大模型的导入会把界面冻住），调用方要 `await`。
## `progress` 可选，签名 `(已完成帧, 总帧数)`；只在多帧时回调（单帧没有进度可言）。
## `cancel` 可选，返回 true 即放弃：**帧边界**上检查，逐帧 await 时最多多跑完当前这一帧。
## 为什么取消也返回 null（而不是报错）：调用方本来就分得清 —— 它自己置的取消标志还在，
## 由此决定提示"已取消"还是"体素化失败"。
static func to_world(scene: Dictionary, resolution := MeshVoxelizer.DEFAULT_RESOLUTION,
		fill := true, progress := Callable(), cancel := Callable()) -> QVoxelWorld:
	if scene.is_empty():
		return null
	var frames: Array = scene.get("frames", [])
	if frames.is_empty():
		return null
	var rast := MeshVoxelizer.frame_grid(scene, resolution)
	if rast.get("empty", true):
		return null
	var tree := Engine.get_main_loop() as SceneTree
	var palette := PackedByteArray()
	var datas: Array = []
	var filled := false
	for i in frames.size():
		if cancel.is_valid() and cancel.call():
			return null
		var res := MeshVoxelizer.voxelize_frame(scene, i, rast, fill, palette)
		if res.is_empty():
			datas.append(null)   # 该帧没有可用三角面：占位，保持帧序不错位
		else:
			if palette.is_empty():
				palette = res["palette"]   # 第 0 个成功的帧定调色板，后续帧复用以免颜色跳变
			datas.append(res["data"])
			filled = true
		if frames.size() > 1 and progress.is_valid():
			progress.call(i + 1, frames.size())
		if tree != null and i + 1 < frames.size():
			await tree.process_frame
	if not filled:
		return null
	var world := QVoxelWorld.create_empty()
	_install_palette(world, palette)
	var model := world.create_model(String(scene.get("name", "model")), rast["grid"], null)
	var animated := datas.size() > 1
	if animated:
		model.make_animated()
		for i in range(1, datas.size()):
			model.add_frame(QVoxelFrame.new())
		model.anim_fps = maxi(1, int(round(float(scene.get("fps", 12.0)))))
	for i in datas.size():
		var data: Variant = datas[i]
		if data == null:
			continue
		if animated:
			model.apply_frame_box(i, Vector3i.ZERO, rast["grid"], data)
		else:
			model.apply_box(Vector3i.ZERO, rast["grid"], data)
	model.compact()
	return world


## 调色板 → 世界材质表。原生返回值 = 调色板下标 + 1，恰好对上"材质 1 起、0 是空气"。
static func _install_palette(world: QVoxelWorld, palette: PackedByteArray) -> void:
	for i in int(palette.size() / 4):
		world.add_material(Color8(palette[i * 4], palette[i * 4 + 1],
				palette[i * 4 + 2], palette[i * 4 + 3]))

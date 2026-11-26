@tool
class_name MeshVoxelWorld
extends RefCounted
## 网格快照 → `QVoxelWorld`。

## 场景 → 世界。
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
		# 缺省 fps 取全仓唯一真值（QVoxelSpec.ANIM_FPS_DEFAULT），不再在这里写裸 12。
		model.anim_fps = maxi(1, int(round(float(scene.get("fps", float(QVoxelSpec.ANIM_FPS_DEFAULT))))))
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

## 调色板 → 世界材质表。
static func _install_palette(world: QVoxelWorld, palette: PackedByteArray) -> void:
	for i in int(palette.size() / 4):
		world.add_material(Color8(palette[i * 4], palette[i * 4 + 1],
				palette[i * 4 + 2], palette[i * 4 + 3]))

@tool
class_name MeshAccess
extends RefCounted
## 外部三维模型 → 统一网格快照。与 `VoxAccess`（.vox）对位：格式层只回答"字节 → 顶点"，
## 不认识体素世界。
## 【三种格式各走各的路，理由不同】
##   glTF/.glb：Godot 内核唯一自带**运行期**加载器（`GLTFDocument`），还有动画与蒙皮，故首选；
##   OBJ/STL：内核只有编辑器导入管线，运行期读不到 —— 格式本身足够简单，自己解析即可。
##   FBX/DAE/.blend 刻意不做：它们依赖编辑器那条管线（ufbx / 外部 Blender），
##   强行支持等于在应用里重造一个导入器，收益远小于"先转成 glTF"。
## 【产物的形状】一串**帧**，每帧一组**零件**（part = 一个 surface 的三角面 + 一个材质槽）。
## 网格原点与体素边长不在这里定 —— 体素化要求所有帧共用一套网格，故由 `MeshVoxelizer` 统一算。

const EXTENSIONS := ["glb", "gltf", "obj", "stl"]
## 动画采样帧率与帧数上限。体素帧动画本来只有 4~12 fps 的观感，采太密只是白烧内存。
const ANIM_FPS := 12.0
const MAX_FRAMES := 64
## 贴图长边上限（超过则等比缩小）：导入一张 4K 图只为取色，没必要按原样常驻。
const TEX_LIMIT := 1024


static func handles(path: String) -> bool:
	return path.get_extension().to_lower() in EXTENSIONS


## 载入外部模型。返回 `{name, frames: Array[{parts: Array[part], time: float}], animated: bool}`；
## 失败返回空字典。`host` 用于把临时场景挂进树（动画 seek / 骨骼求值必须有树），
## 传 null 时按节点自身的 `transform` 链推算。
static func load_scene(path: String, host: Node = null) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var ext := path.get_extension().to_lower()
	var out := {}
	match ext:
		"glb", "gltf":
			out = _load_gltf(path, host)
		"obj":
			out = _load_obj(path)
		"stl":
			out = _load_stl(path)
	if out.is_empty():
		return {}
	if String(out.get("name", "")).is_empty():
		out["name"] = path.get_file().get_basename()
	return out


# glTF / GLB

static func _load_gltf(path: String, host: Node) -> Dictionary:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(path, state) != OK:
		return {}
	var root := doc.generate_scene(state)
	if root == null:
		return {}
	var attached := host != null and host.is_inside_tree()
	if attached:
		if root is Node3D:
			(root as Node3D).visible = false
		host.add_child(root)
	var out := {"name": path.get_file().get_basename(), "frames": [], "animated": false}
	var player := _animation_player(root)
	var anim := _pick_animation(player)
	var times: Array = anim["times"]
	if player != null and not String(anim["name"]).is_empty():
		player.play(anim["name"])
		player.pause()
	var book := {"list": [], "map": {}}
	var frames: Array = out["frames"]
	for t: float in times:
		if player != null and not String(anim["name"]).is_empty():
			player.seek(t, true)
			_refresh_transforms(root)
		var parts: Array = []
		_collect_parts(root, parts, book)
		frames.append({"parts": parts, "time": t})
	out["animated"] = times.size() > 1
	out["slots"] = book["list"]
	if attached:
		root.queue_free()
	else:
		root.free()
	return out


static func _animation_player(root: Node) -> AnimationPlayer:
	for n in root.find_children("*", "AnimationPlayer", true, false):
		var ap := n as AnimationPlayer
		if ap != null and not ap.get_animation_list().is_empty():
			return ap
	return null


## 挑一条动画并**均匀采样一个周期**（不含末端：末帧与首帧同姿态，重复一帧只会白占内存）。
## 取最长的那条 —— 导入器有时会顺带生成长度 0 的 `RESET` 之类，取"第一条"会退化成一帧。
static func _pick_animation(player: AnimationPlayer) -> Dictionary:
	var best := ""
	var best_len := 0.0
	if player != null:
		for n in player.get_animation_list():
			var a := player.get_animation(n)
			if a != null and a.length > best_len and a.length > 0.001:
				best_len = a.length
				best = n
	if best.is_empty():
		return {"name": "", "times": [0.0]}
	var n := clampi(int(round(best_len * ANIM_FPS)), 2, MAX_FRAMES)
	var times: Array = []
	for k in n:
		times.append(best_len * float(k) / float(n))
	return {"name": best, "times": times}


static func _refresh_transforms(node: Node) -> void:
	if node is Node3D:
		(node as Node3D).force_update_transform()
	for c in node.get_children():
		_refresh_transforms(c)


static func _collect_parts(node: Node, out: Array, book: Dictionary) -> void:
	if node is ImporterMeshInstance3D:
		var im := node as ImporterMeshInstance3D
		var imesh := im.mesh
		if imesh != null:
			for i in imesh.get_surface_count():
				var part := _part_from(im, imesh.get_surface_arrays(i),
						imesh.get_surface_material(i), book)
				if not part.is_empty():
					out.append(part)
	elif node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var mesh := mi.mesh
		if mesh != null:
			for i in mesh.get_surface_count():
				var part := _part_from(mi, mesh.surface_get_arrays(i),
						mesh.surface_get_material(i), book)
				if not part.is_empty():
					out.append(part)
	for c in node.get_children():
		_collect_parts(c, out, book)


## 一个 surface → 零件：顶点烘焙到**世界空间**（含骨骼变形），并登记材质槽。
static func _part_from(node: Node3D, arrays: Array, mat: Material, book: Dictionary) -> Dictionary:
	if arrays.size() <= Mesh.ARRAY_VERTEX or arrays[Mesh.ARRAY_VERTEX] == null:
		return {}
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if verts.is_empty():
		return {}
	var idx := PackedInt32Array()
	if arrays[Mesh.ARRAY_INDEX] != null:
		idx = arrays[Mesh.ARRAY_INDEX]
	if idx.is_empty():
		idx.resize(verts.size())
		for i in verts.size():
			idx[i] = i
	var uvs := PackedVector2Array()
	if arrays[Mesh.ARRAY_TEX_UV] != null:
		uvs = arrays[Mesh.ARRAY_TEX_UV]
	var cols := PackedColorArray()
	if arrays[Mesh.ARRAY_COLOR] != null:
		cols = arrays[Mesh.ARRAY_COLOR]
	var posed := _skin_vertices(node, arrays, verts)
	var xf := node.global_transform
	var world := PackedVector3Array()
	world.resize(posed.size())
	for i in posed.size():
		world[i] = xf * posed[i]
	return {
		"verts": world,
		"indices": idx,
		"uvs": uvs,
		"colors": cols,
		"slot": _slot_index(mat, book),
	}


## CPU 蒙皮：`world = 节点变换 × Σ w·(骨骼全局姿态 × 绑定姿态逆) × v`。
## 无骨骼 / 压缩骨骼（4×uint32 打包格式）/ 权重缺失时原样返回，绝不产出歪掉的模型。
static func _skin_vertices(node: Node3D, arrays: Array, verts: PackedVector3Array) -> PackedVector3Array:
	var skin: Skin = null
	var skel: Skeleton3D = null
	if node is ImporterMeshInstance3D:
		var im := node as ImporterMeshInstance3D
		skin = im.skin
		if skin != null and not im.skeleton_path.is_empty():
			skel = node.get_node_or_null(im.skeleton_path) as Skeleton3D
	elif node is MeshInstance3D:
		var mi := node as MeshInstance3D
		skin = mi.skin
		if skin != null and not mi.skeleton.is_empty():
			skel = node.get_node_or_null(mi.skeleton) as Skeleton3D
	if skin == null or skel == null or skin.get_bind_count() <= 0:
		return verts
	if arrays[Mesh.ARRAY_BONES] == null or arrays[Mesh.ARRAY_WEIGHTS] == null:
		return verts
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	if bones.is_empty() or bones.size() % verts.size() != 0 or weights.size() != bones.size():
		return verts
	skel.force_update_all_bone_transforms()
	var bind_n := skin.get_bind_count()
	var mats: Array[Transform3D] = []
	for i in bind_n:
		var bone := skin.get_bind_bone(i)
		var pose := Transform3D.IDENTITY
		if bone >= 0 and bone < skel.get_bone_count():
			pose = skel.get_bone_global_pose(bone)
		mats.append(pose * skin.get_bind_pose(i))
	var per := bones.size() / verts.size()
	var out := PackedVector3Array()
	out.resize(verts.size())
	for vi in verts.size():
		var v := verts[vi]
		var acc := Vector3.ZERO
		var total := 0.0
		for k in per:
			var w := weights[vi * per + k]
			if w <= 0.0:
				continue
			var bi := bones[vi * per + k]
			if bi < 0 or bi >= bind_n:
				continue
			acc += (mats[bi] * v) * w
			total += w
		out[vi] = acc / total if total > 0.0001 else v
	return out


## 材质 → 槽下标（按实例去重：多 surface 共用一份贴图字节）。
static func _slot_index(mat: Material, book: Dictionary) -> int:
	var list: Array = book["list"]
	var map: Dictionary = book["map"]
	var key := 0 if mat == null else mat.get_instance_id()
	if map.has(key):
		return int(map[key])
	var slot := {"tex": PackedByteArray(), "size": Vector2i.ZERO, "color": Color.WHITE}
	if mat is BaseMaterial3D:
		var bm := mat as BaseMaterial3D
		slot["color"] = bm.albedo_color
		var tex := bm.albedo_texture
		if tex != null:
			var img := tex.get_image()
			if img != null:
				if img.is_compressed():
					img.decompress()
				img.convert(Image.FORMAT_RGBA8)
				var w := img.get_width()
				var h := img.get_height()
				if maxi(w, h) > TEX_LIMIT:
					var s := float(TEX_LIMIT) / float(maxi(w, h))
					img.resize(maxi(1, int(w * s)), maxi(1, int(h * s)),
							Image.INTERPOLATE_BILINEAR)
					w = img.get_width()
					h = img.get_height()
				slot["tex"] = img.get_data()
				slot["size"] = Vector2i(w, h)
	list.append(slot)
	map[key] = list.size() - 1
	return list.size() - 1


# OBJ / MTL

static func _load_obj(path: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return {}
	var pos: Array[Vector3] = []
	var uv: Array[Vector2] = []
	var materials := _load_mtl(path)
	var book := {"list": [], "map": {}}
	var groups := {}
	var current := ""
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var p := line.split(" ", false)
		if p.is_empty():
			continue
		match p[0]:
			"v":
				if p.size() >= 4:
					pos.append(Vector3(float(p[1]), float(p[2]), float(p[3])))
			"vt":
				if p.size() >= 3:
					# OBJ 的 V 原点在左下，图像在左上 —— 这里换成采样口径
					uv.append(Vector2(float(p[1]), 1.0 - float(p[2])))
			"usemtl":
				current = p[1] if p.size() > 1 else ""
			"f":
				_obj_face(p, pos, uv, _obj_group(groups, current))
	var parts: Array = []
	for name: String in groups:
		var g: Dictionary = groups[name]
		var idx: PackedInt32Array = g["indices"]
		if idx.is_empty():
			continue
		var mat: Material = materials.get(name, null)
		parts.append({
			"verts": g["verts"],
			"indices": idx,
			"uvs": g["uvs"],
			"colors": PackedColorArray(),
			"slot": _slot_index(mat, book),
		})
	if parts.is_empty():
		return {}
	return {"name": path.get_file().get_basename(),
			"frames": [{"parts": parts, "time": 0.0}], "animated": false,
			"slots": book["list"]}


static func _obj_group(groups: Dictionary, name: String) -> Dictionary:
	if not groups.has(name):
		groups[name] = {"verts": PackedVector3Array(), "uvs": PackedVector2Array(),
				"indices": PackedInt32Array(), "map": {}}
	return groups[name]


## 面 → 三角扇形。逐面无顶点复用（体素化只看三角面，去重收益为零）。
static func _obj_face(p: PackedStringArray, pos: Array[Vector3], uv: Array[Vector2],
		g: Dictionary) -> void:
	var fv: Array[int] = []
	var ft: Array[int] = []
	for k in range(1, p.size()):
		var seg := p[k].split("/")
		if seg.is_empty() or seg[0].is_empty():
			continue
		var vi := int(seg[0])
		vi = vi - 1 if vi > 0 else pos.size() + vi
		fv.append(vi)
		var ti := -1
		if seg.size() > 1 and not seg[1].is_empty() and not uv.is_empty():
			ti = int(seg[1])
			ti = ti - 1 if ti > 0 else uv.size() + ti
		ft.append(ti)
	if fv.size() < 3:
		return
	var verts: PackedVector3Array = g["verts"]
	var uvs: PackedVector2Array = g["uvs"]
	var idx: PackedInt32Array = g["indices"]
	var base := verts.size()
	for k in fv.size():
		var vi := fv[k]
		if vi < 0 or vi >= pos.size():
			return
		verts.append(pos[vi])
		var ti := ft[k]
		uvs.append(uv[ti] if ti >= 0 and ti < uv.size() else Vector2.ZERO)
	for k in range(1, fv.size() - 1):
		idx.append(base)
		idx.append(base + k)
		idx.append(base + k + 1)
	g["verts"] = verts
	g["uvs"] = uvs
	g["indices"] = idx


## 解析同目录 .mtl（Kd 基色 + map_Kd 贴图），返回 {材质名: StandardMaterial3D}。
static func _load_mtl(obj_path: String) -> Dictionary:
	var out := {}
	var text := FileAccess.get_file_as_string(obj_path)
	var dir := obj_path.get_base_dir()
	var names := PackedStringArray()
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.begins_with("mtllib "):
			for n in line.substr(7).split(" ", false):
				names.append(dir.path_join(n))
	for mtl_path in names:
		if not FileAccess.file_exists(mtl_path):
			continue
		var cur: StandardMaterial3D = null
		var cur_name := ""
		for raw in FileAccess.get_file_as_string(mtl_path).split("\n"):
			var line := raw.strip_edges()
			if line.is_empty() or line.begins_with("#"):
				continue
			var p := line.split(" ", false)
			if p.is_empty():
				continue
			match p[0]:
				"newmtl":
					cur_name = p[1] if p.size() > 1 else ""
					cur = StandardMaterial3D.new()
					out[cur_name] = cur
				"Kd":
					if cur != null and p.size() >= 4:
						cur.albedo_color = Color(float(p[1]), float(p[2]), float(p[3]))
				"d":
					if cur != null and p.size() >= 2:
						cur.albedo_color.a = clampf(float(p[1]), 0.0, 1.0)
				"map_Kd":
					if cur != null and p.size() >= 2:
						var img := Image.load_from_file(dir.path_join(p[p.size() - 1]))
						if img != null:
							cur.albedo_texture = ImageTexture.create_from_image(img)
	return out


# STL

static func _load_stl(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var bytes := f.get_buffer(f.get_length())
	f.close()
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	var count := 0 if bytes.size() < 84 else bytes.decode_u32(80)
	if bytes.size() >= 84 and bytes.size() >= 84 + int(count) * 50:
		for i in int(count):
			var off := 84 + i * 50 + 12
			for k in 3:
				verts.append(Vector3(bytes.decode_float(off), bytes.decode_float(off + 4),
						bytes.decode_float(off + 8)))
				off += 12
				idx.append(idx.size())
	else:
		# ASCII STL：顶点顺序即三角形顺序
		for raw in bytes.get_string_from_ascii().split("\n"):
			var p := raw.strip_edges().split(" ", false)
			if p.size() >= 4 and p[0] == "vertex":
				verts.append(Vector3(float(p[1]), float(p[2]), float(p[3])))
				idx.append(idx.size())
	if verts.is_empty():
		return {}
	var book := {"list": [], "map": {}}
	var slot := _slot_index(null, book)
	var part := {"verts": verts, "indices": idx, "uvs": PackedVector2Array(),
			"colors": PackedColorArray(), "slot": slot}
	return {"name": path.get_file().get_basename(),
			"frames": [{"parts": [part], "time": 0.0}], "animated": false,
			"slots": book["list"]}

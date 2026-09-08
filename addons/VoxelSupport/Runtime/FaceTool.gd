class_name FaceTool


## icosphere 缓存：subdivisions -> {vertices: PackedVector3Array, indices: PackedInt32Array}
## 球体模式下所有体素共用同一份单位球模板，避免重复细分计算
static var _icosphere_cache: Dictionary = {}


## 生成（或取缓存）单位半径 icosphere 模板
## 算法：正二十面体(黄金比例顶点) -> 逐次细分(每三角形拆 4 个) -> 中点投影回单位球面
## 相比 UV 球：三角形面积均匀、无极点奇点，适合风格化小球渲染
static func get_icosphere(subdivisions: int = 2) -> Dictionary:
	if _icosphere_cache.has(subdivisions):
		return _icosphere_cache[subdivisions]
	var t := (1.0 + sqrt(5.0)) / 2.0
	var verts: Array[Vector3] = [
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1),
	]
	for i in verts.size():
		verts[i] = verts[i].normalized()
	# 20 个面（逆时针，从外部看）
	var indices: Array[int] = [
		0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11,
		1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
		3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9,
		4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1,
	]
	for _sub in subdivisions:
		var edge_midpoints: Dictionary = {}
		var new_indices: Array[int] = []
		for i in range(0, indices.size(), 3):
			var a := indices[i]
			var b := indices[i + 1]
			var c := indices[i + 2]
			var ab := _edge_midpoint(verts, edge_midpoints, a, b)
			var bc := _edge_midpoint(verts, edge_midpoints, b, c)
			var ca := _edge_midpoint(verts, edge_midpoints, c, a)
			new_indices.append_array([a, ab, ca, b, bc, ab, c, ca, bc, ab, bc, ca])
		indices = new_indices
	var result := {
		"vertices": PackedVector3Array(verts),
		"indices": PackedInt32Array(indices),
	}
	_icosphere_cache[subdivisions] = result
	return result


## 取（或生成并缓存）边 a-b 的中点顶点索引，中点投影到单位球面
static func _edge_midpoint(verts: Array[Vector3], edge_midpoints: Dictionary, a: int, b: int) -> int:
	var key := a * 4194304 + b if a < b else b * 4194304 + a
	if edge_midpoints.has(key):
		return edge_midpoints[key]
	var mid := (verts[a] + verts[b]) * 0.5
	verts.append(mid.normalized())
	var index := verts.size() - 1
	edge_midpoints[key] = index
	return index


## 面可见性统一规则（两条网格生成路径共用，语义权威）：
## 相邻任一侧为空(空气) → 可见
## 透明类型不同 → 可见
## 两者皆透明且材质不同 → 可见
## 其余（不透明体素相邻，含不同实心材质接缝）→ 不可见（内嵌面无法被看到，渲染无意义）
## 注意：VoxelChunkGenerator 热路径为性能内联同一逻辑，改动此函数须同步该内联分支。
static func face_visible(mat: VoxelMaterial, n_mat: VoxelMaterial) -> bool:
	if mat == null or n_mat == null:
		return true
	var m_trans: bool = mat.trans > 0
	var n_trans: bool = n_mat.trans > 0
	if m_trans != n_trans:
		return true
	if m_trans and mat != n_mat:
		return true
	return false


const Faces: Array[Array] = [
	Top,
	Bottom,
	Left,
	Right,
	Front,
	Back,
]


const SliceAxis: Array[Vector3i] = [
	Vector3i(Vector3i.AXIS_Y, Vector3i.AXIS_X, Vector3i.AXIS_Z),
	Vector3i(Vector3i.AXIS_Y, Vector3i.AXIS_X, Vector3i.AXIS_Z),
	Vector3i(Vector3i.AXIS_X, Vector3i.AXIS_Y, Vector3i.AXIS_Z),
	Vector3i(Vector3i.AXIS_X, Vector3i.AXIS_Y, Vector3i.AXIS_Z),
	Vector3i(Vector3i.AXIS_Z, Vector3i.AXIS_X, Vector3i.AXIS_Y),
	Vector3i(Vector3i.AXIS_Z, Vector3i.AXIS_X, Vector3i.AXIS_Y),
]


const Normals: Array[Vector3] = [
	Vector3(0, 1, 0),
	Vector3(0, -1, 0),
	Vector3(-1, 0, 0),
	Vector3(1, 0, 0),
	Vector3(0, 0, 1),
	Vector3(0, 0, -1),
]


const Top: Array[Vector3] = [
	Vector3(1.0000, 1.0000, 1.0000),
	Vector3(0.0000, 1.0000, 1.0000),
	Vector3(0.0000, 1.0000, 0.0000),
	
	Vector3(0.0000, 1.0000, 0.0000),
	Vector3(1.0000, 1.0000, 0.0000),
	Vector3(1.0000, 1.0000, 1.0000),
];


const Bottom: Array[Vector3] = [
	Vector3(0.0000, 0.0000, 0.0000),
	Vector3(0.0000, 0.0000, 1.0000),
	Vector3(1.0000, 0.0000, 1.0000),
	
	Vector3(1.0000, 0.0000, 1.0000),
	Vector3(1.0000, 0.0000, 0.0000),
	Vector3(0.0000, 0.0000, 0.0000),
];


const Front: Array[Vector3] = [
	Vector3(0.0000, 1.0000, 1.0000),
	Vector3(1.0000, 1.0000, 1.0000),
	Vector3(1.0000, 0.0000, 1.0000),
	
	Vector3(1.0000, 0.0000, 1.0000),
	Vector3(0.0000, 0.0000, 1.0000),
	Vector3(0.0000, 1.0000, 1.0000),
];


const Back: Array[Vector3] = [
	Vector3(1.0000, 0.0000, 0.0000),
	Vector3(1.0000, 1.0000, 0.0000),
	Vector3(0.0000, 1.0000, 0.0000),
	
	Vector3(0.0000, 1.0000, 0.0000),
	Vector3(0.0000, 0.0000, 0.0000),
	Vector3(1.0000, 0.0000, 0.0000)
];


const Left: Array[Vector3] = [
	Vector3(0.0000, 1.0000, 1.0000),
	Vector3(0.0000, 0.0000, 1.0000),
	Vector3(0.0000, 0.0000, 0.0000),
	
	Vector3(0.0000, 0.0000, 0.0000),
	Vector3(0.0000, 1.0000, 0.0000),
	Vector3(0.0000, 1.0000, 1.0000),
];


const Right: Array[Vector3] = [
	Vector3(1.0000, 1.0000, 1.0000),
	Vector3(1.0000, 1.0000, 0.0000),
	Vector3(1.0000, 0.0000, 0.0000),
	
	Vector3(1.0000, 0.0000, 0.0000),
	Vector3(1.0000, 0.0000, 1.0000),
	Vector3(1.0000, 1.0000, 1.0000),
];

class_name FaceTool


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

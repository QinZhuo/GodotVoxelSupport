class_name FaceTool

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

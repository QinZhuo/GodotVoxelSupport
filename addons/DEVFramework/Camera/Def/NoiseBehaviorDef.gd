@tool
## 手持抖动行为: 给机位画面叠加常驻的"手持感"晃动。
##
## 与震屏的区别: 本行为是[b]常驻[/b]的镜头质感(让画面不呆板), 且只作用于本机位;
## 爆炸/受击那种[b]事件性[/b]震动请用 [method CameraTool.impulse] / [method CameraTool.shake]。
##
## 抖动通过 [method offset] 叠加, [b]不写回节点[/b]: 既不污染场景 transform,
## 也不会反馈给同机位的跟随/死区计算。
class_name NoiseBehaviorDef extends CameraBehaviorDef

## 各机位共用的默认噪声。Noise 采样是无状态纯函数, 因此共享安全
static var _default_noise: FastNoiseLite

## 位置抖动振幅(机位局部空间, 米)
@export var position_amplitude: Vector3 = Vector3.ZERO
## 旋转抖动振幅(机位局部空间, 角度)
@export var rotation_amplitude: Vector3 = Vector3.ZERO
## 抖动快慢(Hz): 时间推进速度, 与噪声资源自身的 frequency 相乘
@export_range(0.01, 30, 0.01, "or_greater") var frequency: float = 1.0
## 噪声源(Godot 原生 [Noise] 资源, 可换 FastNoiseLite 的任意类型/种子); 留空用默认 Perlin
@export var noise: Noise


func apply_offset(vcam: VirtualCamera3D, pose: Transform3D) -> Transform3D:
	if position_amplitude == Vector3.ZERO and rotation_amplitude == Vector3.ZERO:
		return pose
	var source := _resolve_noise()
	var t := vcam.get_behavior_time() * frequency
	var pos := Vector3(_sample(source, t, 0), _sample(source, t, 1), _sample(source, t, 2)) * position_amplitude
	var rot := Vector3(_sample(source, t, 3), _sample(source, t, 4), _sample(source, t, 5)) * rotation_amplitude
	return pose * Transform3D(Basis.from_euler(rot * (PI / 180.0)), pos)


func _resolve_noise() -> Noise:
	if noise != null:
		return noise
	if _default_noise == null:
		_default_noise = FastNoiseLite.new()
		_default_noise.noise_type = FastNoiseLite.TYPE_PERLIN
		_default_noise.frequency = 1.0
	return _default_noise


## 六条互不相同的采样通道(位置 3 轴 + 旋转 3 轴), 避免各轴同步摆动
func _sample(source: Noise, t: float, channel: int) -> float:
	return source.get_noise_2d(t + channel * 17.13, channel * 31.7)

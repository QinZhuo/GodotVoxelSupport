class_name Sprite3DLight extends Sprite3D

@export var tween: TweenAnimation

var material: StandardMaterial3D:
	get():
		return material_override

func play(time: float = 0.0):
	await tween.play().finished
	if time > 0:
		await get_tree().create_timer(time).timeout
	await tween.playback().finished

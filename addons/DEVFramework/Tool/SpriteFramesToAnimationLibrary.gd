@tool
class_name SpriteFramesToAnimationLibrary extends EditorScript
## This is an editor script for generating an animation library from SpriteFrames resources

func _run():
	var paths = EditorInterface.get_selected_paths()
	if paths.is_empty():
		push_error("Please select SpriteFrames resources in the filesystem dock")
		return

	for path in paths:
		var resource = load(path)
		if not resource:
			push_error("Failed to load resource: ", path)
			paths.erase(path)
			continue

		if not resource is SpriteFrames:
			push_warning("Skipping non-SpriteFrames resource: ", path)
			paths.erase(path)
			continue

	for path in paths:
		_process_sprite_frames(path)

func _process_sprite_frames(resource_path: String) -> bool:
	var sprite_frames: SpriteFrames = load(resource_path)
	var base_name := resource_path.get_basename()
	var extension := resource_path.get_extension()
	if extension != 'tres' or extension != 'res':
		extension = 'tres'
	var library_path = base_name + "_anim_lib." + extension

	var library = null
	if ResourceLoader.exists(library_path):
		library = load(library_path)
		if not library is AnimationLibrary:
			push_error("File exists but is not an AnimationLibrary: ", library_path)
			return false
		print("Loading existing animation library: ", library_path)
	else:
		library = AnimationLibrary.new()
		print("Creating new animation library: ", library_path)

	var anim_count = 0
	for anim_name in sprite_frames.get_animation_names():
		var anim: Animation
		if library.has_animation(anim_name):
			anim = library.get_animation(anim_name)
			print("  Updating existing animation: ", anim_name)
		else:
			anim = Animation.new()
			library.add_animation(anim_name, anim)
			print("  Creating new animation: ", anim_name)

		var frame_count = sprite_frames.get_frame_count(anim_name)
		if frame_count <= 0:
			push_warning("    Skipping empty animation: ", anim_name)
			continue

		var speed = sprite_frames.get_animation_speed(anim_name)
		var frame_time = 1.0 / speed
		anim.length = frame_count * frame_time
		anim.step = frame_time
		anim.loop_mode = Animation.LOOP_LINEAR if anim_name.ends_with('_loop') else Animation.LOOP_NONE

		var sprite_frames_track := _setup_track(anim, "AnimatedSprite2D:sprite_frames", Animation.TrackType.TYPE_VALUE)
		var anim_track := _setup_track(anim, "AnimatedSprite2D:animation", Animation.TrackType.TYPE_VALUE)
		var frame_track := _setup_track(anim, "AnimatedSprite2D:frame", Animation.TrackType.TYPE_VALUE)

		anim.track_insert_key(sprite_frames_track, 0.0, sprite_frames)
		anim.track_insert_key(anim_track, 0.0, anim_name)

		var time_pos := 0.0
		for frame_idx in frame_count:
			anim.track_insert_key(frame_track, time_pos, frame_idx)
			time_pos += frame_time * sprite_frames.get_frame_duration(anim_name, frame_idx)
			prints(frame_idx, frame_time, sprite_frames.get_frame_duration(anim_name, frame_idx), time_pos)

		anim_count += 1

	var save_result = ResourceSaver.save(library, library_path)
	if save_result != OK:
		push_error("Failed to save animation library: ", library_path)
		return false

	print("Successfully processed ", anim_count, " animations. Saved to: ", library_path)
	EditorInterface.get_resource_filesystem().update_file(library_path)
	return true

func _setup_track(anim: Animation, track_path: String, track_type: int) -> int:
	var track = anim.find_track(track_path, track_type)
	if track < 0:
		track = anim.add_track(track_type)
		anim.track_set_path(track, track_path)
	if track_type == Animation.TYPE_VALUE:
		anim.value_track_set_update_mode(track, Animation.UPDATE_DISCRETE)

	var key_count = anim.track_get_key_count(track)
	for i in range(key_count - 1, -1, -1):
		anim.track_remove_key(track, i)

	return track

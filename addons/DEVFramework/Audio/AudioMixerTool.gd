@tool
## 音频配置(编辑器/启动期) —— 效果预设 + 总线布局的构建/应用/保存。
class_name AudioMixerTool

## 总线布局的项目设置键
const LAYOUT_SETTING := "audio/buses/default_bus_layout"
const DEFAULT_LAYOUT_PATH := "res://default_bus_layout.tres"

## 可用的效果预设名(供 fx / build_layout 使用)
const FX_NAMES := [
	"reverb", "reverb_hall", "delay", "distortion",
	"limiter", "compressor", "eq_lowpass", "eq_highpass", "eq_bandpass", "spectrum",
]


## 按名称构造内置效果预设; 未知名称返回 null。params 可覆盖预设属性(键为 AudioEffect 属性名)
static func fx(name: String, params := {}) -> AudioEffect:
	var effect: AudioEffect
	match name:
		"reverb":
			var reverb := AudioEffectReverb.new()
			reverb.room_size = 0.55
			reverb.damping = 0.35
			reverb.dry = 0.85
			reverb.wet = 0.3
			reverb.spread = 0.6
			effect = reverb
		"reverb_hall":
			var hall := AudioEffectReverb.new()
			hall.predelay_msec = 20.0
			hall.room_size = 0.95
			hall.damping = 0.45
			hall.dry = 0.6
			hall.wet = 0.5
			hall.spread = 0.9
			effect = hall
		"delay":
			var delay := AudioEffectDelay.new()
			delay.dry = 1.0
			delay.tap1_active = true
			delay.tap1_delay_ms = 250.0
			delay.tap1_level_db = -10.0
			delay.tap1_pan = -0.3
			delay.feedback_active = true
			delay.feedback_delay_ms = 250.0
			delay.feedback_level_db = -8.0
			delay.feedback_lowpass = 4500.0
			effect = delay
		"distortion":
			var distortion := AudioEffectDistortion.new()
			distortion.mode = AudioEffectDistortion.Mode.MODE_CLIP
			distortion.pre_gain = 6.0
			distortion.drive = 0.35
			distortion.post_gain = -4.0
			effect = distortion
		"limiter":
			var limiter := AudioEffectLimiter.new()
			limiter.threshold_db = -3.0
			limiter.ceiling_db = -1.0
			effect = limiter
		"compressor":
			var compressor := AudioEffectCompressor.new()
			compressor.threshold = -18.0
			compressor.ratio = 3.0
			compressor.gain = 4.0
			compressor.attack_us = 5000
			compressor.release_ms = 120.0
			effect = compressor
		"eq_lowpass":
			var lowpass := AudioEffectLowPassFilter.new()
			lowpass.cutoff_hz = 4500.0
			lowpass.resonance = 0.6
			effect = lowpass
		"eq_highpass":
			var highpass := AudioEffectHighPassFilter.new()
			highpass.cutoff_hz = 160.0
			highpass.resonance = 0.5
			effect = highpass
		"eq_bandpass":
			var bandpass := AudioEffectBandPassFilter.new()
			bandpass.cutoff_hz = 2200.0
			bandpass.resonance = 1.0
			effect = bandpass
		"spectrum":
			effect = AudioEffectSpectrumAnalyzer.new()
		_:
			LogTool.warn("音频", "未知效果预设: ", name)
			return null
	for key: String in params:
		effect.set(key, params[key])
	return effect


## 由总线表构建布局(纯函数, 不改 AudioServer)。0 号必须是 Master。
static func build_layout(spec: Dictionary) -> AudioBusLayout:
	if spec.is_empty() or not spec.has("Master"):
		LogTool.error("音频", "总线表无效(须非空且含 Master): ", spec)
		return null
	var layout := AudioBusLayout.new()
	var idx := 0
	for bus_name: String in spec:
		var cfg: Variant = spec[bus_name]
		var is_cfg := cfg is Dictionary
		var effects: Array = cfg.get("effects", []) if is_cfg else cfg
		layout.set("bus/%d/name" % idx, StringName(bus_name))
		layout.set("bus/%d/volume_db" % idx, VariantTool.get_float(cfg, "volume_db") if is_cfg else 0.0)
		layout.set("bus/%d/send" % idx, StringName(VariantTool.get_string(cfg, "send", "Master")) if is_cfg else &"Master")
		layout.set("bus/%d/mute" % idx, VariantTool.get_bool(cfg, "mute") if is_cfg else false)
		layout.set("bus/%d/solo" % idx, false)
		layout.set("bus/%d/bypass_fx" % idx, false)
		var slot := 0
		for effect_name: Variant in effects:
			var effect := fx(str(effect_name))
			if effect == null:
				continue
			layout.set("bus/%d/effect/%d/effect" % [idx, slot], effect)
			layout.set("bus/%d/effect/%d/enabled" % [idx, slot], true)
			slot += 1
		idx += 1
	return layout


## 应用到运行中的 AudioServer(替换当前总线布局, 含音量/send/效果)
static func apply_layout(layout: AudioBusLayout) -> void:
	if layout == null:
		return
	AudioServer.set_bus_layout(layout)


## 保存布局到 layout_path(); 项目设置未配置时补写路径
static func save_layout(layout: AudioBusLayout) -> Error:
	if layout == null:
		return ERR_INVALID_DATA
	var path := layout_path()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var err := ResourceSaver.save(layout, path)
	if err != OK:
		LogTool.error("音频", "保存总线布局失败: ", err)
		return err
	if str(ProjectSettings.get_setting(LAYOUT_SETTING, "")).strip_edges().is_empty():
		ProjectSettings.set_setting(LAYOUT_SETTING, path)
		ProjectSettings.save()
	LogTool.log("音频", "总线布局已保存: ", path)
	return OK


## 布局落盘路径: 取项目设置 audio/buses/default_bus_layout, uid:// 解析成实际路径;
static func layout_path() -> String:
	var raw := str(ProjectSettings.get_setting(LAYOUT_SETTING, "")).strip_edges()
	if raw.begins_with("uid://"):
		var id := ResourceUID.text_to_id(raw)
		raw = ResourceUID.get_id_path(id) if id != ResourceUID.INVALID_ID else ""
	return raw if not raw.is_empty() else DEFAULT_LAYOUT_PATH


## 一步到位: 构建 → (可选)应用 → (可选)保存
static func setup(spec: Dictionary, apply := true, save := true) -> Dictionary:
	var layout := build_layout(spec)
	if layout == null:
		return {"ok": false}
	if apply:
		apply_layout(layout)
	var path := ""
	if save:
		var err := save_layout(layout)
		if err != OK:
			return {"ok": false, "error": err}
		path = layout_path()
	return {"ok": true, "layout_path": path}

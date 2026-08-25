@tool
class_name AudioGenDef extends PCGGeneratorDef
## 程序化音频生成器 — 把 AudioSynthDef 渲染成 AudioStreamWAV, 接入 PCG 管线
## 对齐 TextureGenDef(程序化纹理): 同为"内容生成器", 结果写入 ctx.output[key]
## 使同一种子管线可同时生成世界 + 配套音效/BGM(自适应音频/程序化配乐)
## 生成核心在 AudioSynthTool(PCG/Tool) + AudioSynthEngine(C++)

## 要渲染的音频定义(音色/编曲/鼓/和声/效果全部配置驱动)
@export var synth_def: AudioSynthDef

## 输出格式: true=AudioStreamWAV(可播放/保存), false=原始数据字典(int16 bytes)
@export var output_stream := true

func generate(ctx: PCGContext) -> void:
	if synth_def == null:
		push_warning("AudioGenDef.generate: 未配置 synth_def (", name, ")")
		return
	var data := AudioSynthTool.render_data(synth_def)
	if data.is_empty() or data.get("err", false):
		push_error("AudioGenDef.generate: 渲染失败: ", synth_def)
		return
	if output_stream:
		var stream := AudioSynthTool.build_stream(data)
		if stream:
			ctx.output[_effective_key()] = stream
	else:
		ctx.output[_effective_key()] = data

func get_desc(_data) -> String:
	return "Audio[%s]" % (synth_def.name if synth_def else "未配置")

func _to_string() -> String:
	return "AudioGen[%s]" % (synth_def.name if synth_def else "?")

## 便捷: 从 AudioSynthDef 直接构建 AudioGenDef(供代码构造管线)
static func from_def(def: AudioSynthDef, key := "") -> AudioGenDef:
	var g := AudioGenDef.new()
	g.synth_def = def
	g.output_key = key
	return g

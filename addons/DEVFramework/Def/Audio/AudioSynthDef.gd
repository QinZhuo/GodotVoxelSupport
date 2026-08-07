@tool
## 程序化音频定义 — 组合一组音色 + 一组序列(显式/自动编曲)，一键渲染成 AudioStreamWAV
class_name AudioSynthDef extends Def

enum Category {
	## 短音效(激光/爆炸/拾取/攻击等单发)
	SFX,
	## 音乐/整段长曲
	BGM,
	## 环境氛围铺设
	AMBIENT,
	## 无限循环的音乐片段(常配 loop=true)
	LOOP,
}

## 音频类别: 决定语义/命名/烘焙约定, 不改变渲染算法
@export var category: Category = Category.SFX
## 采样率(Hz): 44100=CD 音质; 22050 体积减半; 8k~16k 复古/轻负担
@export_range(8000, 48000, 1000) var sample_rate := 44100
## 时长(秒)；0 表示由序列/编曲自动推算
@export_range(0.0, 600.0, 0.1) var duration := 0.0
## 音色表: 每个声部一种发声(音调/打击乐), 事件的 voice_index 指向其中一项
@export var voices: Array[AudioVoiceDef] = []
## 显式音符序列(手工固定旋律/音效/鼓点)
@export var patterns: Array[AudioPatternDef] = []
## 自动编曲(按音阶/和弦/角色生成, 随机种子可复现)
@export var music: Array[AudioMusicDef] = []

## ——— 母带与效果 ———
@export_range(0.0, 1.0, 0.001) var master_volume := 0.9
## 软削波驱动量(>0 启用，值越大越接近压缩/失真；离线母带，仅烘焙进 WAV)
@export_range(0.0, 4.0, 0.05) var soft_clip := 0.5

## ——— 播放总线(整合 Godot AudioServer) ———
## 播放时自动路由到该总线; 标准布局由 AudioTool.setup_audio_buses() 一键创建
@export var bus := "Master"
## 运行时总线效果链(播放与烘焙共用): Godot 原生 AudioEffect 资源数组,
## 在 Inspector 中直接添加效果并调节其原生参数; 也可用 AudioTool.create_fx("reverb") 等预设创建
@export var fx_chain: Array[AudioEffect] = []

## ——— 循环 ———
@export var loop := false
## 头部淡入(秒)，循环音乐 / 场景环境渐入常用；离线烘焙与实时播放均生效
@export_range(0.0, 5.0, 0.05) var fade_in := 0.0
## 尾部淡出(秒)，用于非循环片段平滑收尾
@export_range(0.0, 5.0, 0.05) var fade_out := 0.0

## ——— 随机生成 / 用谐调变体(sfxr 灵感, Inspector 一键批量生成候选) ———
## 随机 / 微调时是否保持各振荡器波形与声部类型(音色基础)；false=随机生成时音色也随机换
@export var random_preserve_wave := true
## 参数锁: 列出的顶层属性名在随机生成/微调时保持不变(如 master_volume/soft_clip/bus)
@export var mutate_locked: Array[StringName] = []


## ——— 编辑器操作(Inspector 按钮, 点击即触发) ———
## 机制: 点击按钮 = 调用该属性存放的 Callable。用 getter 每次实时返回新 Callable,
## 避免脚本热重载后序列化属性变 nil 导致 "invalid callable" 报错。
## 播放/停止切换: 空闲时后台生成并按 bus/fx_chain 试听(BGM 自动循环), 生成中/播放中点击则停止
@export_tool_button("▶ 播放 ／ ■ 停止") var _preview_toggle:
	get:
		return func() -> void:
			if AudioTool.is_editor_preview_busy() or AudioTool.is_editor_preview_playing():
				AudioTool.stop_editor_preview()
			else:
				AudioTool.play_editor_preview(self)

## 弹窗选择保存路径, 异步烘焙当前定义为 WAV 文件并刷新资源面板
@export_tool_button("烘焙 WAV...") var _bake_wav:
	get:
		return func() -> void:
			_bake_to_wav()


## 随机生成音效: 全参数重新随机(默认保持音色波形基础), 生成后自动试听
@export_tool_button("随机生成音效") var _randomize:
	get:
		return func() -> void:
			AudioTool.randomize_def(self)
			AudioTool.play_editor_preview(self)

## 微调变体: 现有参数小幅扰动 + 编曲重新掷种子, 生成后自动试听
@export_tool_button("微调变体") var _mutate:
	get:
		return func() -> void:
			AudioTool.mutate_def(self)
			AudioTool.play_editor_preview(self)

## 烘焙到约定目录 res://Assets/Audio/Baked/<Def名>.wav(异步后台生成, 完成后刷新资源面板)
## 注意: 不用编辑器类硬引用(EditorFileDialog 等), 保证 Def 在游戏端也能安全编译
func _bake_to_wav() -> void:
	if not Engine.is_editor_hint():
		return
	DirAccess.make_dir_recursive_absolute("res://Assets/Audio/Baked")
	var path := "res://Assets/Audio/Baked/" + _default_bake_name()
	var err: Error = await AudioTool.bake_wav(self, path)
	LogTool.log("音频", "烘焙完成: ", path, " err=", err)


func _default_bake_name() -> String:
	var stem := resource_path.get_file().get_basename() if not resource_path.is_empty() else name
	return stem + ".wav"

func get_desc(_data) -> String:
	return "%s[%d声部/%d序列]" % [Category.keys()[category], voices.size(), patterns.size() + music.size()]

func _to_string() -> String:
	return "AudioSynth[%s, %dv]" % [Category.keys()[category], voices.size()]

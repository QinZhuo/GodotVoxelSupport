# Audio 运行时音频与总线

一个静态入口负责放音效 / 换 BGM / 调总线音量，配一个总线布局工具和一个仅编辑器的烘焙工具。
声音通道挂在 `SceneTree.root` 下的常驻容器，跨场景存活、暂停时照常出声；BGM 单通道且带交叉淡化。

| 类 | 职责 |
|---|---|
| `AudioTool` | 运行时：`play` / `play_music` / `stop_music` / `stop_all` / 总线音量与静音 / `reset` |
| `AudioMixerTool` | 总线布局：`fx` 效果预设、`build_layout` / `apply_layout` / `save_layout` / `setup` |
| `AudioBakeTool` | 仅编辑器：把流经效果链真实录回并写标准 WAV |

```gdscript
AudioTool.play(stream)                                     # 2D，默认 bus = "Master"
AudioTool.play(stream, {"bus": "SFX", "volume_db": -6.0})
AudioTool.play(stream, {"target": node3d})                 # 3D：挂目标下的定位通道
AudioTool.play(stream, {"pitch": 1.0, "jitter": 100.0})    # jitter 单位是音分

AudioTool.play_music(bgm, {"fade": 1.0})                   # 交叉淡化，默认 bus = "Music"
AudioTool.stop_music(0.5)
AudioTool.set_bus_volume("Music", -12.0)
AudioTool.reset()                                          # 切场景 / 回标题
```

`play` 的 `opts`：`bus`（默认 `"Master"`）、`target`（`Node3D`）、`volume_db`、`pitch`、`jitter`、`unit_size`、`attenuation_model`。
`play_music` 的 `opts`：`bus`（默认 `"Music"`）、`volume_db`、`fade`（秒，默认 0.5）。

```gdscript
var spec := {
	"Master": {},                                          # 必须存在且是第一个键
	"Music": {"volume_db": -6.0, "effects": ["limiter"]},
	"SFX":   {"effects": ["compressor", "eq_highpass"]},
}
var layout := AudioMixerTool.build_layout(spec)             # 纯函数，不动 AudioServer
AudioMixerTool.apply_layout(layout)
AudioMixerTool.save_layout(layout)
var r := AudioMixerTool.setup(spec)                         # 构建 + 应用 + 保存
```

效果预设（`fx(name, params)` 可按属性名覆盖）：`reverb` / `reverb_hall` / `delay` / `distortion` / `limiter` / `compressor` / `eq_lowpass` / `eq_highpass` / `eq_bandpass` / `spectrum`。

```gdscript
var out := await AudioBakeTool.bake_with_fx(wav, [AudioMixerTool.fx("reverb")])
AudioBakeTool.save_wav(out, "res://some/out.wav")
```

## 坑

1. 音乐是单通道：同一 `stream` 重复 `play_music` 直接返回（想从头播先 `stop_music`）；默认总线 `"Music"`，项目里没这条总线会报错——建总线或用 `opts.bus` 指到已有总线。
2. `play` 返回的是"是否受理"而非"已播完"：`root` 未 ready 时入队（音效队列上限 `PENDING_LIMIT = 64`，满了丢最旧；音乐只保留最近一次），root ready 后补播；`stream` 为 null 返回 false。
3. `stop_all` 只清 2D 通道：3D 通道挂在目标 `Node3D` 下、随目标销毁消失；每个目标只有一个 3D 通道，`bus` 会被最后一次播放覆盖。
4. 常驻容器 `_Audio` 在 root 上且 `PROCESS_MODE_ALWAYS`，`reset()` 不删它、只停声音并清两个队列——暂停菜单/结算界面的音效照常出声是预期行为。
5. `build_layout` 要求 `spec` 非空且含 `Master`，并且 Master 是字典第一个键（0 号总线），否则 `LogTool.error` 后返回 null；`setup` 走这条路径只回 `{"ok": false}`，原因得看日志。
6. `save_layout` 会改项目设置 `audio/buses/default_bus_layout`（未配置时补写并 `ProjectSettings.save()`），是落盘而不只是运行时；`layout_path()` 支持 `uid://` 解析，回退 `res://default_bus_layout.tres`。

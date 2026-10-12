@tool
class_name VoxelImportPluginBase
extends EditorImportPlugin

## `.vox` / `.qvx` 导入插件的公共基类：**扩展名 + `.qvx`/`.vox` 分派 + 落盘**。
## 子类只实现"从资产造产物"（`_from_qvx` / `_from_vox`），不再各写一遍分派与 `ResourceSaver.save`。
## 【headless 友好】选项定义在 `VoxelImportOptions`（静态），故拿不到本插件实例时也能读默认值。

func _get_recognized_extensions():
	return VoxAsset.SUPPORTED_EXTENSIONS.duplicate()


func _import(source_file, save_path, options, _platforms, _gen_files):
	var product: Resource = null
	if QVoxelAsset.handles(source_file):
		var qvx := QVoxelAsset.from_file(source_file)
		if qvx != null:
			product = _from_qvx(qvx, options, source_file)
	else:
		# 解析失败返回 null：直接送进生成器会解引用空数据而崩。
		var vox := VoxAsset.from_asset(source_file)
		if vox != null:
			product = _from_vox(vox, options, source_file)
	if product == null:
		return FAILED
	return ResourceSaver.save(product, "%s.%s" % [save_path, _get_save_extension()])


## 从 `.qvx` 资产造产物（子类实现）。返回 null = 失败。
func _from_qvx(_qvx: QVoxelAsset, _options: Dictionary, _source_file: String) -> Resource:
	return null


## 从 `.vox` 资产造产物（子类实现）。返回 null = 失败。
func _from_vox(_vox: VoxAsset, _options: Dictionary, _source_file: String) -> Resource:
	return null

@tool
class_name TagDef extends EntityDef

func in_tags(target_tags: Array[TagDef]) -> bool:
	for target_tag in target_tags:
		if target_tag == self:
			return true
	return false

static func in_any_tags(tags: Array[TagDef], target_tags: Array[TagDef]) -> bool:
	if target_tags.size() == 0:
		return true
	for tag in tags:
		if not tag:
			continue
		if tag.in_tags(target_tags):
			return true
	return false

static func in_all_tags(tags: Array[TagDef], target_tags: Array[TagDef]) -> bool:
	for target_tag in target_tags:
		if not tags.has(target_tag):
			return false
	return true

func get_csv_path() -> String:
	return "res://Assets/Translation/tag.csv"

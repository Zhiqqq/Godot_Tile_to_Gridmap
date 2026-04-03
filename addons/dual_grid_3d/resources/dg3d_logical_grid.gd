@tool
extends Resource
class_name DG3DLogicalGrid

# Single runtime source of truth — clean Dictionary API for all callers.
# Serialized as compact PackedInt32Array/PackedStringArray via _get/_set/_get_property_list.
var data: Dictionary = {}

# Temporary load buffers, cleared after data is rebuilt from them.
var _lx: PackedInt32Array = []
var _ly: PackedInt32Array = []
var _lv: PackedStringArray = []


# ── Serialization ─────────────────────────────────────────────────────────────

func _get_property_list() -> Array[Dictionary]:
	return [
		{"name": "_lx", "type": TYPE_PACKED_INT32_ARRAY,   "usage": PROPERTY_USAGE_STORAGE},
		{"name": "_ly", "type": TYPE_PACKED_INT32_ARRAY,   "usage": PROPERTY_USAGE_STORAGE},
		{"name": "_lv", "type": TYPE_PACKED_STRING_ARRAY,  "usage": PROPERTY_USAGE_STORAGE},
	]


func _get(property: StringName) -> Variant:
	match property:
		"_lx":
			var arr := PackedInt32Array()
			for pos: Vector2i in data: arr.append(pos.x)
			return arr
		"_ly":
			var arr := PackedInt32Array()
			for pos: Vector2i in data: arr.append(pos.y)
			return arr
		"_lv":
			var arr := PackedStringArray()
			for pos: Vector2i in data: arr.append(data[pos])
			return arr
	return null


func _set(property: StringName, value: Variant) -> bool:
	match property:
		"_lx": _lx = value
		"_ly": _ly = value
		"_lv": _lv = value
		_: return false
	# Rebuild data once all three arrays are loaded (sizes consistent)
	if _lx.size() == _ly.size() and _ly.size() == _lv.size():
		data.clear()
		for i in _lx.size():
			data[Vector2i(_lx[i], _ly[i])] = _lv[i]
		_lx.resize(0)
		_ly.resize(0)
		_lv.resize(0)
	return true


# ── Public API ────────────────────────────────────────────────────────────────

func get_cell(pos: Vector2i) -> String:
	return data.get(pos, "")


func set_cell(pos: Vector2i, terrain: String) -> void:
	if data.get(pos, "") == terrain:
		return
	data[pos] = terrain
	emit_changed()


func erase_cell(pos: Vector2i) -> void:
	if not data.has(pos):
		return
	data.erase(pos)
	emit_changed()


func set_cells_batch(cells: Dictionary) -> void:
	var changed := false
	for pos: Vector2i in cells:
		var terrain: String = cells[pos]
		var current: String = data.get(pos, "")
		if terrain == current:
			continue
		if terrain == "":
			data.erase(pos)
		else:
			data[pos] = terrain
		changed = true
	if changed:
		emit_changed()


func get_used_cells() -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	result.assign(data.keys())
	return result


func clear() -> void:
	if data.is_empty():
		return
	data.clear()
	emit_changed()
@tool
extends Resource
class_name DG3DLogicalGrid

# Single runtime source of truth — clean Dictionary API for all callers.
# Serialized as compact PackedInt32Array/PackedStringArray via _get/_set/_get_property_list.
var data: Dictionary = {}

# Load buffers — names differ from the serialized field names "_lx/_ly/_lv"
# so Godot routes those names through _get/_set instead of bypassing it.
var _buf_x: PackedInt32Array = []
var _buf_y: PackedInt32Array = []
var _buf_v: PackedStringArray = []
var _load_count: int = 0

# Save snapshot — captured on the first _get("_lx") call so all three arrays
# are guaranteed to derive from the same key order.
var _save_keys: Array[Vector2i] = []


# ── Serialization ─────────────────────────────────────────────────────────────

func _get_property_list() -> Array[Dictionary]:
	return [
		{"name": "_lx", "type": TYPE_PACKED_INT32_ARRAY,  "usage": PROPERTY_USAGE_STORAGE},
		{"name": "_ly", "type": TYPE_PACKED_INT32_ARRAY,  "usage": PROPERTY_USAGE_STORAGE},
		{"name": "_lv", "type": TYPE_PACKED_STRING_ARRAY, "usage": PROPERTY_USAGE_STORAGE},
	]


func _get(property: StringName) -> Variant:
	match property:
		"_lx":
			# Snapshot keys once; _ly and _lv reuse the same order.
			_save_keys.assign(data.keys())
			var arr := PackedInt32Array()
			arr.resize(_save_keys.size())
			for i in _save_keys.size():
				arr[i] = _save_keys[i].x
			return arr
		"_ly":
			var arr := PackedInt32Array()
			arr.resize(_save_keys.size())
			for i in _save_keys.size():
				arr[i] = _save_keys[i].y
			return arr
		"_lv":
			var arr := PackedStringArray()
			arr.resize(_save_keys.size())
			for i in _save_keys.size():
				arr[i] = data[_save_keys[i]]
			_save_keys.clear()
			return arr
	return null


func _set(property: StringName, value: Variant) -> bool:
	match property:
		"_lx": _buf_x = value
		"_ly": _buf_y = value
		"_lv": _buf_v = value
		_: return false
	_load_count += 1
	if _load_count == 3:
		_load_count = 0
		data.clear()
		for i in _buf_x.size():
			data[Vector2i(_buf_x[i], _buf_y[i])] = _buf_v[i]
		_buf_x.resize(0)
		_buf_y.resize(0)
		_buf_v.resize(0)
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

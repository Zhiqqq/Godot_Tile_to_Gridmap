@tool
extends Resource
class_name DG3DLogicalGrid

# Parallel arrays for serialization (safe across Godot versions)
@export var _keys_x: PackedInt32Array = []
@export var _keys_y: PackedInt32Array = []
@export var _values: PackedStringArray = []

# Runtime cache (not serialized)
var _cache: Dictionary = {}
var _cache_dirty: bool = true


func get_cell(pos: Vector2i) -> String:
	_rebuild_cache_if_needed()
	return _cache.get(pos, "")


func set_cell(pos: Vector2i, terrain: String) -> void:
	_rebuild_cache_if_needed()
	if _cache.get(pos, "") == terrain:
		return
	_cache[pos] = terrain
	_sync_cache_to_arrays()
	emit_changed()


func erase_cell(pos: Vector2i) -> void:
	_rebuild_cache_if_needed()
	if not _cache.has(pos):
		return
	_cache.erase(pos)
	_sync_cache_to_arrays()
	emit_changed()


func get_used_cells() -> Array[Vector2i]:
	_rebuild_cache_if_needed()
	var result: Array[Vector2i] = []
	for key in _cache.keys():
		result.append(key)
	return result


func clear() -> void:
	_cache.clear()
	_cache_dirty = false
	_keys_x.clear()
	_keys_y.clear()
	_values.clear()
	emit_changed()


func _rebuild_cache_if_needed() -> void:
	if not _cache_dirty:
		return
	_cache.clear()
	for i in _keys_x.size():
		_cache[Vector2i(_keys_x[i], _keys_y[i])] = _values[i]
	_cache_dirty = false


func _sync_cache_to_arrays() -> void:
	_keys_x.clear()
	_keys_y.clear()
	_values.clear()
	for pos in _cache:
		_keys_x.append(pos.x)
		_keys_y.append(pos.y)
		_values.append(_cache[pos])

@tool
extends Node3D
class_name DG3DPainter

# Dual-Grid: each logical cell (lx, lz) maps to 4 GridMap cells via these offsets
const NEIGHBOURS: Array = [
	Vector2i(0, 0),  # bottom-right GridMap cell
	Vector2i(1, 0),  # bottom-left  GridMap cell
	Vector2i(0, 1),  # top-right    GridMap cell
	Vector2i(1, 1),  # top-left     GridMap cell
]

@export var grid_map: GridMap
@export var grid_height: int = 0
@export var logical_grid_data: DG3DLogicalGrid

# Terrain priority: higher value overwrites lower when GridMap cells overlap.
# Example: { "grass": 0, "dirt": 1, "cliff": 2 }
@export var terrain_heights: Dictionary = {}

# Bitmask IDs to skip for each terrain (avoids placing broken/unwanted shapes).
# Example: { "cliff": [0, 1, 2] }
@export var terrain_excludes: Dictionary = {}

@export_tool_button("Rebuild Gridmap") var _btn_rebuild = rebuild_gridmap
@export_tool_button("Clear Gridmap")   var _btn_clear   = clear_gridmap

# Runtime cache of MeshLibrary variants: { "grass0": ["grass0", "grass0b", ...] }
var _tile_variants: Dictionary = {}


# ── Public API ────────────────────────────────────────────────────────────────

func paint_cell(logical_pos: Vector2i, terrain_name: String) -> void:
	if not logical_grid_data:
		push_error("DG3DPainter: logical_grid_data is not assigned")
		return
	_ensure_variants_cached()
	logical_grid_data.set_cell(logical_pos, terrain_name)
	rebuild_cell(logical_pos)


func erase_cell(logical_pos: Vector2i) -> void:
	if not logical_grid_data:
		push_error("DG3DPainter: logical_grid_data is not assigned")
		return
	_ensure_variants_cached()
	logical_grid_data.erase_cell(logical_pos)
	rebuild_cell(logical_pos)


# Batch paint/erase — terrain "" means erase.
# Rebuilds each affected GridMap cell only once, much faster than repeated paint_cell calls.
func paint_cells(cells: Dictionary) -> void:
	if not _validate():
		return
	_ensure_variants_cached()
	var affected: Dictionary = {}
	for pos: Vector2i in cells:
		var terrain: String = cells[pos]
		if terrain == "":
			logical_grid_data.erase_cell(pos)
		else:
			logical_grid_data.set_cell(pos, terrain)
		for gm_pos: Vector3i in _get_affected_gridmap_cells(pos):
			affected[gm_pos] = true
	for gm_pos: Vector3i in affected:
		_recompute_gridmap_cell(gm_pos)


func rebuild_cell(logical_pos: Vector2i) -> void:
	if not _validate():
		return
	for gm_pos in _get_affected_gridmap_cells(logical_pos):
		_recompute_gridmap_cell(gm_pos)


func rebuild_gridmap() -> void:
	if not _validate():
		return
	_cache_tile_variants()
	grid_map.clear()

	# Collect all unique GridMap cells affected by any logical cell
	var affected: Dictionary = {}
	for logical_pos in logical_grid_data.get_used_cells():
		for gm_pos in _get_affected_gridmap_cells(logical_pos):
			affected[gm_pos] = true

	for gm_pos in affected:
		_recompute_gridmap_cell(gm_pos)


func clear_gridmap() -> void:
	if grid_map:
		grid_map.clear()


# ── Internal ──────────────────────────────────────────────────────────────────

func _validate() -> bool:
	if not grid_map:
		push_error("DG3DPainter: grid_map is not assigned")
		return false
	if not grid_map.mesh_library:
		push_error("DG3DPainter: grid_map has no MeshLibrary")
		return false
	if not logical_grid_data:
		push_error("DG3DPainter: logical_grid_data is not assigned")
		return false
	return true


func _ensure_variants_cached() -> void:
	if _tile_variants.is_empty():
		_cache_tile_variants()


func _cache_tile_variants() -> void:
	_tile_variants.clear()
	if not grid_map or not grid_map.mesh_library:
		return
	for item_id in grid_map.mesh_library.get_item_list():
		var item_name: String = grid_map.mesh_library.get_item_name(item_id)
		# Strip trailing lowercase letters (variant suffix, e.g. "grass0b" → "grass0")
		var base_name: String = item_name.rstrip("abcdefghijklmnopqrstuvwxyz")
		if base_name in _tile_variants:
			_tile_variants[base_name].append(item_name)
		else:
			_tile_variants[base_name] = [item_name]


# Returns the GridMap cells (up to 16) that must be recomputed when logical_pos changes.
func _get_affected_gridmap_cells(logical_pos: Vector2i) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	for dx in range(-1, 3):   # -1, 0, 1, 2
		for dz in range(-1, 3):
			result.append(Vector3i(logical_pos.x + dx, grid_height, logical_pos.y + dz))
	return result


# Recomputes a single GridMap cell from the logical grid state.
func _recompute_gridmap_cell(gm_pos: Vector3i) -> void:
	# The 4 logical cells whose terrain determines what goes at this GridMap cell
	var corners := [
		Vector2i(gm_pos.x - 1, gm_pos.z - 1),  # top-left    (NEIGHBOURS[3])
		Vector2i(gm_pos.x,     gm_pos.z - 1),  # top-right   (NEIGHBOURS[2])
		Vector2i(gm_pos.x - 1, gm_pos.z    ),  # bottom-left (NEIGHBOURS[1])
		Vector2i(gm_pos.x,     gm_pos.z    ),  # bottom-right(NEIGHBOURS[0])
	]

	var terrain_name := _pick_terrain_by_height(corners)
	if terrain_name == "":
		grid_map.set_cell_item(gm_pos, GridMap.INVALID_CELL_ITEM)
		return

	var bitmask := _calculate_bitmask(gm_pos, terrain_name)

	var excluded: Array = terrain_excludes.get(terrain_name, [])
	if bitmask in excluded:
		grid_map.set_cell_item(gm_pos, GridMap.INVALID_CELL_ITEM)
		return

	var base_name := "%s%d" % [terrain_name, bitmask]
	var mesh_name := _pick_random_variant(base_name)
	var mesh_id   := grid_map.mesh_library.find_item_by_name(mesh_name)
	if mesh_id != -1:
		grid_map.set_cell_item(gm_pos, mesh_id)
	else:
		grid_map.set_cell_item(gm_pos, GridMap.INVALID_CELL_ITEM)


# Among the logical corners that have a terrain, return the one with the highest height.
func _pick_terrain_by_height(corners: Array) -> String:
	var candidates := []
	for pos in corners:
		var terrain: String = logical_grid_data.get_cell(pos)
		if terrain != "":
			var h: int = terrain_heights.get(terrain, 0)
			candidates.append([terrain, h])
	if candidates.is_empty():
		return ""
	candidates.sort_custom(func(a, b): return a[1] > b[1])
	return candidates[0][0]


# Computes the 4-bit dual-grid bitmask for the given terrain at a GridMap cell.
# Bit layout (matches original v1.x NEIGHBOURS order):
#   +8 = top-left    logical corner
#   +1 = top-right   logical corner
#   +4 = bottom-left logical corner
#   +2 = bottom-right logical corner
func _calculate_bitmask(gm_pos: Vector3i, terrain_name: String) -> int:
	var id := 0
	if logical_grid_data.get_cell(Vector2i(gm_pos.x - 1, gm_pos.z - 1)) == terrain_name: id += 8
	if logical_grid_data.get_cell(Vector2i(gm_pos.x,     gm_pos.z - 1)) == terrain_name: id += 1
	if logical_grid_data.get_cell(Vector2i(gm_pos.x - 1, gm_pos.z    )) == terrain_name: id += 4
	if logical_grid_data.get_cell(Vector2i(gm_pos.x,     gm_pos.z    )) == terrain_name: id += 2
	return id


func _pick_random_variant(base_name: String) -> String:
	if base_name in _tile_variants:
		return _tile_variants[base_name].pick_random()
	return base_name

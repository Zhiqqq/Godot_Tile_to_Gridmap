@tool
extends EditorPlugin

# ── Constants ─────────────────────────────────────────────────────────────────
const PAINT_INTERVAL_MS    := 50.0   # Max 20 paint updates per second
const PREVIEW_MOVE_THRESHOLD := 2.0  # Pixels mouse must move to refresh cursor

# ── State ─────────────────────────────────────────────────────────────────────
var _ui: Control
var _cursor: Node3D

var _active_painter: DG3DPainter = null
var _selected_terrain: String = ""
var _erase_mode: bool = false
var _is_painting: bool = false

# Throttle
var _last_paint_time: float = 0.0
var _last_preview_pos: Vector2i = Vector2i(-99999, -99999)
var _cached_mouse_pos: Vector2 = Vector2.ZERO

# Undo/Redo — snapshot of cells changed during one brush stroke
var _undo_old: Dictionary = {}  # Vector2i → String (terrain before stroke)
var _undo_new: Dictionary = {}  # Vector2i → String (terrain after stroke)


# ── Plugin lifecycle ───────────────────────────────────────────────────────────

func _enter_tree() -> void:
	add_custom_type("DG3DPainter", "Node3D",  preload("res://addons/dual_grid_3d/dg3d_painter.gd"),  preload("res://addons/dual_grid_3d/DualGrid3D.svg"))
	add_custom_type("DG3DProcGen", "Node3D",  preload("res://addons/dual_grid_3d/dg3d_proc_gen.gd"), preload("res://addons/dual_grid_3d/DualGrid3D.svg"))
	add_custom_type("DG3DProps",   "GridMap", preload("res://addons/dual_grid_3d/dg3d_props.gd"),    preload("res://addons/dual_grid_3d/DualGrid3D.svg"))

	_ui = preload("res://addons/dual_grid_3d/dg3d_ui.tscn").instantiate()
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_BL, _ui)
	_ui.build_button_pressed.connect(_on_build_pressed)
	_ui.clear_button_pressed.connect(_on_clear_pressed)

	_cursor = preload("res://addons/dual_grid_3d/dg3d_cursor.gd").new()
	_cursor.name = "DG3DCursor"


func _exit_tree() -> void:
	remove_custom_type("DG3DPainter")
	remove_custom_type("DG3DProcGen")
	remove_custom_type("DG3DProps")
	remove_control_from_docks(_ui)
	_ui.queue_free()
	_remove_cursor()


# ── Node selection ─────────────────────────────────────────────────────────────

func _handles(object: Object) -> bool:
	return object is DG3DPainter


func _edit(object: Object) -> void:
	_active_painter = object as DG3DPainter
	_add_cursor_to_scene()
	_refresh_terrain_list()


func _make_visible(visible: bool) -> void:
	if _cursor:
		_cursor.visible = visible
	if not visible:
		_active_painter = null


# ── 3D viewport input ──────────────────────────────────────────────────────────

func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if not _active_painter or not _active_painter.grid_map:
		return AFTER_GUI_INPUT_PASS

	if event is InputEventMouse:
		_cached_mouse_pos = event.position

	if event is InputEventMouseMotion:
		_handle_mouse_motion(camera)
		if _is_painting:
			_try_paint(camera)
		return AFTER_GUI_INPUT_PASS

	if event is InputEventMouseButton:
		return _handle_mouse_button(event, camera)

	return AFTER_GUI_INPUT_PASS


func _handle_mouse_motion(camera: Camera3D) -> void:
	var logical_pos := _screen_to_logical_cell(camera, _cached_mouse_pos)
	if logical_pos == Vector2i(-99999, -99999):
		return
	if logical_pos == _last_preview_pos:
		return
	_last_preview_pos = logical_pos
	(_cursor as DG3DCursor).move_to(logical_pos, _active_painter.grid_map.cell_size, _active_painter.grid_height, _active_painter.grid_map.global_transform)


func _handle_mouse_button(event: InputEventMouseButton, camera: Camera3D) -> int:
	if event.button_index == MOUSE_BUTTON_LEFT or event.button_index == MOUSE_BUTTON_RIGHT:
		_erase_mode = (event.button_index == MOUSE_BUTTON_RIGHT)
		(_cursor as DG3DCursor).set_erase_mode(_erase_mode)

		if event.pressed:
			if _selected_terrain == "" and not _erase_mode:
				return AFTER_GUI_INPUT_STOP
			_is_painting = true
			_undo_old.clear()
			_undo_new.clear()
			_try_paint(camera)
			return AFTER_GUI_INPUT_STOP
		else:
			if _is_painting:
				_is_painting = false
				_commit_undo()
			return AFTER_GUI_INPUT_STOP

	return AFTER_GUI_INPUT_PASS


func _try_paint(camera: Camera3D) -> void:
	var now := Time.get_ticks_msec()
	if now - _last_paint_time < PAINT_INTERVAL_MS:
		return
	_last_paint_time = now

	var logical_pos := _screen_to_logical_cell(camera, _cached_mouse_pos)
	if logical_pos == Vector2i(-99999, -99999):
		return

	var grid := _active_painter.logical_grid_data
	if not grid:
		return

	var old_val: String = grid.get_cell(logical_pos)

	if _erase_mode:
		if old_val == "":
			return
		if not _undo_old.has(logical_pos):
			_undo_old[logical_pos] = old_val
		_undo_new[logical_pos] = ""
		_active_painter.erase_cell(logical_pos)
	else:
		if old_val == _selected_terrain:
			return
		if not _undo_old.has(logical_pos):
			_undo_old[logical_pos] = old_val
		_undo_new[logical_pos] = _selected_terrain
		_active_painter.paint_cell(logical_pos, _selected_terrain)


# ── Undo/Redo ──────────────────────────────────────────────────────────────────

func _commit_undo() -> void:
	if _undo_old.is_empty():
		return
	var painter: DG3DPainter = _active_painter
	var old_snap := _undo_old.duplicate()
	var new_snap := _undo_new.duplicate()
	var undo_redo := get_undo_redo()
	undo_redo.create_action("DG3D Paint Terrain")
	undo_redo.add_do_method(self, "_apply_batch", painter, new_snap)
	undo_redo.add_undo_method(self, "_apply_batch", painter, old_snap)
	undo_redo.commit_action(false)  # false = don't execute do-method again


func _apply_batch(painter: DG3DPainter, batch: Dictionary) -> void:
	for pos in batch:
		var terrain: String = batch[pos]
		if terrain == "":
			painter.erase_cell(pos)
		else:
			painter.paint_cell(pos, terrain)


# ── Raycasting ────────────────────────────────────────────────────────────────

func _screen_to_logical_cell(camera: Camera3D, screen_pos: Vector2) -> Vector2i:
	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_dir    := camera.project_ray_normal(screen_pos)
	var grid_map   := _active_painter.grid_map
	var cell_size  := grid_map.cell_size

	# Transform ray into GridMap local space so scale/position/rotation are handled correctly
	var inv         := grid_map.global_transform.affine_inverse()
	var local_origin := inv * ray_origin
	var local_dir    := inv.basis * ray_dir

	var plane := Plane(Vector3.UP, _active_painter.grid_height * cell_size.y)
	var hit: Variant = plane.intersects_ray(local_origin, local_dir)
	if hit == null:
		return Vector2i(-99999, -99999)
	return Vector2i(roundi(hit.x / cell_size.x) - 1, roundi(hit.z / cell_size.z) - 1)


# ── Cursor helpers ────────────────────────────────────────────────────────────

func _add_cursor_to_scene() -> void:
	_remove_cursor()
	var root := get_tree().edited_scene_root
	if root:
		root.add_child(_cursor)


func _remove_cursor() -> void:
	if _cursor and _cursor.is_inside_tree():
		_cursor.get_parent().remove_child(_cursor)


# ── UI callbacks ──────────────────────────────────────────────────────────────

func _on_build_pressed() -> void:
	if _active_painter:
		_active_painter.rebuild_gridmap()


func _on_clear_pressed() -> void:
	if _active_painter:
		_active_painter.clear_gridmap()


func _refresh_terrain_list() -> void:
	if not _active_painter or not _active_painter.grid_map or not _active_painter.grid_map.mesh_library:
		return
	var lib := _active_painter.grid_map.mesh_library
	var names: Array[String] = []
	for id in lib.get_item_list():
		var raw: String = lib.get_item_name(id)
		var base: String = raw.rstrip("abcdefghijklmnopqrstuvwxyz").rstrip("0123456789")
		if base != "" and base not in names:
			names.append(base)
	_ui.set_terrain_list(names, func(t): _selected_terrain = t)

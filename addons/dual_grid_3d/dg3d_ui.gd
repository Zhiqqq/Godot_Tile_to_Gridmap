@tool
extends Control

signal build_button_pressed()
signal clear_button_pressed()
signal paint_mode_changed(enabled: bool)

var _terrain_group: ButtonGroup
var _palette_container: HFlowContainer


func _ready() -> void:
	_terrain_group = ButtonGroup.new()
	# Find the palette container node (added in _build_ui if not in tscn)
	_palette_container = _find_or_create_palette()


func _on_build_button_pressed() -> void:
	build_button_pressed.emit()


func _on_clear_button_pressed() -> void:
	clear_button_pressed.emit()


func _on_paint_mode_toggled(pressed: bool) -> void:
	paint_mode_changed.emit(pressed)


func reset_paint_mode() -> void:
	var btn := find_child("PaintModeButton", true, false) as CheckButton
	if btn:
		btn.set_pressed_no_signal(false)


# Called by the plugin when a DG3DPainter is selected.
# terrain_names: Array[String]
# on_select: Callable(terrain_name: String)
func set_terrain_list(terrain_names: Array[String], on_select: Callable) -> void:
	if not _palette_container:
		return
	for child in _palette_container.get_children():
		child.queue_free()

	for terrain in terrain_names:
		var btn := Button.new()
		btn.text = terrain
		btn.toggle_mode = true
		btn.button_group = _terrain_group
		btn.pressed.connect(func(): on_select.call(terrain))
		_palette_container.add_child(btn)


func _find_or_create_palette() -> HFlowContainer:
	# Try to find an existing HFlowContainer named "TerrainPalette" in the scene
	var existing := find_child("TerrainPalette", true, false)
	if existing is HFlowContainer:
		return existing
	# Create one and append it below the existing buttons
	var container := HFlowContainer.new()
	container.name = "TerrainPalette"
	add_child(container)
	return container

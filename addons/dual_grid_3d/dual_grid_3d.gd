@tool
extends EditorPlugin

var _ui

func _enter_tree() -> void:
	add_custom_type("DG3DProcGen", "Node3D", preload("res://addons/dual_grid_3d/dg3d_proc_gen.gd"), preload("res://addons/dual_grid_3d/DualGrid3D.svg"))
	add_custom_type("DG3DProps", "GridMap", preload("res://addons/dual_grid_3d/dg3d_props.gd"), preload("res://addons/dual_grid_3d/DualGrid3D.svg"))
	_ui = preload("res://addons/dual_grid_3d/dg3d_ui.tscn").instantiate()
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_BL, _ui)


func _exit_tree() -> void:
	remove_custom_type("DG3DProcGen")
	remove_custom_type("DG3DProps")
	remove_control_from_docks(_ui)
	_ui.queue_free()

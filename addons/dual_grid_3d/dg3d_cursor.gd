@tool
extends Node3D
class_name DG3DCursor

var _mesh_instance: MeshInstance3D
var _material: StandardMaterial3D

const PAINT_COLOR := Color(0.2, 1.0, 0.3, 0.35)
const ERASE_COLOR := Color(1.0, 0.2, 0.2, 0.35)


func _ready() -> void:
	_material = StandardMaterial3D.new()
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.albedo_color = PAINT_COLOR

	var box := BoxMesh.new()
	box.size = Vector3(1.0, 0.05, 1.0)  # Resized in move_to()

	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.mesh = box
	_mesh_instance.material_override = _material
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh_instance)

	hide()


# Move cursor to the given logical cell position.
# cell_size is the GridMap's cell_size; height is the Y layer index.
func move_to(logical_pos: Vector2i, cell_size: Vector3, height: int, gm_transform: Transform3D) -> void:
	# Dual-Grid: logical cell (lx, lz) covers GridMap cells (lx,h,lz) to (lx+1,h,lz+1)
	# Convert from GridMap local space to world space
	var local_pos := Vector3(
		(logical_pos.x + 1.0) * cell_size.x,
		height * cell_size.y + cell_size.y * 0.5,
		(logical_pos.y + 1.0) * cell_size.z
	)
	position = gm_transform * local_pos
	var gm_scale := gm_transform.basis.get_scale()
	(_mesh_instance.mesh as BoxMesh).size = Vector3(
		cell_size.x * 2.0 * gm_scale.x,
		cell_size.y * 0.05 * gm_scale.y,
		cell_size.z * 2.0 * gm_scale.z
	)
	show()


func set_erase_mode(erase: bool) -> void:
	_material.albedo_color = ERASE_COLOR if erase else PAINT_COLOR

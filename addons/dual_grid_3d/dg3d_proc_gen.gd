@tool
extends Node3D
class_name DG3DProcGen

@export_tool_button("Clear World") var ClearWorld = clear_world
@export_tool_button("Generate World") var GenerateWorld = generate_world

@export var noise_height_texture: NoiseTexture2D
@export var terrains: Array[DG3DTerrain]
@export var width: int = 64
@export var height: int = 64
@export var gridmap: GridMap

const TERRAIN_LOOKUP_BUCKETS := 256
var terrain_lookup_table := []
var global_terrain_map: Dictionary = {}

func clear_world() -> void:
	global_terrain_map.clear()
	if gridmap:
		gridmap.clear()

func generate_world() -> void:
	# TODO: implement using DG3DPainter in Phase 4
	push_warning("DG3DProcGen: generate_world() not yet implemented")

func build_terrain_lookup_table() -> void:
	terrain_lookup_table.resize(TERRAIN_LOOKUP_BUCKETS)
	for i in range(TERRAIN_LOOKUP_BUCKETS):
		var value = i / float(TERRAIN_LOOKUP_BUCKETS - 1)
		terrain_lookup_table[i] = null
		for terrain in terrains:
			if terrain.noise_min <= value and value <= terrain.noise_max:
				terrain_lookup_table[i] = terrain
				break
		if terrain_lookup_table[i] == null:
			push_warning("DG3DProcGen: no terrain for noise value %s" % value)

func get_terrain_for_noise(noise_value: float) -> DG3DTerrain:
	var idx = clamp(int(noise_value * (TERRAIN_LOOKUP_BUCKETS - 1)), 0, TERRAIN_LOOKUP_BUCKETS - 1)
	return terrain_lookup_table[idx]

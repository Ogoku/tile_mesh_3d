@tool
class_name PreviewCursor
extends MultiMeshInstance3D

## Ghost preview mesh that follows mouse cursor during tile placement
##
## Responsibilities:
## - Display semi-transparent preview of selected tile
## - Follow mouse position (snapped to grid)
## - Update mesh when tile selection or plane mode changes
## - Show/hide based on paint mode state
## - React to grid position changes (WASD movement)

var current_tile_key: Dictionary = {}
var current_tileset: TileSet = null
var current_plane: GridManager.PlaneMode = GridManager.PlaneMode.XZ
var preview_alpha: float = 0.65

var _preview_mesh: Mesh = null
var _preview_material: StandardMaterial3D = null


func _ready() -> void:
	deprint("_ready() called")

	# MultiMesh setup for single instance preview
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.instance_count = 1

	# Load alpha from ProjectSettings
	preview_alpha = ProjectSettings.get_setting(
		"tile_mesh_3d/painter/preview_alpha",
		0.65
	)

	deprint("MultiMesh initialized, alpha=%f" % preview_alpha)
	hide_preview()


## Hides preview cursor
func hide_preview() -> void:
	visible = false
	deprint("hide_preview() called")


## Sets preview position (already snapped by grid_manager)
## NEW: Also accepts grid_position from GridManager for WASD movement
func set_position_snapped(pos: Vector3) -> void:
	var xform := Transform3D()
	xform.origin = pos
	multimesh.set_instance_transform(0, xform)

	# Auto-show if hidden
	if not visible:
		show_preview()


## Shows preview cursor
func show_preview() -> void:
	visible = true
	deprint("show_preview() called, visible=%s" % visible)


## Updates preview mesh based on selected tile and current plane mode
func update_preview(tile_key: Dictionary, tileset: TileSet, plane: GridManager.PlaneMode = GridManager.PlaneMode.XZ) -> void:
	deprint("update_preview() called with tile_key=%s, plane=%d" % [tile_key, plane])

	if tile_key.is_empty() or tileset == null:
		deprint("Cannot update preview: invalid tile_key or tileset")
		hide_preview()
		return

	current_tile_key = tile_key
	current_tileset = tileset
	current_plane = plane

	# Generate mesh from tile
	_preview_mesh = _create_tile_mesh(tile_key, tileset, plane)

	if _preview_mesh == null:
		deprint("Failed to create preview mesh")
		hide_preview()
		return

	# Apply to MultiMesh
	multimesh.mesh = _preview_mesh

	# Setup transparent material
	_setup_preview_material()

	show_preview()
	deprint("Preview updated for tile: %s on plane %d" % [tile_key, plane])


## Internal: Creates quad mesh with UV mapping from tile atlas, oriented to specified plane
func _create_tile_mesh(tile_key: Dictionary, tileset: TileSet, plane: GridManager.PlaneMode) -> Mesh:
	var source_id: int = tile_key.get("source_id", -1)
	var atlas_coords: Vector2i = tile_key.get("atlas_coords", Vector2i(-1, -1))
	var alt_id: int = tile_key.get("alternative_id", 0)

	if source_id == -1 or atlas_coords.x < 0:
		push_error("PreviewCursor: Invalid tile_key format")
		return null

	var atlas: TileSetAtlasSource = tileset.get_source(source_id) as TileSetAtlasSource
	if atlas == null:
		push_error("PreviewCursor: TileSetAtlasSource not found (source_id=%d)" % source_id)
		return null

	var tile_data: TileData = atlas.get_tile_data(atlas_coords, alt_id)
	if tile_data == null:
		push_error("PreviewCursor: TileData not found at %s (alt=%d)" % [atlas_coords, alt_id])
		return null

	# Get texture region from atlas
	var region: Rect2 = atlas.get_tile_texture_region(atlas_coords)
	var texture: Texture2D = atlas.texture

	if texture == null:
		push_error("PreviewCursor: Atlas has no texture")
		return null

	# Calculate UVs with padding to avoid texture bleeding
	var padding_px: float = ProjectSettings.get_setting(
		"tile_mesh_3d/painter/atlas_padding_px",
		1.0
	)

	var tex_size := Vector2(texture.get_width(), texture.get_height())
	var uv_min := (region.position + Vector2(padding_px, padding_px)) / tex_size
	var uv_max := (region.end - Vector2(padding_px, padding_px)) / tex_size

	# Get plane-aware vertices and normals
	var verts := _get_quad_vertices_for_plane(plane, 1.0)
	var normals := _get_quad_normals_for_plane(plane)

	# UVs (mapped to atlas region)
	var uvs := PackedVector2Array([
		Vector2(uv_max.x, uv_max.y),
		Vector2(uv_min.x, uv_max.y),
		Vector2(uv_min.x, uv_min.y),
		Vector2(uv_max.x, uv_min.y)
	])

	# Indices (2 triangles)
	var indices := PackedInt32Array([
		0, 1, 2,
		0, 2, 3
	])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	# Create material with atlas texture
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = texture
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST  # Pixel-art
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED  # No lighting for preview

	mesh.surface_set_material(0, mat)
	return mesh


## Internal: Returns 4 normals for the specified plane mode
func _get_quad_normals_for_plane(plane: GridManager.PlaneMode) -> PackedVector3Array:
	var n := Vector3.UP
	match plane:
		GridManager.PlaneMode.XZ:
			n = Vector3.UP
		GridManager.PlaneMode.XY:
			n = Vector3.BACK
		GridManager.PlaneMode.YZ:
			n = Vector3.RIGHT
	return PackedVector3Array([n, n, n, n])


## Internal: Returns 4 vertices for a quad on the specified plane
func _get_quad_vertices_for_plane(plane: GridManager.PlaneMode, tile_size: float) -> PackedVector3Array:
	var s := tile_size
	match plane:
		GridManager.PlaneMode.XZ:
			return PackedVector3Array([
				Vector3(0.0, 0.0, 0.0),
				Vector3(s,   0.0, 0.0),
				Vector3(s,   0.0, s),
				Vector3(0.0, 0.0, s)
			])
		GridManager.PlaneMode.XY:
			return PackedVector3Array([
				Vector3(0.0, 0.0, 0.0),
				Vector3(s,   0.0, 0.0),
				Vector3(s,   s,   0.0),
				Vector3(0.0, s,   0.0)
			])
		GridManager.PlaneMode.YZ:
			return PackedVector3Array([
				Vector3(0.0, 0.0, 0.0),
				Vector3(0.0, s,   0.0),
				Vector3(0.0, s,   s),
				Vector3(0.0, 0.0, s)
			])
	# Fallback XZ
	return PackedVector3Array([
		Vector3(0.0, 0.0, 0.0),
		Vector3(s,   0.0, 0.0),
		Vector3(s,   0.0, s),
		Vector3(0.0, 0.0, s)
	])


## Internal: Applies transparent material to preview mesh
func _setup_preview_material() -> void:
	if multimesh.mesh == null:
		return

	# Get base material from mesh
	var base_mat := multimesh.mesh.surface_get_material(0) as StandardMaterial3D
	if base_mat == null:
		return

	# Clone and modify for transparency
	_preview_material = base_mat.duplicate() as StandardMaterial3D
	_preview_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_preview_material.albedo_color.a = preview_alpha
	_preview_material.cull_mode = BaseMaterial3D.CULL_DISABLED  # Show both sides

	# Apply to mesh
	multimesh.mesh.surface_set_material(0, _preview_material)
	deprint("Material setup complete, alpha=%f" % _preview_material.albedo_color.a)


func deprint(msg: String) -> void:
	if ProjectSettings.get_setting("tile_mesh_3d/general/debug", false):
		print("[PreviewCursor] ", msg)

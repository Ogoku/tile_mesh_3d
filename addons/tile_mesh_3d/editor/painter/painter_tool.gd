@tool
class_name PainterTool
extends RefCounted

## Main painting logic for tile placement in 3D viewport
##
## Responsibilities:
## - Process 3D viewport input (mouse events + hotkeys)
## - Raycast against current grid plane
## - Place/remove tiles with undo/redo support
## - Update preview cursor position
## - Generate tile meshes with UV mapping and collision
## - Switch placement plane (XZ/XY/YZ) and adjust offset
## - NEW: Automatic plane switching based on camera direction

signal tile_placed(mesh: MeshInstance3D)
signal tile_removed(mesh: MeshInstance3D)
signal plane_info_changed(plane_name: String, offset: float)

var _target: TileMesh3D
var _current_tile_key: Dictionary = {}
var _grid_manager: GridManager
var _preview_cursor: PreviewCursor
var _undo_redo: EditorUndoRedoManager
var _camera: Camera3D

var _is_active: bool = false
var _mouse_over_viewport: bool = false


## Activates painter tool for specified target node
func activate(target: TileMesh3D, tile_key: Dictionary, undo_redo: EditorUndoRedoManager) -> void:
	if _is_active:
		deactivate()

	_target = target
	_current_tile_key = tile_key
	_undo_redo = undo_redo
	_is_active = true

	# Initialize grid manager
	_grid_manager = GridManager.new()
	_grid_manager.set_grid_size_from_node(target)
	_grid_manager.set_plane(GridManager.PlaneMode.XZ)
	_grid_manager.plane_changed.connect(_on_plane_changed)
	_grid_manager.grid_position_changed.connect(_on_grid_position_changed)

	# Initialize preview cursor
	_preview_cursor = PreviewCursor.new()
	_preview_cursor.name = "TilePainterPreview"
	_preview_cursor.top_level = true

	target.add_child(_preview_cursor, false, Node.INTERNAL_MODE_BACK)
	deprint("Preview added as INTERNAL child")

	deprint("Preview instance valid: %s" % is_instance_valid(_preview_cursor))
	deprint("Preview visible: %s" % _preview_cursor.visible)
	deprint("Preview parent: %s" % _preview_cursor.get_parent().name)

	if not tile_key.is_empty() and target.tileset != null:
		_preview_cursor.update_preview(tile_key, target.tileset, _grid_manager.current_plane)
	else:
		deprint("No tile selected or no tileset - preview hidden")

	_emit_plane_info()
	deprint("Painter tool activated for %s" % target.name)


## Deactivates painter tool and cleans up
func deactivate() -> void:
	if not _is_active:
		return

	_is_active = false
	deprint("Deactivating painter tool")

	# Cleanup preview cursor
	if _preview_cursor != null and is_instance_valid(_preview_cursor):
		deprint("Removing preview cursor")
		if _preview_cursor.get_parent() != null:
			_preview_cursor.get_parent().remove_child(_preview_cursor)
		_preview_cursor.queue_free()
		_preview_cursor = null

	# Disconnect signals
	if _grid_manager != null:
		if _grid_manager.plane_changed.is_connected(_on_plane_changed):
			_grid_manager.plane_changed.disconnect(_on_plane_changed)
		if _grid_manager.grid_position_changed.is_connected(_on_grid_position_changed):
			_grid_manager.grid_position_changed.disconnect(_on_grid_position_changed)
		_grid_manager = null

	_target = null
	_current_tile_key = {}
	deprint("Painter tool deactivated")


## Handles 3D viewport input events (mouse, keyboard)
## Returns EditorPlugin.AFTER_GUI_INPUT_STOP if handled, else AFTER_GUI_INPUT_PASS
func forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if not _is_active or _target == null:
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	_camera = camera

	# NEW: Auto-detect and switch plane based on camera direction
	_auto_update_plane(camera)

	# Keyboard input - plane switching and offset
	if event is InputEventKey and event.pressed and not event.echo:
		var result := _handle_key_input(event)
		if result != EditorPlugin.AFTER_GUI_INPUT_PASS:
			return result

	# Mouse scroll with Shift - adjust plane offset
	if event is InputEventMouseButton and event.pressed and event.shift_pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_grid_manager.adjust_offset(_grid_manager.grid_size)
			_emit_plane_info()
			deprint("Offset increased to %f" % _grid_manager.plane_offset)
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_grid_manager.adjust_offset(-_grid_manager.grid_size)
			_emit_plane_info()
			deprint("Offset decreased to %f" % _grid_manager.plane_offset)
			return EditorPlugin.AFTER_GUI_INPUT_STOP

	# Mouse motion - update preview position
	if event is InputEventMouseMotion:
		_handle_mouse_motion(event)
		return EditorPlugin.AFTER_GUI_INPUT_PASS  # Don't block camera controls

	# Mouse buttons - place/remove tiles
	if event is InputEventMouseButton and event.pressed:
		return _handle_mouse_button(event)

	return EditorPlugin.AFTER_GUI_INPUT_PASS


## Returns current grid manager (for external access, e.g. status display)
func get_grid_manager() -> GridManager:
	return _grid_manager


## Updates current tile selection
func set_current_tile(tile_key: Dictionary) -> void:
	if not _is_active:
		return

	deprint("set_current_tile called: %s" % tile_key)
	_current_tile_key = tile_key

	if _preview_cursor != null and _target != null and _target.tileset != null:
		_preview_cursor.update_preview(tile_key, _target.tileset, _grid_manager.current_plane)


## NEW: Automatically detects and switches plane based on camera direction
func _auto_update_plane(camera: Camera3D) -> void:
	if not _grid_manager:
		return

	# Detect which plane the camera is looking at
	var plane_changed := _grid_manager.update_plane_from_camera(camera)

	if plane_changed:
		# Refresh preview for new plane orientation
		_refresh_preview()

		# Emit signal for dock UI update
		_emit_plane_info()

		deprint("Auto-switched to plane: %s" % _grid_manager.get_plane_name())


## Internal: Refreshes preview mesh (called after plane changes)
func _refresh_preview() -> void:
	if _preview_cursor == null or _current_tile_key.is_empty():
		return

	if _target == null or _target.tileset == null:
		return

	_preview_cursor.update_preview(
		_current_tile_key,
		_target.tileset,
		_grid_manager.current_plane
	)


## Internal: Emits plane info for UI status display
func _emit_plane_info() -> void:
	if _grid_manager != null:
		emit_signal("plane_info_changed", _grid_manager.get_plane_name(), _grid_manager.plane_offset)


## Internal: Signal handler for grid position changes (WASD movement)
func _on_grid_position_changed(new_position: Vector3) -> void:
	if _preview_cursor == null:
		return

	# Update preview cursor to follow grid position
	var snapped_pos := _grid_manager.snap_to_plane(new_position)
	_preview_cursor.set_position_snapped(snapped_pos)


## Internal: Signal handler for plane changes
func _on_plane_changed(new_plane: GridManager.PlaneMode) -> void:
	deprint("Plane changed to: %s" % _grid_manager.get_plane_name())

	# Refresh preview for new plane orientation
	_refresh_preview()

	# Emit signal for dock UI update
	_emit_plane_info()


## Internal: Applies collision shape to tile if physics layer exists
func _apply_tile_collision(mesh: MeshInstance3D, tile_key: Dictionary) -> void:
	var source_id: int = tile_key.get("source_id", -1)
	var atlas_coords: Vector2i = tile_key.get("atlas_coords", Vector2i(-1, -1))
	var alt_id: int = tile_key.get("alternative_id", 0)

	if source_id == -1 or atlas_coords.x < 0:
		return

	var atlas: TileSetAtlasSource = _target.tileset.get_source(source_id) as TileSetAtlasSource
	if atlas == null:
		return

	var tile_data: TileData = atlas.get_tile_data(atlas_coords, alt_id)
	if tile_data == null:
		return

	# Check if tile has physics layer (layer 0 is default)
	var physics_layer_count := tile_data.get_collision_polygons_count(0)
	if physics_layer_count == 0:
		return  # No collision data

	# Create StaticBody3D with box collision
	var body := StaticBody3D.new()
	body.name = "CollisionBody"

	var shape := CollisionShape3D.new()
	shape.name = "CollisionShape"

	var box := BoxShape3D.new()
	box.size = Vector3(_target.tile_world_size, _target.tile_world_size, _target.tile_world_size)
	shape.shape = box

	# Center the collision box
	var half_size := _target.tile_world_size * 0.5
	shape.position = Vector3(half_size, half_size, half_size)

	body.add_child(shape)
	mesh.add_child(body)

	# Set owner for proper scene tree integration
	body.owner = _target
	shape.owner = _target

	deprint("Collision applied to tile at %s" % mesh.position)


## Internal: Creates MeshInstance3D from tile_key with UV mapping
## Uses grid_manager.current_plane for correct vertex orientation
func _create_tile_mesh(tile_key: Dictionary) -> MeshInstance3D:
	var source_id: int = tile_key.get("source_id", -1)
	var atlas_coords: Vector2i = tile_key.get("atlas_coords", Vector2i(-1, -1))
	var alt_id: int = tile_key.get("alternative_id", 0)

	if source_id == -1 or atlas_coords.x < 0:
		push_error("PainterTool: Invalid tile_key format")
		return null

	var atlas: TileSetAtlasSource = _target.tileset.get_source(source_id) as TileSetAtlasSource
	if atlas == null:
		push_error("PainterTool: TileSetAtlasSource not found (source_id=%d)" % source_id)
		return null

	var tile_data: TileData = atlas.get_tile_data(atlas_coords, alt_id)
	if tile_data == null:
		push_error("PainterTool: TileData not found at %s (alt=%d)" % [atlas_coords, alt_id])
		return null

	# Get texture region from atlas
	var region: Rect2 = atlas.get_tile_texture_region(atlas_coords)
	var texture: Texture2D = atlas.texture

	if texture == null:
		push_error("PainterTool: Atlas has no texture")
		return null

	# Calculate UVs with padding to avoid texture bleeding
	var padding_px: float = ProjectSettings.get_setting(
		"tile_mesh_3d/painter/atlas_padding_px",
		1.0
	)

	var tex_size := Vector2(texture.get_width(), texture.get_height())
	var uv_min := (region.position + Vector2(padding_px, padding_px)) / tex_size
	var uv_max := (region.end - Vector2(padding_px, padding_px)) / tex_size

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	# Plane-aware vertices and normals from GridManager
	var verts := _grid_manager.get_quad_vertices(_target.tile_world_size)
	var normals := _grid_manager.get_quad_normals()

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
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	mesh.surface_set_material(0, mat)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh

	# Store plane mode as metadata for potential later use
	mesh_instance.set_meta("plane_mode", _grid_manager.current_plane)

	return mesh_instance


## Internal: Finds tile mesh at specified position
func _get_tile_at_position(world_pos: Vector3) -> MeshInstance3D:
	var snap_threshold := _grid_manager.grid_size * 0.1  # 10% tolerance

	for child in _target.get_children(true):
		if child is MeshInstance3D and child != _preview_cursor:
			var distance = child.position.distance_to(world_pos)
			if distance < snap_threshold:
				return child
	return null


## Internal: Handles keyboard input for plane switching
func _handle_key_input(event: InputEventKey) -> int:
	match event.keycode:
		KEY_X:
			_grid_manager.set_plane(GridManager.PlaneMode.YZ, _grid_manager.plane_offset)
			_refresh_preview()
			_emit_plane_info()
			deprint("Switched to YZ plane (Side Wall)")
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		KEY_Y:
			_grid_manager.set_plane(GridManager.PlaneMode.XZ, _grid_manager.plane_offset)
			_refresh_preview()
			_emit_plane_info()
			deprint("Switched to XZ plane (Floor/Ceiling)")
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		KEY_Z:
			_grid_manager.set_plane(GridManager.PlaneMode.XY, _grid_manager.plane_offset)
			_refresh_preview()
			_emit_plane_info()
			deprint("Switched to XY plane (Front/Back Wall)")
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		KEY_G:
			# Toggle grid visibility (Phase 2)
			deprint("Grid toggle (not yet implemented)")
			return EditorPlugin.AFTER_GUI_INPUT_STOP

	return EditorPlugin.AFTER_GUI_INPUT_PASS


## Internal: Handles mouse button clicks for placement/removal
func _handle_mouse_button(event: InputEventMouseButton) -> int:
	var place_button: int = ProjectSettings.get_setting(
		"tile_mesh_3d/painter/place_button",
		MOUSE_BUTTON_LEFT
	)
	var remove_button: int = ProjectSettings.get_setting(
		"tile_mesh_3d/painter/remove_button",
		MOUSE_BUTTON_RIGHT
	)

	# Calculate world position
	var world_pos := _grid_manager.raycast_to_grid(_camera, event.position)
	if world_pos == null:
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	# Place tile
	if event.button_index == place_button:
		if _current_tile_key.is_empty():
			deprint("Cannot place tile: no tile selected")
			return EditorPlugin.AFTER_GUI_INPUT_STOP

		_place_tile(world_pos)
		return EditorPlugin.AFTER_GUI_INPUT_STOP

	# Remove tile
	if event.button_index == remove_button:
		_remove_tile(world_pos)
		return EditorPlugin.AFTER_GUI_INPUT_STOP

	return EditorPlugin.AFTER_GUI_INPUT_PASS


## Internal: Handles mouse motion for preview cursor
func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	var world_pos := _grid_manager.raycast_to_grid(_camera, event.position)

	if world_pos != null:
		_preview_cursor.set_position_snapped(world_pos)
		_mouse_over_viewport = true
	else:
		_preview_cursor.hide_preview()
		_mouse_over_viewport = false


## Internal: Places tile at world position with undo/redo support
func _place_tile(world_pos: Vector3) -> void:
	# Check if tile already exists at position
	var existing_tile := _get_tile_at_position(world_pos)
	if existing_tile != null:
		deprint("Tile already exists at position %s" % world_pos)
		return

	# Create tile mesh
	var mesh_instance := _create_tile_mesh(_current_tile_key)
	if mesh_instance == null:
		push_error("PainterTool: Failed to create tile mesh")
		return

	mesh_instance.position = world_pos

	# Generate name based on plane mode and position
	var plane_prefix := "F"  # Floor
	match _grid_manager.current_plane:
		GridManager.PlaneMode.XY:
			plane_prefix = "W"  # Wall (front/back)
		GridManager.PlaneMode.YZ:
			plane_prefix = "S"  # Side wall

	mesh_instance.name = "Tile_%s_%d_%d_%d" % [
		plane_prefix,
		int(world_pos.x),
		int(world_pos.y),
		int(world_pos.z)
	]

	# Apply collision if tile has physics layer
	_apply_tile_collision(mesh_instance, _current_tile_key)

	# Undo/Redo action
	_undo_redo.create_action("Place Tile")
	_undo_redo.add_do_method(self, "_do_place_tile", mesh_instance)
	_undo_redo.add_undo_method(self, "_undo_place_tile", mesh_instance)
	_undo_redo.commit_action()

	emit_signal("tile_placed", mesh_instance)


## Internal: Removes tile at world position with undo/redo support
func _remove_tile(world_pos: Vector3) -> void:
	deprint("_remove_tile() called at position: %s" % world_pos)

	var tile := _get_tile_at_position(world_pos)

	if tile == null:
		deprint("No tile found at position %s" % world_pos)
		return

	# Undo/Redo action
	_undo_redo.create_action("Remove Tile")
	_undo_redo.add_do_method(self, "_do_remove_tile", tile)
	_undo_redo.add_undo_method(self, "_undo_remove_tile", tile)
	_undo_redo.commit_action()

	deprint("Removed tile: %s" % tile.name)
	emit_signal("tile_removed", tile)


## Undo/Redo methods (must be public for EditorUndoRedoManager)

func _do_place_tile(mesh: MeshInstance3D) -> void:
	_target.add_child(mesh, false, Node.INTERNAL_MODE_BACK)
	mesh.owner = _target.get_tree().edited_scene_root


func _undo_place_tile(mesh: MeshInstance3D) -> void:
	if is_instance_valid(mesh):
		_target.remove_child(mesh)
		mesh.queue_free()


func _do_remove_tile(mesh: MeshInstance3D) -> void:
	if is_instance_valid(mesh):
		_target.remove_child(mesh)


func _undo_remove_tile(mesh: MeshInstance3D) -> void:
	if is_instance_valid(mesh):
		_target.add_child(mesh)
		mesh.owner = _target.get_tree().edited_scene_root


func deprint(msg: String) -> void:
	if ProjectSettings.get_setting("tile_mesh_3d/general/debug", false):
		print("[PainterTool] ", msg)

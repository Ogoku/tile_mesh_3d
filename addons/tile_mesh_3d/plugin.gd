@tool
extends EditorPlugin

const CUSTOM_TYPE_NAME := "TileMesh3D"
const CUSTOM_BASE_TYPE := "Node3D"
const TILE_MESH_SCRIPT := preload("res://addons/tile_mesh_3d/nodes/tile_mesh_3d.gd")
const PAINTER_TOOL_SCRIPT := preload("res://addons/tile_mesh_3d/editor/painter/painter_tool.gd")

var _tileset_dock: TilesetDock
var _selection: EditorSelection
var _selected_tile_key: Dictionary = {}
var _target_node: TileMesh3D
var _painter_tool: PainterTool


func _enter_tree() -> void:
	_register_project_settings()

	# Optional icon: use a built-in editor icon so we don't depend on an asset yet.
	var base_control := get_editor_interface().get_base_control()
	var _custom_icon = base_control.get_theme_icon("MultiMeshInstance3D", "EditorIcons")

	# Register our custom node type so it appears in "Create New Node".
	add_custom_type(CUSTOM_TYPE_NAME, CUSTOM_BASE_TYPE, TILE_MESH_SCRIPT, _custom_icon)

	_selection = get_editor_interface().get_selection()
	_selection.selection_changed.connect(_on_selection_changed)

	_tileset_dock = preload("res://addons/tile_mesh_3d/editor/dock/tileset_dock.tscn").instantiate()
	_tileset_dock.tile_selected.connect(_on_tile_selected)
	_tileset_dock.plane_changed.connect(_on_dock_plane_changed)
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, _tileset_dock)

	_on_selection_changed()


func _exit_tree() -> void:
	# Cleanup painter tool
	if _painter_tool != null:
		_painter_tool.deactivate()
		_painter_tool = null

	# Unregister custom node type
	remove_custom_type(CUSTOM_TYPE_NAME)

	if _selection and _selection.selection_changed.is_connected(_on_selection_changed):
		_selection.selection_changed.disconnect(_on_selection_changed)

	if _tileset_dock:
		if _tileset_dock.tile_selected.is_connected(_on_tile_selected):
			_tileset_dock.tile_selected.disconnect(_on_tile_selected)
		if _tileset_dock.plane_changed.is_connected(_on_dock_plane_changed):
			_tileset_dock.plane_changed.disconnect(_on_dock_plane_changed)
		remove_control_from_docks(_tileset_dock)
		_tileset_dock.queue_free()
		_tileset_dock = null


func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	# NEW: Handle keyboard input for WASD grid movement
	if event is InputEventKey and event.pressed and not event.echo:
		var result := _handle_keyboard_input(event, camera)
		if result != EditorPlugin.AFTER_GUI_INPUT_PASS:
			return result
	
	# Existing painter tool input
	if _painter_tool != null:
		return _painter_tool.forward_3d_gui_input(camera, event)
	
	return EditorPlugin.AFTER_GUI_INPUT_PASS


func _handles(object: Object) -> bool:
	var handles := object is TileMesh3D
	if handles:
		deprint("_handles() called for TileMesh3D - returning true")
	return handles


func _make_visible(visible: bool) -> void:
	if visible:
		deprint("Plugin made visible - 3D input enabled")
	else:
		deprint("Plugin made invisible - 3D input disabled")
		if _painter_tool != null:
			_painter_tool.deactivate()


func _on_dock_plane_changed(plane_mode: int, offset: float) -> void:
	deprint("Dock plane changed: mode=%d, offset=%f" % [plane_mode, offset])

	if _painter_tool == null or not _painter_tool._is_active:
		return

	var gm := _painter_tool.get_grid_manager()
	if gm == null:
		return

	gm.set_plane(plane_mode as GridManager.PlaneMode, offset)

	# Refresh preview mesh for new plane orientation
	_painter_tool._refresh_preview()

	# Update dock status
	if _tileset_dock != null:
		_tileset_dock.set_plane_info(gm.get_plane_name(), gm.plane_offset)


func _on_plane_info_changed(plane_name: String, offset: float) -> void:
	if _tileset_dock != null:
		_tileset_dock.set_plane_info(plane_name, offset)


func _on_selection_changed() -> void:
	var nodes := _selection.get_selected_nodes()

	if nodes.size() == 1 and nodes[0] is TileMesh3D:
		_target_node = nodes[0]
		_tileset_dock.set_target(_target_node)

		# Activate painter tool
		if _painter_tool == null:
			_painter_tool = PAINTER_TOOL_SCRIPT.new()
			_painter_tool.plane_info_changed.connect(_on_plane_info_changed)

		# Check if target has tileset before activation
		if _target_node.tileset != null:
			_painter_tool.activate(
				_target_node,
				_selected_tile_key,
				get_undo_redo()
			)
		else:
			deprint("TileMesh3D has no tileset assigned - painter tool inactive")
	else:
		# Deactivate painter tool
		if _painter_tool != null:
			_painter_tool.deactivate()

		_target_node = null
		_tileset_dock.clear_target()


func _on_tile_selected(tile_key: Dictionary) -> void:
	deprint("Selected tile_key: %s" % tile_key)

	_selected_tile_key = tile_key.duplicate(true)

	# Update painter tool if active
	if _painter_tool != null:
		_painter_tool.set_current_tile(tile_key)


# ============================================================================
# NEW: Keyboard Input Handling for Grid Movement
# ============================================================================

## Handles WASD keyboard input for grid movement
func _handle_keyboard_input(event: InputEventKey, camera: Camera3D) -> int:
	if not _painter_tool or not _painter_tool._is_active:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	
	# Check UI Focus (prevents WASD when typing in LineEdit/SpinBox)
	var focused = get_editor_interface().get_base_control().get_viewport().gui_get_focus_owner()
	if focused and (focused is LineEdit or focused is SpinBox or focused is TextEdit):
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	
	var gm := _painter_tool.get_grid_manager()
	if not gm:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	
	var shift_pressed := event.shift_pressed
	var move_vector := Vector3.ZERO
	var basis := camera.global_transform.basis
	
	# Determine movement direction
	match event.keycode:
		KEY_W:
			if shift_pressed:
				move_vector = _snap_to_cardinal(basis.y)       # Up
			else:
				move_vector = _snap_to_cardinal(-basis.z)      # Forward
		
		KEY_S:
			if shift_pressed:
				move_vector = _snap_to_cardinal(-basis.y)      # Down
			else:
				move_vector = _snap_to_cardinal(basis.z)       # Backward
		
		KEY_A:
			move_vector = _snap_to_cardinal(-basis.x)          # Left
		
		KEY_D:
			move_vector = _snap_to_cardinal(basis.x)           # Right
	
	# Execute movement
	if move_vector.length_squared() > 0.0:
		gm.move_grid_position(move_vector)
		
		# Update preview cursor position to match grid
		if _painter_tool._preview_cursor:
			_painter_tool._preview_cursor.set_position_snapped(gm.grid_position)
		
		deprint("Grid moved to: %s" % gm.grid_position)
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	
	return EditorPlugin.AFTER_GUI_INPUT_PASS


## Snaps a direction vector to nearest cardinal direction (+/- X/Y/Z)
func _snap_to_cardinal(direction: Vector3) -> Vector3:
	var abs_x := abs(direction.x)
	var abs_y := abs(direction.y)
	var abs_z := abs(direction.z)
	
	if abs_x > abs_y and abs_x > abs_z:
		return Vector3(sign(direction.x), 0, 0)
	elif abs_y > abs_z:
		return Vector3(0, sign(direction.y), 0)
	else:
		return Vector3(0, 0, sign(direction.z))


# ============================================================================
# ProjectSettings Registration
# ============================================================================

func _register_project_settings() -> void:
	# General
	ProjectSettings.set_setting("tile_mesh_3d/general/debug", false)
	ProjectSettings.set_initial_value("tile_mesh_3d/general/debug", false)
	
	# Grid
	ProjectSettings.set_setting("tile_mesh_3d/grid/show_grid", true)
	ProjectSettings.set_initial_value("tile_mesh_3d/grid/show_grid", true)
	
	ProjectSettings.set_setting("tile_mesh_3d/grid/line_color", Color(1.0, 1.0, 1.0, 0.25))
	ProjectSettings.set_initial_value("tile_mesh_3d/grid/line_color", Color(1.0, 1.0, 1.0, 0.25))
	
	ProjectSettings.set_setting("tile_mesh_3d/grid/extent", 20)
	ProjectSettings.set_initial_value("tile_mesh_3d/grid/extent", 20)
	
	# Painter
	ProjectSettings.set_setting("tile_mesh_3d/painter/default_grid_size", 1.0)
	ProjectSettings.set_initial_value("tile_mesh_3d/painter/default_grid_size", 1.0)

	ProjectSettings.set_setting("tile_mesh_3d/painter/max_raycast_distance", 4096.0)
	ProjectSettings.set_initial_value("tile_mesh_3d/painter/max_raycast_distance", 4096.0)

	ProjectSettings.set_setting("tile_mesh_3d/painter/place_button", int(MOUSE_BUTTON_LEFT))
	ProjectSettings.set_initial_value("tile_mesh_3d/painter/place_button", int(MOUSE_BUTTON_LEFT))

	ProjectSettings.set_setting("tile_mesh_3d/painter/remove_button", int(MOUSE_BUTTON_RIGHT))
	ProjectSettings.set_initial_value("tile_mesh_3d/painter/remove_button", int(MOUSE_BUTTON_RIGHT))

	ProjectSettings.set_setting("tile_mesh_3d/painter/preview_alpha", 0.65)
	ProjectSettings.set_initial_value("tile_mesh_3d/painter/preview_alpha", 0.65)

	ProjectSettings.set_setting("tile_mesh_3d/painter/atlas_padding_px", 1.0)
	ProjectSettings.set_initial_value("tile_mesh_3d/painter/atlas_padding_px", 1.0)


func deprint(msg: String) -> void:
	if ProjectSettings.get_setting("tile_mesh_3d/general/debug", false):
		print("[TileMesh3DPlugin] ", msg)

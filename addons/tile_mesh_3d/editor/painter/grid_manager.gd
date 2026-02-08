@tool
class_name GridManager
extends RefCounted

## Manages grid plane switching, snapping, and grid visualization for tile placement
##
## Responsibilities:
## - Current plane mode (XZ, XY, YZ)
## - Grid snapping calculations
## - Raycast plane generation for mouse intersection
## - Quad vertex/normal generation per plane mode
## - Grid position tracking for WASD movement
## - Simple plane detection based on camera direction

signal plane_changed(new_plane: PlaneMode)
signal offset_changed(new_offset: float)
signal grid_position_changed(new_position: Vector3)

enum PlaneMode { XZ, XY, YZ }

var current_plane: PlaneMode = PlaneMode.XZ
var grid_size: float = 1.0
var plane_offset: float = 0.0  # Y-offset for XZ, Z-offset for XY, X-offset for YZ
var grid_visible: bool = false

# NEW: Grid position for WASD movement (world space)
var grid_position: Vector3 = Vector3.ZERO


func _init() -> void:
	pass


## Adjusts plane offset by delta (typically ±grid_size)
func adjust_offset(delta: float) -> void:
	plane_offset += delta
	deprint("Offset adjusted to %f" % plane_offset)
	emit_signal("offset_changed", plane_offset)


## NEW: Detects which plane the camera is looking at
## Returns the plane that's most perpendicular to camera forward vector
func detect_plane_from_camera(camera: Camera3D) -> PlaneMode:
	if not camera:
		return current_plane
	
	var camera_forward := -camera.global_transform.basis.z
	var abs_x := abs(camera_forward.x)
	var abs_y := abs(camera_forward.y)
	var abs_z := abs(camera_forward.z)
	
	# Y-axis dominant (looking up/down) → XZ plane (floor/ceiling)
	if abs_y > abs_x and abs_y > abs_z:
		return PlaneMode.XZ
	
	# X-axis dominant (looking left/right) → YZ plane (side wall)
	elif abs_x > abs_y and abs_x > abs_z:
		return PlaneMode.YZ
	
	# Z-axis dominant (looking forward/back) → XY plane (front/back wall)
	else:
		return PlaneMode.XY


## Returns human-readable plane name for UI/debug
func get_plane_name() -> String:
	match current_plane:
		PlaneMode.XZ:
			return "XZ (Floor/Ceiling)"
		PlaneMode.XY:
			return "XY (Front/Back Wall)"
		PlaneMode.YZ:
			return "YZ (Side Wall)"
	return "Unknown"


## Returns the normal vector of the current plane
func get_plane_normal() -> Vector3:
	match current_plane:
		PlaneMode.XZ:
			return Vector3.UP
		PlaneMode.XY:
			return Vector3.BACK
		PlaneMode.YZ:
			return Vector3.RIGHT
	return Vector3.UP


## Returns PackedVector3Array with 4 normals for quad mesh on current plane
func get_quad_normals() -> PackedVector3Array:
	var n := get_plane_normal()
	return PackedVector3Array([n, n, n, n])


## Returns PackedVector3Array with 4 vertices for a quad on the current plane
## Vertices form a tile_size × tile_size quad starting at origin (0,0,0)
func get_quad_vertices(tile_size: float) -> PackedVector3Array:
	var s := tile_size
	match current_plane:
		PlaneMode.XZ:
			# Floor/Ceiling: spans X and Z
			return PackedVector3Array([
				Vector3(0.0, 0.0, 0.0),
				Vector3(s,   0.0, 0.0),
				Vector3(s,   0.0, s),
				Vector3(0.0, 0.0, s)
			])
		PlaneMode.XY:
			# Front/Back wall: spans X and Y
			return PackedVector3Array([
				Vector3(0.0, 0.0, 0.0),
				Vector3(s,   0.0, 0.0),
				Vector3(s,   s,   0.0),
				Vector3(0.0, s,   0.0)
			])
		PlaneMode.YZ:
			# Side wall: spans Y and Z
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


## Returns mathematical Plane for raycasting based on current plane mode
## The plane is offset by both plane_offset AND grid_position (for WASD movement)
func get_raycast_plane() -> Plane:
	match current_plane:
		PlaneMode.XZ:
			# XZ plane (floor/ceiling) - offset by Y component of grid_position
			return Plane(Vector3.UP, plane_offset + grid_position.y)
		PlaneMode.XY:
			# XY plane (front/back wall) - offset by Z component of grid_position
			return Plane(Vector3.BACK, plane_offset + grid_position.z)
		PlaneMode.YZ:
			# YZ plane (side wall) - offset by X component of grid_position
			return Plane(Vector3.RIGHT, plane_offset + grid_position.x)
	return Plane()


## NEW: Moves grid position by offset (for WASD movement)
## Offset should be a cardinal direction (e.g. Vector3(1,0,0) for right)
func move_grid_position(offset: Vector3) -> void:
	grid_position += offset * grid_size
	deprint("Grid position moved to: %s" % grid_position)
	emit_signal("grid_position_changed", grid_position)


## Performs raycast from camera through mouse position against current plane
## Returns snapped world position or null if no intersection
func raycast_to_grid(camera: Camera3D, mouse_pos: Vector2) -> Variant:
	var from := camera.project_ray_origin(mouse_pos)
	var dir := camera.project_ray_normal(mouse_pos)

	var plane := get_raycast_plane()
	var intersection := plane.intersects_ray(from, dir)

	if intersection == null:
		return null

	return snap_to_plane(intersection)


## Sets grid size from TileMesh3D node or fallback to ProjectSettings
func set_grid_size_from_node(node: TileMesh3D) -> void:
	if node != null and node.tile_world_size > 0.0:
		grid_size = node.tile_world_size
		deprint("Grid size set from node: %f" % grid_size)
	else:
		grid_size = ProjectSettings.get_setting(
			"tile_mesh_3d/painter/default_grid_size",
			1.0
		)
		deprint("Grid size set from ProjectSettings: %f" % grid_size)


## Sets plane offset directly
func set_offset(offset: float) -> void:
	plane_offset = offset
	deprint("Offset set to %f" % plane_offset)
	emit_signal("offset_changed", plane_offset)


## Switches to specified plane mode
func set_plane(mode: PlaneMode, offset: float = 0.0) -> void:
	var old_plane := current_plane
	current_plane = mode
	plane_offset = offset
	
	if old_plane != mode:
		deprint("Plane switched to %s (offset: %f)" % [get_plane_name(), offset])
		emit_signal("plane_changed", mode)


## NEW: Updates plane based on camera direction (auto-detection)
func update_plane_from_camera(camera: Camera3D) -> bool:
	var detected_plane := detect_plane_from_camera(camera)
	
	if detected_plane != current_plane:
		set_plane(detected_plane, plane_offset)
		return true  # Plane changed
	
	return false  # No change


## Snaps world position to grid based on current grid_size
func snap_to_grid(pos: Vector3) -> Vector3:
	return Vector3(
		_snap_axis(pos.x),
		_snap_axis(pos.y),
		_snap_axis(pos.z)
	)


## Snaps position to grid and locks to current plane
## IMPORTANT: Must include grid_position offset to respect WASD movement
func snap_to_plane(pos: Vector3) -> Vector3:
	var snapped := snap_to_grid(pos)

	# Lock the axis perpendicular to current plane, including grid_position offset
	match current_plane:
		PlaneMode.XZ:
			snapped.y = plane_offset + grid_position.y  # FIX: Include grid_position.y
		PlaneMode.XY:
			snapped.z = plane_offset + grid_position.z  # FIX: Include grid_position.z
		PlaneMode.YZ:
			snapped.x = plane_offset + grid_position.x  # FIX: Include grid_position.x

	return snapped


## Internal: Snaps single axis value to grid
func _snap_axis(value: float) -> float:
	return floor(value / grid_size) * grid_size


func deprint(msg: String) -> void:
	if ProjectSettings.get_setting("tile_mesh_3d/general/debug", false):
		print("[GridManager] ", msg)

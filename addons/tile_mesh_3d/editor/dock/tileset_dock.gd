@tool
class_name TilesetDock
extends Control

signal plane_changed(plane_mode: int, offset: float)
signal tile_selected(tile_key: Dictionary)

@onready var _target_label: Label = $mc/tabs/tileset_settings/header/lbl_target
@onready var _source_option: OptionButton = $mc/tabs/tileset_settings/header/btn_refresh
@onready var _alt_spin: SpinBox = $mc/tabs/tileset_settings/source/sb_alt_spin
@onready var _atlas_view: TextureRect = $mc/tabs/tileset_settings/atlas/content/atlas_view
@onready var _selected_label: Label = $mc/tabs/tileset_settings/info/lbl_selected
@onready var _status_label: Label = $mc/tabs/tileset_settings/info/lbl_status
@onready var _btn_xz: Button = $mc/tabs/tileset_settings/plane/btn_xz
@onready var _btn_xy: Button = $mc/tabs/tileset_settings/plane/btn_xy
@onready var _btn_yz: Button = $mc/tabs/tileset_settings/plane/btn_yz
@onready var _offset_spin: SpinBox = $mc/tabs/tileset_settings/offset/sb_offset

var show_grid: bool = true
var grid_line_alpha: float = 0.25

var _target: TileMesh3D
var _tileset: TileSet
var _current_source_id: int = -1
var _current_atlas: TileSetAtlasSource
var _current_plane: int = 0  # GridManager.PlaneMode.XZ
var _selected_atlas_coords: Vector2i = Vector2i(-1, -1)


func clear_target() -> void:
	deprint("clear target")
	_target = null
	_tileset = null
	_current_atlas = null
	_current_source_id = -1
	_selected_atlas_coords = Vector2i(-1, -1)

	_source_option.clear()
	_atlas_view.set_texture(null)

	_target_label.text = "Target: (none)"
	_selected_label.text = "Selected: (none)"
	_status_label.text = "Select a TileMesh3D node to begin."


func get_selected_tile_key() -> Dictionary:
	if _current_source_id == -1 or _selected_atlas_coords.x < 0:
		return {}

	return {
		"source_id": _current_source_id,
		"atlas_coords": _selected_atlas_coords,
		"alternative_id": int(_alt_spin.value),
	}


## Updates plane info display in status label (called from plugin when painter changes plane)
func set_plane_info(plane_name: String, offset: float) -> void:
	_status_label.text = "Plane: %s | Offset: %.1f" % [plane_name, offset]

	# Sync buttons without re-emitting signal
	_sync_plane_buttons_from_name(plane_name)

	# Sync offset spinner without re-emitting signal
	if not is_equal_approx(_offset_spin.value, offset):
		_offset_spin.set_value_no_signal(offset)


func set_target(node: TileMesh3D) -> void:
	_target = node
	_tileset = node.tileset if node != null else null

	_target_label.text = "Target: %s" % (node.name if node != null else "(none)")

	_refresh_sources()
	_refresh_atlas_view()
	_status_label.text = "Plane: XZ (Floor/Ceiling) | Offset: 0.0"


func _atlas_view_to_texture_pos(local_pos: Vector2) -> Vector2:
	if _atlas_view.texture == null:
		return local_pos

	var tex_size := Vector2(_atlas_view.texture.get_width(), _atlas_view.texture.get_height())
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return local_pos

	var rect_size := _atlas_view.get_rect().size
	if rect_size.x <= 0.0 or rect_size.y <= 0.0:
		return local_pos

	var uv := Vector2(local_pos.x / rect_size.x, local_pos.y / rect_size.y)
	return Vector2(uv.x * tex_size.x, uv.y * tex_size.y)


func _ready() -> void:
	_source_option.item_selected.connect(_on_source_selected)
	_alt_spin.value_changed.connect(_on_alt_changed)
	_atlas_view.gui_input.connect(_on_atlas_gui_input)

	_alt_spin.min_value = 0
	_alt_spin.step = 1
	_alt_spin.value = 0

	clear_target()


func _on_alt_changed(_v: float) -> void:
	_update_selected_label()


func _on_atlas_gui_input(ev: InputEvent) -> void:
	if _current_atlas == null or _atlas_view.texture == null:
		_status_label.text = "No Tileset"
		return

	if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		var local_pos := _atlas_view.get_local_mouse_position()
		deprint("local_pos: %s" % local_pos)
		var tex_pos := _atlas_view_to_texture_pos(local_pos)
		deprint("tex_pos: %s" % tex_pos)
		var coords := _pos_to_atlas_coords(tex_pos)
		deprint("coords: %s" % coords)

		if coords.x < 0:
			return

		var alt_id := int(_alt_spin.value)
		var region := _current_atlas.get_tile_texture_region(coords, alt_id)
		if region.size.x <= 0 or region.size.y <= 0:
			_status_label.text = "No tile at %s (alt=%d)" % [coords, alt_id]
			return

		_selected_atlas_coords = coords
		_update_selected_label()
		_atlas_view.queue_redraw()

		emit_signal("tile_selected", get_selected_tile_key())


## Plane button callbacks (connected via .tscn signals)

func _on_offset_changed(value: float) -> void:
	deprint("Offset changed via spinner: %f" % value)
	emit_signal("plane_changed", _current_plane, value)


func _on_plane_xz_pressed() -> void:
	_current_plane = 0  # GridManager.PlaneMode.XZ
	deprint("Plane button: XZ")
	emit_signal("plane_changed", _current_plane, _offset_spin.value)


func _on_plane_xy_pressed() -> void:
	_current_plane = 1  # GridManager.PlaneMode.XY
	deprint("Plane button: XY")
	emit_signal("plane_changed", _current_plane, _offset_spin.value)


func _on_plane_yz_pressed() -> void:
	_current_plane = 2  # GridManager.PlaneMode.YZ
	deprint("Plane button: YZ")
	emit_signal("plane_changed", _current_plane, _offset_spin.value)


func _on_source_selected(idx: int) -> void:
	if idx < 0:
		return
	_current_source_id = int(_source_option.get_item_metadata(idx))
	_refresh_atlas_view()


func _refresh_atlas_view() -> void:
	_selected_atlas_coords = Vector2i(-1, -1)
	_update_selected_label()

	if _tileset == null or _current_source_id == -1:
		_current_atlas = null
		_atlas_view.texture = null
		return

	var src := _tileset.get_source(_current_source_id)
	_current_atlas = src as TileSetAtlasSource
	_atlas_view.texture = _current_atlas.texture if _current_atlas != null else null


func _refresh_sources() -> void:
	_source_option.clear()
	_current_source_id = -1
	_current_atlas = null

	if _tileset == null:
		_status_label.text = "TileMesh3D has no TileSet assigned."
		return

	var count := _tileset.get_source_count()
	for i in range(count):
		var source_id := _tileset.get_source_id(i)
		var src := _tileset.get_source(source_id)
		if src != null and src is TileSetAtlasSource:
			var atlas := src as TileSetAtlasSource
			var tex := atlas.texture
			var label := "%d" % source_id
			if tex != null and tex.resource_path != "":
				label = "%d: %s" % [source_id, tex.resource_path.get_file()]
			_source_option.add_item(label)
			_source_option.set_item_metadata(_source_option.item_count - 1, source_id)

	if _source_option.item_count > 0:
		_source_option.select(0)
		_current_source_id = int(_source_option.get_item_metadata(0))
	else:
		_status_label.text = "TileSet has no TileSetAtlasSource."


func _pos_to_atlas_coords(local_pos: Vector2) -> Vector2i:
	if _current_atlas == null:
		return Vector2i(-1, -1)

	deprint("local_pos: %s" % local_pos)
	var tile_size: Vector2i = _current_atlas.texture_region_size
	deprint("tile_size: %s" % tile_size)
	var separation: Vector2i = _current_atlas.separation
	deprint("separation: %s" % separation)
	var margins: Vector2i = _current_atlas.margins
	deprint("margins: %s" % margins)

	var p := Vector2i(int(floor(local_pos.x)), int(floor(local_pos.y))) - margins
	if p.x < 0 or p.y < 0:
		return Vector2i(-1, -1)

	var step := tile_size + separation
	if step.x <= 0 or step.y <= 0:
		return Vector2i(-1, -1)

	return Vector2i(p.x / step.x, p.y / step.y)


## Internal: Syncs button pressed state from plane name without emitting signals
func _sync_plane_buttons_from_name(plane_name: String) -> void:
	if "XZ" in plane_name and not _btn_xz.button_pressed:
		_btn_xz.set_pressed_no_signal(true)
		_current_plane = 0
	elif "XY" in plane_name and not _btn_xy.button_pressed:
		_btn_xy.set_pressed_no_signal(true)
		_current_plane = 1
	elif "YZ" in plane_name and not _btn_yz.button_pressed:
		_btn_yz.set_pressed_no_signal(true)
		_current_plane = 2


func _update_selected_label() -> void:
	if _selected_atlas_coords.x < 0:
		_selected_label.text = "Selected: (none)"
		return
	_selected_label.text = "Selected: %s alt=%d" % [_selected_atlas_coords, int(_alt_spin.value)]


func deprint(string: String):
	if ProjectSettings.get_setting("tile_mesh_3d/general/debug", false) == false: return
	print(string)

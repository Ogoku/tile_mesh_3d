@tool
class_name TileMesh3D
extends Node3D
 
@export_group("⚙️ Settings")
@export var tile_world_size: float = 1.0 # 1 tile = 1 world unit (PDD concept)
@export var auto_rebuild: bool = true

@export_group("👁 Visuals")
@export var tileset: TileSet

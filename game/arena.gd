extends Node3D

const HALF := 50.0
const CELL := 0.5
const GRID := 200
# Zombies have no physics body, so boxes are widened by roughly their radius.
const ZOMBIE_MARGIN := 0.25
const CRATE_HEIGHT := 1.2
const PLATFORM_HEIGHT := 2.4
const GROUND_SHADER := """
shader_type spatial;
varying vec3 world;
void vertex() { world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	float checker = mod(floor(world.x / 2.0) + floor(world.z / 2.0), 2.0);
	ALBEDO = mix(vec3(0.20, 0.29, 0.19), vec3(0.24, 0.34, 0.22), checker);
}
"""

# Top surface height per grid cell; the zombie simulation walks on this
# instead of using physics.
var heights := PackedFloat32Array()


func _ready() -> void:
	heights.resize(GRID * GRID)
	_build_lighting()
	_build_ground()
	_build_walls()
	_build_boxes()


func height_at(x: float, z: float) -> float:
	var cx := int((x + HALF) / CELL)
	var cz := int((z + HALF) / CELL)
	if cx < 0 or cz < 0 or cx >= GRID or cz >= GRID:
		return 0.0
	return heights[cz * GRID + cx]


func _build_lighting() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 35, 0)
	sun.shadow_enabled = true
	add_child(sun)

	var sky := Environment.new()
	sky.background_mode = Environment.BG_COLOR
	sky.background_color = Color(0.07, 0.09, 0.11)
	sky.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	sky.ambient_light_color = Color(0.55, 0.6, 0.7)
	sky.ambient_light_energy = 0.6
	var environment := WorldEnvironment.new()
	environment.environment = sky
	add_child(environment)


func _build_ground() -> void:
	var shader := Shader.new()
	shader.code = GROUND_SHADER
	var material := ShaderMaterial.new()
	material.shader = shader
	var plane := PlaneMesh.new()
	plane.size = Vector2(HALF * 2, HALF * 2)
	plane.material = material
	var mesh := MeshInstance3D.new()
	mesh.mesh = plane
	var collider := CollisionShape3D.new()
	collider.shape = WorldBoundaryShape3D.new()
	var ground := StaticBody3D.new()
	ground.add_child(mesh)
	ground.add_child(collider)
	add_child(ground)


func _build_walls() -> void:
	var color := Color(0.16, 0.17, 0.2)
	for side in [-1.0, 1.0]:
		_add_body(Vector3(side * (HALF + 0.5), 1.5, 0), Vector3(1, 3, HALF * 2 + 2), color)
		_add_body(Vector3(0, 1.5, side * (HALF + 0.5)), Vector3(HALF * 2 + 2, 3, 1), color)


# The layout is generated from a fixed seed so every peer builds the same map.
func _build_boxes() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 7
	var crate_color := Color(0.55, 0.42, 0.26)
	var platform_color := Color(0.42, 0.44, 0.5)
	for i in 12:
		var center := _random_spot(random)
		_add_box(center, Vector2(5, 5), PLATFORM_HEIGHT, platform_color)
		# A crate against one side is the step players need to get up.
		var side := Vector2.RIGHT.rotated(random.randi_range(0, 3) * PI / 2)
		_add_box(center + side * 3.75, Vector2(2.5, 2.5), CRATE_HEIGHT, crate_color)
	for i in 25:
		_add_box(_random_spot(random), Vector2(2, 2), CRATE_HEIGHT, crate_color)


func _random_spot(random: RandomNumberGenerator) -> Vector2:
	while true:
		var spot := Vector2(random.randf_range(-40, 40), random.randf_range(-40, 40))
		# Keep the spawn area in the middle clear.
		if spot.length() > 9.0:
			return spot
	return Vector2.ZERO


func _add_box(center: Vector2, size: Vector2, height: float, color: Color) -> void:
	_add_body(Vector3(center.x, height / 2, center.y), Vector3(size.x, height, size.y), color)
	var low := center - size / 2 - Vector2.ONE * ZOMBIE_MARGIN
	var high := center + size / 2 + Vector2.ONE * ZOMBIE_MARGIN
	for cz in range(int((low.y + HALF) / CELL), int((high.y + HALF) / CELL) + 1):
		for cx in range(int((low.x + HALF) / CELL), int((high.x + HALF) / CELL) + 1):
			if cx >= 0 and cz >= 0 and cx < GRID and cz < GRID:
				heights[cz * GRID + cx] = maxf(heights[cz * GRID + cx], height)


func _add_body(center: Vector3, size: Vector3, color: Color) -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	var box := BoxMesh.new()
	box.size = size
	box.material = material
	var mesh := MeshInstance3D.new()
	mesh.mesh = box
	var shape := BoxShape3D.new()
	shape.size = size
	var collider := CollisionShape3D.new()
	collider.shape = shape
	var body := StaticBody3D.new()
	body.position = center
	body.add_child(mesh)
	body.add_child(collider)
	add_child(body)

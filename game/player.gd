extends CharacterBody3D

const SPEED := 7.0
const TURN_SPEED := 12.0

# Dev flag: walk in a straight line without input, for headless network tests.
static var bot := false


func setup(id: int, display_name: String, start: Vector3) -> void:
	name = str(id)
	position = start

	var capsule := CapsuleMesh.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.from_hsv(fmod(id * 0.618034, 1.0), 0.65, 0.95)
	capsule.material = material
	var body := MeshInstance3D.new()
	body.mesh = capsule
	body.position.y = 0.9
	add_child(body)

	var nose_mesh := BoxMesh.new()
	nose_mesh.size = Vector3(0.25, 0.25, 0.5)
	nose_mesh.material = material
	var nose := MeshInstance3D.new()
	nose.mesh = nose_mesh
	nose.position = Vector3(0, 1.3, 0.45)
	add_child(nose)

	var shape := CapsuleShape3D.new()
	shape.radius = 0.4
	shape.height = 1.8
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.position.y = 0.9
	add_child(collider)

	var label := Label3D.new()
	label.text = display_name
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.font_size = 48
	label.outline_size = 12
	label.position.y = 2.4
	add_child(label)

	var config := SceneReplicationConfig.new()
	for path in [NodePath(".:position"), NodePath(".:rotation")]:
		config.add_property(path)
		config.property_set_spawn(path, false)
		config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	var sync := MultiplayerSynchronizer.new()
	sync.replication_config = config
	add_child(sync)

	# Each player simulates their own character; everyone else only receives it.
	set_multiplayer_authority(id)


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return
	var input := Vector2(
		float(_pressed(KEY_D, KEY_RIGHT)) - float(_pressed(KEY_A, KEY_LEFT)),
		float(_pressed(KEY_S, KEY_DOWN)) - float(_pressed(KEY_W, KEY_UP)),
	)
	if bot:
		input = Vector2.RIGHT
	var direction := Vector3(input.x, 0, input.y).limit_length(1.0)
	velocity = direction * SPEED
	move_and_slide()
	if direction != Vector3.ZERO:
		rotation.y = lerp_angle(rotation.y, atan2(direction.x, direction.z), TURN_SPEED * delta)


func _pressed(key: Key, alternative: Key) -> bool:
	return Input.is_physical_key_pressed(key) or Input.is_physical_key_pressed(alternative)

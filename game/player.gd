extends CharacterBody3D

const SPEED := 7.0
const TURN_SPEED := 12.0
const GRAVITY := 20.0
# Clears a crate (1.2 m) but not a platform (2.4 m), so crates work as steps.
const JUMP_SPEED := 7.6

# Dev flag: wander without input, for headless network tests.
static var bot := false

# Both are decided by the host and arrive with the game state.
var speed_scale := 1.0
var downed := false

var _spawn: Vector3
var _visual: Node3D


func setup(id: int, display_name: String, start: Vector3) -> void:
	name = str(id)
	position = start
	_spawn = start

	var capsule := CapsuleMesh.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.from_hsv(fmod(id * 0.618034, 1.0), 0.65, 0.95)
	capsule.material = material
	var body := MeshInstance3D.new()
	body.mesh = capsule
	body.position.y = 0.9

	var nose_mesh := BoxMesh.new()
	nose_mesh.size = Vector3(0.25, 0.25, 0.5)
	nose_mesh.material = material
	var nose := MeshInstance3D.new()
	nose.mesh = nose_mesh
	nose.position = Vector3(0, 1.3, 0.45)

	_visual = Node3D.new()
	_visual.add_child(body)
	_visual.add_child(nose)
	add_child(_visual)

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


func set_downed(value: bool) -> void:
	if downed == value:
		return
	downed = value
	_visual.rotation.x = -PI / 2 if downed else 0.0
	_visual.position.y = 0.4 if downed else 0.0


func respawn() -> void:
	position = _spawn
	velocity = Vector3.ZERO


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return
	var input := Vector2(
		float(_pressed(KEY_D, KEY_RIGHT)) - float(_pressed(KEY_A, KEY_LEFT)),
		float(_pressed(KEY_S, KEY_DOWN)) - float(_pressed(KEY_W, KEY_UP)),
	)
	if bot:
		input = Vector2.from_angle(Time.get_ticks_msec() / 2000.0)
	if downed:
		input = Vector2.ZERO
	var direction := Vector3(input.x, 0, input.y).limit_length(1.0)
	velocity.x = direction.x * SPEED * speed_scale
	velocity.z = direction.z * SPEED * speed_scale
	if is_on_floor():
		velocity.y = JUMP_SPEED if Input.is_physical_key_pressed(KEY_SPACE) and not downed else 0.0
	else:
		velocity.y -= GRAVITY * delta
	move_and_slide()
	if direction != Vector3.ZERO:
		rotation.y = lerp_angle(rotation.y, atan2(direction.x, direction.z), TURN_SPEED * delta)


func _pressed(key: Key, alternative: Key) -> bool:
	return Input.is_physical_key_pressed(key) or Input.is_physical_key_pressed(alternative)

extends Node3D

# The host simulates every zombie as plain data (no nodes, no physics) and
# sends compact position snapshots; clients only interpolate and draw.

signal killed(kind: int)

enum { WALKER, RUNNER, BOSS }

const SPEED := [3.2, 5.5, 3.8]
const SCALE := [1.0, 0.85, 3.0]
const REACH := [0.9, 0.9, 2.2]
const DAMAGE_PER_SECOND := [10.0, 8.0, 40.0]
const KNOCKBACK_FACTOR := [1.0, 1.3, 0.15]
const COLORS := [Color(0.36, 0.62, 0.3), Color(0.8, 0.72, 0.25), Color(0.65, 0.2, 0.2)]
const MAX_ZOMBIES := 300
const GRAVITY := 20.0
const SPACING := 0.8
const STEP_HEIGHT := 0.3
const SNAPSHOT_INTERVAL := 0.1
const BYTES_PER_ZOMBIE := 7
# Most jumps clear a crate; only the strongest reach a platform.
const JUMP_SPEED_MIN := 6.5
const JUMP_SPEED_MAX := 10.5


class Zombie:
	var id: int
	var kind: int
	var position: Vector3
	var fall_speed: float
	var knockback: Vector3
	var health: float
	var jump_wait: float
	var yaw: float


class View:
	var kind: int
	var from: Vector3
	var to: Vector3
	var yaw: float
	var stamp: int


var arena: Node3D
var game: Node

var zombies: Array[Zombie] = []
var views := {}

var _next_id := 0
var _has_dead := false
var _cells := {}
var _since_snapshot := 0.0
var _snapshot_age := 0.0
var _stamp := 0
var _multimesh: MultiMesh


func _ready() -> void:
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	var mesh := _zombie_mesh()
	mesh.surface_set_material(0, material)

	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_multimesh.use_colors = true
	_multimesh.mesh = mesh
	_multimesh.instance_count = MAX_ZOMBIES + 8
	_multimesh.visible_instance_count = 0
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = _multimesh
	instance.custom_aabb = AABB(Vector3(-60, -1, -60), Vector3(120, 14, 120))
	add_child(instance)


func _process(delta: float) -> void:
	var index := 0
	if game.hosting:
		for zombie in zombies:
			_draw(index, zombie.kind, zombie.position, zombie.yaw)
			index += 1
	else:
		_snapshot_age += delta
		var blend := minf(_snapshot_age / SNAPSHOT_INTERVAL, 1.2)
		for view: View in views.values():
			_draw(index, view.kind, view.from.lerp(view.to, blend), view.yaw)
			index += 1
	_multimesh.visible_instance_count = index


func clear() -> void:
	zombies.clear()
	views.clear()


func spawn(kind: int, at: Vector3, health: float) -> void:
	var zombie := Zombie.new()
	zombie.id = _next_id
	_next_id = (_next_id + 1) & 0xFFFF
	zombie.kind = kind
	zombie.position = at
	zombie.health = health
	zombie.jump_wait = randf_range(0.5, 2.0)
	zombies.append(zombie)


# targets: [[player id, position], ...] for every player still standing.
func simulate(delta: float, targets: Array) -> void:
	_remove_dead()
	_index_cells()
	var limit: float = arena.HALF - 1.5
	for zombie in zombies:
		var target: Array = _nearest_target(zombie.position, targets)
		var stunned := zombie.knockback.length_squared() > 4.0
		var walk := Vector3.ZERO
		var distance := INF
		var target_above := false
		if not target.is_empty():
			var offset: Vector3 = target[1] - zombie.position
			target_above = offset.y > 0.8
			var height_gap := absf(offset.y)
			offset.y = 0
			distance = offset.length()
			if distance > 0.4 and not stunned:
				walk = offset / distance * SPEED[zombie.kind]
				zombie.yaw = atan2(offset.x, offset.z)
			if distance < REACH[zombie.kind] and height_gap < 1.2:
				game.hurt(target[0], DAMAGE_PER_SECOND[zombie.kind] * delta)

		var blocked := _walk(zombie, (walk + _separation(zombie) + zombie.knockback) * delta)
		zombie.position.x = clampf(zombie.position.x, -limit, limit)
		zombie.position.z = clampf(zombie.position.z, -limit, limit)
		zombie.knockback *= maxf(0.0, 1.0 - 5.0 * delta)

		zombie.fall_speed -= GRAVITY * delta
		zombie.position.y += zombie.fall_speed * delta
		var floor_height: float = arena.height_at(zombie.position.x, zombie.position.z)
		if zombie.position.y <= floor_height:
			zombie.position.y = floor_height
			zombie.fall_speed = 0.0
			zombie.jump_wait -= delta
			var wants_up := blocked or (target_above and distance < 4.0)
			if wants_up and zombie.jump_wait <= 0.0 and not stunned:
				zombie.fall_speed = JUMP_SPEED_MAX if zombie.kind == BOSS else randf_range(JUMP_SPEED_MIN, JUMP_SPEED_MAX)
				zombie.jump_wait = randf_range(1.2, 2.5)

	_since_snapshot += delta
	if _since_snapshot >= SNAPSHOT_INTERVAL:
		_since_snapshot = 0.0
		receive_snapshot.rpc(_encode_snapshot())


func hit(zombie: Zombie, damage: float, knockback: Vector3) -> void:
	if zombie.health <= 0.0:
		return
	zombie.health -= damage
	zombie.knockback += knockback * KNOCKBACK_FACTOR[zombie.kind]
	if zombie.health <= 0.0:
		_has_dead = true
		killed.emit(zombie.kind)


func blast(center: Vector3, radius: float, damage: float, force: float) -> void:
	for zombie in zombies:
		var offset := zombie.position - center
		offset.y = 0
		var distance := offset.length()
		if distance > radius + REACH[zombie.kind] * 0.5:
			continue
		var direction := offset / distance if distance > 0.05 else Vector3.RIGHT.rotated(Vector3.UP, randf() * TAU)
		hit(zombie, damage, direction * force)
		# The hop is what throws them off crates and platforms.
		zombie.fall_speed = maxf(zombie.fall_speed, 6.0 * KNOCKBACK_FACTOR[zombie.kind])


func nearest(from: Vector3, max_range: float, count: int) -> Array[Zombie]:
	var found: Array[Zombie] = []
	var ranked := []
	for zombie in zombies:
		if zombie.health <= 0.0:
			continue
		var distance := from.distance_squared_to(zombie.position)
		if distance < max_range * max_range:
			ranked.append([distance, zombie])
	ranked.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for entry: Array in ranked.slice(0, count):
		found.append(entry[1])
	return found


@rpc("authority", "call_remote", "unreliable")
func receive_snapshot(data: PackedByteArray) -> void:
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = data
	_stamp += 1
	var blend := minf(_snapshot_age / SNAPSHOT_INTERVAL, 1.2)
	for i in data.size() / BYTES_PER_ZOMBIE:
		var id := buffer.get_u16()
		var at := Vector3(buffer.get_16() / 100.0, 0, buffer.get_16() / 100.0)
		at.y = buffer.get_u8() / 20.0
		var kind := buffer.get_u8()
		var view: View = views.get(id)
		if view == null:
			view = View.new()
			view.from = at
			views[id] = view
		else:
			view.from = view.from.lerp(view.to, blend)
		view.to = at
		view.kind = kind
		view.stamp = _stamp
		var moved := view.to - view.from
		if Vector2(moved.x, moved.z).length_squared() > 0.0004:
			view.yaw = atan2(moved.x, moved.z)
	for id: int in views.keys():
		if views[id].stamp != _stamp:
			views.erase(id)
	_snapshot_age = 0.0


func _encode_snapshot() -> PackedByteArray:
	var buffer := StreamPeerBuffer.new()
	for zombie in zombies:
		if zombie.health <= 0.0:
			continue
		buffer.put_u16(zombie.id)
		buffer.put_16(roundi(zombie.position.x * 100.0))
		buffer.put_16(roundi(zombie.position.z * 100.0))
		buffer.put_u8(clampi(roundi(zombie.position.y * 20.0), 0, 255))
		buffer.put_u8(zombie.kind)
	return buffer.data_array


func _remove_dead() -> void:
	if not _has_dead:
		return
	_has_dead = false
	var alive: Array[Zombie] = []
	for zombie in zombies:
		if zombie.health > 0.0:
			alive.append(zombie)
	zombies = alive


func _nearest_target(from: Vector3, targets: Array) -> Array:
	var best := []
	var best_distance := INF
	for target: Array in targets:
		var distance := from.distance_squared_to(target[1])
		if distance < best_distance:
			best_distance = distance
			best = target
	return best


func _cell_key(x: float, z: float) -> int:
	return (int(floorf(x)) + 512) * 1024 + int(floorf(z)) + 512


func _index_cells() -> void:
	_cells.clear()
	for zombie in zombies:
		var key := _cell_key(zombie.position.x, zombie.position.z)
		if _cells.has(key):
			_cells[key].append(zombie)
		else:
			_cells[key] = [zombie]


func _separation(zombie: Zombie) -> Vector3:
	var push := Vector3.ZERO
	for dx in [-1.0, 0.0, 1.0]:
		for dz in [-1.0, 0.0, 1.0]:
			var neighbours: Array = _cells.get(_cell_key(zombie.position.x + dx, zombie.position.z + dz), [])
			for other: Zombie in neighbours:
				if other == zombie:
					continue
				var offset := zombie.position - other.position
				offset.y = 0
				var distance := offset.length()
				if distance < SPACING and distance > 0.001:
					push += offset / distance * (SPACING - distance) * 6.0
	return push


# Returns true when a box taller than a step stopped the zombie.
func _walk(zombie: Zombie, step: Vector3) -> bool:
	var x := zombie.position.x + step.x
	var z := zombie.position.z + step.z
	var climbable := zombie.position.y + STEP_HEIGHT
	if arena.height_at(x, z) <= climbable:
		zombie.position.x = x
		zombie.position.z = z
		return false
	if arena.height_at(x, zombie.position.z) <= climbable:
		zombie.position.x = x
	elif arena.height_at(zombie.position.x, z) <= climbable:
		zombie.position.z = z
	return true


func _draw(index: int, kind: int, at: Vector3, yaw: float) -> void:
	var size: float = SCALE[kind]
	_multimesh.set_instance_transform(index, Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(size, size, size)), at))
	_multimesh.set_instance_color(index, COLORS[kind])


func _zombie_mesh() -> ArrayMesh:
	var parts := [
		[Vector3(0.5, 0.55, 0.3), Vector3(0, 0.275, 0)],
		[Vector3(0.6, 0.65, 0.35), Vector3(0, 0.875, 0)],
		[Vector3(0.4, 0.4, 0.4), Vector3(0, 1.4, 0)],
		[Vector3(0.14, 0.14, 0.6), Vector3(-0.3, 1.0, 0.4)],
		[Vector3(0.14, 0.14, 0.6), Vector3(0.3, 1.0, 0.4)],
	]
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for part: Array in parts:
		var box := BoxMesh.new()
		box.size = part[0]
		surface.append_from(box, 0, Transform3D(Basis.IDENTITY, part[1]))
	return surface.commit()

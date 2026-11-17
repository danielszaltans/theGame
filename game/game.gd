extends Node

# Run rules. The host owns all of it (time, spawning, attacks, health, XP)
# and broadcasts a small state dictionary that every peer's HUD reads.

const Swarm := preload("res://swarm.gd")

const BOSS_TIME := 300.0
const WAVE_LENGTH := 30.0
const GUN_RANGE := 14.0
const BLAST_RANGE := 16.0
const BLAST_FORCE := 16.0
const REVIVE_DISTANCE := 2.0
const REVIVE_TIME := 3.0
const RESTART_DELAY := 6.0
const SYNC_INTERVAL := 0.1
const UPGRADES := {
	"damage": ["Sharper rounds", "+25% gun damage"],
	"rate": ["Faster trigger", "+20% fire rate"],
	"targets": ["Split shot", "Gun hits +1 zombie"],
	"knockback": ["Heavy rounds", "+40% gun knockback"],
	"health": ["Thick skin", "+25 max health, heal 25"],
	"speed": ["Quick feet", "+10% move speed"],
	"blast_radius": ["Bigger blast", "+25% blast radius"],
	"blast_cooldown": ["Quick cast", "-20% blast cooldown"],
	"blast_damage": ["Blast power", "+40% blast damage"],
}

enum { BOSS_PENDING, BOSS_ALIVE, BOSS_DEFEATED }

var swarm: Node3D
var arena: Node3D
var players: Node3D
var camera: Camera3D

var hosting := false
# Last state received from the host; empty when not in a run.
var view := {}

var _time := 0.0
var _level := 1
var _xp := 0
var _run := 1
var _over := false
var _restart_in := 0.0
var _boss := BOSS_PENDING
var _boss_health := 1.0
var _stats := {}
var _spawn_debt := 0.0
var _since_sync := 0.0
var _seen_run := 0


func _ready() -> void:
	swarm.killed.connect(_on_killed)


func start_hosting() -> void:
	_reset()
	hosting = true


func stop() -> void:
	hosting = false
	view = {}
	_seen_run = 0
	swarm.clear()


func my_state() -> Array:
	return view.get("players", {}).get(multiplayer.get_unique_id(), [])


func choose(upgrade: String) -> void:
	_to_host(choose_upgrade, upgrade)


func hurt(id: int, amount: float) -> void:
	var stats: Dictionary = _stats.get(id, {})
	if stats.is_empty() or stats.downed:
		return
	stats.health -= amount
	if stats.health <= 0.0:
		stats.health = 0.0
		stats.downed = true
		stats.revive = 0.0


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	if my_state().is_empty():
		return
	var origin := camera.project_ray_origin(event.position)
	var point: Variant = Plane(Vector3.UP, 0.0).intersects_ray(origin, camera.project_ray_normal(event.position))
	if point != null:
		_to_host(cast_blast, point)


func _physics_process(delta: float) -> void:
	if not hosting:
		return
	_track_players()
	if _over:
		_restart_in -= delta
		if _restart_in <= 0.0:
			_reset()
	elif not _stats.is_empty():
		_time += delta
		_spawn(delta)
		_fight(delta)
		_revive(delta)
		swarm.simulate(delta, _standing())
		if _standing().is_empty():
			_over = true
			_restart_in = RESTART_DELAY
	_since_sync += delta
	if _since_sync >= SYNC_INTERVAL:
		_since_sync = 0.0
		sync.rpc(_state())


func _reset() -> void:
	_time = 0.0
	_level = 1
	_xp = 0
	_run += 1
	_over = false
	_boss = BOSS_PENDING
	_stats.clear()
	_spawn_debt = 0.0
	swarm.clear()


func _track_players() -> void:
	var present := {}
	for player in players.get_children():
		var id := int(str(player.name))
		present[id] = true
		if not _stats.has(id):
			_stats[id] = {
				"health": 100.0, "max_health": 100.0, "downed": false, "revive": 0.0, "picks": 0,
				"damage": 10.0, "interval": 0.4, "targets": 1, "knockback": 7.0, "gun_wait": 0.0,
				"speed": 1.0, "blast_cooldown": 6.0, "blast_radius": 4.0, "blast_damage": 40.0, "blast_wait": 0.0,
			}
	for id: int in _stats.keys():
		if not present.has(id):
			_stats.erase(id)


func _standing() -> Array:
	var standing := []
	for id: int in _stats:
		if not _stats[id].downed:
			standing.append([id, players.get_node(str(id)).position])
	return standing


func _wave() -> int:
	return 1 + int(_time / WAVE_LENGTH)


func _spawn(delta: float) -> void:
	var crowd := 0.5 + 0.5 * _stats.size()
	_spawn_debt += (1.0 + _time / 60.0) * crowd * delta
	var standing := _standing()
	while _spawn_debt >= 1.0:
		_spawn_debt -= 1.0
		if swarm.zombies.size() >= Swarm.MAX_ZOMBIES or standing.is_empty():
			continue
		var runner_chance := clampf(0.05 * (_wave() - 2), 0.0, 0.4)
		var kind := Swarm.RUNNER if randf() < runner_chance else Swarm.WALKER
		var health := 20.0 + 3.0 * (_wave() - 1)
		swarm.spawn(kind, _spawn_point(standing), health * (0.6 if kind == Swarm.RUNNER else 1.0))
	if _boss == BOSS_PENDING and _time >= BOSS_TIME and not standing.is_empty():
		_boss = BOSS_ALIVE
		_boss_health = 1500.0 * crowd
		swarm.spawn(Swarm.BOSS, _spawn_point(standing), _boss_health)


# Just outside the camera's view of a random player.
func _spawn_point(standing: Array) -> Vector3:
	var around: Vector3 = standing.pick_random()[1]
	var limit: float = arena.HALF - 2.0
	var point := around + Vector3.RIGHT.rotated(Vector3.UP, randf() * TAU) * randf_range(26.0, 32.0)
	point.x = clampf(point.x, -limit, limit)
	point.z = clampf(point.z, -limit, limit)
	point.y = arena.height_at(point.x, point.z)
	return point


func _fight(delta: float) -> void:
	var shots := PackedVector3Array()
	for id: int in _stats:
		var stats: Dictionary = _stats[id]
		stats.blast_wait = maxf(0.0, stats.blast_wait - delta)
		stats.gun_wait -= delta
		if stats.downed or stats.gun_wait > 0.0:
			continue
		var muzzle: Vector3 = players.get_node(str(id)).position + Vector3(0, 1.2, 0)
		for zombie in swarm.nearest(muzzle, GUN_RANGE, stats.targets):
			var aim: Vector3 = zombie.position + Vector3(0, 1.0, 0) * Swarm.SCALE[zombie.kind]
			var push := (aim - muzzle) * Vector3(1, 0, 1)
			swarm.hit(zombie, stats.damage, push.normalized() * stats.knockback)
			shots.append(muzzle)
			shots.append(aim)
			stats.gun_wait = stats.interval
	if not shots.is_empty():
		show_shots.rpc(shots)


func _revive(delta: float) -> void:
	var standing := _standing()
	for id: int in _stats:
		var stats: Dictionary = _stats[id]
		if not stats.downed:
			continue
		var body: Vector3 = players.get_node(str(id)).position
		var helped := standing.any(func(other: Array) -> bool: return body.distance_to(other[1]) < REVIVE_DISTANCE)
		stats.revive = stats.revive + delta if helped else 0.0
		if stats.revive >= REVIVE_TIME:
			stats.downed = false
			stats.health = stats.max_health * 0.5


func _on_killed(kind: int) -> void:
	_xp += [1, 2, 50][kind]
	if kind == Swarm.BOSS:
		_boss = BOSS_DEFEATED
	while _xp >= _xp_needed():
		_xp -= _xp_needed()
		_level += 1
		for stats: Dictionary in _stats.values():
			stats.picks += 1


func _xp_needed() -> int:
	return 4 + _level * 3


func _state() -> Dictionary:
	var boss_health := 0.0
	for zombie in swarm.zombies:
		if zombie.kind == Swarm.BOSS:
			boss_health = maxf(0.0, zombie.health / _boss_health)
	var per_player := {}
	for id: int in _stats:
		var stats: Dictionary = _stats[id]
		per_player[id] = [stats.health, stats.max_health, stats.downed, stats.picks, stats.blast_wait, stats.speed, stats.revive / REVIVE_TIME]
	return {
		"time": _time, "wave": _wave(), "level": _level, "xp": _xp, "xp_needed": _xp_needed(),
		"run": _run, "over": _over, "restart_in": _restart_in, "zombies": swarm.zombies.size(),
		"boss": _boss, "boss_health": boss_health, "boss_in": BOSS_TIME - _time, "players": per_player,
	}


@rpc("authority", "call_local", "unreliable_ordered")
func sync(state: Dictionary) -> void:
	view = state
	for id: int in state.players:
		var player := players.get_node_or_null(str(id))
		if player:
			player.set_downed(state.players[id][2])
			player.speed_scale = state.players[id][5]
	if state.run != _seen_run:
		_seen_run = state.run
		var me := players.get_node_or_null(str(multiplayer.get_unique_id()))
		if me:
			me.respawn()


@rpc("any_peer", "call_remote", "reliable")
func choose_upgrade(upgrade: String) -> void:
	var stats: Dictionary = _stats.get(_sender(), {})
	if not hosting or stats.is_empty() or stats.picks <= 0 or not UPGRADES.has(upgrade):
		return
	stats.picks -= 1
	match upgrade:
		"damage": stats.damage *= 1.25
		"rate": stats.interval /= 1.2
		"targets": stats.targets += 1
		"knockback": stats.knockback *= 1.4
		"health":
			stats.max_health += 25.0
			stats.health = minf(stats.health + 25.0, stats.max_health)
		"speed": stats.speed *= 1.1
		"blast_radius": stats.blast_radius *= 1.25
		"blast_cooldown": stats.blast_cooldown *= 0.8
		"blast_damage": stats.blast_damage *= 1.4


@rpc("any_peer", "call_remote", "reliable")
func cast_blast(point: Vector3) -> void:
	var id := _sender()
	var stats: Dictionary = _stats.get(id, {})
	if not hosting or _over or stats.is_empty() or stats.downed or stats.blast_wait > 0.0:
		return
	var caster: Vector3 = players.get_node(str(id)).position
	var offset := (point - caster) * Vector3(1, 0, 1)
	point = caster + offset.limit_length(BLAST_RANGE)
	point.y = 0.0
	stats.blast_wait = stats.blast_cooldown
	swarm.blast(point, stats.blast_radius, stats.blast_damage, BLAST_FORCE)
	show_blast.rpc(point, stats.blast_radius)


@rpc("authority", "call_local", "unreliable")
func show_shots(points: PackedVector3Array) -> void:
	for i in range(0, points.size() - 1, 2):
		var length := points[i].distance_to(points[i + 1])
		if length < 0.1:
			continue
		var tracer := _effect(BoxMesh.new(), Color(1.0, 0.9, 0.5), 0.05)
		tracer.mesh.size = Vector3(0.05, 0.05, length)
		tracer.look_at_from_position((points[i] + points[i + 1]) / 2, points[i + 1])


@rpc("authority", "call_local", "unreliable")
func show_blast(point: Vector3, radius: float) -> void:
	var ring := _effect(CylinderMesh.new(), Color(1.0, 0.5, 0.15, 0.7), 0.35)
	ring.mesh.top_radius = radius
	ring.mesh.bottom_radius = radius
	ring.mesh.height = 0.3
	ring.position = point + Vector3(0, 0.2, 0)
	ring.scale = Vector3(0.2, 1, 0.2)
	create_tween().tween_property(ring, "scale", Vector3.ONE, 0.2)


func _effect(mesh: PrimitiveMesh, color: Color, lifetime: float) -> MeshInstance3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = color
	mesh.material = material
	var effect := MeshInstance3D.new()
	effect.mesh = mesh
	effect.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(effect)
	get_tree().create_timer(lifetime).timeout.connect(effect.queue_free)
	return effect


# The host's own requests skip the network: an RPC cannot target yourself.
func _to_host(method: Callable, argument: Variant) -> void:
	if multiplayer.is_server():
		method.call(argument)
	else:
		method.rpc_id(1, argument)


func _sender() -> int:
	var id := multiplayer.get_remote_sender_id()
	return id if id != 0 else 1

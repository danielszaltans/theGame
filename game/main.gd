extends Node3D

const Player := preload("res://player.gd")
const Arena := preload("res://arena.gd")
const Swarm := preload("res://swarm.gd")
const Game := preload("res://game.gd")
const Hud := preload("res://hud.gd")

const PORT := 24565
const MAX_PLAYERS := 6
const CAMERA_OFFSET := Vector3(0, 16, 12)

var version: String = ProjectSettings.get_setting("application/config/version", "dev")
var kick_reason := ""

var game: Node
var players: Node3D
var spawner: MultiplayerSpawner
var camera: Camera3D
var menu: Control
var hud: Control
var hud_label: Label
var name_edit: LineEdit
var address_edit: LineEdit
var status: Label


func _ready() -> void:
	_build_world()
	_build_menu()
	_build_hud()
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_leave.bind("Could not connect to the host."))
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	_run_dev_flags()


func _process(_delta: float) -> void:
	var me := players.get_node_or_null(str(multiplayer.get_unique_id()))
	if me:
		camera.position = me.position + CAMERA_OFFSET
	if hud.visible:
		var role := "hosting on UDP port %d" % PORT if multiplayer.is_server() else "connected"
		hud_label.text = "v%s · %d/%d players · %s" % [version, players.get_child_count(), MAX_PLAYERS, role]


func _host() -> void:
	var peer := ENetMultiplayerPeer.new()
	if peer.create_server(PORT, MAX_PLAYERS - 1) != OK:
		status.text = "Could not host: UDP port %d is already in use." % PORT
		return
	multiplayer.multiplayer_peer = peer
	game.start_hosting()
	_add_player(1, _my_name())
	_show_game(true)


func _join(address: String) -> void:
	address = address.strip_edges()
	if address.is_empty():
		address = "127.0.0.1"
	var peer := ENetMultiplayerPeer.new()
	if peer.create_client(address, PORT) != OK:
		status.text = "That address does not look right."
		return
	multiplayer.multiplayer_peer = peer
	kick_reason = ""
	status.text = "Connecting to %s…" % address


func _leave(message := "") -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	game.stop()
	for player in players.get_children():
		player.queue_free()
	_show_game(false)
	status.text = message


func _on_connected() -> void:
	register.rpc_id(1, _my_name(), version)
	_show_game(true)


func _on_server_disconnected() -> void:
	_leave(kick_reason if kick_reason else "The host closed the game.")


func _on_peer_disconnected(id: int) -> void:
	if multiplayer.is_server() and players.has_node(str(id)):
		players.get_node(str(id)).queue_free()


@rpc("any_peer", "call_remote", "reliable")
func register(player_name: String, client_version: String) -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if client_version != version:
		rejected.rpc_id(id, "The host runs v%s and you run v%s. Restart the launcher to update." % [version, client_version])
		# The kick would otherwise overtake the message that explains it.
		await get_tree().create_timer(0.5).timeout
		if id in multiplayer.get_peers():
			multiplayer.multiplayer_peer.disconnect_peer(id)
		return
	if not players.has_node(str(id)):
		_add_player(id, player_name)


@rpc("authority", "call_remote", "reliable")
func rejected(reason: String) -> void:
	kick_reason = reason


func _add_player(id: int, player_name: String) -> void:
	player_name = player_name.strip_edges().left(16)
	if player_name.is_empty():
		player_name = "Player"
	var angle := players.get_child_count() * TAU / MAX_PLAYERS
	spawner.spawn({"id": id, "name": player_name, "position": Vector3(cos(angle), 0, sin(angle)) * 3.0})


func _spawn_player(data: Dictionary) -> Node:
	var player := Player.new()
	player.setup(data.id, data.name, data.position)
	print("spawned player %d (%s)" % [data.id, data.name])
	return player


func _my_name() -> String:
	return name_edit.text


func _show_game(in_game: bool) -> void:
	menu.visible = not in_game
	hud.visible = in_game


func _build_world() -> void:
	var arena := Arena.new()
	arena.name = "Arena"
	add_child(arena)

	camera = Camera3D.new()
	camera.fov = 40
	add_child(camera)
	camera.position = CAMERA_OFFSET
	camera.look_at(Vector3.ZERO)

	players = Node3D.new()
	players.name = "Players"
	add_child(players)

	spawner = MultiplayerSpawner.new()
	spawner.name = "Spawner"
	spawner.spawn_function = _spawn_player
	add_child(spawner)
	spawner.spawn_path = spawner.get_path_to(players)

	var swarm := Swarm.new()
	swarm.name = "Swarm"
	swarm.arena = arena
	game = Game.new()
	game.name = "Game"
	game.swarm = swarm
	game.arena = arena
	game.players = players
	game.camera = camera
	swarm.game = game
	add_child(swarm)
	add_child(game)

	var game_hud := Hud.new()
	game_hud.game = game
	add_child(game_hud)


func _build_menu() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	menu = CenterContainer.new()
	menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(menu)

	var column := VBoxContainer.new()
	column.custom_minimum_size.x = 320
	column.add_theme_constant_override("separation", 10)
	menu.add_child(column)

	var title := Label.new()
	title.text = "theGame"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 56)
	column.add_child(title)

	name_edit = LineEdit.new()
	name_edit.placeholder_text = "Your name"
	name_edit.max_length = 16
	column.add_child(name_edit)

	var host_button := Button.new()
	host_button.text = "Host a game"
	host_button.pressed.connect(_host)
	column.add_child(host_button)

	address_edit = LineEdit.new()
	address_edit.placeholder_text = "Host address (empty = this computer)"
	column.add_child(address_edit)

	var join_button := Button.new()
	join_button.text = "Join a game"
	join_button.pressed.connect(func() -> void: _join(address_edit.text))
	column.add_child(join_button)

	status = Label.new()
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(status)

	var version_label := Label.new()
	version_label.text = "v" + version
	version_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	version_label.modulate.a = 0.5
	column.add_child(version_label)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	hud = HBoxContainer.new()
	hud.position = Vector2(12, 12)
	hud.add_theme_constant_override("separation", 12)
	hud.visible = false
	layer.add_child(hud)

	var leave_button := Button.new()
	leave_button.text = "Leave"
	leave_button.pressed.connect(_leave)
	hud.add_child(leave_button)

	hud_label = Label.new()
	hud.add_child(hud_label)


# Dev flags, passed after "--": --name=X, --host, --join=ADDRESS, --bot, --dump=SECONDS
func _run_dev_flags() -> void:
	var args := OS.get_cmdline_user_args()
	for arg in args:
		if arg.begins_with("--name="):
			name_edit.text = arg.trim_prefix("--name=")
	Player.bot = "--bot" in args
	for arg in args:
		if arg == "--host":
			_host()
		elif arg.begins_with("--join="):
			_join(arg.trim_prefix("--join="))
	for arg in args:
		if not arg.begins_with("--dump="):
			continue
		await get_tree().create_timer(float(arg.trim_prefix("--dump="))).timeout
		for player in players.get_children():
			print("dump %s %s" % [player.name, player.position.snapped(Vector3.ONE * 0.1)])
		print("dump state %s, %d zombies drawn" % [game.view, maxi(game.swarm.zombies.size(), game.swarm.views.size())])
		get_tree().quit()

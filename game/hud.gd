extends CanvasLayer

const Game := preload("res://game.gd")

var game: Node

var _root: Control
var _status: Label
var _boss_bar: ProgressBar
var _xp_label: Label
var _xp_bar: ProgressBar
var _health_label: Label
var _health_bar: ProgressBar
var _blast: Label
var _message: Label
var _picker: HBoxContainer
var _options: Array = []
# Covers the gap until the host confirms a pick, so the picker does not flash back.
var _picker_pause := 0.0


func _ready() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	var top := _column(Control.PRESET_TOP_WIDE)
	top.offset_top = 52
	_status = _label(top, 20)
	_boss_bar = _bar(top, Color(0.8, 0.2, 0.2), 420)
	_xp_label = _label(top, 14)
	_xp_bar = _bar(top, Color(0.3, 0.6, 1.0), 420)

	_message = _label(_root, 40)
	_message.set_anchors_preset(Control.PRESET_FULL_RECT)
	_message.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

	var bottom := _column(Control.PRESET_BOTTOM_WIDE)
	bottom.grow_vertical = Control.GROW_DIRECTION_BEGIN
	bottom.offset_bottom = -24
	_picker = HBoxContainer.new()
	_picker.alignment = BoxContainer.ALIGNMENT_CENTER
	_picker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_picker.add_theme_constant_override("separation", 12)
	bottom.add_child(_picker)
	_blast = _label(bottom, 16)
	_health_label = _label(bottom, 16)
	_health_bar = _bar(bottom, Color(0.3, 0.8, 0.35), 320)


func _process(delta: float) -> void:
	var view: Dictionary = game.view
	var me: Array = game.my_state()
	_root.visible = not me.is_empty()
	if me.is_empty():
		_close_picker()
		return

	_status.text = "%s · Wave %d · %d zombies" % [_clock(view.time), view.wave, view.zombies]
	_boss_bar.visible = view.boss == Game.BOSS_ALIVE
	_boss_bar.value = view.boss_health
	if view.boss == Game.BOSS_PENDING:
		_status.text += " · Boss in %s" % _clock(view.boss_in)
	elif view.boss == Game.BOSS_ALIVE:
		_status.text += " · BOSS"
	else:
		_status.text += " · Endless"
	_xp_label.text = "Level %d" % view.level
	_xp_bar.value = float(view.xp) / view.xp_needed

	_health_label.text = "%d / %d" % [ceili(me[0]), me[1]]
	_health_bar.value = me[0] / me[1]
	_blast.text = "Blast ready (left click)" if me[4] <= 0.0 else "Blast in %.1fs" % me[4]

	if view.over:
		_message.text = "Everyone is down\nSurvived %s, wave %d\nNew run in %d" % [_clock(view.time), view.wave, ceili(view.restart_in)]
	elif me[2]:
		_message.text = "You are down\nA teammate can revive you by standing next to you"
		if me[6] > 0.0:
			_message.text += "\nReviving %d%%" % int(me[6] * 100)
	else:
		_message.text = ""

	_picker_pause -= delta
	if me[3] > 0 and not view.over and _picker_pause <= 0.0:
		if _options.is_empty():
			_open_picker()
	else:
		_close_picker()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event.pressed or event.echo:
		return
	var index: int = [KEY_1, KEY_2, KEY_3].find(event.physical_keycode)
	if index >= 0 and index < _options.size():
		_pick(_options[index])


func _open_picker() -> void:
	_options = Game.UPGRADES.keys()
	_options.shuffle()
	_options.resize(3)
	for i in _options.size():
		var upgrade: Array = Game.UPGRADES[_options[i]]
		var button := Button.new()
		button.text = "[%d] %s\n%s" % [i + 1, upgrade[0], upgrade[1]]
		button.custom_minimum_size = Vector2(220, 64)
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(_pick.bind(_options[i]))
		_picker.add_child(button)


func _close_picker() -> void:
	_options.clear()
	for button in _picker.get_children():
		button.queue_free()


func _pick(upgrade: String) -> void:
	game.choose(upgrade)
	_picker_pause = 0.4
	_close_picker()


func _clock(seconds: float) -> String:
	var whole := maxi(0, int(seconds))
	return "%d:%02d" % [whole / 60, whole % 60]


func _column(preset: Control.LayoutPreset) -> VBoxContainer:
	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(preset)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 4)
	_root.add_child(column)
	return column


func _label(parent: Control, font_size: int) -> Label:
	var label := Label.new()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_constant_override("outline_size", 6)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	parent.add_child(label)
	return label


func _bar(parent: Control, color: Color, width: float) -> ProgressBar:
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	var bar := ProgressBar.new()
	bar.max_value = 1.0
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(width, 12)
	bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_theme_stylebox_override("fill", fill)
	parent.add_child(bar)
	return bar

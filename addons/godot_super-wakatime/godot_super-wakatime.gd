@tool
extends EditorPlugin

#------------------------------- SETUP -------------------------------
# Utilities
var Utils = preload("res://addons/godot_super-wakatime/utils.gd").new()

# Paths, Urls
const PLUGIN_PATH: String = "res://addons/godot_super-wakatime"

# Change the binary string pointer to look at the native lib directory
const TERMUX_WAKA_CLI: String = "/data/data/org.godotengine.editor.v4/lib/libwakatime.so"


# Hackatime Hardcoded Configuration
const HACKATIME_API_URL: String = "https://hackatime.hackclub.com/api/hackatime/v1"
const HACKATIME_API_KEY: String = "f62d2fed-77bd-4e72-b800-706a7e451564"

var counter_instance: Node = null
var current_time: String = "0 hrs, 0mins"

# Set platform
var system_platform: String = Utils.set_platform()[0]
var system_architecture: String = Utils.set_platform()[1]

var debug: bool = true
var wakatime_cli = null

# Rate limit synced to Hackatime preferences (30 seconds)
const LOG_INTERVAL: int = 30000
var last_tick_frame: int = 0
var last_mouse_event: InputEventMouse
var moved_on_edit: bool = false
var tab_open: String = "2D"

# Counter node
var Counter: PackedScene = preload("res://addons/godot_super-wakatime/counter.tscn")

#------------------------------- DIRECT PLUGIN FUNCTIONS -------------------------------
func _ready() -> void:
	setup_plugin()
	set_process(true)
	
func _exit_tree() -> void:
	_disable_plugin()
	set_process(false)
	
class DataSnapshot:
	var file_path: String
	var line_no: int 
	var cursor_pos: int 
	var lines: int 

func get_coding_data(file: Script = null) ->  DataSnapshot:
	var snapshot = DataSnapshot.new()
	if not file:
		file = get_editor_interface().get_script_editor().get_current_script()

	if not file:
		return null

	snapshot.file_path = ProjectSettings.globalize_path(file.resource_path)

	var code_edit: CodeEdit = get_editor_interface().get_script_editor().get_current_editor().get_base_editor()
	if code_edit is not CodeEdit:
		return null
	snapshot.line_no = code_edit.get_caret_line()
	snapshot.cursor_pos = code_edit.get_caret_column()
	snapshot.lines = code_edit.get_line_count()

	return snapshot

func get_building_data(mouse_event: InputEventMouse, file_path: String = "") -> DataSnapshot:
	var snapshot = DataSnapshot.new()
	if file_path == "":
		if EditorInterface.get_edited_scene_root() == null:
			return null
		var file = EditorInterface.get_edited_scene_root().scene_file_path

		if not file:
			return null

		snapshot.file_path = ProjectSettings.globalize_path(file)
	else:
		snapshot.file_path = file_path

	snapshot.line_no = int(roundf(mouse_event.position.x))
	snapshot.cursor_pos = int(roundf(mouse_event.position.y))

	snapshot.lines = 0
	return snapshot

func _input(event: InputEvent) -> void:
	if Time.get_ticks_msec() - last_tick_frame > LOG_INTERVAL:
		if tab_open == "Script":
			if event is InputEventKey:
				var key_event = event as InputEventKey
				if (key_event.keycode == KEY_UP   || key_event.keycode == KEY_DOWN 
				 || key_event.keycode == KEY_LEFT || key_event.keycode == KEY_RIGHT 
				 || key_event.keycode == KEY_ALT  || key_event.keycode == KEY_SHIFT):
					return
  
				var snapshot = get_coding_data()

				if snapshot == null:
					return

				send_heartbeat(snapshot.file_path, "coding",  snapshot.line_no, snapshot.cursor_pos, snapshot.lines, false)
				last_tick_frame = Time.get_ticks_msec()

		elif tab_open == "2D" || tab_open == "3D":
			if event is InputEventMouseButton:
				var snapshot = get_building_data(event)

				if snapshot == null:
					return

				send_heartbeat(snapshot.file_path, "building",  snapshot.line_no, snapshot.cursor_pos, snapshot.lines, false)
				last_tick_frame = Time.get_ticks_msec()
 
	if tab_open == "2D" || tab_open == "3D":
		if event is InputEventMouse:
			last_mouse_event = event
			moved_on_edit = true

func _main_screen_changed(tab_name: String):
	tab_open = tab_name

func _scene_saved(file_path: String):
	if last_mouse_event == null:
		return
	if !moved_on_edit:
		return

	moved_on_edit = false
	var snapshot = get_building_data(last_mouse_event)

	if snapshot == null:
		return

	send_heartbeat(snapshot.file_path, "building",  snapshot.line_no, snapshot.cursor_pos, snapshot.lines, true)
 
func _resource_saved(resource: Resource):
	if not resource is GDScript:
		return
	var snapshot = get_coding_data(resource)
	if snapshot == null:
		return

	send_heartbeat(snapshot.file_path, "coding",  snapshot.line_no, snapshot.cursor_pos, snapshot.lines, true)

func setup_plugin() -> void:
	Utils.plugin_print("Setting up %s" % get_user_agent())
	check_dependencies()

	main_screen_changed.connect(_main_screen_changed)
	scene_saved.connect(_scene_saved)
	resource_saved.connect(_resource_saved)
	 
	await get_tree().process_frame
	
	counter_instance = Counter.instantiate()
	add_control_to_bottom_panel(counter_instance, current_time)

func _disable_plugin() -> void:
	if counter_instance:
		remove_control_from_bottom_panel(counter_instance)
		counter_instance.queue_free()
		counter_instance = null

func send_heartbeat(filepath: String, catagory: String, line_num: int, cursor_pos: int, lines: int, is_write: bool) -> void:
	if not FileAccess.file_exists(TERMUX_WAKA_CLI):
		print("Wakatime CLI binary not found at target path: %s" % TERMUX_WAKA_CLI)
		return

	var cmd: Array[Variant] = [
		"--entity", filepath, 
		"--key", HACKATIME_API_KEY, 
		"--api-url", HACKATIME_API_URL,
		"--exclude-unknown-project"
	]
	
	if is_write:
		cmd.append("--write")
		
	cmd.append_array(["--alternate-project", ProjectSettings.get("application/config/name")])
	cmd.append_array(["--time", str(Time.get_unix_time_from_system())])
	cmd.append_array(["--lineno", str(line_num)])
	cmd.append_array(["--cursorpos", str(cursor_pos)])
	cmd.append_array(["--lines-in-file", str(lines)])
	cmd.append_array(["--plugin", get_user_agent()])
	cmd.append_array(["--category", catagory])

	var cmd_callable = Callable(self, "_handle_heartbeat").bind(cmd)
	WorkerThreadPool.add_task(cmd_callable)
	
func _handle_heartbeat(cmd_arguments) -> void:
	if wakatime_cli == null:
		wakatime_cli = TERMUX_WAKA_CLI
		
	var output: Array[Variant] = []
	var exit_code: int = OS.execute(wakatime_cli, cmd_arguments, output, true)
	
	update_today_time(wakatime_cli)
		
	if debug:
		if exit_code == -1:
			Utils.plugin_print("Failed to send heartbeat. Output: %s" % output)
		else:
			Utils.plugin_print("Heartbeat sent successfully. Code: %d" % exit_code)
			
func update_today_time(wakatime_cli) -> void:
	var output: Array[Variant] = []
	var exit_code: int = OS.execute(wakatime_cli, [
		"--today", 
		"--key", HACKATIME_API_KEY, 
		"--api-url", HACKATIME_API_URL
	], output, true)
	
	if exit_code == 0 and output.size() > 0:
		current_time = output[0]
	else:
		current_time = "Wakatime"
	call_deferred("_update_panel_label", current_time, "")
	
func _update_panel_label(label: String, content: String):
	if counter_instance and counter_instance.has_node("HBoxContainer/Label"):
		counter_instance.get_node("HBoxContainer/Label").text = content
		remove_control_from_bottom_panel(counter_instance)
		add_control_to_bottom_panel(counter_instance, label)
		
#------------------------------- FILE FUNCTIONS -------------------------------
func check_dependencies() -> void:
	if not FileAccess.file_exists(TERMUX_WAKA_CLI):
		Utils.plugin_print_err("Wakatime binary not found at path: %s" % TERMUX_WAKA_CLI)
	else:
		Utils.plugin_print("Using executable binary path: %s" % TERMUX_WAKA_CLI)

#------------------------------- PLUGIN INFORMATIONS -------------------------------
	
func get_user_agent() -> String:
	return "godot/%s %s/%s" % [
		get_engine_version(), 
		_get_plugin_name(),
		_get_plugin_version()
	]
	 
func _get_plugin_name() -> String:
	return "Godot_Super-Wakatime"
	
func _get_plugin_version() -> String:
	if get_plugin_version() == "":
		return "unknown"
	return get_plugin_version()
	
func get_engine_version() -> String:
	return "%s.%s.%s" % [Engine.get_version_info()["major"], Engine.get_version_info()["minor"], 
		Engine.get_version_info()["patch"]]

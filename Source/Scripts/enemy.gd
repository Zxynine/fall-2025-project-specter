extends CharacterBody3D

enum {IDLE, ROAMING, SEARCHING, HUNTING}
@onready var current_state = ROAMING

# for debug
func _enter_tree():
	add_to_group("Enemy")

@onready var player = %Player
@onready var pause_menu = %PauseMenu
@onready var nav_agent = $NavigationAgent3D
@onready var sfx_kill = $sfx_kill
@onready var sfx_echo = $sfx_echo
@onready var rc = $RayCast3D
@onready var echolocation_timer = $EchoTimer
@onready var confidence : ConfidenceWrapper

var target_pos : Vector3
var search_pos : Vector3
var roam_target : Vector3
var SPEED = 3.0
var search_counter = 0
const ROAM_SPEED = 2.0
const SEARCH_SPEED = 2.5
const HUNT_SPEED = 5.0

const ECHOLOCATION_RANGE = 15.0
const ECHOLOCATION_ANGLE = PI / 4
const ECHOLOCATION_COOLDOWN = 3.0
const ECHOLOCATION_COOLDOWN_SEARCHING = 1.5
const ECHOLOCATION_COOLDOWN_HUNTING = 1.0

const ROAM_RADIUS = 10.0
const PLAYER_BIAS = 0.3
var roam_wait_time : float = 0.0

func _ready():
	confidence = ConfidenceWrapper.new()
	confidence.enemy = self
	
	SoundManager.register_enemy(self) #give bro ears
	roam_target = global_position
	set_new_roam_target()
	sfx_kill.volume_db = -14

func _exit_tree():
	SoundManager.unregister_enemy(self)

func _physics_process(delta: float) -> void:
	confidence.interval_decay(delta)
	
	roam_wait_time -= delta
	
	if rc.is_colliding() and rc.get_collider() == player:
		kill_player() #TODO
		return
	
	match current_state:
		IDLE:
			velocity = Vector3.ZERO
			if roam_wait_time <= 0:
				change_state(ROAMING)
		
		ROAMING:
			if global_position.distance_to(roam_target) < 2.0 or roam_wait_time <= 0:
				set_new_roam_target()
				roam_wait_time = randf_range(3.0, 6.0)
			nav_agent.target_position = roam_target
			var next_nav_point = nav_agent.get_next_path_position()
			velocity = (next_nav_point - global_position).normalized() * SPEED
			var target_rot = Vector3(next_nav_point.x, global_position.y, next_nav_point.z)
			
			if velocity.length() > 0.1 and global_position != target_rot:
				look_at(target_rot)
			
			
			move_and_slide()

		SEARCHING:
			if randf() < 0.05 * search_counter:
				confidence.new_interval()
				search_counter = 0
			
			if global_position.distance_to(target_pos) < 1.5:
				set_search_point()
				search_counter += 1
			
			nav_agent.target_position = target_pos
			var next_nav_point = nav_agent.get_next_path_position()
			velocity = (next_nav_point - global_position).normalized() * SPEED
			
			var target_rot = Vector3(next_nav_point.x, global_position.y, next_nav_point.z)
			
			if velocity.length() > 0.1 and !global_position.is_equal_approx(target_rot):
				look_at(target_rot)
			
			move_and_slide()
			
			if echolocation_timer.is_stopped() and randf() < 0.01:
				echolocate()
		HUNTING:
			target_pos = confidence.get_cur_interval_pos()
			if global_position.distance_to(target_pos) < 0.5:
				confidence.new_interval()
			
			nav_agent.target_position = target_pos
			var next_nav_point = nav_agent.get_next_path_position()
			velocity = (next_nav_point - global_position).normalized() * SPEED
			
			var target_rot = Vector3(next_nav_point.x, global_position.y, next_nav_point.z)
			
			if velocity.length() > 0.1 and global_position != target_rot:
				look_at(target_rot)
			
			move_and_slide()
			
			if echolocation_timer.is_stopped() and randf() < 0.025:
				echolocate()


func change_state(state):
	if current_state == state:
		return
	current_state = state
	match state:
		IDLE:
			print("State changed to: IDLE")
			SPEED = 0.5
			roam_wait_time = randf_range(2.0, 4.0)
		ROAMING:
			print("State changed to: ROAMING")
			SPEED = ROAM_SPEED
			set_new_roam_target()
		SEARCHING:
			print("State changed to: SEARCHING")
			SPEED = SEARCH_SPEED
			search_pos = confidence.get_interval(SEARCHING)
			search_counter = 0
			set_search_point()
		HUNTING:
			print("State changed to: HUNTING")
			SPEED = HUNT_SPEED
			target_pos = confidence.get_interval(HUNTING)

func set_search_point():
	var angle = randf() * 2 * PI
	var radius = randf_range(2.0, 5.0)
	var offset = Vector3(cos(angle) * radius, 0, sin(angle) * radius)
	target_pos = search_pos + offset

func set_new_roam_target():
	var bias = randf()
	if bias < PLAYER_BIAS:
		var to_player = (player.global_position - global_position).normalized()
		var angle_offset = randf_range(-PI/3, PI/3)  # +/- 60 degrees
		var rotated = to_player.rotated(Vector3.UP, angle_offset)
		var distance = randf_range(5.0, ROAM_RADIUS)
		roam_target = global_position + rotated * distance
	else:
		var angle = randf() * 2 * PI
		var radius = randf_range(5.0, ROAM_RADIUS)
		var offset = Vector3(cos(angle) * radius, 0, sin(angle) * radius)
		roam_target = global_position + offset

	roam_target.y = global_position.y

func echolocate():
	print("Echolocate!")
	sfx_echo.play()
	match current_state:
		HUNTING:
			echolocation_timer.start(ECHOLOCATION_COOLDOWN_HUNTING)
		SEARCHING:
			echolocation_timer.start(ECHOLOCATION_COOLDOWN_SEARCHING)
		_:
			echolocation_timer.start(ECHOLOCATION_COOLDOWN)
	var to_player = player.global_position - global_position
	var distance = to_player.length()
	var direction = to_player.normalized()

	if distance > ECHOLOCATION_RANGE:
		#print("echo too far (%.1fm)" % distance)
		return
		
	var forward = -transform.basis.z
	var plangle = forward.angle_to(direction)
	var in_zone = plangle <= ECHOLOCATION_ANGLE
		
	if in_zone:
		var space_state = get_world_3d().direct_space_state
		var query = PhysicsRayQueryParameters3D.create(
			global_position + Vector3(0, 1, 0),
			player.global_position + Vector3(0, 1, 0)
		)
		query.collision_mask = 1
		query.exclude = [self]
		
		var result = space_state.intersect_ray(query)
		
		if result.is_empty():
			#print("no raycast collision")
			return
		elif result.collider == player:
			SoundManager.emit_sound(player.global_position, 10, player)
		else:
			#print(" blocked - %s" % result.collider.name)
			return

func on_sound_heard(sound_pos: Vector3, strength: float, wall_count: int):
	confidence.on_sound_heard(sound_pos, strength, wall_count)

func kill_player():
	sfx_kill.play()
	current_state = IDLE
	velocity = Vector3.ZERO
	await get_tree().create_timer(0.98).timeout
	pause_menu.end_game()

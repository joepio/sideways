extends Node
func _physics_process(_d):
	var m = get_parent()
	if Engine.get_physics_frames() % 120 != 0 or m.players.is_empty(): return
	for p in m.players:
		var c: Car = p.car
		if c == null: continue
		var road_h = m.stage.height(c.global_position.x, c.global_position.z)
		print("%s t=%.1f v=%.1f along=%.1f gear=%d rpm=%d ground=%d y=%.2f road=%.2f thr=%.2f brk=%.2f st=%.2f hb=%.1f w=%.1f" % [p.name, m.clock, c.speed, p.along, c.gear, c.rpm(), c.on_ground, c.global_position.y, road_h, c.throttle, c.brake, c.steer_input, c.handbrake, c.wheels[2].omega])

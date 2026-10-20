class_name CarSpec
## The numbers that make a car. Lengths in metres, masses in kg, torque in Nm.
## Local frame: -Z is forward, +X right, +Y up; y = 0 is the wheel-centre
## height at rest, z = 0 is midway between the axles.

const CARS := {
	# A four-wheel drive gravel car in the spirit of today's Rally2 cars:
	# 1.6 turbo, sequential six-speed, locked centre, plated front and rear diffs.
	"rally2": {
		"name": "Rally2",
		"mass": 1230.0,
		"inertia": Vector3(1900.0, 2100.0, 520.0), # pitch, yaw, roll
		"cg": Vector3(0.0, 0.16, -0.12),
		"wheelbase": 2.50,
		"track": 1.56,
		"wheel_radius": 0.33,
		"wheel_inertia": 1.1,
		"droop_y": -0.10, # wheel centre at full extension
		"travel": 0.24,
		"spring": [34000.0, 30000.0], # front, rear N/m
		"bump": [3200.0, 2800.0], # damping N/(m/s)
		"rebound": [4800.0, 4200.0],
		"arb": [9000.0, 6000.0], # anti-roll bar N/m
		"max_steer": deg_to_rad(30.0),
		"brake": [1650.0, 1050.0], # max torque per wheel
		"handbrake": 2600.0, # per rear wheel
		"drive": [0.5, 0.5], # front/rear share
		"centre_lock": 900.0, # Nm the centre coupling can carry; opened by the handbrake
		"diff_preload": [80.0, 120.0],
		"diff_ramp": [0.45, 0.65], # extra lock as a share of axle torque
		# Engine
		"idle_rpm": 950.0,
		"limit_rpm": 7600.0,
		"engine_inertia": 0.16,
		"torque": [[1000.0, 160.0], [2000.0, 250.0], [3000.0, 390.0], [4000.0, 440.0],
			[5000.0, 430.0], [6000.0, 385.0], [7000.0, 330.0], [7600.0, 290.0], [8200.0, 0.0]],
		"friction": [18.0, 0.0085], # engine braking: a + b * rpm
		"gears": [3.20, 3.00, 2.15, 1.67, 1.36, 1.15, 1.00], # index 0 is reverse
		"final": 4.40,
		"shift_time": 0.08,
		"clutch": 650.0, # max clutch torque
		"upshift_rpm": 7150.0,
		"downshift_rpm": 3600.0,
		"drag": 0.42, # 0.5 * rho * Cd * A
		"downforce": 0.12,
	},
}


static func get_car(id: String) -> Dictionary:
	return CARS.get(id, CARS["rally2"])

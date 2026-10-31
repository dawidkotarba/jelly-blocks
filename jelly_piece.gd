class_name JellyPiece
extends Node2D

## Typy kształtów klocków (Blocks)
enum ShapeType {
	I_SHAPE,
	J_SHAPE,
	L_SHAPE,
	O_SHAPE,
	S_SHAPE,
	T_SHAPE,
	Z_SHAPE
}

enum PieceState {
	FALLING,  # Klocek sterowany przez gracza
	LOCKING,  # Klocek dotknął podłoża/innego klocka, trwa odliczanie blokady
	SETTLED,  # Klocek osiadł na planszy (nadal sprężysty i uginający się pod uderzeniem!)
	CLEARING  # Klocek w trakcie animacji zniknięcia (czyszczenie linii)
}

# --- Cząstka masy (Verlet) ---
class JellyPoint:
	var position: Vector2
	var prev_position: Vector2
	var rest_local_pos: Vector2 = Vector2.ZERO
	var acceleration: Vector2 = Vector2.ZERO
	var is_pinned: bool = false

	func _init(p_pos: Vector2) -> void:
		position = p_pos
		prev_position = p_pos
		rest_local_pos = p_pos

# --- Więz sprężynowy ---
class JellySpring:
	var a: JellyPoint
	var b: JellyPoint
	var rest_length: float
	var stiffness: float

	func _init(p_a: JellyPoint, p_b: JellyPoint, p_stiffness: float = 1.0) -> void:
		a = p_a
		b = p_b
		rest_length = a.position.distance_to(b.position)
		stiffness = p_stiffness

# --- Parametry Konfiguracyjne ---
@export var shape_type: ShapeType = ShapeType.L_SHAPE
@export var cell_size: float = 38.0
@export var subdivisions: int = 2

# Właściwości fizyczne (soczysta sprężystość i uginanie, bez deformowania w potworka)
@export var base_gravity: float = 400.0
@export var damping: float = 0.985
@export var stiffness: float = 0.88
@export var shape_recovery_stiffness: float = 0.35 # Utrzymywanie kształtu żelki (Shape Matching)
@export var solver_iterations: int = 8
@export var bounciness: float = 0.38              # Sprężyste, miękkie uginanie i odbicie żelek
@export var friction: float = 0.65                # Brak zacinania na ścianach

# Wygląd
@export var jelly_color: Color = Color(1.0, 0.55, 0.05, 0.88)
@export var outline_color: Color = Color(0.9, 0.35, 0.0, 1.0)
@export var outline_width: float = 3.2
@export var enable_smoothing: bool = true
@export var show_eyes: bool = true
@export var debug_draw: bool = false

# Stan gry
var state: PieceState = PieceState.FALLING
var lock_timer: float = 0.0
const LOCK_DELAY: float = 0.50 # Czas od kontaktu do zablokowania

# Granice studni (współrzędne lokalne wewnątrz kontenera studni)
var board_left: float = 0.0
var board_right: float = 380.0
var board_floor: float = 760.0

# Kąt obrotu klocka (do Shape Matching)
var target_rotation_angle: float = 0.0

# Podświetlenie przy zderzeniu żelek (Jelly Glow)
var glow_intensity: float = 0.0
var recent_impact_pos: Vector2 = Vector2.ZERO
var impact_ring_radius: float = 0.0

# Flaga szybkiego opadania (spacja / przycisk na telefonie)
var is_fast_dropping: bool = false

# Struktury wewnętrzne
var points: Array[JellyPoint] = []
var springs: Array[JellySpring] = []
var boundary_indices: Array[int] = []
var current_boundary_polygon: PackedVector2Array = PackedVector2Array()

# Referencje do węzłów
var polygon_node: Polygon2D
var outline_node: Line2D
var clear_alpha: float = 1.0
var clear_scale: float = 1.0

# Sygnały
signal piece_locked(piece: JellyPiece)
signal piece_cleared(piece: JellyPiece)

# Kolory klasyczne klocków (soczyste kolory żelek)
const PALETTE = {
	ShapeType.I_SHAPE: Color(0.0, 0.88, 0.98), # Cyan - guma balonowa
	ShapeType.J_SHAPE: Color(0.22, 0.48, 0.98), # Niebieska malina
	ShapeType.L_SHAPE: Color(1.0, 0.56, 0.06), # Pomarańczowa żelka
	ShapeType.O_SHAPE: Color(1.0, 0.88, 0.12), # Cytrynowy żelek
	ShapeType.S_SHAPE: Color(0.24, 0.88, 0.32), # Jabłuszko
	ShapeType.T_SHAPE: Color(0.78, 0.28, 0.95), # Jagodowy fiolet
	ShapeType.Z_SHAPE: Color(0.98, 0.24, 0.28) # Truskawkowy czerwony
}

func _ready() -> void:
	if PALETTE.has(shape_type):
		jelly_color = PALETTE[shape_type]
		jelly_color.a = 0.90
		outline_color = jelly_color.darkened(0.32)
		outline_color.a = 1.0

	_setup_visual_nodes()
	build_jelly_mesh()

func _setup_visual_nodes() -> void:
	if not polygon_node:
		polygon_node = Polygon2D.new()
		polygon_node.name = "Polygon"
		polygon_node.antialiased = true
		add_child(polygon_node)

	if not outline_node:
		outline_node = Line2D.new()
		outline_node.name = "Outline"
		outline_node.joint_mode = Line2D.LINE_JOINT_ROUND
		outline_node.begin_cap_mode = Line2D.LINE_CAP_ROUND
		outline_node.end_cap_mode = Line2D.LINE_CAP_ROUND
		add_child(outline_node)

## Generowanie punktów i sprężyn dla wybranego kształtu klocka
func build_jelly_mesh() -> void:
	points.clear()
	springs.clear()
	boundary_indices.clear()

	var cells: Array[Vector2i] = _get_cells(shape_type)
	var sub: int = subdivisions
	var mini_size: float = cell_size / float(sub)

	var occupied_mini: Dictionary = {}
	for c in cells:
		for sx in range(sub):
			for sy in range(sub):
				var mx = c.x * sub + sx
				var my = c.y * sub + sy
				occupied_mini[Vector2i(mx, my)] = true

	var vertex_map: Dictionary = {}

	for mcell in occupied_mini.keys():
		var mx = mcell.x
		var my = mcell.y
		var corners = [
			Vector2i(mx, my),
			Vector2i(mx + 1, my),
			Vector2i(mx + 1, my + 1),
			Vector2i(mx, my + 1)
		]
		for corner in corners:
			if not vertex_map.has(corner):
				var pos = Vector2(corner.x * mini_size, corner.y * mini_size)
				var pt = JellyPoint.new(pos)
				var idx = points.size()
				points.append(pt)
				vertex_map[corner] = idx

	var added_springs: Dictionary = {}
	var add_spring = func(idx_a: int, idx_b: int, s_stiffness: float) -> void:
		if idx_a == idx_b:
			return
		var key = Vector2i(mini(idx_a, idx_b), maxi(idx_a, idx_b))
		if not added_springs.has(key):
			added_springs[key] = true
			springs.append(JellySpring.new(points[idx_a], points[idx_b], s_stiffness))

	for mcell in occupied_mini.keys():
		var mx = mcell.x
		var my = mcell.y
		var i_tl: int = vertex_map[Vector2i(mx, my)]
		var i_tr: int = vertex_map[Vector2i(mx + 1, my)]
		var i_br: int = vertex_map[Vector2i(mx + 1, my + 1)]
		var i_bl: int = vertex_map[Vector2i(mx, my + 1)]

		# Sprężyny krawędziowe (strukturalne)
		add_spring.call(i_tl, i_tr, stiffness)
		add_spring.call(i_tr, i_br, stiffness)
		add_spring.call(i_br, i_bl, stiffness)
		add_spring.call(i_bl, i_tl, stiffness)

		# Sprężyny ukośne (shear/diagonal) - trzymające kształt
		add_spring.call(i_tl, i_br, stiffness * 0.92)
		add_spring.call(i_tr, i_bl, stiffness * 0.92)

	# Bending springs
	for corner in vertex_map.keys():
		var orig = vertex_map[corner]
		var r2 = corner + Vector2i(2, 0)
		var d2 = corner + Vector2i(0, 2)
		if vertex_map.has(r2):
			add_spring.call(orig, vertex_map[r2], stiffness * 0.50)
		if vertex_map.has(d2):
			add_spring.call(orig, vertex_map[d2], stiffness * 0.50)

	# Obwód wielokąta w kierunku zgodnym z ruchem wskazówek zegara
	var boundary_edges: Dictionary = {}
	for mcell in occupied_mini.keys():
		var mx = mcell.x
		var my = mcell.y
		if not occupied_mini.has(Vector2i(mx, my - 1)):
			boundary_edges[vertex_map[Vector2i(mx, my)]] = vertex_map[Vector2i(mx + 1, my)]
		if not occupied_mini.has(Vector2i(mx + 1, my)):
			boundary_edges[vertex_map[Vector2i(mx + 1, my)]] = vertex_map[Vector2i(mx + 1, my + 1)]
		if not occupied_mini.has(Vector2i(mx, my + 1)):
			boundary_edges[vertex_map[Vector2i(mx + 1, my + 1)]] = vertex_map[Vector2i(mx, my + 1)]
		if not occupied_mini.has(Vector2i(mx - 1, my)):
			boundary_edges[vertex_map[Vector2i(mx, my + 1)]] = vertex_map[Vector2i(mx, my)]

	if boundary_edges.size() > 0:
		var start_idx: int = boundary_edges.keys()[0]
		var curr: int = start_idx
		var visited: Dictionary = {}
		while true:
			boundary_indices.append(curr)
			visited[curr] = true
			if not boundary_edges.has(curr):
				break
			curr = boundary_edges[curr]
			if curr == start_idx or visited.has(curr):
				break

	# Wycentruj punkty wokół środka klocka i zachowaj ich idealne pozycje bazowe
	var com = get_center_of_mass()
	for pt in points:
		pt.position -= com
		pt.prev_position -= com
		pt.rest_local_pos = pt.position

	_update_polygon()

func _get_cells(type: ShapeType) -> Array[Vector2i]:
	match type:
		ShapeType.I_SHAPE:
			return [Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1), Vector2i(3, 1)]
		ShapeType.J_SHAPE:
			return [Vector2i(0, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1)]
		ShapeType.L_SHAPE:
			return [Vector2i(2, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1)]
		ShapeType.O_SHAPE:
			return [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]
		ShapeType.S_SHAPE:
			return [Vector2i(1, 0), Vector2i(2, 0), Vector2i(0, 1), Vector2i(1, 1)]
		ShapeType.T_SHAPE:
			return [Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1)]
		ShapeType.Z_SHAPE:
			return [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(2, 1)]
	return [Vector2i(0, 0)]

func _process(delta: float) -> void:
	# Wygaszanie poświaty zderzenia
	if glow_intensity > 0.0:
		glow_intensity = move_toward(glow_intensity, 0.0, delta * 2.8)
		if impact_ring_radius > 0.0:
			impact_ring_radius += delta * 45.0
		_update_visual_colors()
		queue_redraw()

func trigger_collision_glow(intensity: float = 1.0, impact_pos: Vector2 = Vector2.ZERO) -> void:
	glow_intensity = clampf(maxf(glow_intensity, intensity), 0.0, 1.0)
	if impact_pos != Vector2.ZERO:
		recent_impact_pos = impact_pos
		impact_ring_radius = 3.0
	_update_visual_colors()
	queue_redraw()

func _update_visual_colors() -> void:
	if state == PieceState.CLEARING:
		return
	if polygon_node:
		var brightened = jelly_color.lerp(Color(1.0, 1.0, 1.0, jelly_color.a), glow_intensity * 0.45)
		polygon_node.color = brightened

	if outline_node:
		var outline_glow = outline_color.lerp(Color(1.0, 1.0, 0.85, 1.0), glow_intensity * 0.80)
		outline_node.default_color = outline_glow
		outline_node.width = outline_width + glow_intensity * 2.4

## Główna pętla fizyki klocka
func step_physics(delta: float, fall_speed_multiplier: float, other_pieces: Array) -> void:
	if state == PieceState.CLEARING:
		_process_clearing(delta)
		return

	# Użyj stabilnego tłumienia (żelki na dole nadal zachowują elastyczność i uginają się)
	var cur_damping = damping
	if state == PieceState.SETTLED:
		cur_damping = 0.96

	# 1. KROK VERLETA: Aktualizacja pozycji na podstawie pędu i grawitacji
	var delta_sq: float = delta * delta
	var current_gravity = base_gravity
	if state == PieceState.FALLING:
		if is_fast_dropping:
			current_gravity *= 5.5
		else:
			current_gravity *= fall_speed_multiplier

	for pt in points:
		if pt.is_pinned:
			continue
		var vel = (pt.position - pt.prev_position) * cur_damping
		# Ograniczenie maksymalnej prędkości w dół (zapobiega przebijaniu)
		if vel.y > 18.0:
			vel.y = 18.0
		pt.prev_position = pt.position
		pt.position += vel + (pt.acceleration + Vector2(0, current_gravity)) * delta_sq
		pt.acceleration = Vector2.ZERO

	# 2. RELAKSACJA WIĘZÓW + SHAPE MATCHING (zapobiega wykrzywianiu i dziwnym deformacjom)
	var is_grounded: bool = false
	var hit_floor: bool = false
	var hit_support: bool = false

	var shape_match_rate = shape_recovery_stiffness / float(solver_iterations) * 2.2

	for _i in range(solver_iterations):
		_solve_springs()
		_apply_shape_matching(shape_match_rate)
		if _solve_boundaries_position_only():
			hit_floor = true
			is_grounded = true
		if _solve_piece_collisions(other_pieces):
			hit_support = true
			is_grounded = true

	# 3. KROK POST-RESOLVE: Sprężyste odbicia i tarcie
	_post_resolve_contact(hit_floor, hit_support)

	# 4. Logika blokowania klocka (Lock Delay) - aktywowana TYLKO przy podparciu od spodu!
	if state == PieceState.FALLING or state == PieceState.LOCKING:
		if is_grounded:
			state = PieceState.LOCKING
			var delay_threshold = 0.12 if is_fast_dropping else LOCK_DELAY
			lock_timer += delta
			if lock_timer >= delay_threshold:
				lock_piece()
		else:
			state = PieceState.FALLING
			lock_timer = 0.0

	_update_polygon()
	queue_redraw()

## Shape Matching: ściąganie punktów do idealnego kształtu żelki
func _apply_shape_matching(factor: float) -> void:
	if points.is_empty():
		return
	var com = get_center_of_mass()
	for pt in points:
		var ideal_pos = com + pt.rest_local_pos.rotated(target_rotation_angle)
		pt.position = pt.position.lerp(ideal_pos, factor)

func _solve_springs() -> void:
	for s in springs:
		var delta_pos = s.b.position - s.a.position
		var cur_len = delta_pos.length()
		if cur_len < 0.0001:
			continue
		var diff = (cur_len - s.rest_length) / cur_len
		var correction = delta_pos * 0.5 * diff * s.stiffness
		if not s.a.is_pinned and not s.b.is_pinned:
			s.a.position += correction
			s.b.position -= correction
		elif not s.a.is_pinned:
			s.a.position += correction * 2.0
		elif not s.b.is_pinned:
			s.b.position -= correction * 2.0

## Kolizje ze ścianami i podłogą: gładki ześlizg bez haczenia o ściany
func _solve_boundaries_position_only() -> bool:
	var touched_floor: bool = false
	for pt in points:
		# Podłoga studni
		if pt.position.y >= board_floor:
			pt.position.y = board_floor
			touched_floor = true
			if pt.prev_position.y > board_floor:
				pt.prev_position.y = board_floor

		# Ściana lewa - bez tarcia pionowego (płynny ślizg)
		if pt.position.x <= board_left:
			pt.position.x = board_left
			if pt.prev_position.x < board_left:
				pt.prev_position.x = board_left

		# Ściana prawa - bez tarcia pionowego (płynny ślizg)
		if pt.position.x >= board_right:
			pt.position.x = board_right
			if pt.prev_position.x > board_right:
				pt.prev_position.x = board_right

	return touched_floor

## Kolizje między klockami: uginanie żelek pod spodem + brak zatrzymywania w powietrzu
func _solve_piece_collisions(other_pieces: Array) -> bool:
	var my_aabb = get_bounding_box()
	var supported_from_below: bool = false

	for other in other_pieces:
		if other == self or other.state == PieceState.CLEARING:
			continue
		var other_aabb = other.get_bounding_box()
		if not my_aabb.intersects(other_aabb):
			continue

		var other_poly = other.current_boundary_polygon
		if other_poly.size() < 3:
			continue

		# Sprawdź punkty tego klocka wewnątrz obrysu drugiego klocka
		for pt in points:
			if Geometry2D.is_point_in_polygon(pt.position, other_poly):
				var closest_edge_info = _find_closest_edge(pt.position, other_poly)
				var edge_norm: Vector2 = closest_edge_info["normal"]
				var closest_pt: Vector2 = closest_edge_info["point"]
				var pen_depth = pt.position.distance_to(closest_pt) + 0.6

				# Klocek jest podparty od dołu TYLKO gdy normalna wskazuje w górę (edge_norm.y < -0.35)
				# Zderzenia boczne (spadanie wzdłuż ściany innego klocka) NIGDY nie blokują klocka w powietrzu!
				if edge_norm.y < -0.35:
					supported_from_below = true

				# Rozepchnięcie: ten klocek wypychamy w kierunku normalnej
				var push_self = edge_norm * (pen_depth * 0.55)
				pt.position += push_self

				# Klocek pod spodem: uginamy jego punkty w dół/w głąb (ugięcie pod ciężarem!)
				var push_other = -edge_norm * (pen_depth * 0.45)
				for other_pt in other.points:
					var d = other_pt.position.distance_to(closest_pt)
					if d < cell_size * 0.90:
						var w = 1.0 - (d / (cell_size * 0.90))
						other_pt.position += push_other * w

				# Transfer energii i uderzenia (ugięcie + sprężyste odbicie + świecenie żelki)
				var v_self = pt.position - pt.prev_position
				var closest_other_pt: JellyPoint = null
				var min_d_sq: float = 999999.0
				for other_pt in other.points:
					var d_sq = other_pt.position.distance_squared_to(closest_pt)
					if d_sq < min_d_sq:
						min_d_sq = d_sq
						closest_other_pt = other_pt

				var v_other = Vector2.ZERO
				if closest_other_pt:
					v_other = closest_other_pt.position - closest_other_pt.prev_position

				var v_rel = v_self - v_other
				var vn = v_rel.dot(edge_norm)
				if vn < 0.0: # Zbliżają się do siebie
					var impulse_mag = -(1.0 + bounciness) * vn
					var impulse = edge_norm * impulse_mag

					# Odbicie tego klocka
					pt.prev_position -= impulse * 0.50
					# Ugięcie i przekazanie pędu na klocek pod spodem!
					if closest_other_pt:
						closest_other_pt.prev_position += impulse * 0.50

					# Podświetlenie przy zderzeniu żelek!
					if impulse_mag > 0.8:
						trigger_collision_glow(clampf(impulse_mag / 6.0, 0.45, 1.0), pt.position)
						other.trigger_collision_glow(clampf(impulse_mag / 6.0, 0.45, 1.0), closest_pt)

	return supported_from_below

func _find_closest_edge(p: Vector2, poly: PackedVector2Array) -> Dictionary:
	var min_dist: float = 999999.0
	var best_pt: Vector2 = p
	var best_norm: Vector2 = Vector2.UP
	var n: int = poly.size()

	for i in range(n):
		var p1 = poly[i]
		var p2 = poly[(i + 1) % n]
		var proj = Geometry2D.get_closest_point_to_segment(p, p1, p2)
		var d = p.distance_to(proj)
		if d < min_dist:
			min_dist = d
			best_pt = proj
			var edge = p2 - p1
			# Zewnętrzna normalna dla obrysu zgodnie z ruchem wskazówek zegara
			var norm = Vector2(edge.y, -edge.x)
			var l = norm.length()
			best_norm = norm / l if l > 0.0001 else Vector2.UP

	return {"point": best_pt, "normal": best_norm, "dist": min_dist}

## Kontakt z podłożem – sprężystość i tłumienie
func _post_resolve_contact(hit_floor: bool, hit_support: bool) -> void:
	for pt in points:
		var vel = pt.position - pt.prev_position

		# Kontakt z podłożem
		if pt.position.y >= board_floor - 0.5:
			# Tarcie poziome na podłodze
			pt.prev_position.x = pt.position.x - vel.x * (1.0 - friction)
			# Sprężyste odbicie w pionie
			if vel.y > 0.0:
				pt.prev_position.y = pt.position.y + vel.y * bounciness
				if vel.y > 1.8:
					trigger_collision_glow(clampf(vel.y / 7.0, 0.4, 0.9), pt.position)

		# Uśpienie mikro-drgań dla klocków leżących
		if state == PieceState.SETTLED:
			if vel.length_squared() < 0.06:
				pt.prev_position = pt.position

## Ruch poziomy
func move_horizontal(dir: int, other_pieces: Array) -> bool:
	if state != PieceState.FALLING and state != PieceState.LOCKING:
		return false

	var shift = Vector2(dir * cell_size, 0)

	# Sprawdź granice studni
	var min_x = get_min_x() + shift.x
	var max_x = get_max_x() + shift.x
	if min_x < board_left - 1.0 or max_x > board_right + 1.0:
		return false

	# Sprawdź kolizję z leżącymi klockami
	for pt in points:
		var future_pos = pt.position + shift
		for other in other_pieces:
			if other == self or other.state == PieceState.CLEARING:
				continue
			if Geometry2D.is_point_in_polygon(future_pos, other.current_boundary_polygon):
				return false

	# Przesuń z lekkim, soczystym ugięciem żelki
	for pt in points:
		pt.position += shift
		pt.prev_position += shift * 0.80

	if state == PieceState.LOCKING:
		lock_timer = 0.0

	_update_polygon()
	return true

## Obrót o 90 stopni z zachowaniem fizyki i Shape Matching
func rotate_piece(direction: int, other_pieces: Array) -> bool:
	if state != PieceState.FALLING and state != PieceState.LOCKING:
		return false

	var com = get_center_of_mass()
	var angle = (PI / 2.0) * float(direction)

	var old_positions: Array[Vector2] = []
	var old_prevs: Array[Vector2] = []
	for pt in points:
		old_positions.append(pt.position)
		old_prevs.append(pt.prev_position)
		pt.position = com + (pt.position - com).rotated(angle)
		pt.prev_position = com + (pt.prev_position - com).rotated(angle)

	target_rotation_angle += angle

	# Wall-kick: skoryguj pozycję, jeśli wystaje za ściany studni
	var min_x = get_min_x()
	var max_x = get_max_x()
	var max_y = get_max_y()
	var kick = Vector2.ZERO

	if min_x < board_left:
		kick.x = board_left - min_x
	elif max_x > board_right:
		kick.x = board_right - max_x

	if max_y > board_floor:
		kick.y = board_floor - max_y

	if kick != Vector2.ZERO:
		for pt in points:
			pt.position += kick
			pt.prev_position += kick

	_update_polygon()

	# Sprawdź nakładanie na inne klocki
	var collides = false
	for other in other_pieces:
		if other == self or other.state == PieceState.CLEARING:
			continue
		for pt in points:
			if Geometry2D.is_point_in_polygon(pt.position, other.current_boundary_polygon):
				collides = true
				break
		if collides:
			break

	if collides:
		# Cofnij obrót jeśli brak miejsca
		target_rotation_angle -= angle
		for i in range(points.size()):
			points[i].position = old_positions[i]
			points[i].prev_position = old_prevs[i]
		_update_polygon()
		return false

	if state == PieceState.LOCKING:
		lock_timer = 0.0

	return true

## Przyspieszone opadanie (Spacja / Dotyk w dół)
func trigger_fast_drop() -> void:
	if state != PieceState.FALLING and state != PieceState.LOCKING:
		return
	is_fast_dropping = true
	# Nadaj kontrolowaną prędkość w dół
	for pt in points:
		var current_vy = pt.position.y - pt.prev_position.y
		if current_vy < 7.0:
			pt.prev_position.y = pt.position.y - 7.0

## Zablokowanie klocka na planszy (nadal zachowuje elastyczność i uginanie!)
func lock_piece() -> void:
	state = PieceState.SETTLED
	is_fast_dropping = false
	damping = 0.96
	friction = 0.85
	bounciness = 0.25
	piece_locked.emit(self)

## Rozpoczęcie zniknięcia przy czyszczeniu linii
func start_clear_animation() -> void:
	state = PieceState.CLEARING

func _process_clearing(delta: float) -> void:
	clear_alpha = move_toward(clear_alpha, 0.0, delta * 3.5)
	clear_scale = move_toward(clear_scale, 0.0, delta * 3.0)

	if polygon_node:
		var c = Color.WHITE.lerp(jelly_color, clear_alpha) # błysk na biało przy znikaniu
		c.a = clear_alpha
		polygon_node.color = c
		polygon_node.scale = Vector2(clear_scale, clear_scale)

	if outline_node:
		var oc = outline_color
		oc.a = clear_alpha
		outline_node.default_color = oc

	if clear_alpha <= 0.05:
		piece_cleared.emit(self)
		queue_free()

## Aktualizacja wielokąta Polygon2D
func _update_polygon() -> void:
	if boundary_indices.is_empty():
		return

	var raw_poly = PackedVector2Array()
	raw_poly.resize(boundary_indices.size())
	for i in range(boundary_indices.size()):
		raw_poly[i] = points[boundary_indices[i]].position

	var final_poly = raw_poly
	if enable_smoothing and raw_poly.size() >= 3:
		final_poly = _chaikin_smooth(raw_poly, 2)

	current_boundary_polygon = final_poly

	_update_visual_colors()

	if polygon_node:
		polygon_node.polygon = final_poly

	if outline_node and outline_width > 0.0:
		var loop = final_poly.duplicate()
		if loop.size() > 0:
			loop.append(loop[0])
		outline_node.points = loop

func _chaikin_smooth(poly: PackedVector2Array, iterations: int) -> PackedVector2Array:
	var cur = poly
	for _it in range(iterations):
		var n = cur.size()
		if n < 3:
			break
		var next_pts = PackedVector2Array()
		next_pts.resize(n * 2)
		for i in range(n):
			var p0 = cur[i]
			var p1 = cur[(i + 1) % n]
			next_pts[i * 2] = p0 * 0.75 + p1 * 0.25
			next_pts[i * 2 + 1] = p0 * 0.25 + p1 * 0.75
		cur = next_pts
	return cur

func get_center_of_mass() -> Vector2:
	if points.is_empty():
		return Vector2.ZERO
	var com = Vector2.ZERO
	for pt in points:
		com += pt.position
	return com / float(points.size())

func get_min_x() -> float:
	var m = 999999.0
	for pt in points:
		m = minf(m, pt.position.x)
	return m

func get_max_x() -> float:
	var m = -999999.0
	for pt in points:
		m = maxf(m, pt.position.x)
	return m

func get_min_y() -> float:
	var m = 999999.0
	for pt in points:
		m = minf(m, pt.position.y)
	return m

func get_max_y() -> float:
	var m = -999999.0
	for pt in points:
		m = maxf(m, pt.position.y)
	return m

func get_bounding_box() -> Rect2:
	if points.is_empty():
		return Rect2()
	var min_p = points[0].position
	var max_p = points[0].position
	for pt in points:
		min_p.x = minf(min_p.x, pt.position.x)
		min_p.y = minf(min_p.y, pt.position.y)
		max_p.x = maxf(max_p.x, pt.position.x)
		max_p.y = maxf(max_p.y, pt.position.y)
	return Rect2(min_p - Vector2(2, 2), (max_p - min_p) + Vector2(4, 4))

## Efekty wizualne: blik żelki, fala uderzeniowa i oczy
func _draw() -> void:
	if debug_draw:
		for s in springs:
			draw_line(s.a.position, s.b.position, Color(1, 1, 1, 0.2), 1.0)
		for pt in points:
			draw_circle(pt.position, 2.0, Color.RED)

	# Błyszczący blik żelki (gummy candy specular shine)
	if points.size() > 0 and state != PieceState.CLEARING:
		_draw_jelly_gloss()

	# Efekt rozbłysku fali uderzeniowej przy zderzeniu żelek
	if glow_intensity > 0.05 and recent_impact_pos != Vector2.ZERO:
		var ring_alpha = glow_intensity * 0.75
		var ring_color = Color(1.0, 1.0, 0.85, ring_alpha)
		draw_circle(recent_impact_pos, impact_ring_radius, Color(1.0, 1.0, 0.9, ring_alpha * 0.35))
		draw_arc(recent_impact_pos, impact_ring_radius, 0, TAU, 16, ring_color, 2.0)

	if show_eyes and points.size() > 0 and state != PieceState.CLEARING:
		_draw_cute_eyes()

func _draw_jelly_gloss() -> void:
	var com = get_center_of_mass()
	var gloss_offset = Vector2(-cell_size * 0.25, -cell_size * 0.30).rotated(target_rotation_angle)
	var gloss_pos = com + gloss_offset
	var alpha = 0.22 + glow_intensity * 0.40
	var gloss_col = Color(1.0, 1.0, 1.0, alpha)
	# Subtelny, miękki blik żelki
	draw_circle(gloss_pos, cell_size * 0.18, gloss_col)
	draw_circle(gloss_pos + Vector2(cell_size * 0.12, cell_size * 0.06).rotated(target_rotation_angle), cell_size * 0.10, Color(1.0, 1.0, 1.0, alpha * 0.7))

func _draw_cute_eyes() -> void:
	var com = get_center_of_mass()
	var avg_vel = Vector2.ZERO
	for pt in points:
		avg_vel += (pt.position - pt.prev_position)
	avg_vel /= float(points.size())

	var eye_offset = avg_vel.limit_length(3.5)
	var eye_spacing = cell_size * 0.25
	var eye_radius = 4.2
	var pupil_radius = 2.1

	var p1 = com + Vector2(-eye_spacing, -1.0)
	var p2 = com + Vector2(eye_spacing, -1.0)

	draw_circle(p1, eye_radius, Color.WHITE)
	draw_circle(p2, eye_radius, Color.WHITE)
	draw_circle(p1 + eye_offset, pupil_radius, Color(0.1, 0.1, 0.15))
	draw_circle(p2 + eye_offset, pupil_radius, Color(0.1, 0.1, 0.15))
	draw_circle(p1 + eye_offset + Vector2(-1, -1), 1.0, Color.WHITE)
	draw_circle(p2 + eye_offset + Vector2(-1, -1), 1.0, Color.WHITE)

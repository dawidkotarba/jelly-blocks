class_name BlocksGame
extends Node2D

const JellyPieceScript = preload("res://jelly_piece.gd")

# Wymiary studni dostosowane do ekranu pionowego (Portrait 720 x 1280)
const COLS: int = 10
const ROWS: int = 20
const CELL_SIZE: float = 38.0

const WELL_WIDTH: float = COLS * CELL_SIZE   # 380.0 px
const WELL_HEIGHT: float = ROWS * CELL_SIZE  # 760.0 px

# Pozycja studni na ekranie pionowym (wycentrowana poziomo, idealne proporcje pod telefon)
const WELL_OFFSET: Vector2 = Vector2(170.0, 185.0)

# Stan gry
var active_piece: JellyPiece = null
var settled_pieces: Array[JellyPiece] = []
var next_shape: JellyPiece.ShapeType = JellyPiece.ShapeType.T_SHAPE
var piece_bag: Array[int] = []

var score: int = 0
var lines_cleared: int = 0
var level: int = 1
var is_game_over: bool = false

# Obsługa powtarzania klawiszy (DAS)
var das_direction: int = 0
var das_timer: float = 0.0
const DAS_DELAY: float = 0.16
const DAS_INTERVAL: float = 0.05

# Obsługa sterowania dotykowego na telefonie (Touch Buttons & Gestures)
var touch_down_pos: Vector2 = Vector2.ZERO
var touch_start_time: float = 0.0
var is_touch_active: bool = false
var touch_dragged: bool = false
var touch_held_dir: int = 0
var touch_held_timer: float = 0.0
var is_touch_down_held: bool = false

# Przyciski dotykowe na ekranie (pozycje w pionie pod studnią)
var btn_left_rect: Rect2 = Rect2(40.0, 975.0, 120.0, 115.0)
var btn_right_rect: Rect2 = Rect2(180.0, 975.0, 120.0, 115.0)
var btn_rotate_rect: Rect2 = Rect2(420.0, 975.0, 120.0, 115.0)
var btn_down_rect: Rect2 = Rect2(560.0, 975.0, 120.0, 115.0)
var btn_drop_rect: Rect2 = Rect2(180.0, 1120.0, 360.0, 100.0)
var btn_restart_rect: Rect2 = Rect2(180.0, 700.0, 360.0, 95.0)
var btn_top_restart_rect: Rect2 = Rect2(625.0, 25.0, 65.0, 65.0)

# Wizualny stan wciśnięcia przycisków
var pressed_buttons: Dictionary = {
	"left": false,
	"right": false,
	"rotate": false,
	"down": false,
	"drop": false,
	"restart": false
}

# Efekt błysku czyszczonej linii
var flash_rows: Array[float] = []
var flash_timer: float = 0.0

# Kontener klocków i warstwa wierzchnia
var pieces_container: Node2D
var overlay_node: Node2D

func _ready() -> void:
	randomize()

	# 1. Kontener na klocki (warstwa środkowa wewnątrz studni)
	pieces_container = Node2D.new()
	pieces_container.name = "PiecesContainer"
	pieces_container.position = WELL_OFFSET
	pieces_container.z_index = 0
	add_child(pieces_container)

	# 2. Warstwa wierzchnia (ściany studni, błysk linii, Game Over, UI)
	overlay_node = Node2D.new()
	overlay_node.name = "Overlay"
	overlay_node.z_index = 10
	overlay_node.draw.connect(_draw_overlay)
	add_child(overlay_node)

	_fill_bag()
	next_shape = _take_from_bag()
	spawn_next_piece()

func _fill_bag() -> void:
	piece_bag = [0, 1, 2, 3, 4, 5, 6]
	piece_bag.shuffle()

func _take_from_bag() -> JellyPiece.ShapeType:
	if piece_bag.is_empty():
		_fill_bag()
	return piece_bag.pop_back() as JellyPiece.ShapeType

## Tworzenie nowego aktywnego klocka w studni
func spawn_next_piece() -> void:
	if is_game_over:
		return

	var shape_to_spawn = next_shape
	next_shape = _take_from_bag()

	var piece: JellyPiece = JellyPieceScript.new()
	piece.shape_type = shape_to_spawn
	piece.cell_size = CELL_SIZE
	piece.subdivisions = 2
	# Granice lokalne wewnątrz kontenera studni
	piece.board_left = 0.0
	piece.board_right = WELL_WIDTH
	piece.board_floor = WELL_HEIGHT

	pieces_container.add_child(piece)

	# Ustaw pozycję startową (środek górnej krawędzi)
	var spawn_pos = Vector2(WELL_WIDTH * 0.5, CELL_SIZE * 1.5)
	for pt in piece.points:
		pt.position += spawn_pos
		pt.prev_position += spawn_pos

	piece._update_polygon()
	piece.piece_locked.connect(_on_piece_locked)
	piece.piece_cleared.connect(_on_piece_cleared)
	active_piece = piece

	# Sprawdź Game Over (czy klocek od razu nie koliduje z ułożoną wieżą u samej góry)
	for other in settled_pieces:
		if other.state != JellyPiece.PieceState.CLEARING and other.get_min_y() < CELL_SIZE * 2.2:
			for pt in piece.points:
				if Geometry2D.is_point_in_polygon(pt.position, other.current_boundary_polygon):
					_trigger_game_over()
					return

	refresh_views()

func _trigger_game_over() -> void:
	is_game_over = true
	refresh_views()

func restart_game() -> void:
	if active_piece and is_instance_valid(active_piece):
		active_piece.queue_free()
		active_piece = null

	for p in settled_pieces:
		if is_instance_valid(p):
			p.queue_free()
	settled_pieces.clear()

	score = 0
	lines_cleared = 0
	level = 1
	is_game_over = false
	touch_held_dir = 0
	is_touch_down_held = false
	for k in pressed_buttons.keys():
		pressed_buttons[k] = false

	_fill_bag()
	next_shape = _take_from_bag()
	spawn_next_piece()
	refresh_views()

## Obsługa zdarzeń wejściowych: klawiatura + dotyk na telefonie
func _input(event: InputEvent) -> void:
	# Obsługa dotyku na ekranie telefonu
	if event is InputEventScreenTouch or event is InputEventMouseButton:
		var pos = event.position
		var is_press = event.pressed

		if is_game_over:
			if is_press and btn_restart_rect.has_point(pos):
				pressed_buttons["restart"] = true
				restart_game()
				get_viewport().set_input_as_handled()
			return

		if is_press:
			_handle_touch_press(pos)
		else:
			_handle_touch_release(pos)
		get_viewport().set_input_as_handled()
		return

	if event is InputEventScreenDrag or event is InputEventMouseMotion:
		if is_touch_active and not is_game_over:
			_handle_touch_drag(event.position)
		return

	# Obsługa klawiatury (PC / Emulator)
	if is_game_over:
		if event.is_action_pressed("ui_accept") or _is_key_pressed(event, KEY_R):
			restart_game()
		return

	if _is_key_pressed(event, KEY_R):
		restart_game()
		return

	if not active_piece or active_piece.state == JellyPiece.PieceState.CLEARING:
		return

	# Ruch poziomy
	if event.is_action_pressed("ui_left") or _is_key_pressed(event, KEY_A):
		active_piece.move_horizontal(-1, settled_pieces)
		das_direction = -1
		das_timer = DAS_DELAY
	elif event.is_action_released("ui_left") or _is_key_released(event, KEY_A):
		if das_direction == -1:
			das_direction = 0

	if event.is_action_pressed("ui_right") or _is_key_pressed(event, KEY_D):
		active_piece.move_horizontal(1, settled_pieces)
		das_direction = 1
		das_timer = DAS_DELAY
	elif event.is_action_released("ui_right") or _is_key_released(event, KEY_D):
		if das_direction == 1:
			das_direction = 0

	# Obrót
	if event.is_action_pressed("ui_up") or _is_key_pressed(event, KEY_W) or _is_key_pressed(event, KEY_X):
		active_piece.rotate_piece(1, settled_pieces)

	if _is_key_pressed(event, KEY_Z):
		active_piece.rotate_piece(-1, settled_pieces)

	# Zrzut (Hard Drop)
	if event.is_action_pressed("ui_select") or _is_key_pressed(event, KEY_SPACE):
		active_piece.trigger_fast_drop()

func _handle_touch_press(pos: Vector2) -> void:
	touch_down_pos = pos
	touch_start_time = Time.get_ticks_msec() / 1000.0
	is_touch_active = true
	touch_dragged = false

	# Przycisk restart w prawym górnym rogu
	if btn_top_restart_rect.has_point(pos):
		restart_game()
		return

	if not active_piece or active_piece.state == JellyPiece.PieceState.CLEARING:
		return

	# Przyciski sterowania na dole
	if btn_left_rect.has_point(pos):
		pressed_buttons["left"] = true
		active_piece.move_horizontal(-1, settled_pieces)
		touch_held_dir = -1
		touch_held_timer = DAS_DELAY
		refresh_views()
		return

	if btn_right_rect.has_point(pos):
		pressed_buttons["right"] = true
		active_piece.move_horizontal(1, settled_pieces)
		touch_held_dir = 1
		touch_held_timer = DAS_DELAY
		refresh_views()
		return

	if btn_rotate_rect.has_point(pos):
		pressed_buttons["rotate"] = true
		active_piece.rotate_piece(1, settled_pieces)
		refresh_views()
		return

	if btn_down_rect.has_point(pos):
		pressed_buttons["down"] = true
		is_touch_down_held = true
		refresh_views()
		return

	if btn_drop_rect.has_point(pos):
		pressed_buttons["drop"] = true
		active_piece.trigger_fast_drop()
		refresh_views()
		return

func _handle_touch_release(pos: Vector2) -> void:
	for k in pressed_buttons.keys():
		pressed_buttons[k] = false

	touch_held_dir = 0
	is_touch_down_held = false
	is_touch_active = false

	# Dotknięcie bezpośrednio wewnątrz studni (tap to rotate / swipe to drop)
	var well_rect = Rect2(WELL_OFFSET.x, WELL_OFFSET.y, WELL_WIDTH, WELL_HEIGHT)
	if well_rect.has_point(touch_down_pos) and not touch_dragged and active_piece:
		var touch_duration = (Time.get_ticks_msec() / 1000.0) - touch_start_time
		if touch_duration < 0.25:
			# Krótkie tapnięcie w studnię = obrót klocka
			active_piece.rotate_piece(1, settled_pieces)

	refresh_views()

func _handle_touch_drag(pos: Vector2) -> void:
	if not active_piece or active_piece.state == JellyPiece.PieceState.CLEARING:
		return

	var delta_pos = pos - touch_down_pos
	# Przeciąganie palcem po studni do przesuwania
	var well_rect = Rect2(WELL_OFFSET.x, WELL_OFFSET.y, WELL_WIDTH, WELL_HEIGHT)
	if well_rect.has_point(touch_down_pos):
		if absf(delta_pos.x) > CELL_SIZE * 0.75:
			var dir = 1 if delta_pos.x > 0 else -1
			active_piece.move_horizontal(dir, settled_pieces)
			touch_down_pos.x = pos.x
			touch_dragged = true
		elif delta_pos.y > CELL_SIZE * 1.5:
			active_piece.trigger_fast_drop()
			touch_down_pos = pos
			touch_dragged = true

func _is_key_pressed(event: InputEvent, keycode: Key) -> bool:
	return event is InputEventKey and event.pressed and not event.echo and event.keycode == keycode

func _is_key_released(event: InputEvent, keycode: Key) -> bool:
	return event is InputEventKey and not event.pressed and event.keycode == keycode

func _process(delta: float) -> void:
	# Obsługa powtarzania klawiszy klawiatury (DAS)
	if das_direction != 0 and active_piece and not is_game_over:
		das_timer -= delta
		if das_timer <= 0.0:
			active_piece.move_horizontal(das_direction, settled_pieces)
			das_timer = DAS_INTERVAL

	# Obsługa powtarzania dotykowego przytrzymanego przycisku (Touch DAS)
	if touch_held_dir != 0 and active_piece and not is_game_over:
		touch_held_timer -= delta
		if touch_held_timer <= 0.0:
			active_piece.move_horizontal(touch_held_dir, settled_pieces)
			touch_held_timer = DAS_INTERVAL

	# Animacja błysku usuniętych linii
	if flash_timer > 0.0:
		flash_timer -= delta
		if flash_timer <= 0.0:
			flash_rows.clear()
		refresh_views()

func _physics_process(delta: float) -> void:
	if is_game_over:
		return

	# Soft Drop (Strzałka w dół, S lub wciśnięty przycisk dotykowy)
	var fall_mult: float = 1.0 + (level - 1) * 0.12
	if Input.is_action_pressed("ui_down") or Input.is_key_pressed(KEY_S) or is_touch_down_held:
		fall_mult *= 3.5

	# Aktualizacja fizyki aktywnego klocka
	if active_piece and is_instance_valid(active_piece):
		active_piece.step_physics(delta, fall_mult, settled_pieces)

	# Aktualizacja fizyki leżących klocków (uginają się pod uderzeniem nowo spadającej żelki)
	for p in settled_pieces:
		if is_instance_valid(p):
			p.step_physics(delta, 1.0, settled_pieces)

## Klocek osiadł na planszy
func _on_piece_locked(piece: JellyPiece) -> void:
	if piece == active_piece:
		settled_pieces.append(piece)
		active_piece = null

		score += 10 * level

		# Sprawdź i usuń ułożone linie (dokładne i restrykcyjne wypełnienie)
		_check_and_clear_lines()

		# Zespawnuj kolejny klocek
		spawn_next_piece()

func _on_piece_cleared(piece: JellyPiece) -> void:
	settled_pieces.erase(piece)

## Sprawdzanie i czyszczenie ułożonych linii:
## Wymagamy gęstego, niemal całkowitego pokrycia wiersza przez żelki (brak luk i pustych kolumn)
func _check_and_clear_lines() -> void:
	var rows_to_clear: Array[int] = []

	for r in range(ROWS):
		var y_row = WELL_HEIGHT - (float(r) + 0.5) * CELL_SIZE
		var total_covered_samples = 0
		var cols_with_coverage = 0

		# Próbkowanie każdej z 10 kolumn w wielu punktach (6 punktów na kolumnę = 60 punktów w wierszu)
		for c in range(COLS):
			var col_samples_covered = 0
			var xs = [
				(float(c) + 0.22) * CELL_SIZE,
				(float(c) + 0.50) * CELL_SIZE,
				(float(c) + 0.78) * CELL_SIZE
			]
			var ys = [
				y_row - CELL_SIZE * 0.22,
				y_row + CELL_SIZE * 0.22
			]

			for x_pt in xs:
				for y_pt in ys:
					var test_pos = Vector2(x_pt, y_pt)
					var covered = false
					for p in settled_pieces:
						if p.state == JellyPiece.PieceState.CLEARING:
							continue
						if Geometry2D.is_point_in_polygon(test_pos, p.current_boundary_polygon):
							covered = true
							break
					if covered:
						col_samples_covered += 1

			# Kolumna musi mieć co najmniej 2 z 6 punktów pokryte
			if col_samples_covered >= 2:
				cols_with_coverage += 1
			total_covered_samples += col_samples_covered

		# Restrykcyjny warunek usunięcia linii:
		# 1. Wszystkie 10 kolumn musi mieć obecną żelkę (brak pustych dziur!)
		# 2. Co najmniej 50 na 60 próbek (ponad 83% objętości wiersza) musi być wypełnione
		if cols_with_coverage >= 10 and total_covered_samples >= 50:
			rows_to_clear.append(r)

	if rows_to_clear.is_empty():
		return

	# Uruchom efekt błysku
	flash_rows.clear()
	for r in rows_to_clear:
		flash_rows.append(WELL_HEIGHT - (float(r) + 0.5) * CELL_SIZE)
	flash_timer = 0.35

	# Znajdź i usuń klocki w wyczyszczonych liniach
	var pieces_to_destroy: Array[JellyPiece] = []
	for p in settled_pieces:
		if p.state == JellyPiece.PieceState.CLEARING:
			continue
		var com_y = p.get_center_of_mass().y
		var in_row = false
		for r in rows_to_clear:
			var y_row = WELL_HEIGHT - (float(r) + 0.5) * CELL_SIZE
			if absf(com_y - y_row) < CELL_SIZE * 0.95:
				in_row = true
				break
			# Sprawdź czy istotna część punktów klocka leży w tym wierszu
			var pts_in_row = 0
			for pt in p.points:
				if absf(pt.position.y - y_row) < CELL_SIZE * 0.6:
					pts_in_row += 1
			if pts_in_row >= maxi(2, int(p.points.size() * 0.25)):
				in_row = true
				break

		if in_row and not pieces_to_destroy.has(p):
			pieces_to_destroy.append(p)

	for p in pieces_to_destroy:
		p.start_clear_animation()

	# Punktacja klasyczna gry Blocks
	var count = rows_to_clear.size()
	lines_cleared += count
	level = 1 + (lines_cleared / 10)

	var score_table = [0, 100, 300, 500, 800]
	var pts = score_table[mini(count, 4)] * level
	score += pts

	refresh_views()

func refresh_views() -> void:
	queue_redraw()
	if overlay_node:
		overlay_node.queue_redraw()

## Rysowanie tła, siatki, UI i przycisków mobilnych
func _draw() -> void:
	# 1. Tło ekranu telefonu (elegancki, głęboki odcień)
	var viewport_size = get_viewport_rect().size
	var screen_rect = Rect2(0, 0, maxf(720.0, viewport_size.x), maxf(1280.0, viewport_size.y))
	draw_rect(screen_rect, Color(0.06, 0.07, 0.10))

	# 2. Studnia gry (Matrix 10x20 w pionie)
	var well_rect = Rect2(WELL_OFFSET.x, WELL_OFFSET.y, WELL_WIDTH, WELL_HEIGHT)
	# Wnętrze studni
	draw_rect(well_rect, Color(0.03, 0.04, 0.06, 0.96))

	# Delikatna siatka kolumn i wierszy
	var grid_color = Color(1.0, 1.0, 1.0, 0.035)
	for c in range(1, COLS):
		var x = WELL_OFFSET.x + float(c) * CELL_SIZE
		draw_line(Vector2(x, WELL_OFFSET.y), Vector2(x, WELL_OFFSET.y + WELL_HEIGHT), grid_color, 1.0)
	for r in range(1, ROWS):
		var y = WELL_OFFSET.y + float(r) * CELL_SIZE
		draw_line(Vector2(WELL_OFFSET.x, y), Vector2(WELL_OFFSET.x + WELL_WIDTH, y), grid_color, 1.0)

	# 3. Górny nagłówek telefonu: Tytuł, Wynik, Poziom, Następny klocek
	_draw_phone_header()

	# 4. Dolny panel dotykowy: Duże, wygodne przyciski na ekran telefonu
	_draw_phone_controls()

## Rysowanie górnego nagłówka zorganizowanego pod ekran telefonu
func _draw_phone_header() -> void:
	var font = ThemeDB.fallback_font

	# Logo i tytuł gry
	draw_string(font, Vector2(35, 52), "JELLY BLOCKS", HORIZONTAL_ALIGNMENT_LEFT, -1, 30, Color(0.15, 0.88, 1.0))
	draw_string(font, Vector2(35, 75), "Miękkie żelki • Gra mobilna", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.7, 0.75, 0.85, 0.75))

	# Przycisk Restart (w prawym górnym rogu)
	var top_btn_col = Color(0.18, 0.22, 0.30, 0.85)
	draw_rect(btn_top_restart_rect, top_btn_col)
	draw_rect(btn_top_restart_rect, Color(0.35, 0.45, 0.60), false, 2.0)
	draw_string(font, Vector2(btn_top_restart_rect.position.x + 20, btn_top_restart_rect.position.y + 42), "↺", HORIZONTAL_ALIGNMENT_LEFT, -1, 30, Color.WHITE)

	# Karty statystyk w pionie (Wynik, Poziom/Linie, Następny)
	var y_card = 95.0
	var card_h = 75.0

	# Karta 1: Wynik
	var card1_rect = Rect2(35.0, y_card, 190.0, card_h)
	draw_rect(card1_rect, Color(0.10, 0.12, 0.16, 0.92))
	draw_rect(card1_rect, Color(0.20, 0.26, 0.36), false, 1.5)
	draw_string(font, Vector2(48, y_card + 24), "WYNIK", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.55, 0.65, 0.8))
	draw_string(font, Vector2(48, y_card + 56), str(score), HORIZONTAL_ALIGNMENT_LEFT, -1, 26, Color.WHITE)

	# Karta 2: Poziom i Linie
	var card2_rect = Rect2(240.0, y_card, 190.0, card_h)
	draw_rect(card2_rect, Color(0.10, 0.12, 0.16, 0.92))
	draw_rect(card2_rect, Color(0.20, 0.26, 0.36), false, 1.5)
	draw_string(font, Vector2(252, y_card + 28), "POZIOM: " + str(level), HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(1.0, 0.85, 0.2))
	draw_string(font, Vector2(252, y_card + 56), "LINIE: " + str(lines_cleared), HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.85, 0.9, 0.95))

	# Karta 3: Następny klocek
	var card3_rect = Rect2(445.0, y_card, 240.0, card_h)
	draw_rect(card3_rect, Color(0.10, 0.12, 0.16, 0.92))
	draw_rect(card3_rect, Color(0.20, 0.26, 0.36), false, 1.5)
	draw_string(font, Vector2(458, y_card + 45), "NASTĘPNY", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.65, 0.75, 0.9))

	# Podgląd kształtu klocka w karcie
	_draw_shape_preview(next_shape, Vector2(610.0, y_card + card_h * 0.5))

## Podgląd klocka w karcie
func _draw_shape_preview(type: JellyPiece.ShapeType, center: Vector2) -> void:
	var dummy = JellyPieceScript.new()
	var cells = dummy._get_cells(type)
	var col = dummy.PALETTE[type]
	dummy.queue_free()

	var preview_cell = 14.0
	var min_c = Vector2i(99, 99)
	var max_c = Vector2i(-99, -99)
	for c in cells:
		min_c.x = mini(min_c.x, c.x)
		min_c.y = mini(min_c.y, c.y)
		max_c.x = maxi(max_c.x, c.x)
		max_c.y = maxi(max_c.y, c.y)

	var shape_w = float(max_c.x - min_c.x + 1) * preview_cell
	var shape_h = float(max_c.y - min_c.y + 1) * preview_cell
	var offset = center - Vector2(shape_w * 0.5, shape_h * 0.5)

	for c in cells:
		var pos = offset + Vector2((c.x - min_c.x) * preview_cell, (c.y - min_c.y) * preview_cell)
		var r = Rect2(pos + Vector2(1, 1), Vector2(preview_cell - 2, preview_cell - 2))
		draw_rect(r, col)
		draw_rect(r, col.darkened(0.35), false, 1.2)

## Rysowanie przycisków dotykowych na telefonie
func _draw_phone_controls() -> void:
	var font = ThemeDB.fallback_font

	# Funkcja pomocnicza do rysowania neonowych przycisków mobilnych
	var draw_touch_btn = func(rect: Rect2, label: String, sublabel: String, is_active: bool, accent_col: Color) -> void:
		var bg_col = accent_col.darkened(0.75) if is_active else Color(0.11, 0.13, 0.18, 0.95)
		bg_col.a = 0.95
		var border_col = accent_col if is_active else Color(0.25, 0.32, 0.44)
		var text_col = Color.WHITE if is_active else Color(0.9, 0.95, 1.0)

		# Tło i ramka
		draw_rect(rect, bg_col)
		draw_rect(rect, border_col, false, 2.5 if is_active else 1.8)

		# Ikona i etykieta
		var center_x = rect.position.x + rect.size.x * 0.5
		if sublabel != "":
			draw_string(font, Vector2(center_x - 16, rect.position.y + rect.size.y * 0.48), label, HORIZONTAL_ALIGNMENT_CENTER, -1, 32, text_col)
			draw_string(font, Vector2(center_x - 35, rect.position.y + rect.size.y * 0.80), sublabel, HORIZONTAL_ALIGNMENT_CENTER, -1, 12, text_col.darkened(0.2))
		else:
			draw_string(font, Vector2(center_x - 15, rect.position.y + rect.size.y * 0.62), label, HORIZONTAL_ALIGNMENT_CENTER, -1, 34, text_col)

	# 1. Przycisk LEWO (◄)
	draw_touch_btn.call(btn_left_rect, "◄", "LEWO", pressed_buttons["left"], Color(0.2, 0.75, 1.0))

	# 2. Przycisk PRAWO (►)
	draw_touch_btn.call(btn_right_rect, "►", "PRAWO", pressed_buttons["right"], Color(0.2, 0.75, 1.0))

	# 3. Przycisk OBRÓT (↻)
	draw_touch_btn.call(btn_rotate_rect, "↻", "OBRÓT", pressed_buttons["rotate"], Color(0.85, 0.35, 1.0))

	# 4. Przycisk W DÓŁ (▼)
	draw_touch_btn.call(btn_down_rect, "▼", "W DÓŁ", pressed_buttons["down"], Color(1.0, 0.65, 0.1))

	# 5. Przycisk ZRZUT (⏬)
	draw_touch_btn.call(btn_drop_rect, "⏬", "SZYBKI ZRZUT (DROP)", pressed_buttons["drop"], Color(0.25, 0.95, 0.45))

	# Podpowiedź klawiatury dla PC
	draw_string(font, Vector2(35, 1255), "Klawiatura: A/D/◄► Ruch • W/▲/X Obrót • S/▼ Dół • Spacja Zrzut • R Restart", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.5, 0.55, 0.65, 0.6))

## Rysowanie ścian studni, błysków i nakładki Game Over (Overlay)
func _draw_overlay() -> void:
	# Błysk ułożonych linii
	if flash_timer > 0.0:
		for y_line in flash_rows:
			var flash_y = WELL_OFFSET.y + y_line - CELL_SIZE * 0.5
			var r = Rect2(WELL_OFFSET.x, flash_y, WELL_WIDTH, CELL_SIZE)
			overlay_node.draw_rect(r, Color(1.0, 1.0, 0.95, flash_timer * 2.8))

	# Solidne, neonowe ściany ograniczające studnię
	var border_color = Color(0.18, 0.72, 1.0, 0.95)
	var border_w = 4.0
	# Ściana lewa
	overlay_node.draw_line(Vector2(WELL_OFFSET.x, WELL_OFFSET.y), Vector2(WELL_OFFSET.x, WELL_OFFSET.y + WELL_HEIGHT), border_color, border_w)
	# Ściana prawa
	overlay_node.draw_line(Vector2(WELL_OFFSET.x + WELL_WIDTH, WELL_OFFSET.y), Vector2(WELL_OFFSET.x + WELL_WIDTH, WELL_OFFSET.y + WELL_HEIGHT), border_color, border_w)
	# Podłoga
	overlay_node.draw_line(Vector2(WELL_OFFSET.x - 2.0, WELL_OFFSET.y + WELL_HEIGHT), Vector2(WELL_OFFSET.x + WELL_WIDTH + 2.0, WELL_OFFSET.y + WELL_HEIGHT), border_color, border_w + 2.0)

	# Nakładka Game Over (dostosowana do pionowego ekranu telefonu)
	if is_game_over:
		var overlay_full = Rect2(0, 0, 720, 1280)
		overlay_node.draw_rect(overlay_full, Color(0.02, 0.03, 0.05, 0.88))

		var font = ThemeDB.fallback_font
		overlay_node.draw_string(font, Vector2(160, 480), "KONIEC GRY", HORIZONTAL_ALIGNMENT_CENTER, -1, 46, Color(1.0, 0.25, 0.3))
		overlay_node.draw_string(font, Vector2(160, 540), "Twój wynik: " + str(score), HORIZONTAL_ALIGNMENT_CENTER, -1, 26, Color.WHITE)
		overlay_node.draw_string(font, Vector2(160, 580), "Ułożone linie: " + str(lines_cleared), HORIZONTAL_ALIGNMENT_CENTER, -1, 22, Color(1.0, 0.85, 0.25))

		# Duży przycisk dotykowy "ZAGRAJ PONOWNIE"
		var is_btn_active = pressed_buttons["restart"]
		var btn_bg = Color(0.2, 0.75, 1.0, 0.9) if is_btn_active else Color(0.15, 0.22, 0.32, 0.95)
		overlay_node.draw_rect(btn_restart_rect, btn_bg)
		overlay_node.draw_rect(btn_restart_rect, Color(0.2, 0.85, 1.0), false, 3.0)
		overlay_node.draw_string(font, Vector2(btn_restart_rect.position.x + 45, btn_restart_rect.position.y + 58), "ZAGRAJ PONOWNIE", HORIZONTAL_ALIGNMENT_CENTER, -1, 24, Color.WHITE)

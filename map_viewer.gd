extends Control
class_name MapViewer

## Основной скрипт Web Mercator

@export
var base_url:String = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png':
    set(v):
        if base_url != v:
            base_url = v
            _clean_all()
            queue_redraw()
@export_range(1,1000,1) var max_concurrent_requests:int = 5
@export_range(100,100000,1) var max_cached_tiles:int = 200
@export_range(0,25,1) var max_zoom_level:int = 21
@export var position_on_map: Vector2
@export var ax: float = 0.0: 
    set(v):
        _xyz.x = v
    get:
        return _xyz.x
@export var ay: float = 0.0: 
    set(v):
        _xyz.y = v
    get:
        return _xyz.y
@export var az: float = 0.0: 
    set(v):
        _xyz.z = v
    get:
        return _xyz.z

@onready var Mark: PackedScene = load("res://marks_dot/mark.tscn")
@onready var Scene1: PackedScene = load("res://marks_dot/control.tscn")
@onready var Scene2: PackedScene = load("res://marks_dot/plane.tscn")


const TILE_WIDTH:float = 256.0
const TILE_HEIGHT:float = 256.0
const MIN_ZOOM:float = 0.1
const MAX_ZOOM:float = 25.0


var _xyz:Vector3 = Vector3(0,0,2.5)
var _position:Vector2 = Vector2 (0,0)
var _cache:Dictionary = {}
var _queue:Dictionary = {}
var _error:Dictionary = {}
var _dragging:bool = false
var _drag_pos:Vector2 = Vector2.ZERO
var _last_error_check:int = 0
var _last_cache_check:int = 0
var _rollover:bool = false
var _cursor:Vector2 = Vector2.ZERO
var _point1:Vector2
var _point2:Vector2
var world_pos:Vector2
var _distance:float
var _requests:Array = []
var _selecting:bool = false
var _dots: = []
var taggled_entered = false
var JSOON = JSON.new()
var scene_name = ''


func _ready():
    scene_name = 'Mark'
    load_tiles()
    load_dots()
    # on mouse enter
    connect('mouse_entered', func():
        _rollover = true
        queue_redraw())
    # on mouse exit
    connect('mouse_exited', func():
        _rollover = false
        queue_redraw())
    
    
func _input(e):
    if Engine.is_editor_hint():
        return
    if e is InputEventMouseButton:
        var mouse_pos = get_global_mouse_position()
        var is_over_list = $ScrollContainer2.get_global_rect().has_point(mouse_pos)
        var is_over_map = get_tree().get_root().get_node("/root")
        if e.button_index == MOUSE_BUTTON_WHEEL_DOWN or e.button_index == MOUSE_BUTTON_WHEEL_UP:
            if is_over_list:
                return
            else:
                if e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
                    apply_zoom(0.95, get_local_mouse_position())
                elif e.button_index == MOUSE_BUTTON_WHEEL_UP:
                    apply_zoom(1.05, get_local_mouse_position())
    
    if e is InputEventMouseButton:
        if not $taggled.button_pressed:
            if e.button_index == MOUSE_BUTTON_LEFT:
                if e.pressed and _rollover:
                    _dragging = true
                    var lmp = get_local_mouse_position()
                    _drag_pos = screen_to_world(lmp.x, lmp.y)
                else:
                    _dragging = false
    elif e is InputEventMouseMotion:
        _cursor = get_local_mouse_position()
        if _dragging:
            var lmp = get_local_mouse_position()
            var wp = screen_to_world(lmp.x, lmp.y)
            var diff = _drag_pos - wp
            _xyz.x += diff.x
            _xyz.y += diff.y
        queue_redraw()

    if e is InputEventMouseButton:
        if e.pressed and _rollover:
            if e.button_index == MOUSE_BUTTON_RIGHT:
                if not _selecting:
                    _point1 = get_local_mouse_position()
                    _selecting = true
                else:
                    _point2 = get_local_mouse_position()
                    _selecting = false
                    var lat1 = screen_to_lonlat(_point1.x, _point1.y).x
                    var lon1 = screen_to_lonlat(_point1.x, _point1.y).y
                    var lat2 = screen_to_lonlat(_point2.x, _point2.y).x
                    var lon2 = screen_to_lonlat(_point2.x, _point2.y).y
            # Расчет расстояния
                    var dist:int = haversine_m(lon1, lat1, lon2, lat2)
                    $DistanceLabel_m.text = " Distance (m): " + str(dist) + " m "
                    $DistanceLabel_km.text = " Distance (km): " + str(dist/1000) + " km "
            elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN or MOUSE_BUTTON_WHEEL_UP:
                # Отмена выбора точек
                _selecting = false
                _point1 = Vector2.ZERO
                _point2 = Vector2.ZERO

    if e is InputEventMouseButton:
        if $taggled.button_pressed and e.pressed:
            if e.button_index == MOUSE_BUTTON_MIDDLE:
            # Создаем новую точку
                var world_pos = screen_to_world(e.position.x, e.position.y)
                var tile_index = xyz_to_idx(world_to_tile(world_pos.x, world_pos.y, _xyz.z, true).x, world_to_tile(world_pos.x, world_pos.y, _xyz.z, true).y, _xyz.z)
                var mark: Control = get(scene_name).instantiate()
                var new_dot = {
                    'position': world_pos,
                    'tile_index': tile_index,
                    'mark': mark,
                    'scene_name': scene_name
                }
                _dots.append(new_dot)
                add_child(mark)
                if not is_dot_visible(new_dot):
                    # Перемещаем точку в новую позицию
                    new_dot.position = get_new_dot_position(new_dot)
                _on_remove_dot_pressed()
            elif e.button_index == MOUSE_BUTTON_LEFT:
                if not taggled_entered and (not $point.get_global_rect().has_point(e.position)) and (not $star.get_global_rect().has_point(e.position)) and (not $plane.get_global_rect().has_point(e.position)):
                    remove_closest_dot(e.position)
                    _on_remove_dot_pressed()


func apply_zoom(multiplier: float, pivot: Vector2):
    var p1 = screen_to_world(pivot.x, pivot.y)
    _xyz.z = max(min(_xyz.z*multiplier, MAX_ZOOM),MIN_ZOOM)
    var p2 = screen_to_world(pivot.x, pivot.y)
    _xyz.x -= p2.x-p1.x
    _xyz.y -= p2.y-p1.y
    queue_redraw()


func _draw():
    var z = min(max_zoom_level, _xyz.z)
    var t1 = screen_to_tile(0, 0, z, true)
    var t2 = screen_to_tile(size.x, size.y, z, true)
    for tx in range(t1.x,t2.x+1):
        for ty in range(t1.y,t2.y+1):
            _draw_tile(tx,ty,z)
    # draw cursor
    var ll = screen_to_lonlat(_cursor.x,_cursor.y)
    var textt = lonlat_to_dms(ll.x, ll.y)
    $nsew.text = textt
    if _point1 != Vector2.ZERO:
        draw_circle(_point1, 5, Color.BLUE)
    if _point2 != Vector2.ZERO:
        draw_circle(_point2, 5, Color.BLUE)
    if _point1!= Vector2.ZERO and _point2!= Vector2.ZERO:
        draw_line(_point1, _point2, Color.BLUE, 1, true)
        #draw_line(_point2, _point2 + Vector2(0, 10), Color.RED, 2)
    var n = pow(2, z)
    for dot in _dots:
        var screen_pos = world_to_screen(dot.position.x, dot.position.y)
        if screen_pos.x >= 0:
            screen_pos.x = fmod(screen_pos.x, n * 256)
        else:
            screen_pos.x = -screen_pos.x - 1
            screen_pos.x = int(n * 256 - 1) - fmod(screen_pos.x, n * 256)
        dot.mark.position = screen_pos
    var start_screen = Vector2(250, get_size().y - 20)  # Начало линейки
    var scale_bar_lengths = [100, 95, 90, 85, 80, 75, 70, 65, 60, 75, 70, 85, 90, 95, 100, 95, 90, 85, 75, 70, 65]
    var optimal_length = scale_bar_lengths[_xyz.z - 1] if _xyz.z - 1 < scale_bar_lengths.size() else scale_bar_lengths[scale_bar_lengths.size() - 1]
    var end_screen = start_screen + Vector2(optimal_length, 0)
    var center_line = (start_screen + end_screen) / 2
    var start_world = screen_to_world(start_screen.x, start_screen.y)
    var end_world = screen_to_world(end_screen.x, end_screen.y)
    var distance_meters = 0.0
    distance_meters = haversine_m(
        world_to_lonlat(start_world.x, start_world.y).x,
        world_to_lonlat(start_world.x, start_world.y).y,
        world_to_lonlat(end_world.x, end_world.y).x,
        world_to_lonlat(end_world.x, end_world.y).y
    )
    var fnt = Label.new().get_theme_font('')
    var d_m = distance_meters
    var d_km = distance_meters/1000
    var distance_str = str(round(fmod(d_km, 10000))) + " км" if distance_meters >= 1000 else str((round(fmod(d_m, 10000)))) + " м"
    draw_string(fnt, center_line + Vector2(-30, -10), distance_str, HORIZONTAL_ALIGNMENT_CENTER, -1, 15, Color.BLACK)
    draw_line(start_screen, end_screen, Color.WHITE, 6, true)
    draw_line(start_screen, end_screen, Color.BLACK, 2, true)
    
    
func _clean_all():
    _queue.clear()
    _cache.clear()
    _error.clear()
    _requests.clear()
    for c in get_children():
        remove_child(c)
        c.queue_free()


# get the tile from queue with the newest timestamp
func get_next_in_queue():
    if _queue.is_empty():
        return null
    var tile = null
    for idx in _queue:
        var t = _queue.get(idx)
        if not tile or t.t > tile.t:
            tile = t
    return tile


# delete oldest tiles from cache
func _clean_cache():
    var overflow = _cache.size() - max_cached_tiles
    if overflow <= 0:
        return
    var list = _cache.values()
    list.sort_custom(func(t1,t2):
        return t1.t < t2.t
    )
    for i in range(overflow):
        var t = list[i]
        _cache.erase(t.i)


func _clean_errors():
    var now = Time.get_unix_time_from_system()
    var keys = _error.keys()
    for idx in keys:
        var t = _error.get(idx)
        var d = now - t.t
        if d > 10:
            _error.erase(t.i)


func _process(delta):
    var now = Time.get_unix_time_from_system()
    # reset tile errors
    if not _last_error_check or now - _last_error_check > 10:
        _last_error_check = now
        _clean_errors()
    # if cache is overflowing - clean it
    if not _last_cache_check or now - _last_cache_check > 5:
        _last_cache_check = now
        _clean_cache()
    # if queue contains items - and new requests can be made
    while not _queue.is_empty() and (_requests.size() < max_concurrent_requests):
        var tile = get_next_in_queue()
        if not tile:
            return
        var req = HTTPRequest.new()
        req.set_meta('tile', tile)
        add_child(req)
        _requests.append(req)
        req.name = str(tile.i)
        req.request_completed.connect(_response.bind(req,tile))
        req.use_threads = true
        _queue.erase(tile.i)
        if req.request(tile.url) != OK:
            tile.t = Time.get_unix_time_from_system()
            _error[tile.i] = tile
            var i = _requests.find(req)
            _requests.remove_at(i)
            remove_child(req)
            req.queue_free()


# result, response_code, headers, body
func _response(result,code,headers,body,req,tile):
    var i = _requests.find(req)
    _requests.remove_at(i)
    remove_child(req)
    req.queue_free()
    if code == 404:
        prints('File not found')
        tile.t = Time.get_unix_time_from_system()
        _error[tile.i] = tile
        return
    # get the image type from the reponse header
    var h = ''.join(headers)
    var type = ''
    if   h.contains('image/png'):  type = 'png'
    elif h.contains('image/jpg'):  type = 'jpg'
    elif h.contains('image/jpeg'): type = 'jpg'
    elif h.contains('image/bmp'):  type = 'bmp'
    elif h.contains('image/tga'):  type = 'tga'
    elif h.contains('image/webp'): type = 'webp'
    # unrecognized image type
    if not type:
        tile.t = Time.get_unix_time_from_system()
        _error[tile.i] = tile
        return
    # construct image from response body
    var image = Image.new()
    var error = OK
    if   type == 'png':		error = image.load_png_from_buffer(body)
    elif type == 'jpg':		error = image.load_jpg_from_buffer(body)
    elif type == 'bmp':		error = image.load_bmp_from_buffer(body)
    elif type == 'tga':		error = image.load_tga_from_buffer(body)
    elif type == 'webp':	error = image.load_webp_from_buffer(body)
    if error != OK:
        prints('Could not load the '+type+' image')
        tile.t = Time.get_unix_time_from_system()
        _error[tile.i] = tile
        return
    # create texture from image and add it to the cache
    var texture = ImageTexture.create_from_image(image)
    tile.texture = texture
    _cache[tile.i] = tile
    save_tile(tile.x, tile.y, tile.z, body)
    # redraw the map
    queue_redraw()
 

func quadkey(x: int, y: int, zoom: int) -> String:
    var rs: = ''
    for z in range(zoom, 0, -1):
        var digit = 0
        var mask = 1 << (z - 1)
        if x & mask:
            digit += 1
        if y & mask:
            digit += 2
        rs += str(digit)
    return rs


func quadkey_to_tile(qk:String) -> Vector3i:
    var x = 0
    var y = 0
    var z = len(qk)
    for i in range(z):
        var digit = int(qk[z - i - 1])
        if digit == 1:
            x |= 1 << i
        elif digit == 2:
            y |= 1 << i
        elif digit == 3:
            x |= 1 << i
            y |= 1 << i
    return Vector3(x, y, z)
    
    
func tile_name(x: int, y: int, zoom: int) -> String:
    var quadkey_str = quadkey(x,y,zoom)
    var tile_n = quadkey_str + ".png"
    return tile_n


func _draw_subtile(tx:int, ty:int, tz:int, origx:int, origy:int, origz:float) -> bool:
    var subtile = get_tile(tx, ty, tz)
    if not subtile:
        return false
    var p1 = tile_to_screen(origx,origy, origz)
    var p2 = tile_to_screen(origx+1, origy+1, origz)
    var x1 = tile_to_screen(tx,ty, tz)
    var x2 = tile_to_screen(tx+1, ty+1, tz)
    var xdiff = x2.x - x1.x
    var xrat1 = (p1.x - x1.x) / xdiff
    var xrat2 = (p2.x - x1.x) / xdiff
    var xwidth = xrat2-xrat1
    var ydiff = x2.y - x1.y
    var yrat1 = (p1.y - x1.y) / ydiff
    var yrat2 = (p2.y - x1.y) / ydiff
    var yheight = yrat2-yrat1
    var rect = Rect2(xrat1*TILE_WIDTH, yrat1*TILE_HEIGHT,xwidth*TILE_WIDTH, yheight*TILE_HEIGHT)
    if subtile.texture:
        draw_texture_rect_region(subtile.texture, Rect2(p1, p2-p1), rect)
        return true
    return false


func _draw_tile(tx:int, ty:int, z:float):
    var tz = floor(z)
    var p1 = tile_to_screen(tx, ty, z)
    var p2 = tile_to_screen(tx+1, ty+1, z)
    var p3 = p1 + (p2-p1) / 2
    var tile = get_tile(tx,ty,tz)
    $ZoomLabel.text = " Zoom: %d " % tz
    if tile:
        if tile.texture:
            draw_texture_rect(tile.texture, Rect2(p1, p2-p1), false, Color.WHITE, false)
        else:
            var zzz = tz
            var txx = tx
            var tyy = ty
            while zzz > 1:
                zzz -= 1
                txx = floor(txx/2)
                tyy = floor(tyy/2)
                if _draw_subtile(txx, tyy, zzz, tx,ty,z):
                    break


## convert lon/lat to world coords
func lonlat_to_world(lon:float, lat:float) -> Vector2:
    var x = lon / 180.0
    var latsin = sin(deg_to_rad(lat) * sign(lat))
    var y = (sign(lat) * (log((1.0+latsin) / (1.0-latsin)) / 2.0)) / PI
    return Vector2(x,y)


## convert world coords to lon/lat
func world_to_lonlat(wx:float, wy:float) -> Vector2:
    var lon = wx * 180.0
    var lat = rad_to_deg(atan(sinh(wy * PI)))
    return Vector2(lon,lat)


## convert screen coords to lon/lat
func screen_to_lonlat(sx:float, sy:float) -> Vector2:
    var w = screen_to_world(sx,sy)
    return world_to_lonlat(w.x, w.y)


## convert screen coords to world coords
func screen_to_world(sx:float, sy:float) -> Vector2:
    var n = pow(2.0, _xyz.z)
    var span_w = n * TILE_WIDTH
    var span_h = n * TILE_HEIGHT
    var px = sx - size.x/2 + span_w/2
    var py = sy - size.y/2 + span_h/2
    var xr = px / span_w
    var yr = py / span_h
    var x = (xr*2.0-1.0) + _xyz.x
    var y = ((-yr*2.0)+1.0) + _xyz.y
    return Vector2(x,y)


## convert screen coords to tile coords
func screen_to_tile(sx:float, sy:float, z:float, do_floor:bool=false) -> Vector2:
    var world = screen_to_world(sx,sy)
    return world_to_tile(world.x, world.y, z, do_floor)


## convert tile coords to screen coords
func tile_to_screen(tx:float, ty:float, tz:float) -> Vector2:
    var w = tile_to_world(tx, ty, tz)
    return world_to_screen(w.x, w.y)


## convert tile coords to world coords
func tile_to_world(tx:float, ty:float, tz:float) -> Vector2:
    var n = pow(2.0, floor(tz))
    var x = (tx / n) * 2.0 - 1.0
    var y = -((ty / n) * 2.0 - 1.0)
    return Vector2(x,y)


## convert world coords to tile coords
func world_to_tile(wx:float, wy:float, z:float, do_floor:bool=false) -> Vector2:
    var n = pow(2.0, floor(z))
    var tx = ((wx+1.0) / 2.0) * n
    var ty = ((-wy + 1.0) / 2.0) * n
    if do_floor:
        tx = floor(tx)
        ty = floor(ty)
    return Vector2(tx,ty)


## convert world coords to screen coords
func world_to_screen(wx:float, wy:float) -> Vector2:
    var n = pow(2.0, _xyz.z)
    var w = n * TILE_WIDTH
    var h = n * TILE_HEIGHT
    var xr = (((wx-_xyz.x)+1.0)/2.0)
    var yr = ((-(wy-_xyz.y)+1.0)/2.0)
    var x = w * xr - w/2 + size.x/2
    var y = h * yr - h/2 + size.y/2
    return Vector2(x,y)


## get the tile index from xyz tile coords
func xyz_to_idx(x:int, y:int, z:int)->int:
    var i = (pow(4,z)-1) / 3
    var n = pow(2,z)
    return i + (y * n + x)


func get_tile(x:int, y:int, z:int, create:bool=true)->Tile:
    # out of bounds
    var n = pow(2, z)
    if x >= 0:
        x = fmod(x, int(n))
    else:
        x = -x - 1
        x = int(n - 1) - fmod(x, int(n))
    if z < 0 or y < 0 or y >= n:
        return null
    # get tile index
    var idx = xyz_to_idx(x,y,z)
    var now = Time.get_unix_time_from_system()
    var tile = null
    # retrieve from error queue
    tile = _error.get(idx)
    if tile:
        return tile
    # retrieve from current requests...
    var req = find_child(str(idx), false, false)
    if req:
        tile = req.get_meta('tile')
        tile.t = now
        return tile
    # retrieve from cache
    tile = _cache.get(idx)
    if tile:
        tile.t = now
        return tile
    # retrieve from queue
    tile = _queue.get(idx)
    if tile:
        tile.t = now
        return tile
    # create a new tile - add it to queue
    if create:
        tile = Tile.new(idx,x,y,z)
        tile.url = base_url.replace('{x}',str(x)).replace('{y}', str(y)).replace('{z}', str(z))
        tile.t = now
        _queue[idx] = tile
    return tile


func lonlat_to_dms(lon:float, lat:float) -> String:
    var pf = 'N' if lat >= 0 else 'S'
    lat = abs(lat)
    var deg = floor(lat)
    var minute = (lat - deg) * 60
    var second = (minute - floor(minute)) * 600
    var text = (' ')+(pf)+(' ')+('%02d'%deg)+('°')+('%02d'%floor(minute))+('.')+('%03d'%floor(second))+("'")+('   ')
    pf = 'E' if lon >= 0 else 'W'
    lon = abs(lon)
    deg = floor(lon)
    minute = (lon - deg) * 60
    second = (minute - floor(minute)) * 600
    text += (pf)+(' ')+('%02d'%deg)+('°')+('%02d'%floor(minute))+('.')+('%03d'%floor(second))+("'")+(' ')
    return text


class Tile:
    var i:int = 0
    var x:int = 0
    var y:int = 0
    var z:int = 0
    var t:int = 0
    var url:String = ''
    var texture:Texture2D = null
    
    
    func _init(i:int, x:int, y:int, z:int):
        self.i = i
        self.x = x
        self.y = y
        self.z = z


func _on_move_button_pressed():
        var x = float($x_input.text)
        var y = float($y_input.text)
        # Преобразование широты/долготы в мировые координаты
        var world_coords = lonlat_to_world(x, y)
        var zoom_level = 7
        var anim = $AnimationPlayer.get_animation("move")
        anim.track_insert_key(0, 0, _xyz.x)
        anim.track_insert_key(1, 0, _xyz.y)
        anim.track_insert_key(2, 0, _xyz.z)
        # Обновление _xyz для отражения нового центрального положения
        _xyz.x = world_coords.x
        _xyz.y = world_coords.y
        _xyz.z = zoom_level
        anim.track_insert_key(0, 1, _xyz.x)
        anim.track_insert_key(1, 1, _xyz.y)
        anim.track_insert_key(2, 1, _xyz.z)
        $AnimationPlayer.play("move")
        # Перерисование карты для отражения нового местоположения
        queue_redraw()


func haversine_m(lat1, lon1, lat2, lon2):
    # Радиус Земли в метрах
    var R = 6372795
    # Преобразование градусов в радианы
    var rlat1 = deg_to_rad(lat1)
    var rlon1 = deg_to_rad(lon1)
    var rlat2 = deg_to_rad(lat2)
    var rlon2 = deg_to_rad(lon2)
    var cl1 = cos(rlat1)
    var cl2 = cos(rlat2)
    var sl1 = sin(rlat1)
    var sl2 = sin(rlat2)
    var delta = rlon2 - rlon1
    var cdelta = cos(delta)
    var sdelta = sin(delta)
    # вычисления длины большого круга
    var y = sqrt(pow(cl2*sdelta, 2) + pow(cl1*sl2-sl1*cl2*cdelta, 2))
    var x = sl1 * sl2 + cl1 * cl2 * cdelta
    var ad = atan2(y,x)
    var dist = ad * R
    return dist


func remove_closest_dot(screen_pos):
    var closest_dot = null
    var closest_l = null
    var closest_distance = INF
    for dot in _dots:
        var dot_screen_pos = world_to_screen(dot.position.x, dot.position.y)
        var distance = dot_screen_pos.distance_to(screen_pos)
        if distance < closest_distance:
            closest_distance = distance
            closest_dot = dot
    if closest_dot:
        remove_child(closest_dot.mark)
        closest_dot.mark.queue_free()
        _dots.erase(closest_dot)
        
        
func _on_dotsloc_pressed():
    var x = float($dotsx.text)
    var y = float($dotsy.text)
    var world_coords = lonlat_to_world(x, y)
    var sc_screen = world_to_screen(world_coords.x, world_coords.y)
    var mark: Control = get(scene_name).instantiate()
    mark.set_global_position(sc_screen)
    mark.position = world_coords
    var new_d = {
        'position': world_coords,
        'mark': mark,
        'scene_name': scene_name
                }
    _dots.append(new_d)
    add_child(mark)
    _on_remove_dot_pressed()
        

func _on_remove_dot_pressed():
    var cs = $ScrollContainer2/GridContainer.get_children()
    for c in cs:
        $ScrollContainer2/GridContainer.remove_child(c)
        c.queue_free()
    var marks = []
    for index in range(_dots.size()):
        var dot = _dots[index]
        var lonlat_coords = world_to_lonlat(dot.position.x, dot.position.y)
        var nul = Label.new()
        nul.text = "  "
        $ScrollContainer2/GridContainer.add_child(nul)
        var mark: Control = get(dot.scene_name).instantiate()
        mark.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
        $ScrollContainer2/GridContainer.add_child(mark)
        marks.append(mark)
        var point_label = Label.new()
        point_label.text = "  Метка " + str(index + 1) + ": (" + str(decimal(lonlat_coords.y, 2)) + ", " + str(decimal(lonlat_coords.x, 2)) + ")"
        point_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
        $ScrollContainer2/GridContainer.add_child(point_label)
          
          
func get_scale_bar_length_meters(zoom):
    return 100 * zoom


func get_zoom_level():
    return _xyz.z


func _on_taggled_mouse_entered():
    taggled_entered = true


func _on_taggled_mouse_exited():
    taggled_entered = false


func _draw_map(rect:Rect2, map_index:int):
    var tile_size = Vector2(256, 256)
    var tile_count = Vector2(rect.size.x / tile_size.x, rect.size.y/tile_size.y)
    for x in range(tile_count.x):
        for y in range(tile_count.y):
            var tile_pos = Vector2(rect.position.x + x * tile_size.x, rect.position.y + y * tile_size.y)
            var tile = get_tile(map_index, x, y)
            if tile:
                if tile.texture:
                    draw_texture_rect(tile.texture, Rect2(tile_pos, tile_size), false, Color.WHITE, false)
                else:
                    var zzz = 1
                    var txx = x
                    var tyy = y
                    while zzz > 1:
                        zzz -= 1
                        txx = floor(txx/2)
                        tyy = floor(tyy/2)
                        if _draw_subtile(txx, tyy, zzz, map_index, x, y):
                            break
      
    
func is_dot_visible(dot):
    var screen_pos = world_to_screen(dot.position.x, dot.position.y)
    return screen_pos.x > 0 and screen_pos.x < size.x


func get_new_dot_position(dot):
    # Возвращает новую позицию для точки, если она выходит из поля видимости
    var new_x = dot.position.x
    var new_y = dot.position.y
    # Если точка выходит из поля видимости по x
    if dot.position.x < _xyz.x - size.x / (2 * TILE_WIDTH * pow(2, _xyz.z)):
        new_x = _xyz.x - size.x / (2 * TILE_WIDTH * pow(2, _xyz.z))
    elif dot.position.x > _xyz.x + size.x / (2 * TILE_WIDTH * pow(2, _xyz.z)):
        new_x = _xyz.x + size.x / (2 * TILE_WIDTH * pow(2, _xyz.z))
    return Vector2(new_x, new_y)
    
    
func save_tile(x: int, y: int, zoom: int, body):
    var dir = DirAccess.open("user://")
    dir.make_dir("tiles")
    var tile_n = tile_name(x, y, zoom)
    var file_path = "user://tiles/" + tile_n
    var file_access = FileAccess.open(file_path, FileAccess.WRITE)
    file_access.store_buffer(body)
    file_access.close()


func load_tiles():
    var dir_path = "user://tiles/"
    var dir_root = DirAccess.open("user://")
    if not dir_root:
        print("Не удалось открыть user://")
        return
    if not dir_root.dir_exists("tiles"):
        dir_root.make_dir_recursive("tiles")
    var dir = DirAccess.open(dir_path)
    if not dir:
        print("Не удалось открыть папку tiles")
        return
    var files = dir.get_files()
    for file in files:
        var tile_coords = quadkey_to_tile(file.get_basename())
        var file_access = FileAccess.open("user://tiles/" + file, FileAccess.READ)
        var l = file_access.get_length()
        var body = file_access.get_buffer(l)
        var image = Image.new()
        var error = image.load_png_from_buffer(body)
        if error == OK:
            var texture = ImageTexture.create_from_image(image)
            var idx = xyz_to_idx(tile_coords.x, tile_coords.y, tile_coords.z)
            var tile = Tile.new(idx, tile_coords.x, tile_coords.y, tile_coords.z)
            tile.texture = texture
            _cache[tile.i] = tile
        file_access.close()
 

func save_dots():
    var data = []
    for dot in _dots:
        data.append({"position": {"x": dot.position.x, "y": dot.position.y}, "mark_position": dot.mark.position, "scene_name": dot.scene_name})
    var file = FileAccess.open("user://dots.json", FileAccess.WRITE)
    file.store_string(JSON.stringify(data))
    file.close()
    
    
func load_dots():
    var file = FileAccess.open("user://dots.json", FileAccess.READ)
    if file!= null and file.is_open():
        var data = JSON.parse_string(file.get_as_text())
        for dot in data:
            var new_dot = {
                'position': Vector2(dot.position.x, dot.position.y),
            }
            var pckd_scene_name = dot.scene_name if dot.has('scene_name') else 'Mark'
            if pckd_scene_name == '':
                pckd_scene_name = 'Mark'
            var pckd_scene = get(pckd_scene_name)
            new_dot.mark = pckd_scene.instantiate()
            new_dot["scene_name"] = pckd_scene_name
            add_child(new_dot.mark)
            _dots.append(new_dot)
            _on_remove_dot_pressed()
        file.close()
    else:
        print("No dots file found")
        
        
func _notification(what):
    if what == NOTIFICATION_WM_CLOSE_REQUEST:
        save_dots()
        
        
func decimal(number: float, decimal_plases: int) -> float:
    var mut = pow(10, decimal_plases)
    return floor(number * mut)/mut
    
    
func _on_x_input_text_changed(new_text: String) -> void:
    if $x_input.text.length() == 2:
        $x_input.text += '.'
        $x_input.max_length = 5
    $x_input.caret_column = $x_input.text.length()


func _on_y_input_text_changed(new_text: String) -> void:
    if $y_input.text.length() == 2:
        $y_input.text += '.'
        $y_input.max_length = 5
    $y_input.caret_column = $y_input.text.length()


func _on_dotsx_text_changed(new_text: String) -> void:
    if $dotsx.text.length() == 2:
        $dotsx.text += '.'
        $dotsx.max_length = 5
    $dotsx.caret_column = $dotsx.text.length()
    
    
func _on_dotsy_text_changed(new_text: String) -> void:
    if $dotsy.text.length() == 2:
        $dotsy.text += '.'
        $dotsy.max_length = 5
    $dotsy.caret_column = $dotsy.text.length()


func _on_star_pressed() -> void:
    scene_name = "Scene1"
    
    
func _on_point_pressed() -> void:
    scene_name = "Mark"


func _on_plane_pressed() -> void:
    scene_name = "Scene2"

package main

import "core:fmt"
import "core:strings"

import "core:math"
import "core:math/linalg"

import "base:runtime"
import "core:reflect"
import "core:mem/virtual"
import "core:mem"

import rl "vendor:raylib"
import "rulti"

Color   :: [4]  u8
Vector  :: [2] f32
Texture :: rl.Texture
Camera  :: rl.Camera2D
Font    :: rl.Font

Origin :: enum { TOP, CENTER, BOTTOM, }

Pane :: struct {
    pos     : Vector,
    size    : Vector,
    scroll  : rulti.Scroll
}

window : struct {
    exists  : bool,
    size    : Vector,
    unit    : f32,
    frame   : int,
    camera  : Camera,
    cam_vel : Vector,
    mouse   : Vector,
    refresh : bool,

    font    : Font,

    alloc     : Allocator,
    tmp_alloc : Allocator,
    lhs_alloc : Allocator,
    rhs_alloc : Allocator,

    lhs : struct { 
        using _      : Pane,
        names        : [dynamic] string,
        types        : [dynamic] string,
        small_values : [dynamic] string,

        cursor : int,
        viewed : any,
        parents      : [dynamic] any,
        parent_names : [dynamic] string,

    },
    rhs : struct {
        using _: Pane,
        // viewed : reflect.Struct_Field,
        viewed : struct {
            name   : string,
            type   : string,
            value  : any,
        },

        name   : string,
        type   : string,
        value  : string,
        binary : string,

        value_scroll  : rulti.Scroll,
        binary_scroll : rulti.Scroll,
    },

    small_value_limit : int,

}

FONT_SIZE  :: 15
TARGET_FPS :: 60

start_rendering :: proc() {
    window = { size = { 1280, 720 } }

    rl.SetConfigFlags({ .WINDOW_RESIZABLE })
    rl.SetTraceLogLevel(.ERROR)
    rl.InitWindow(i32(window.size.x), i32(window.size.y), "Frigg")
    rl.SetTargetFPS(TARGET_FPS)

    window.font      = rulti.LoadFontFromMemory(#load("font.ttf"), FONT_SIZE)
    window.exists    = true
    window.alloc     = make_arena()
    window.tmp_alloc = make_arena()
    window.lhs_alloc = make_arena()
    window.rhs_alloc = make_arena()
    window.camera.zoom = 1
    window.lhs.cursor  = 1

    rulti.DEFAULT_TEXT_OPTIONS.font = window.font
    rulti.DEFAULT_TEXT_OPTIONS.camera = &window.camera
    rulti.DEFAULT_TEXT_OPTIONS.spacing = 1
    rulti.DEFAULT_TEXT_OPTIONS.size = FONT_SIZE
    rulti.DEFAULT_TEXT_OPTIONS.color = rl.WHITE
    rulti.DEFAULT_TEXT_OPTIONS.center_x = false
    rulti.DEFAULT_TEXT_OPTIONS.center_y = false
    rulti.DEFAULT_TEXT_OPTIONS.line_spacing = 0

    rulti.DEFAULT_UI_OPTIONS.scroll.width = 15
    rulti.DEFAULT_UI_OPTIONS.scroll.track_bg = { 40, 40, 40, 255 } 
    rulti.DEFAULT_UI_OPTIONS.scroll.thumb_bg = { 103, 112, 106, 255 } 

    test.a[.B] = 4
    test.b = 4
    test.d = "str"

    test.e["012345678901234356789__test"] = 3.14159
    test.e["012345678901234356789__test2"] = 3.14159 * 2
    test.e["012345678901234356789__test3"] = 3.14159 * 3
    test.e["012345678901234356789__test4"] = 3.14159 * 3
    test.e["012345678901234356789__test5"] = 3.14159 * 3
    test.e["012345678901234356789__test6"] = 3.14159 * 3
    test.e["012345678901234356789__test7"] = 3.14159 * 3
    test.e["012345678901234356789__test8"] = 3.14159 * 3
    test.e["012345678901234356789__test9"] = 3.14159 * 3
    test.e["012345678901234356789__test10"] = 3.14159 * 3
    test.e["012345678901234356789__test11"] = 3.14159 * 3
    test.e["012345678901234356789__test12"] = 3.14159 * 3
    test.e["012345678901234356789__test13"] = 3.14159 * 3
    test.e["012345678901234356789__test14"] = 3.14159 * 3
    test.e["012345678901234356789__A_test"] = 3.14159
    test.e["012345678901234356789__A_test2"] = 3.14159 * 2
    test.e["012345678901234356789__A_test3"] = 3.14159 * 3
    test.e["012345678901234356789__A_test4"] = 3.14159 * 3
    test.e["012345678901234356789__A_test5"] = 3.14159 * 3
    test.e["012345678901234356789__A_test6"] = 3.14159 * 3
    test.e["012345678901234356789__A_test7"] = 3.14159 * 3
    test.e["012345678901234356789__A_test8"] = 3.14159 * 3
    test.e["012345678901234356789__A_test9"] = 3.14159 * 3
    test.e["012345678901234356789__A_test10"] = 3.14159 * 3
    test.e["012345678901234356789__A_test11"] = 3.14159 * 3
    test.e["012345678901234356789__A_test12"] = 3.14159 * 3
    test.e["012345678901234356789__A_test13"] = 3.14159 * 3
    test.e["012345678901234356789__A_test14"] = 3.14159 * 3
    test.f = 42
    test.g = "str2"
    test.c = {
        1, 12, 123,
        41, 9, 12312412,
        -152, 23, 2
    }
    // test.h = (^int)(uintptr(0x1234))
    test.h = &test.f
    test.i = "c_string"
    watch(window)

    prev_hash: u32

    for !rl.WindowShouldClose() {
        frame_start := now()
        window.size = { f32(rl.GetRenderWidth()), f32(rl.GetRenderHeight()) }
        window.mouse = rl.GetMousePosition()

        the_hash := hash(window.lhs.viewed)
        if prev_hash != the_hash do window.refresh = true
        prev_hash = the_hash

        window.lhs.cursor += int( key(.DOWN) || (!shift() && key(.TAB)) )
        window.lhs.cursor -= int( key(.UP)   || (shift() && key(.TAB))  )
        if window.lhs.cursor >= len(window.lhs.names) { window.lhs.cursor = 1 }
        if window.lhs.cursor < 1 { window.lhs.cursor = len(window.lhs.names) - 1 }

        if key(.ENTER) {
            append(&window.lhs.parents, window.lhs.viewed)
            append(&window.lhs.parent_names, window.rhs.viewed.name)
            watch(reflect.struct_field_value(window.lhs.viewed, reflect.struct_field_at(window.lhs.viewed.id, window.lhs.cursor - 1)))
        }
        if key(.BACKSPACE) && len(window.lhs.parents) > 0 {
            window.lhs.viewed = pop(&window.lhs.parents)
            pop(&window.lhs.parent_names)
            watch(window.lhs.viewed)
        }

        half_pos  : Vector = { 1.0/2, 0 } if window.size.x > window.size.y else { 0, 1.0/2 }
        half_size : Vector = { 1.0/2, 1 } if window.size.x > window.size.y else { 1, 1.0/2 }

        window.lhs.pos  = { }
        window.lhs.size = window.size * half_size
        window.rhs.pos  = window.size * half_pos
        window.rhs.size = window.size * half_size

        window.small_value_limit = int( window.size.x * half_size.x / measure_text(" ").x / 4 )

        rl.BeginDrawing()

        rl.ClearBackground({ 0, 0, 0, 255 })

        draw_lhs_pane()
        draw_rhs_pane()

        frame_took := diff(frame_start, now())
        rl.DrawTextEx(window.font, 
            fmt.caprint("frame took:", frame_took, allocator = window.tmp_alloc), 
            { 8, window.size.y - FONT_SIZE - 8 }, FONT_SIZE, 1, rl.GRAY)

        if window.refresh {
            update_lhs()
            update_rhs()
        }


        rl.EndDrawing()
        free_all(window.tmp_alloc)
        window.frame += 1
    }
}

stop_renderer :: proc() {
    if !window.exists do return
    window.exists = false
    free_all(window.alloc)
    rl.CloseWindow()
}

key :: proc(key: rl.KeyboardKey) -> bool { return rl.IsKeyPressed(key) || rl.IsKeyPressedRepeat(key) }
shift :: proc() -> bool { return rl.IsKeyDown(.LEFT_SHIFT) }

draw_lhs_pane :: proc() {
    base_pos := window.lhs.pos - window.lhs.scroll.pos

    offsets: [4] f32
    for name in window.lhs.names { offsets[1] = max(offsets[1], rulti.MeasureTextLine(name).x) }
    for type in window.lhs.types { offsets[2] = max(offsets[2], rulti.MeasureTextLine(type).x) }
    for sval in window.lhs.small_values { offsets[3] = max(offsets[3], rulti.MeasureTextLine(sval).x) }

    LINE_HEIGHT := rulti.MeasureRune(' ', {}).y

    window.lhs.scroll.max = { offsets.y + offsets.z + offsets.w, f32(len(window.lhs.names)) * LINE_HEIGHT }

    rl.BeginScissorMode(i32(window.lhs.pos.x), i32(window.lhs.pos.y), i32(window.lhs.size.x), i32(window.lhs.size.y))
    defer rl.EndScissorMode()

    {   i := window.lhs.cursor
        y := window.lhs.pos.y - window.lhs.scroll.pos.y
        w := window.lhs.size.x
        rl.DrawRectangleV({ 8, y + LINE_HEIGHT*f32(i) }, { w - 16, FONT_SIZE-1 }, { 48, 48, 32, 255 })
    }
    
    offset := offsets[0]
    for name, i in window.lhs.names {
        pos := window.lhs.pos + { offset, f32(i) * LINE_HEIGHT } + base_pos
        if i != 0 do pos.x += 16
        rulti.DrawTextBasic(name, pos)
    }
    offset += 16

    offset += offsets[1] + 16
    for type, i in window.lhs.types {
        pos := window.lhs.pos + { offset, f32(i) * LINE_HEIGHT } + base_pos
        rulti.DrawTextBasic(type, pos)
    }

    offset += offsets[2] + 16
    for value, i in window.lhs.small_values {
        pos := window.lhs.pos + { offset, f32(i) * LINE_HEIGHT } + base_pos
        rulti.DrawTextBasic(value, pos)
    }

    rulti.DrawScrollbar(&window.lhs.scroll, window.lhs.pos, window.lhs.size)

}

draw_rhs_pane :: proc() {
    base_pos := window.rhs.pos + window.rhs.scroll.pos
    
    base_pos.y += rulti.DrawTextBasic(window.rhs.name, base_pos).y
    base_pos.y += rulti.DrawTextBasic(window.rhs.type, base_pos).y * 2

    size := draw_text_wrapped_rhs(string(window.rhs.value), base_pos)
    rulti.DrawScrollbar(&window.rhs.value_scroll, base_pos, { window.rhs.size.x, size.y })

    size.x *= 0
    size.y += FONT_SIZE + rulti.DEFAULT_TEXT_OPTIONS.line_spacing
    base_pos += size
    
    size = draw_text_wrapped_binary(string(window.rhs.binary), base_pos)
    min_size := Vector { window.rhs.size.x, min(size.y, window.rhs.size.y - (base_pos.y - window.rhs.pos.y)) }
    window.rhs.binary_scroll.max = { 0, size.y }
    rulti.DrawScrollbar(&window.rhs.binary_scroll, base_pos, min_size)
}

watch :: proc(value: any, caller_expression := #caller_expression(value)) {// {{{
    if len(window.lhs.parent_names) == 0 { 
        append(&window.lhs.parent_names, caller_expression) 
    } 

    window.lhs.viewed = value
    update_lhs()
    
}// }}}

@private
update_lhs :: proc() {// {{{
    if window.frame % (TARGET_FPS / 6) != 0 do return
    lhs_clear()
    free_all(window.lhs_alloc)
    value := window.lhs.viewed
    lhs_add(window.lhs.parent_names[len(window.lhs.parent_names) - 1], "", "", window.lhs_alloc)

    the_type := reflect.type_info_base(type_info_of(value.id))
    #partial switch real_type in the_type.variant {
    case reflect.Type_Info_Struct:
        for field, i in reflect.struct_fields_zipped(value.id) {
            name := fmt.aprint(field.name, allocator = window.alloc)
            type := soft_up_to(fmt.aprint(field.type, allocator = window.alloc), 24)
            data := format_value_small(to_any(ptr_add(value.data, field.offset), field.type.id))
            lhs_add(name, type, data, window.lhs_alloc)

            if i + 1 == window.lhs.cursor { 
                window.rhs.viewed = {
                    name = strings.clone(field.name, window.alloc),
                    type = soft_up_to(fmt.aprint(field.type, allocator = window.alloc), 24),
                    value = to_any(ptr_add(value.data, field.offset), field.type.id) 
                }
            }
        }

    case reflect.Type_Info_Slice, reflect.Type_Info_Array, reflect.Type_Info_Dynamic_Array:
        iterator: int
        for elem, i in iterate_array(value, &iterator) {
            name  := fmt.aprint(i, allocator = window.tmp_alloc)
            value := format_value_small(elem)
            lhs_add(name, "", value, window.lhs_alloc)

            if i + 1 == window.lhs.cursor { 
                window.rhs.viewed = {
                    name = name,
                    type = soft_up_to(fmt.aprint(elem.id, allocator = window.lhs_alloc), 24),
                    value = elem,   
                }
            }
        }



    case: fmt.println("bad value for visualization for now:", value)
    }
}// }}}

update_rhs :: proc() {
    if window.frame % (TARGET_FPS / 6) != 0 do return
    free_all(window.rhs_alloc)

    cursor := window.lhs.cursor
    field  := window.rhs.viewed
    value  := field.value

    window.rhs.name = strings.clone(field.name, window.rhs_alloc)
    window.rhs.type = strings.clone(field.type, window.rhs_alloc)
    window.rhs.value = strings.clone(format_value_big(value), window.rhs_alloc)
    window.rhs.binary = strings.clone(format_value_binary(value), window.rhs_alloc)   

}

soft_up_to :: proc(str: string, max_len: int) -> string {
    if len(str) <= max_len do return str

    curly := strings.last_index(str[:max_len], "{")
    if curly != -1 do return str[:curly]

    space := strings.last_index(str[:max_len], " ")
    if space == -1 do return str[:max_len]

    return str[:space]
}

ptr_add :: proc(a: rawptr, b: uintptr) -> rawptr {// {{{
    return rawptr(uintptr(a) + b)
}// }}}

to_any :: proc(ptr: rawptr, type: typeid) -> any {// {{{
    return transmute(any) runtime.Raw_Any { data = ptr, id = type }
}// }}}
// TODO
measure_text_str :: proc(text: string) -> Vector {// {{{
    size := rl.MeasureTextEx(window.font, " ", FONT_SIZE, 1)
    return size * { f32(len(text)) + 2, 0 }
}// }}}

measure_text :: proc(text: cstring) -> Vector {// {{{
    return rl.MeasureTextEx(window.font, text, FONT_SIZE, 1)
}// }}}

draw_text :: proc(text: cstring, pos: Vector) {// {{{
    rl.DrawTextEx(window.font, text, pos, FONT_SIZE, 1, rl.WHITE)
}// }}}

draw_text_wrapped_rhs :: proc(text: string, pos: Vector) -> (size: Vector) {
    max_size := window.rhs.size * { 1, 0.33333 }
    rl.BeginScissorMode(i32(pos.x), i32(pos.y), i32(max_size.x), i32(max_size.y))
    size = rulti.DrawTextWrapped(text, pos - window.rhs.value_scroll.pos, window.rhs.size)
    window.rhs.value_scroll.max = { 0, size.y }
    rl.EndScissorMode()
    return max_size
}


draw_text_wrapped_binary :: proc(text: string, pos: Vector) -> (size: Vector) {
    text := strings.trim_right(text, " \n")
    original_pos := pos
    pos := pos

    opts := rulti.DEFAULT_TEXT_OPTIONS

    length := int( window.rhs.size.x / measure_text(" ").x / 2 / 3 )
    length -= min(int(length) % 8, 64)

    // you won't believe how I got it!   for i in 0..<64 { fmt.printf("%02X ", i) }; fmt.println()
    @static xlabel := "   00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F 10 11 12 13 14 15 16 17 18 19 1A 1B 1C 1D 1E 1F 20 21 22 23 24 25 26 27 28 29 2A 2B 2C 2D 2E 2F 30 31 32 33 34 35 36 37 38 39 3A 3B 3C 3D 3E 3F"
    @static ylabel := "00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F 10 11 12 13 14 15 16 17 18 19 1A 1B 1C 1D 1E 1F 20 21 22 23 24 25 26 27 28 29 2A 2B 2C 2D 2E 2F 30 31 32 33 34 35 36 37 38 39 3A 3B 3C 3D 3E 3F"
    opts.color = rl.PINK

    offset := rulti.DrawTextBasic(xlabel[:3*length+3], pos, opts)
    pos.y += offset.y

    opts.color = rl.WHITE

    rl.BeginScissorMode(i32(pos.x), i32(pos.y), i32(window.rhs.size.x), i32(window.rhs.size.y))
    defer rl.EndScissorMode()
    pos -= window.rhs.binary_scroll.pos
    for i in 0..<2048 {

        opts.color = rl.PINK
        offset := rulti.DrawTextBasic(fmt.aprintf("%02X ", i), pos, opts)
        pos.x += offset.x
        defer pos.x -= offset.x
        opts.color = rl.WHITE

        if len(text) > 3*length {
            offset := rulti.DrawTextBasic(text[:3*length], pos, opts)
            pos.y += offset.y
            text = text[3*length:]
            if len(text) == 0 do return pos - original_pos
        } else {
            offset := rulti.DrawTextBasic(text, pos, opts)
            pos.y += offset.y
            return pos - original_pos
        }
    }
    return {}
}




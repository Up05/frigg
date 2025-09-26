package main

import "core:fmt"
import "core:strings"

import "core:math"
import "core:math/linalg"

import "base:runtime"
import "core:reflect"
import "core:mem/virtual"
import "core:mem"

import     "vendor:glfw"
import  gl "vendor:OpenGL"
import nvg "vendor:nanovg"
import ngl "vendor:nanovg/gl"

Color   :: [4]  u8
Vector  :: [2] f32

WHITE : Color : { 255, 255, 255, 255 }

RendererKind :: enum {
    NEW_WINDOW,
    AUTO_DRAWING,
    MANUAL,
    NETWORK,
}

Origin :: enum { TOP, CENTER, BOTTOM, }

Scroll :: struct {
    min, max, pos: Vector
}

Pane :: struct {
    pos     : Vector,
    size    : Vector,
    scroll  : Scroll,
}

Window :: struct {
    using options : struct {
        kind  : RendererKind,
        pos   : Vector,
        size  : Vector,
    },

    handle    : glfw.WindowHandle,
    ctx       : ^nvg.Context,

    resizable : bool,
    inited    : bool,
    exists    : bool,
    unit      : f32,
    frame     : int,
    mouse     : Vector,
    refresh   : bool,

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
        viewed : struct {
            name   : string,
            type   : string,
            value  : any,
        },

        name   : string,
        type   : string,
        value  : string,
        binary : string,

        value_scroll  : Scroll,
        binary_scroll : Scroll,
    },

    using palette : struct {
        bg  : [4] f32, // background rgba
        hl  : [4] f32, // highlight  rgba
        fg  : [4] f32, // foreground rgba
        bin : [4] f32, // binary hex rgba
    },

    small_value_limit : int,
    previous_hash     : u32,
}

events : struct {
    using single_frame : struct {
        pressed  : [64] i32,
        released : [64] i32, 
        num_pressed   : int,
        num_released  : int,
        active_window : glfw.WindowHandle,
    },

    down : [64] i32,
    num_down  : int,
}

// window: Window
windows: [dynamic] ^Window

FONT_SIZE  :: 15
TARGET_FPS :: 60

glfw_initialized: bool

initialize_window :: proc(window: ^Window) {// {{{
    defer window.inited = true
    window.size = { 640, 400 }

    if !glfw_initialized {
        assert( bool(glfw.Init()) )
        glfw_initialized = true
    }
    
    { // GLFW window {{{
        glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
        glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
        glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, 1)
        glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
        glfw.WindowHint(glfw.OPENGL_DEBUG_CONTEXT, 1)
        glfw.WindowHint(glfw.SAMPLES, 4)

        window.handle = glfw.CreateWindow(i32(window.size.x), i32(window.size.y), "frigg", nil, nil)
        assert(window.handle != nil)

        glfw.MakeContextCurrent(window.handle)
        gl.load_up_to(4, 5, glfw.gl_set_proc_address) 
        gl.Enable(gl.MULTISAMPLE)
        
        gl.Enable(gl.BLEND)
        gl.BlendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA)

        glfw.SetKeyCallback(window.handle, key_callback)
    } // }}}

    { // nanovg context {{{
        window.ctx = ngl.Create({ .ANTI_ALIAS, .STENCIL_STROKES })

        glfw.SetTime(0)
        prevt := glfw.GetTime()

        fw, fh := glfw.GetFramebufferSize(window.handle)
        w, h := glfw.GetWindowSize(window.handle)
        px_ratio := f32(fw) / f32(w)
        fb := ngl.CreateFramebuffer(
            window.ctx,
            int(100 * px_ratio),
            int(100 * px_ratio),
            { .REPEAT_X, .REPEAT_Y },
        )


    }// }}}

    nvg.CreateFont(window.ctx, "mono", "font.ttf")
    // TODO CreateFontMem
    nvg.FontSize(window.ctx, FONT_SIZE)

    window.exists    = true
    window.alloc     = make_arena()
    window.tmp_alloc = make_arena()
    window.lhs_alloc = make_arena()
    window.rhs_alloc = make_arena()
    window.lhs.cursor  = 1

    make_color_palette(window)

    // rulti.DEFAULT_UI_OPTIONS.scroll.width = 15
    // rulti.DEFAULT_UI_OPTIONS.scroll.track_bg = { 40, 40, 40, 255 } 
    // rulti.DEFAULT_UI_OPTIONS.scroll.thumb_bg = { 103, 112, 106, 255 } 
}// }}}

render_frame_for_all :: proc(take_time_off_for_ms : Duration = 33) -> (no_more_windows: bool) {// {{{
    if len(windows) == 0 do return true 

    frame_start := now()
    no_more_windows = true
    for window in windows {
        render_frame(window)

        if glfw.WindowShouldClose(window.handle) {
            exit_window(window)
        } else do no_more_windows = false
    }

    events.single_frame = {}
    glfw.WaitEventsTimeout(1)

    sleep_for := take_time_off_for_ms * ms - diff(frame_start, now())
    sleep_for  = min(max(sleep_for, 0), take_time_off_for_ms * ms)
    sleep(sleep_for) // wayland :)

    return
}// }}}

render_frame :: proc(window: ^Window) {// {{{
    if !window.inited { initialize_window(window) }

    frame_start := now()

    { // beginning frame
        glfw.MakeContextCurrent(window.handle)
        fw, fh := glfw.GetFramebufferSize(window.handle)
        w, h := glfw.GetWindowSize(window.handle)
        px_ratio := f32(fw) / f32(w)

        gl.Viewport(0, 0, fw, fh)
        gl.ClearColor(window.bg.r, window.bg.g, window.bg.b, window.bg.a)
        gl.Clear(gl.COLOR_BUFFER_BIT | gl.STENCIL_BUFFER_BIT)
        nvg.BeginFrame(window.ctx, f32(w), f32(h), px_ratio)
        window.size = { f32(fw), f32(fh) }
    }

    mx, my := glfw.GetCursorPos(window.handle)
    window.mouse = { f32(mx), f32(my) }

    half_pos  : Vector = { 1.0/2, 0 } if window.size.x > window.size.y else { 0, 1.0/2 }
    half_size : Vector = { 1.0/2, 1 } if window.size.x > window.size.y else { 1, 1.0/2 }

    window.lhs.pos  = { }
    window.lhs.size = window.size * half_size
    window.rhs.pos  = window.size * half_pos
    window.rhs.size = window.size * half_size

    window.small_value_limit = int( window.size.x * half_size.x / text_width(window, " ") / 4 )

    draw_lhs_pane(window)
    draw_rhs_pane(window)

    frame_took := diff(frame_start, now())
    draw_text(window, fmt.aprint("frame took:", frame_took, allocator = window.tmp_alloc), { 8, window.size.y - FONT_SIZE - 8 }, window.fg )

    if window.refresh {
        update_lhs(window)
        update_rhs(window)
    }

    nvg.EndFrame(window.ctx)
    glfw.SwapBuffers(window.handle)

    free_all(window.tmp_alloc)
    window.frame += 1
}// }}}

exit_window :: proc(window: ^Window) {// {{{
    if !window.exists do return
    window.exists = false
    free_all(window.alloc)
    glfw.DestroyWindow(window.handle)

    window_index := find(windows[:], window)
    if window_index != -1 do unordered_remove(&windows, window_index)
}// }}}

draw_lhs_pane :: proc(window: ^Window) {// {{{
    the_hash := hash(window.lhs.viewed, { window = window })
    if window.previous_hash != the_hash do window.refresh = true
    window.previous_hash = the_hash

    if window.handle == events.active_window {
        key :: is_key_pressed
        shift :: proc() -> bool { return is_key_down(glfw.KEY_LEFT_SHIFT) }

        window.lhs.cursor += int( key(glfw.KEY_DOWN) || (!shift() && key(glfw.KEY_TAB)) )
        window.lhs.cursor -= int( key(glfw.KEY_UP)   || ( shift() && key(glfw.KEY_TAB)) )

        if window.lhs.cursor >= len(window.lhs.names) { window.lhs.cursor = 1 }
        if window.lhs.cursor < 1 { window.lhs.cursor = len(window.lhs.names) - 1 }

        if key(glfw.KEY_ENTER) {
            if window.lhs.viewed == nil do return
            append(&window.lhs.parents, window.lhs.viewed)
            append(&window.lhs.parent_names, window.rhs.viewed.name)

            field := reflect.struct_field_at(window.lhs.viewed.id, window.lhs.cursor - 1)
            if field.type == nil do return
            watch(reflect.struct_field_value(window.lhs.viewed, field), false)
        }
        if key(glfw.KEY_BACKSPACE) && len(window.lhs.parents) > 0 {
            window.lhs.viewed = pop(&window.lhs.parents)
            pop(&window.lhs.parent_names)
            if window.options.kind == .NEW_WINDOW { exit_window(window) }
        }
    }

    base_pos := window.lhs.pos - window.lhs.scroll.pos

    offsets: [4] f32
    for name in window.lhs.names { offsets[1] = max(offsets[1], text_width(window, name)) }
    for type in window.lhs.types { offsets[2] = max(offsets[2], text_width(window, type)) }
    for sval in window.lhs.small_values { offsets[3] = max(offsets[3], text_width(window, sval)) }

    LINE_HEIGHT : f32 = FONT_SIZE

    window.lhs.scroll.max = { offsets.y + offsets.z + offsets.w, f32(len(window.lhs.names)) * LINE_HEIGHT }

    nvg.Scissor(window.ctx, window.lhs.pos.x, window.lhs.pos.y, window.lhs.size.x, window.lhs.size.y)
    defer nvg.ResetScissor(window.ctx)

    {   i := max(window.lhs.cursor - 1, 0)
        y := window.lhs.pos.y - window.lhs.scroll.pos.y + 2
        w := window.lhs.size.x
        draw_rect(window, { 8, y + LINE_HEIGHT*f32(i) }, { w - 16, FONT_SIZE }, window.palette.hl)
    }
    
    offset := offsets[0]
    for name, i in window.lhs.names {
        pos := window.lhs.pos + { offset, f32(i) * LINE_HEIGHT } + base_pos
        if i != 0 do pos.x += 16
        draw_text(window, name, { pos.x, pos.y }, window.palette.fg)
    }
    offset += 16

    offset += offsets[1] + 16
    for type, i in window.lhs.types {
        pos := window.lhs.pos + { offset, f32(i) * LINE_HEIGHT } + base_pos
        draw_text(window, type, { pos.x, pos.y }, window.fg)
    }

    offset += offsets[2] + 16
    for value, i in window.lhs.small_values {
        pos := window.lhs.pos + { offset, f32(i) * LINE_HEIGHT } + base_pos
        draw_text(window, value, { pos.x, pos.y }, window.fg)
    }

    // rulti.DrawScrollbar(&window.lhs.scroll, window.lhs.pos, window.lhs.size)

}// }}}

draw_rhs_pane :: proc(window: ^Window) {// {{{
    base_pos := window.rhs.pos + window.rhs.scroll.pos
    
    nvg.FillColor(window.ctx, nvg.RGBA(255, 255, 255, 255))
    draw_text(window, window.rhs.name, { base_pos.x, base_pos.y }, window.fg)
    base_pos.y += FONT_SIZE
    draw_text(window, window.rhs.type, { base_pos.x, base_pos.y }, window.fg)
    base_pos.y += FONT_SIZE * 2

    size := draw_text_wrapped_rhs(window, string(window.rhs.value), base_pos)
    // rulti.DrawScrollbar(&window.rhs.value_scroll, base_pos, { window.rhs.size.x, size.y })

    size.x *= 0
    size.y += FONT_SIZE + 1
    base_pos += size
    
    size = draw_text_wrapped_binary(window, string(window.rhs.binary), base_pos)
    min_size := Vector { window.rhs.size.x, min(size.y, window.rhs.size.y - (base_pos.y - window.rhs.pos.y)) }
    window.rhs.binary_scroll.max = { 0, size.y }
    // rulti.DrawScrollbar(&window.rhs.binary_scroll, base_pos, min_size)
}// }}}

watch :: proc(value: any, pause_program: bool, expr := #caller_expression(value)) -> ^Window {// {{{
    window := new(Window)
    append(&windows, window)

    if len(window.lhs.parent_names) == 0 { 
        append(&window.lhs.parent_names, expr) 
    } 

    window.lhs.viewed = value
    update_lhs(window)

    if pause_program {
        for !render_frame_for_all() { }
    }
    
    return window
}// }}}

@private
update_lhs :: proc(window: ^Window) {// {{{
    if window.frame % (TARGET_FPS / 6) != 0 do return
    lhs_clear(window)
    free_all(window.lhs_alloc)
    value := window.lhs.viewed
    lhs_add(window, window.lhs.parent_names[len(window.lhs.parent_names) - 1], "", "", window.lhs_alloc)

    the_type := reflect.type_info_base(type_info_of(value.id))
    #partial switch real_type in the_type.variant {
    case reflect.Type_Info_Struct:
        for field, i in reflect.struct_fields_zipped(value.id) {
            name := fmt.aprint(field.name, allocator = window.alloc)
            type := soft_up_to(fmt.aprint(field.type, allocator = window.alloc), 24)
            data := format_value_small(window, to_any(ptr_add(value.data, field.offset), field.type.id))
            lhs_add(window, name, type, data, window.lhs_alloc)

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
            value := format_value_small(window, elem)
            lhs_add(window, name, "", value, window.lhs_alloc)

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
update_rhs :: proc(window: ^Window) {// {{{
    if window.frame % (TARGET_FPS / 6) != 0 do return
    free_all(window.rhs_alloc)

    cursor := window.lhs.cursor
    field  := window.rhs.viewed
    value  := field.value

    window.rhs.name = strings.clone(field.name, window.rhs_alloc)
    window.rhs.type = strings.clone(field.type, window.rhs_alloc)
    window.rhs.value = strings.clone(format_value_big(window, value), window.rhs_alloc)
    window.rhs.binary = strings.clone(format_value_binary(window, value), window.rhs_alloc)   

}// }}}

soft_up_to :: proc(str: string, max_len: int) -> string {// {{{{{{
    if len(str) <= max_len do return str

    curly := strings.last_index(str[:max_len], "{")
    if curly != -1 do return str[:curly]

    space := strings.last_index(str[:max_len], " ")
    if space == -1 do return str[:max_len]

    return str[:space]
}// }}}}}}
ptr_add :: proc(a: rawptr, b: uintptr) -> rawptr {// {{{
    return rawptr(uintptr(a) + b)
}// }}}
to_any :: proc(ptr: rawptr, type: typeid) -> any {// {{{
    return transmute(any) runtime.Raw_Any { data = ptr, id = type }
}// }}}
draw_text_wrapped_rhs :: proc(window: ^Window, text: string, pos: Vector) -> (size: Vector) {// {{{
    max_size := window.rhs.size * { 1, 0.33333 }
    nvg.Scissor(window.ctx, pos.x, pos.y - FONT_SIZE, max_size.x, max_size.y)
    size = draw_text_wrapped(window, text, pos - window.rhs.value_scroll.pos, max_size, window.palette.fg)
    window.rhs.value_scroll.max = { 0, size.y }
    nvg.ResetScissor(window.ctx)
    return max_size
}// }}}
draw_text_wrapped_binary :: proc(window: ^Window, text: string, pos: Vector) -> (size: Vector) {// {{{
    text := strings.trim_right(text, " \n")
    original_pos := pos
    pos := pos

    length := int( window.rhs.size.x / text_width(window, "_") / 2 / 3 )
    length -= min(int(length) % 8, 64)
    if length == 0 do return

    // you won't believe how I got it!   for i in 0..<64 { fmt.printf("%02X ", i) }; fmt.println()
    @static xlabel := "   00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F 10 11 12 13 14 15 16 17 18 19 1A 1B 1C 1D 1E 1F 20 21 22 23 24 25 26 27 28 29 2A 2B 2C 2D 2E 2F 30 31 32 33 34 35 36 37 38 39 3A 3B 3C 3D 3E 3F"
    @static ylabel := "00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F 10 11 12 13 14 15 16 17 18 19 1A 1B 1C 1D 1E 1F 20 21 22 23 24 25 26 27 28 29 2A 2B 2C 2D 2E 2F 30 31 32 33 34 35 36 37 38 39 3A 3B 3C 3D 3E 3F"

    draw_text(window, xlabel[:3*length+3], { pos.x, pos.y }, window.bin)

    nvg.Scissor(window.ctx, pos.x, pos.y, window.rhs.size.x, window.rhs.size.y)
    defer nvg.ResetScissor(window.ctx)
    pos -= window.rhs.binary_scroll.pos
    for i in 0..<2048 {
        advance_x := draw_text(window, fmt.aprintf("%02X ", i), { pos.x, pos.y }, window.bin) - pos.x
        pos.x += advance_x
        defer pos.x -= advance_x

        if len(text) > 3*length {
            draw_text(window, text[:3*length], { pos.x, pos.y }, window.fg)
            pos.y += FONT_SIZE
            text = text[3*length:]
            if len(text) == 0 do return pos - original_pos
        } else {
            draw_text(window, text, { pos.x, pos.y }, window.fg)
            pos.y += FONT_SIZE
            return pos - original_pos
        }
    }
    return {}
}// }}}

// ==================================== nanovg indirection ====================================

key_callback :: proc "c" (window: glfw.WindowHandle, key: i32, scancode: i32, action: i32, mods: i32) {// {{{

    is_friggs_window: bool
    for a_window in windows {
        if a_window.handle == window {
            is_friggs_window = true
            break
        }
    }
    if !is_friggs_window do return
    events.active_window = window

    if action == glfw.PRESS || action == glfw.REPEAT {
        if !is_key_pressed(key) {
            events.pressed[events.num_pressed] = key
            events.num_pressed += 1
        }

        if !is_key_down(key) && events.num_down < 40 {
            events.down[events.num_down] = key
            events.num_down += 1
        }
    }

    if action == glfw.RELEASE {
        if !is_key_released(key) {
            events.released[events.num_released] = key
            events.num_released += 1
        }

        start_moving: bool
        for i in 0..<events.num_down {
            if start_moving do events.down[i - 1] = events.down[i]
            if events.down[i] == key do start_moving = true
        }
        if start_moving do events.num_down -= 1
    }

}// }}}
draw_rect :: proc(window: ^Window, pos: Vector, size: Vector, color: [4] f32) {// {{{
    nvg.BeginPath(window.ctx)
    nvg.Rect(window.ctx, pos.x, pos.y, size.x, size.y)
    nvg.FillColor(window.ctx, color)
    nvg.Fill(window.ctx)
    nvg.ClosePath(window.ctx)
    nvg.FillColor(window.ctx, { 1, 1, 1, 1 })
}// }}}
draw_text_wrapped :: proc(window: ^Window, text: string, pos: Vector, size: Vector, color: [4] f32) -> Vector {// {{{
    _text := text
    assert(size.y / FONT_SIZE < 128)
    lines: [128] nvg.Text_Row
    line_slice := lines[:]
    line_count, _, _ := nvg.TextBreakLines(window.ctx, &_text, size.x, &line_slice)

    y: f32
    w: f32
    for line in lines[:line_count] {
        w  = max( w,  draw_text(window, text[line.start:line.end], pos + {0, y}, color) )
        y += FONT_SIZE + 1
    }

    return { w, y }
}// }}}
draw_text :: proc(window: ^Window, text: string, pos: Vector, color: [4] f32) -> (width: f32) {// {{{
    nvg.FillColor(window.ctx, color)
    width = nvg.Text(window.ctx, pos.x, pos.y, text)
    nvg.FillColor(window.ctx, { 1, 1, 1, 1 })
    return
}// }}}
text_width :: proc(window: ^Window, text: string) -> f32 {// {{{
    bounds: [4] f32
    return nvg.TextBounds(window.ctx, 0, 0, text, &bounds) - 1
}// }}}

is_key_down     :: proc "c" (key: i32) -> bool { return find(events.down[:events.num_down], key) != -1 }
is_key_pressed  :: proc "c" (key: i32) -> bool { return find(events.pressed[:events.num_pressed], key) != -1 }
is_key_released :: proc "c" (key: i32) -> bool { return find(events.released[:events.num_released], key) != -1 }




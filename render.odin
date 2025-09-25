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

    small_value_limit : int,
    previous_hash     : u32,
}

window: Window

FONT_SIZE  :: 15
TARGET_FPS :: 60

glfw_initialized: bool

initialize_window :: proc(window: ^Window) {
    window.size = { 1280, 720 }

    if !glfw_initialized {
        assert( bool(glfw.Init()) )
        glfw_initialized = true
    }
    
    { // GLFW window
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
        gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
    }

    { // nanovg context
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
    }

    nvg.CreateFont(window.ctx, "main", "font.ttf")
    // TODO CreateFontMem
    nvg.FontSize(window.ctx, FONT_SIZE)

    window.exists    = true
    window.alloc     = make_arena()
    window.tmp_alloc = make_arena()
    window.lhs_alloc = make_arena()
    window.rhs_alloc = make_arena()
    window.lhs.cursor  = 1

    // rulti.DEFAULT_UI_OPTIONS.scroll.width = 15
    // rulti.DEFAULT_UI_OPTIONS.scroll.track_bg = { 40, 40, 40, 255 } 
    // rulti.DEFAULT_UI_OPTIONS.scroll.thumb_bg = { 103, 112, 106, 255 } 
}

start_rendering :: proc(window: ^Window) {
    if window.options.kind == .NEW_WINDOW { initialize_window(window) }

    for !glfw.WindowShouldClose(window.handle) {
        frame_start := now()

        { // beginning frame
            glfw.MakeContextCurrent(window.handle)
            fw, fh := glfw.GetFramebufferSize(window.handle)
            w, h := glfw.GetWindowSize(window.handle)
            px_ratio := f32(fw) / f32(w)

            gl.Viewport(0, 0, fw, fh)
            gl.ClearColor(0, 0, 0, 1.0)
            gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT | gl.STENCIL_BUFFER_BIT)
            nvg.BeginFrame(window.ctx, f32(w), f32(h), 1)
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
        nvg.Text(window.ctx, 8, window.size.y - FONT_SIZE - 8, fmt.aprint("frame took:", frame_took, allocator = window.tmp_alloc))

        if window.refresh {
            update_lhs()
            update_rhs()
        }

        nvg.EndFrame(window.ctx)
        glfw.SwapBuffers(window.handle)
        glfw.WaitEventsTimeout(1)

        free_all(window.tmp_alloc)
        window.frame += 1
    }

    if window.options.kind == .NEW_WINDOW { exit_window(window) }
}

stop_renderer :: proc() {
    if !window.exists do return
    window.exists = false
    free_all(window.alloc)
    glfw.DestroyWindow(window.handle)
}

exit_window :: proc(window: ^Window) {

}

text_width :: proc(window: ^Window, text: string) -> f32 {
    bounds: [4] f32
    return nvg.TextBounds(window.ctx, 0, 0, text, &bounds)
}

// key :: proc(key: rl.KeyboardKey) -> bool { return rl.IsKeyPressed(key) || rl.IsKeyPressedRepeat(key) }
// shift :: proc() -> bool { return rl.IsKeyDown(.LEFT_SHIFT) }

draw_lhs_pane :: proc(window: ^Window) {
    the_hash := hash(window.lhs.viewed)
    if window.previous_hash != the_hash do window.refresh = true
    window.previous_hash = the_hash

    // window.lhs.cursor += int( key(.DOWN) || (!shift() && key(.TAB)) )
    // window.lhs.cursor -= int( key(.UP)   || (shift() && key(.TAB))  )
    if window.lhs.cursor >= len(window.lhs.names) { window.lhs.cursor = 1 }
    if window.lhs.cursor < 1 { window.lhs.cursor = len(window.lhs.names) - 1 }

    // if key(.ENTER) {
    //     if window.lhs.viewed == nil do return
    //     append(&window.lhs.parents, window.lhs.viewed)
    //     append(&window.lhs.parent_names, window.rhs.viewed.name)
    //     new_window := new(Window)
    //     new_window.options = window.options
    //     if window.kind == .NEW_WINDOW do new_window.kind = .AUTO_DRAWING

    //     field := reflect.struct_field_at(window.lhs.viewed.id, window.lhs.cursor - 1)
    //     if field.type == nil do return
    //     watch(reflect.struct_field_value(window.lhs.viewed, field), new_window)
    // }
    // if key(.BACKSPACE) && len(window.lhs.parents) > 0 {
    //     window.lhs.viewed = pop(&window.lhs.parents)
    //     pop(&window.lhs.parent_names)
    //     if window.options.kind == .NEW_WINDOW { exit_window(window) }
    // }

    base_pos := window.lhs.pos - window.lhs.scroll.pos

    offsets: [4] f32
    for name in window.lhs.names { offsets[1] = max(offsets[1], text_width(window, name)) }
    for type in window.lhs.types { offsets[2] = max(offsets[2], text_width(window, type)) }
    for sval in window.lhs.small_values { offsets[3] = max(offsets[3], text_width(window, sval)) }

    LINE_HEIGHT : f32 = FONT_SIZE

    window.lhs.scroll.max = { offsets.y + offsets.z + offsets.w, f32(len(window.lhs.names)) * LINE_HEIGHT }

    nvg.Scissor(window.ctx, window.lhs.pos.x, window.lhs.pos.y, window.lhs.size.x, window.lhs.size.y)
    defer nvg.ResetScissor(window.ctx)

    {   i := window.lhs.cursor
        y := window.lhs.pos.y - window.lhs.scroll.pos.y
        w := window.lhs.size.x
        nvg.FillColor(window.ctx, { 48, 48, 32, 255 })
        nvg.Rect(window.ctx, 8, y + LINE_HEIGHT*f32(i), w - 16, FONT_SIZE-1)
    }
    
    offset := offsets[0]
    for name, i in window.lhs.names {
        pos := window.lhs.pos + { offset, f32(i) * LINE_HEIGHT } + base_pos
        if i != 0 do pos.x += 16
        nvg.Text(window.ctx, pos.x, pos.y, name)
    }
    offset += 16

    offset += offsets[1] + 16
    for type, i in window.lhs.types {
        pos := window.lhs.pos + { offset, f32(i) * LINE_HEIGHT } + base_pos
        nvg.Text(window.ctx, pos.x, pos.y, type)
    }

    offset += offsets[2] + 16
    for value, i in window.lhs.small_values {
        pos := window.lhs.pos + { offset, f32(i) * LINE_HEIGHT } + base_pos
        nvg.Text(window.ctx, pos.x, pos.y, value)
    }

    // rulti.DrawScrollbar(&window.lhs.scroll, window.lhs.pos, window.lhs.size)

}

draw_rhs_pane :: proc(window: ^Window) {
    base_pos := window.rhs.pos + window.rhs.scroll.pos
    
    nvg.Text(window.ctx, base_pos.x, base_pos.y, window.rhs.name)
    base_pos.y += FONT_SIZE
    nvg.Text(window.ctx, base_pos.x, base_pos.y, window.rhs.type)
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
}

watch :: proc(value: any, window: ^Window, expr := #caller_expression(value)) {// {{{
    if len(window.lhs.parent_names) == 0 { 
        append(&window.lhs.parent_names, expr) 
    } 

    window.lhs.viewed = value
    update_lhs()

    opts := window.options
    window.resizable = opts.size == {}
    
    if opts.kind == .NEW_WINDOW || opts.kind == .AUTO_DRAWING {
        start_rendering(window)
    }

    // .MANUAL:
    // .NETWORK:

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

draw_text_wrapped :: proc(ctx: ^nvg.Context, text: string, pos: [2] f32, size: [2] f32) -> [2] f32 {
    _text := text
    assert(size.y / FONT_SIZE < 128)
    lines: [128] nvg.Text_Row
    line_slice := lines[:]
    line_count, _, _ := nvg.TextBreakLines(ctx, &_text, size.x, &line_slice)

    y: f32
    for line in lines[:line_count] {
        nvg.Text(ctx, pos.x, pos.y + y, text[line.start:line.end])
        y += 14 + 1
    }

    return { 0, y }
}


draw_text_wrapped_rhs :: proc(window: ^Window, text: string, pos: Vector) -> (size: Vector) {
    max_size := window.rhs.size * { 1, 0.33333 }
    nvg.Scissor(window.ctx, pos.x, pos.y, max_size.x, max_size.y)
    size = draw_text_wrapped(window.ctx, text, pos - window.rhs.value_scroll.pos, window.rhs.size)
    window.rhs.value_scroll.max = { 0, size.y }
    nvg.ResetScissor(window.ctx)
    return max_size
}


draw_text_wrapped_binary :: proc(window: ^Window, text: string, pos: Vector) -> (size: Vector) {
    text := strings.trim_right(text, " \n")
    original_pos := pos
    pos := pos

    length := int( window.rhs.size.x / text_width(window, " ") / 2 / 3 )
    length -= min(int(length) % 8, 64)

    // you won't believe how I got it!   for i in 0..<64 { fmt.printf("%02X ", i) }; fmt.println()
    @static xlabel := "   00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F 10 11 12 13 14 15 16 17 18 19 1A 1B 1C 1D 1E 1F 20 21 22 23 24 25 26 27 28 29 2A 2B 2C 2D 2E 2F 30 31 32 33 34 35 36 37 38 39 3A 3B 3C 3D 3E 3F"
    @static ylabel := "00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F 10 11 12 13 14 15 16 17 18 19 1A 1B 1C 1D 1E 1F 20 21 22 23 24 25 26 27 28 29 2A 2B 2C 2D 2E 2F 30 31 32 33 34 35 36 37 38 39 3A 3B 3C 3D 3E 3F"

    nvg.FillColor(window.ctx, { 200, 200, 127, 255 })
    nvg.Text(window.ctx, pos.x, pos.y, xlabel[:3*length+3])
    pos.y += FONT_SIZE

    nvg.FillColor(window.ctx, { 255, 255, 255, 255 })

    nvg.Scissor(window.ctx, pos.x, pos.y, window.rhs.size.x, window.rhs.size.y)
    defer nvg.ResetScissor(window.ctx)
    pos -= window.rhs.binary_scroll.pos
    for i in 0..<2048 {
        nvg.FillColor(window.ctx, { 200, 200, 127, 255 })
        advance_x := nvg.Text(window.ctx, pos.x, pos.y, fmt.aprintf("%02X ", i)) - pos.x
        pos.x += FONT_SIZE
        defer pos.x -= advance_x
        nvg.FillColor(window.ctx, { 255, 255, 255, 255 })

        if len(text) > 3*length {
            nvg.Text(window.ctx, pos.x, pos.y, text[:3*length])
            pos.y += FONT_SIZE
            text = text[3*length:]
            if len(text) == 0 do return pos - original_pos
        } else {
            fmt.println(text, 3 * length)
            nvg.Text(window.ctx, pos.x, pos.y, text)
            pos.y += FONT_SIZE
            return pos - original_pos
        }
    }
    return {}
}




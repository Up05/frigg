/*
   frigg package ... TODO
*/
package main

import "core:fmt"
import "core:strings"

import "core:math"
import "core:math/rand"

import "base:intrinsics"
import "base:runtime"
import "core:reflect"
import "core:mem"
import "core:mem/virtual"

import     "vendor:glfw"
import  gl "vendor:OpenGL"
import nvg "vendor:nanovg"
import ngl "vendor:nanovg/gl"

Color   :: [4]  u8
Vector  :: [2] f32

// mousewheel scrolling info (per window, per section)
Scroll :: struct {
    min, max, pos : Vector,
    vel : Vector,
    id  : int,
}

// fancy rl.Rect{}
Pane :: struct {
    pos     : Vector,
    size    : Vector,
    scroll  : Scroll,
    hidden  : bool,
}

// the big boy
Window :: struct {
    handle    : glfw.WindowHandle,
    ctx       : ^nvg.Context,
    size      : Vector,
    mouse     : Vector,

    inited    : bool, // has window itself been initialized
    exists    : bool, // initialize..(): true; exit..(): false
    frame     : int,  // frames since start...
    refresh   : bool, // should refresh lhs & rhs data now

    alloc     : Allocator, // lifetime of the window
    tmp_alloc : Allocator, // lifetime of a single frigg's frame
    lhs_alloc : Allocator, // lifetime of the current lhs
    rhs_alloc : Allocator, // lifetime of the current rhs

    lhs : struct { // left hand side (may be top half)
        using _      : Pane,
        names        : [dynamic] string, // first  column
        types        : [dynamic] string, // second column (sometimes empty)
        small_values : [dynamic] string, // third  column
        real_values  : [dynamic] any,    // memoization

        cursor       : int, // which row is active
        viewed       : any, // one of the real_values (although unrelated in code)
        parents      : [dynamic] any,
        parent_names : [dynamic] string, // 1st parent's name is the #caller_expr of watch()
        parent_cursor: [dynamic] int,    // QoL when backtracing
    },

    rhs : struct { // right hand side (may be bottom half)
        using _: Pane,
        viewed : struct {
            name   : string, // 1st row of rhs
            type   : string, // 2nd row of rhs
            value  : any,    // other rows
        },

        name   : string, // I don't know, I think
        type   : string, // These are just generated
        value  : string, // instead
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

    small_value_limit : int, // when should they get cut off
    previous_hash     : u32, // used for figuring out when to refresh formatted data
}

events : struct {
    using single_frame : struct {
        pressed  : [64] i32, // keys pressed  specifically this frame (or repeated)
        released : [64] i32, // keys released specifically this frame
        num_pressed   : int, // len(pressed)
        num_released  : int, // len(released)
        scroll        : Vector, // mouse wheel / touchpad scroll velocity
        active_window : glfw.WindowHandle, // to others: please check this in event handling
    },

    down : [64] i32, // keys held down this frame
    num_down  : int, // len(down)
}

TARGET_FPS :: 30 // I couldn't be bothered...

options : struct {
    initial_window_size   : Vector,     // ..
    vamos                 : bool,       // Do not wait for events / target fps
    target_fps            : f32,        // Setting this wastes fewer resources
    font_size             : f32,        // ..

    scrollbar_width       : f32,        // > = easier to drag, but distracting
    scroll_speed          : f32,        // Whatever feels good #1
    scroll_speed_maintain : f32,        // Whatever feels good #2,  0..1

    major_glfw_version    : i32,        // Try changing this if missing drivers
    use_extra_glfw_crap   : bool        // I don't think, this does anything...

} = {
    initial_window_size = { 600, 800 },
    vamos = true,
    target_fps = 30,
    font_size = 15,
    
    scrollbar_width = 8,
    scroll_speed = 20,
    scroll_speed_maintain = 0.825,

    major_glfw_version = 4,
}


windows   : [dynamic] ^Window
len_links : map [rawptr] any 
ignored   : [dynamic] u32

/*
The function opens a new window and displays the given value inside of it.

If `pause_program` is `true`, it will render everything fully automatically until all windows are 
closed by the user, then the original program will continue.

If `pause_program` is `false`, the user needs to call `render_frame_for_all()` in some loop.
I imagine, this will often be the main game loop.

Functions such as `link(array, &seperate_length)` and `ignore("field name or list index")` may 
also be used to control what values are shown (or to display multipointers).

Refer to README.md # Keyboard Shortcuts for those.
------------------------------------
*/
watch :: proc(value: any, pause_program: bool, expr := #caller_expression(value)) -> ^Window {// {{{
    if len(windows) > 7 do return nil

    window := new(Window)
    append(&windows, window)

    window.lhs.parents       = make(type_of(window.lhs.parents      ), window.alloc)
    window.lhs.parent_names  = make(type_of(window.lhs.parent_names ), window.alloc)
    window.lhs.parent_cursor = make(type_of(window.lhs.parent_cursor), window.alloc)

    append(&window.lhs.parent_names, expr) 

    window.lhs.viewed = value
    update_lhs(window)

    if pause_program {
        for !render_frame_for_all() { }
    }
    
    return window
}// }}}

/*
This function renders 1 frame of all frigg's windows. 
Use it when all active `watch(...)` calls have `pause_program = false`.

The simplest usage for this function is to just call it as a for condition
```c
for !render_frame_for_all() { test.z[1] += 1 }
```

Also, frigg 
1. ON WAYLAND: uses options.target_fps to slow down itself & the user program.
2. ELSEWHERE:  uses glfw.WaitEventsTimeout(1) to only rerender frames when needed.
if you wish to, instead, f*cking rip it, please set `options.vamos` to `true`

------------------------------------
*/
render_frame_for_all :: proc() -> (no_more_windows: bool) {// {{{
    if len(windows) == 0 do return true 

    @static frame_start: Tick
    for window in windows {
        render_frame(window)

        if glfw.WindowShouldClose(window.handle) {
            exit_window(window)
        } 
    }

    no_more_windows = len(windows) == 0

    events.single_frame = {}
    if options.vamos {
        glfw.PollEvents()

    } else {
        glfw.WaitEventsTimeout(1)

        // wayland :)
        rest_duration := Duration(1000 / options.target_fps) * ms
        sleep_for := rest_duration - diff(frame_start, now())
        sleep_for  = min(max(sleep_for, 0), rest_duration)
        sleep(sleep_for) 
        frame_start = now()
    }
    return
}// }}}

/*
Used to set a custom length for a list and to render the values of a `[^] multi_pointer`. 
linked length arrays are formatted with `[:LINKED_LENGTH]` prefix, as a reminder about hidden info.

You may also use `unlink(same_array)`

*Don't measure dangling pointers... 
You don't know how their length compares to the real deal...*
------------------------------------
*/
link :: proc(array: any, length: ^$NUMBER_TYPE) where intrinsics.type_is_integer(NUMBER_TYPE) {// {{{
    len_links[array.data] = to_any( length, NUMBER_TYPE )
}// }}}

/*
Used to unlink the custom length of a list from that list.
The opposite of `link()`.

careful that it actually gets called.
------------------------------------
*/
unlink :: proc(array: any) {// {{{
    delete_key(&len_links, array.data)
}// }}}

/*
Used to hide struct fields, map entries and list elements
by their name, key or index.

Please specify the exact string. 
Plus, this applies universally for all windows and types, careful:
```c
ignore("test1")
my_struct.test1 = 1; watch(my_struct)
my_map["test1"] = 2; watch(my_map)
```
------------------------------------
*/
ignore :: proc(bad_names: ..string) { // {{{
    for name in bad_names {
        append(&ignored, hash_string(name))
    }
}// }}}



initialize_window :: proc(window: ^Window) {// {{{
    defer window.inited = true
    window.size = options.initial_window_size

    // glfw automatically checks whether it's initialized
    assert( bool(glfw.Init()) )
    
    { // GLFW window {{{
        glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, options.major_glfw_version)
        if options.use_extra_glfw_crap {
            glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, 1)
            glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
            glfw.WindowHint(glfw.OPENGL_DEBUG_CONTEXT, 1)
        }

        window.handle = glfw.CreateWindow(i32(window.size.x), i32(window.size.y), "frigg", nil, nil)
        fmt.assertf(window.handle != nil, "Failed to create Frigg's window. with error: \n%v %v\n\nIt's, probably, the drivers...", glfw.GetError())

        glfw.MakeContextCurrent(window.handle)
        gl.load_up_to(4, 5, glfw.gl_set_proc_address) 
        
        if options.use_extra_glfw_crap {
            gl.Enable(gl.MULTISAMPLE)
            gl.Enable(gl.BLEND)
            gl.BlendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
        }

        glfw.SetKeyCallback(window.handle, key_callback)
        glfw.SetScrollCallback(window.handle, scroll_callback)


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
    nvg.FontSize(window.ctx, options.font_size)

    window.exists    = true
    window.alloc     = make_arena()
    window.tmp_alloc = make_arena()
    window.lhs_alloc = make_arena()
    window.rhs_alloc = make_arena()
    window.lhs.cursor  = 1

    make_color_palette(window)
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
    window.lhs.size = window.size * half_size  if !window.rhs.hidden else  window.size
    window.rhs.pos  = window.size * half_pos   if !window.lhs.hidden else  { }
    window.rhs.size = window.size * half_size  if !window.lhs.hidden else  window.size

    window.small_value_limit = int( window.size.x * half_size.x / text_width(window, " ") / 4 )

    draw_lhs_pane(window)
    draw_rhs_pane(window)

    frame_took := fmt.aprint("frame took:", diff(frame_start, now()), allocator = window.tmp_alloc)
    draw_text(window, frame_took, { window.size.x - text_width(window, frame_took) - 8, 0 }, window.fg )

    the_hash := hash(window.lhs.viewed, { window = window })
    defer window.previous_hash = the_hash

    if window.previous_hash != the_hash || window.refresh {
        update_lhs(window)
        update_rhs(window)
        window.refresh = false
        post_empty_event()
    }

    handle_keyboard(window)

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
    if window.lhs.hidden do return
    base_pos := window.lhs.pos - window.lhs.scroll.pos

    offsets: [4] f32
    for name in window.lhs.names { offsets[1] = max(offsets[1], text_width(window, name)) }
    for type in window.lhs.types { offsets[2] = max(offsets[2], text_width(window, type)) }
    for sval in window.lhs.small_values { offsets[3] = max(offsets[3], text_width(window, sval)) }

    window.lhs.scroll.max = { offsets.y + offsets.z + offsets.w, f32(len(window.lhs.names)) * options.font_size }

    scissor(window, window.lhs.pos, window.lhs.size - { 4, options.font_size*2 })
    defer nvg.ResetScissor(window.ctx)
    defer handle_scrolling(window, &window.lhs.scroll, window.lhs.pos, window.lhs.size)

    { // draw cursor  
        i := window.lhs.cursor // max(i-1,0)+1 = i
        y := window.lhs.pos.y - window.lhs.scroll.pos.y + options.font_size*f32(i)
        w := window.lhs.size.x
        draw_rect(window, { 8, y }, { w - 16, options.font_size }, window.palette.hl)
        
        if window.refresh {
            dist := math.round((y - window.lhs.pos.y) / options.font_size)
            window.lhs.scroll.pos.y += (dist - 15) * options.font_size
            window.lhs.scroll.vel.y  = 0
        }
    }
    
    offset := offsets[0]
    for name, i in window.lhs.names {
        pos := window.lhs.pos + { offset, f32(i) * options.font_size } + base_pos
        draw_text(window, name, pos + { 16*f32(i32(i != 0)), 0 }, window.palette.fg)
    }
    offset += 16

    offset += offsets[1] + 16 
    for type, i in window.lhs.types {
        pos := window.lhs.pos + { offset, f32(i) * options.font_size } + base_pos
        draw_text(window, type, pos, window.fg)
    }

    offset += offsets[2] + 16
    for value, i in window.lhs.small_values {
        pos := window.lhs.pos + { offset, f32(i) * options.font_size } + base_pos
        draw_text(window, value, pos, window.fg)
    }

}// }}}

draw_rhs_pane :: proc(window: ^Window) {// {{{
    if window.rhs.hidden do return
    base_pos := window.rhs.pos + window.rhs.scroll.pos
    offset: Vector
    
    draw_text(window, window.rhs.name, base_pos + offset, window.fg)
    offset.y += options.font_size
    draw_text(window, window.rhs.type, base_pos + offset, window.fg)
    offset.y += options.font_size * 2

    max_size := window.rhs.size * { 1, 0.4 }

    scissor(window, window.rhs.pos + offset, max_size)
    size := draw_text_wrapped_rhs(window, window.rhs.value, base_pos + offset)
    nvg.ResetScissor(window.ctx)
    handle_scrolling(window, &window.rhs.value_scroll, window.rhs.pos + offset, max_size)

    offset += { 0, window.rhs.size.y * 0.4 }
    
    scissor(window, window.rhs.pos + offset, window.rhs.size * { 1, 0.45 })
    size = draw_text_wrapped_binary(window, window.rhs.binary, window.rhs.pos + offset, max_size)
    window.rhs.binary_scroll.max = { 0, size.y }
    nvg.ResetScissor(window.ctx)
    handle_scrolling(window, &window.rhs.binary_scroll, window.rhs.pos + offset, max_size)
}// }}}

@private draw_text_wrapped_rhs :: proc(window: ^Window, text: string, pos: Vector) -> (size: Vector) {// {{{
    max_size := window.rhs.size * { 1, 0.33333 }
    size = draw_text_wrapped(window, text, pos - window.rhs.value_scroll.pos, max_size, window.palette.fg)
    window.rhs.value_scroll.max = { 0, size.y }
    return max_size
}// }}}

@private draw_text_wrapped_binary :: proc(window: ^Window, text: string, pos: Vector, max_size: Vector) -> (size: Vector) {// {{{
    text := strings.trim_right(text, " \n")
    original_pos := pos
    pos := pos - window.rhs.binary_scroll.pos

    length_f32 := math.floor(window.rhs.size.x / text_width(window, "_") / 3.4)
    length_f32  = math.pow(2, math.floor(math.log2(length_f32)))
    length := int(length_f32)

    // you won't believe how I got it!   for i in 0..<64 { fmt.printf("%02X ", i) }; fmt.println()
    @static xlabel := "**** 00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F 10 11 12 13 14 15 16 17 18 19 1A 1B 1C 1D 1E 1F 20 21 22 23 24 25 26 27 28 29 2A 2B 2C 2D 2E 2F 30 31 32 33 34 35 36 37 38 39 3A 3B 3C 3D 3E 3F"

    draw_text(window, xlabel[:min(3*length, len(text))+5], { pos.x, pos.y }, window.bin)
    pos.y += options.font_size

    advance_x := text_width(window, "0000 ") - pos.x
    for i in 0..<2048 {
        should_draw := pos.y > original_pos.y - options.font_size*1
        should_draw &= pos.y < original_pos.y + max_size.y + options.font_size*2

        if should_draw do draw_text(window, fmt.aprintf("%04X ", i*length), { pos.x, pos.y }, window.bin)
        pos.x += advance_x
        defer pos.x -= advance_x

        if len(text) > 3*length {
            // NOTE: actually fully fucking insane, I spent 3 hours on the: pos.x + window.rhs.pos.x
            // like what am I even doing here anymore?..
            if should_draw do draw_text(window, text[:3*length], { pos.x + window.rhs.pos.x, pos.y }, window.fg)
            pos.y += options.font_size
            text = text[3*length:]
            if len(text) == 0 do return pos - original_pos

        } else {
            if should_draw do draw_text(window, text, { pos.x + window.rhs.pos.x, pos.y }, window.fg)
            pos.y += options.font_size
            return pos - original_pos
        }
    }
    return {}
}// }}}

@private handle_keyboard :: proc(window: ^Window) {// {{{
    if window.handle == events.active_window {
        key :: is_key_pressed
        ctrl  :: proc() -> bool { return is_key_down(glfw.KEY_LEFT_CONTROL) }
        shift :: proc() -> bool { return is_key_down(glfw.KEY_LEFT_SHIFT) }

        if (key(glfw.KEY_BACKSPACE) || key(glfw.KEY_LEFT)) && len(window.lhs.parents) > 0 {
            window.lhs.cursor = pop(&window.lhs.parent_cursor)
            window.lhs.viewed = pop(&window.lhs.parents)
            pop(&window.lhs.parent_names)
            window.refresh = true
            reset_scroll(window)
        }

        if window.lhs.hidden do return  // !!! CAREFUL THIS MIGHT CANCEL YOUR SHIT

        previous_cursor   := window.lhs.cursor
        window.lhs.cursor += int( key(glfw.KEY_DOWN) || (!shift() && key(glfw.KEY_TAB)) )
        window.lhs.cursor -= int( key(glfw.KEY_UP)   || ( shift() && key(glfw.KEY_TAB)) )

        if window.lhs.cursor >= len(window.lhs.names) { window.lhs.cursor = 1 }
        if window.lhs.cursor < 1 { window.lhs.cursor = len(window.lhs.names) - 1 }

        if window.lhs.cursor != previous_cursor {
            window.refresh = true
        }

        if len(window.lhs.names) == 1 { // may be useless now
            window.lhs.cursor = pop(&window.lhs.parent_cursor)
            window.lhs.viewed = pop(&window.lhs.parents)
            pop(&window.lhs.parent_names)
            window.refresh = true
            return
        }

        selected_item_name := window.lhs.names[window.lhs.cursor] 

        if key(glfw.KEY_ENTER) || key(glfw.KEY_RIGHT) {
            reset_scroll(window)

            if ctrl() {
                if window.lhs.viewed == nil do return

                watch(window.lhs.real_values[window.lhs.cursor], false, selected_item_name)
                window.refresh = true

            } else {
                if window.lhs.viewed == nil do return
                append(&window.lhs.parents, window.lhs.viewed)
                append(&window.lhs.parent_names, window.rhs.viewed.name)
                append(&window.lhs.parent_cursor, window.lhs.cursor)

                window.lhs.viewed = window.lhs.real_values[window.lhs.cursor]
                window.lhs.cursor = 1
                window.refresh = true
            }
        }
    }
}// }}}

dragged_scrollbar: int // id of dragged scrollbar or 0
@private handle_scrolling :: proc(window: ^Window, scroll: ^Scroll, pos, size: Vector) {// {{{

    draw_vertical   := scroll.max.y != 0 && scroll.max.y > size.y  

    if scroll.id == 0 { scroll.id = int(rand.int63()) }

    left_click_released := glfw.GetMouseButton(window.handle, glfw.MOUSE_BUTTON_LEFT) == glfw.RELEASE 
    if left_click_released { dragged_scrollbar = 0 }

    if scroll.id == dragged_scrollbar {
        
        track_pos  : Vector = pos + { options.scrollbar_width, 0 }
        track_size : Vector = { options.scrollbar_width, size.y }

        thumb_height := track_size.y*track_size.y * (1/scroll.max.y)
        scroll.pos.y = (window.mouse.y - track_pos.y - thumb_height/2) / track_size.y / (1/scroll.max.y)
    }

    if intersects(window.mouse, pos, size) && events.active_window == window.handle {
        scroll.vel += -events.scroll * options.scroll_speed * { 1, f32(i32(draw_vertical)) }
    }

    scroll.pos  += scroll.vel
    scroll.pos.x = max(scroll.pos.x, 0)
    scroll.pos.y = max(scroll.pos.y, 0)
    scroll.vel  *= options.scroll_speed_maintain // 0..<1

    end := scroll.max * 1.05
    scroll.pos = { max(scroll.pos.x, 0),     max(scroll.pos.y, 0) }
    scroll.pos = { min(scroll.pos.x, end.x), min(scroll.pos.y, end.y) }

    if scroll.vel.y > 0.1 {
        post_empty_event()
    }

    if draw_vertical { 
        track_pos  : Vector = pos + { size.x - options.scrollbar_width, 0 }
        track_size : Vector = { options.scrollbar_width, size.y }

        left_clicked := glfw.GetMouseButton(window.handle, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS 
        if left_clicked && intersects(window.mouse, track_pos, track_size) {
            dragged_scrollbar = scroll.id
        } 

        fraction     := f32(scroll.pos.y) / f32(scroll.max.y)
        thumb_offset := track_size.y * fraction + track_pos.y
        thumb_height := track_size.y*track_size.y * (1/scroll.max.y)
        
        if thumb_offset-track_pos.y + thumb_height > track_size.y {
            thumb_height = max(track_size.y - (thumb_offset-track_pos.y), 0)
        }

        draw_rect(window, track_pos, track_size, window.bg)
        draw_rect(window, { track_pos.x, thumb_offset }, { track_size.x, thumb_height }, window.hl)
    }
    
}// }}}
@private reset_scroll :: proc(window: ^Window) {// {{{
    window.lhs.scroll.pos = {}
    window.rhs.value_scroll.pos = {}
    window.rhs.binary_scroll.pos = {}
}// }}}

// ==================================== nanovg indirection ====================================

@private key_callback :: proc "c" (window: glfw.WindowHandle, key: i32, scancode: i32, action: i32, mods: i32) {// {{{

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
@private scroll_callback :: proc "c" (window: glfw.WindowHandle, x, y: f64) {// {{{
    is_friggs_window: bool
    for a_window in windows {
        if a_window.handle == window {
            is_friggs_window = true
            break
        }
    }
    if !is_friggs_window do return
    events.active_window = window

    events.scroll = { f32(x), f32(y) }       
}// }}}
@private draw_rect :: proc(window: ^Window, pos: Vector, size: Vector, color: [4] f32) {// {{{
    nvg.BeginPath(window.ctx)
    nvg.Rect(window.ctx, pos.x, pos.y, size.x, size.y)
    nvg.FillColor(window.ctx, color)
    nvg.Fill(window.ctx)
    nvg.ClosePath(window.ctx)
    nvg.FillColor(window.ctx, { 1, 1, 1, 1 })
}// }}}
@private draw_text_wrapped :: proc(window: ^Window, text: string, pos: Vector, size: Vector, color: [4] f32) -> Vector {// {{{
    _text := text
    assert(size.y / options.font_size < 128)
    lines: [128] nvg.Text_Row
    line_slice := lines[:]
    line_count, _, _ := nvg.TextBreakLines(window.ctx, &_text, size.x, &line_slice)

    y, w: f32
    for line in lines[:line_count] {
        draw_text(window, text[line.start:line.end], pos + { 0, y }, color)
        w  = max(w, text_width(window, text[line.start:line.end]))
        y += options.font_size + 1
    }

    return { w, y }
}// }}}
@private draw_text :: proc(window: ^Window, text: string, pos: Vector, color: [4] f32) {// {{{
    should_draw := pos.y > -options.font_size
    should_draw &= pos.y < window.size.y + options.font_size
    if !should_draw do return 

    nvg.FillColor(window.ctx, color)
    nvg.TextAlignVertical(window.ctx, .TOP)
    nvg.Text(window.ctx, pos.x, pos.y, text)
    nvg.FillColor(window.ctx, { 1, 1, 1, 1 })
    return
}// }}}
@private text_width :: proc(window: ^Window, text: string) -> f32 {// {{{
    @static base_width: f32
    if base_width == 0 {
        bounds: [4] f32
        base_width = nvg.TextBounds(window.ctx, 0, 0, "_", &bounds)
    }
    // if this causes a bug for you, you should try Monocraft. It's good for your soul.
    return base_width * f32(len(text))
}// }}}
@private scissor :: proc(window: ^Window, pos, size: Vector) {// {{{
    nvg.Scissor(window.ctx, pos.x, pos.y, size.x, size.y)
}// }}}
@private post_empty_event :: proc() {// {{{
    // Wayland:
    //   1. ignores WaitEventsTimeout
    //   2. resets KEY_REPEAT on PostEmptyEvent

    if are_we_wayland() do return
    glfw.PostEmptyEvent()
}// }}}

@private is_key_down     :: proc "c" (key: i32) -> bool { return find(events.down[:events.num_down], key) != -1 }
@private is_key_pressed  :: proc "c" (key: i32) -> bool { return find(events.pressed[:events.num_pressed], key) != -1 }
@private is_key_released :: proc "c" (key: i32) -> bool { return find(events.released[:events.num_released], key) != -1 }




/*
Structured, formatted memory viewer GUI program-in-a-library that uses reflection.

Used via `watch(anything, true)` or 
`watch(anything, false); for render_frame_for_all() { }`     

More info can be found in README.md.
*/
package frigg

import "core:os"
import "core:fmt"
import "core:time"
import "core:strings"
import "core:math"
import "core:math/rand"

import "base:intrinsics"
import "base:runtime"
import "core:reflect"
import "core:mem"
import "core:mem/virtual"

import "core:hash/xxhash"
import "core:sys/linux"

import     "vendor:glfw"
import  gl "vendor:OpenGL"
import nvg "vendor:nanovg"
import ngl "vendor:nanovg/gl"

Color   :: [4]  u8
Vector  :: [2] f32

Allocator :: mem.Allocator
Duration  :: time.Duration
Tick      :: time.Tick

now :: time.tick_now
ms  :: time.Millisecond

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

options : struct {
    initial_window_size   : Vector,     // ..
    vamos                 : bool,       // Do not wait for events / target fps
    target_fps            : f32,        // Setting this wastes fewer resources
    update_tps            : f32,        // ticks per second for data formating
    font_size             : f32,        // ..

    scrollbar_width       : f32,        // > = easier to drag, but distracting
    scroll_speed          : f32,        // Whatever feels good #1
    scroll_speed_maintain : f32,        // Whatever feels good #2,  0..1

    major_glfw_version    : i32,        // Try changing this if missing drivers
    use_extra_glfw_crap   : bool        // I don't think, this does anything...

} = {
    initial_window_size = { 600, 800 },
    vamos = false,
    target_fps = 60,
    update_tps =  5,
    font_size  = 15,
    
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
        sleep_for := rest_duration - time.tick_diff(frame_start, now())
        sleep_for  = min(max(sleep_for, 0), rest_duration)
        frame_start = now()

        time.sleep(sleep_for) 
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


// ==================================== rendering ====================================


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

    nvg.CreateFontMem(window.ctx, "mono", #load("font.ttf"), false)
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

    // frame_took := fmt.aprint("frame took:", time.tick_diff(frame_start, now()), allocator = window.tmp_alloc)
    // draw_text(window, frame_took, { window.size.x - text_width(window, frame_took) - 8, 0 }, window.fg )

    the_hash := hash(window.lhs.viewed, { window = window })

    if window.previous_hash != the_hash {
        @static last_update: time.Tick
        update_freq := Duration(1000 / options.update_tps) * ms
        if window.refresh || update_freq < time.tick_diff(last_update, now()) {
            update_lhs(window)
            update_rhs(window)
            window.previous_hash = the_hash
            last_update = now()
        }
        post_empty_event()
        window.refresh = false
    } else if window.refresh {
        update_lhs(window)
        update_rhs(window)
        post_empty_event()
        window.refresh = false
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


// ==================================== value formatting ====================================


update_hash :: xxhash.XXH32_update 
HashState :: struct {
    window : ^Window,
    hash   : ^xxhash.XXH32_state,
}

@private lhs_clear :: proc(window: ^Window) {// {{{
    clear(&window.lhs.names)      
    clear(&window.lhs.types)      
    clear(&window.lhs.small_values)
    clear(&window.lhs.real_values)
}// }}}

@private lhs_add :: proc(window: ^Window, name, type, value: string, real_value: any, allocator: Allocator) {// {{{
    append(&window.lhs.names,        strings.clone(name,  allocator))
    append(&window.lhs.types,        strings.clone(type,  allocator))
    append(&window.lhs.small_values, strings.clone(value, allocator))
    append(&window.lhs.real_values,  real_value)
}// }}}

@private lhs_comment :: proc(window: ^Window, comment: string) {// {{{
    if len(window.lhs.small_values) == 0 do return
    window.lhs.small_values[0] = strings.clone(comment, window.lhs_alloc)
}// }}}

// the window is used for its allocators
format_value_small :: proc(window: ^Window, value: any, level := 0) -> string {// {{{
    if value.data == nil do return "<nil>"
    if level > 15 do return "<self>"

    text : string

    the_type := reflect.type_info_base(type_info_of(value.id))
    switch real_type in the_type.variant {
    case reflect.Type_Info_Any:              text = format_value_small(window, collapse_any(window, value), level + 1)

    case reflect.Type_Info_Named:            text = format_basic(window, value)
    case reflect.Type_Info_Integer:          text = format_basic(window, value) 
    case reflect.Type_Info_Float:            text = format_basic(window, value) 
    case reflect.Type_Info_Complex:          text = format_basic(window, value) 
    case reflect.Type_Info_Quaternion:       text = format_basic(window, value) 
    case reflect.Type_Info_Boolean:          text = format_basic(window, value) 
    case reflect.Type_Info_Type_Id:          text = format_basic(window, value)
    case reflect.Type_Info_Enum:             text = format_basic(window, value) 
    case reflect.Type_Info_Bit_Set:          text = format_basic(window, value) 
    case reflect.Type_Info_Bit_Field:        text = format_basic(window, value) 
    case reflect.Type_Info_Procedure:        text = format_basic(window, "proc")

    case reflect.Type_Info_Rune:             text = format_string(window, value)
    case reflect.Type_Info_String:           text = format_string(window, value) 

    case reflect.Type_Info_Pointer:          text = format_pointer(window, value) 
    case reflect.Type_Info_Soa_Pointer:      text = format_pointer(window, value) 
    case reflect.Type_Info_Multi_Pointer:    text = format_multi_pointer(window, value) 

    case reflect.Type_Info_Array:            text = format_array(window, value) 
    case reflect.Type_Info_Enumerated_Array: text = format_array(window, value)
    case reflect.Type_Info_Dynamic_Array:    text = format_array(window, value)
    case reflect.Type_Info_Slice:            text = format_array(window, value) 
    case reflect.Type_Info_Simd_Vector:      text = format_array(window, value) 
    case reflect.Type_Info_Matrix:           text = format_array(window, value) 

    case reflect.Type_Info_Struct:           text = format_struct(window, value)
    case reflect.Type_Info_Union:            text = format_union(window, value)
    case reflect.Type_Info_Map:              text = format_map(window, value)
    case reflect.Type_Info_Parameters:       text = "proc parameters"
    }

    format_basic :: proc(window: ^Window, value: any) -> string {// {{{
        return fmt.aprint(value, allocator = window.tmp_alloc)
    }// }}}

    format_string :: proc(window: ^Window, value: any) -> string {// {{{
        return fmt.aprintf("%q", value, allocator = window.tmp_alloc)
    }// }}}

    format_pointer :: proc(window: ^Window, value: any) -> string {// {{{
        return fmt.aprintf("%p", value, allocator = window.tmp_alloc)
    }// }}}

    format_array :: proc(window: ^Window, array: any) -> string {// {{{
        builder := strings.builder_make(allocator = window.tmp_alloc)

        length := get_array_length(array)

        if new_length, has_length := get_linked_len(array); has_length {
            strings.write_string(&builder, "[:")
            strings.write_int(&builder, new_length)
            strings.write_string(&builder, "]")
            length = new_length
        }

        if length == 0 {
            strings.write_string(&builder, "[]")
            return strings.to_string(builder)
        }

        if is_zero_array(array, length) {
            fmt.sbprintf(&builder, "[0*%d]", length)
            return strings.to_string(builder)
        }

        strings.write_string(&builder, "[ ")

        iterator: int
        for item, i in iterate_array(array, &iterator, length) {
            formatted := format_value_small(window, item)
            if len(formatted) + len(builder.buf) > window.small_value_limit {
                strings.write_string(&builder, "..<")
                strings.write_int(&builder, length)
                break
            }

            strings.write_string(&builder, formatted)
            if i != length - 1 {
                strings.write_string(&builder, ", ")
            }
        }

        strings.write_string(&builder, " ]")
        return strings.to_string(builder)
    }// }}}

    format_multi_pointer :: proc(window: ^Window, array: any) -> string {// {{{
        builder := strings.builder_make(allocator = window.tmp_alloc)

        strings.write_string(&builder, "[:")
        length, has_length := get_linked_len(array)
        if !has_length {
            strings.write_string(&builder, "?]")
            strings.write_string(&builder, format_pointer(window, array))
            return strings.to_string(builder)
        }
        strings.write_int(&builder, length)
        strings.write_string(&builder, "]")

        strings.write_string(&builder, "[ ")

        iterator: int
        for item, i in iterate_array(array, &iterator, length) {
            formatted := format_value_small(window, item)
            if len(formatted) + len(builder.buf) > window.small_value_limit {
                strings.write_string(&builder, "..<")
                strings.write_int(&builder, length)
                break
            }

            strings.write_string(&builder, formatted)
            if i != length - 1 {
                strings.write_string(&builder, ", ")
            }
        }

        strings.write_string(&builder, " ]")
        return strings.to_string(builder)
    }// }}}

    format_struct :: proc(window: ^Window, value: any) -> string {// {{{
        builder := strings.builder_make(allocator = window.tmp_alloc)
        strings.write_string(&builder, "{ ")

        fields := reflect.struct_fields_zipped(value.id) 
        for field, i in fields {
            member := reflect.struct_field_value(value, field)
            formatted := format_value_small(window, member)
            if len(formatted) + len(builder.buf) > window.small_value_limit {
                strings.write_string(&builder, "..")
                break
            }

            strings.write_string(&builder, formatted)
            if i != len(fields) - 1 {
                strings.write_string(&builder, ", ")
            }
        }


        strings.write_string(&builder, " }")
        return strings.to_string(builder)
    }// }}}

    format_union :: proc(window: ^Window, value: any) -> string {// {{{
        builder := strings.builder_make(window.tmp_alloc)
        fmt.sbprintf(&builder, "(%v) ", reflect.union_variant_type_info(value))
        strings.write_string(&builder, format_value_small(window, reflect.get_union_variant(value)))
        return strings.to_string(builder)
    }// }}}

    format_map :: proc(window: ^Window, value: any) -> string {// {{{
        builder := strings.builder_make(window.tmp_alloc)
        length  := get_array_length(value)
        if length == 0 do return "[]"

        strings.write_string(&builder, "[ ")

        overall_length: int
        pairs := make([dynamic] string, 0, length, window.tmp_alloc)

        iterator: int
        for k, v in reflect.iterate_map(value, &iterator) {
            if find(ignored[:], hash_any_string(k)) != -1 do continue 

            key   := format_value_small(window, k)
            value := format_value_small(window, v)

            overall_length += len(key) + len(value) + 5 // ' = , '
            if overall_length > window.small_value_limit { 
                append(&pairs, "..")
                break
            }

            append(&pairs, strings.concatenate({ key, " = " , value }, window.tmp_alloc))
        }

        for pair, i in pairs {
            strings.write_string(&builder, pair)
            if i != len(pairs) - 1 do strings.write_string(&builder, ", ")
        }

        strings.write_string(&builder, " ]")
        return strings.to_string(builder)
    }// }}}

    return text
}// }}}

// the window is used for its allocators
format_value_big :: proc(window: ^Window, value: any, level := 0) -> string {// {{{
    if value.data == nil do return "<nil>"
    if level > 15 do return "<self>"
    text : string

    the_type := reflect.type_info_base(type_info_of(value.id))
    switch real_type in the_type.variant {
    case reflect.Type_Info_Any:              text = format_value_big(window, collapse_any(window, value), level + 1)

    case reflect.Type_Info_Named:            text = format_basic(window, value)
    case reflect.Type_Info_Float:            text = format_basic(window, value) 
    case reflect.Type_Info_Complex:          text = format_basic(window, value) 
    case reflect.Type_Info_Quaternion:       text = format_basic(window, value) 
    case reflect.Type_Info_Boolean:          text = format_basic(window, value) 
    case reflect.Type_Info_Type_Id:          text = format_basic(window, value)
    case reflect.Type_Info_Enum:             text = format_basic(window, value) 
    case reflect.Type_Info_Bit_Set:          text = format_basic(window, value) 
    case reflect.Type_Info_Bit_Field:        text = format_basic(window, value) 
    case reflect.Type_Info_Procedure:        text = format_basic(window, "proc")

    case reflect.Type_Info_Integer:          text = format_integer(window, value) 
    case reflect.Type_Info_Rune:             text = format_string(window, value)
    case reflect.Type_Info_String:           text = format_string(window, value) 

    case reflect.Type_Info_Pointer:          text = format_pointer(window, value, level) 
    case reflect.Type_Info_Soa_Pointer:      text = format_pointer(window, value, level) 
    case reflect.Type_Info_Multi_Pointer:    text = format_multi_pointer(window, value) 

    case reflect.Type_Info_Array:            text = format_array(window, value) 
    case reflect.Type_Info_Enumerated_Array: text = format_array(window, value)
    case reflect.Type_Info_Dynamic_Array:    text = format_array(window, value)
    case reflect.Type_Info_Slice:            text = format_array(window, value) 
    case reflect.Type_Info_Simd_Vector:      text = format_array(window, value) 
    case reflect.Type_Info_Matrix:           text = format_matrix(window, value) 

    case reflect.Type_Info_Struct:           text = format_struct(window, value)
    case reflect.Type_Info_Union:            text = format_union(window, value)
    case reflect.Type_Info_Map:              text = format_map(window, value)
    case reflect.Type_Info_Parameters:       text = "proc parameters"
    }

    format_basic :: proc(window: ^Window, value: any) -> string {// {{{
        return fmt.aprint(value, allocator = window.tmp_alloc)
    }// }}}

    format_integer :: proc(window: ^Window, value: any) -> string {// {{{
        return fmt.aprintf("dec: %d\nhex: %x\noct: %o\nbin: %08b", value, value, value, value, allocator = window.tmp_alloc)
    }// }}}

    format_string :: proc(window: ^Window, value: any) -> string {// {{{
        ihatemylife, _ := strings.replace_all(fmt.aprint(value), " ", "\u2002", allocator = window.tmp_alloc)
        return fmt.aprintf("%q \n\n```\n%s\n```", value, ihatemylife, allocator = window.tmp_alloc)
    }// }}}

    format_pointer :: proc(window: ^Window, value: any, level := 0) -> string {// {{{
        can_access  := ODIN_OS == .Linux
        can_access &&= value.data != nil
        is_invalid := !is_memory_safe(((^rawptr)(value.data))^, reflect.size_of_typeid(value.id), window.tmp_alloc)
        can_access &&= !is_invalid
        
        if is_invalid  do return fmt.aprintf("<%p>\n<invalid pointer>", value, allocator = window.tmp_alloc)
        if !can_access do return fmt.aprintf("<%p>", value, allocator = window.tmp_alloc)

        builder := strings.builder_make(window.tmp_alloc)    
        fmt.sbprintf(&builder, "<%p>\n", value)
        
        strings.write_string(&builder, format_value_big(window, reflect.deref(value), level + 1))

        return strings.to_string(builder)
    }// }}}

    format_multi_pointer :: proc(window: ^Window, array: any) -> string {// {{{
        builder := strings.builder_make(allocator = window.tmp_alloc)

        length, has_length := get_linked_len(array)
        if !has_length { return format_value_small(window, array) }

        strings.write_string(&builder, "[:")
        strings.write_int(&builder, length)
        strings.write_string(&builder, "]")

        if length == 0 {
            strings.write_string(&builder, "[]")
            return strings.to_string(builder)
        }

        if is_zero_array(array, length) {
            fmt.sbprintf(&builder, "[0*%d]", length)
            return strings.to_string(builder)
        }

        strings.write_string(&builder, "[ ")

        iterator: int
        for item, i in iterate_array(array, &iterator, length) {
            formatted := format_value_small(window, item)
            if len(formatted) + len(builder.buf) > 1024 {
                strings.write_string(&builder, "..<")
                strings.write_int(&builder, length)
                break
            }

            strings.write_string(&builder, formatted)
            if i != length - 1 {
                strings.write_string(&builder, ", ")
            }
        }

        strings.write_string(&builder, " ]")
        return strings.to_string(builder)
    }// }}}

    format_array :: proc(window: ^Window, array: any) -> string {// {{{
        builder := strings.builder_make(allocator = window.tmp_alloc)

        length := get_array_length(array)

        if new_length, has_length := get_linked_len(array); has_length {
            strings.write_string(&builder, "[:")
            strings.write_int(&builder, new_length)
            strings.write_string(&builder, "]")
            length = new_length
        }

        if length == 0 {
            strings.write_string(&builder, "[]")
            return strings.to_string(builder)
        }

        if is_zero_array(array, length) {
            fmt.sbprintf(&builder, "[0*%d]", length)
            return strings.to_string(builder)
        }

        strings.write_string(&builder, "[ ")

        iterator: int
        for item, i in iterate_array(array, &iterator, length) {
            formatted := format_value_small(window, item)
            if len(formatted) + len(builder.buf) > 1024 {
                strings.write_string(&builder, "..<")
                strings.write_int(&builder, length)
                break
            }

            strings.write_string(&builder, formatted)
            if i != length - 1 {
                strings.write_string(&builder, ", ")
            }
        }

        strings.write_string(&builder, " ]")
        return strings.to_string(builder)
    }// }}}

    format_matrix :: proc(window: ^Window, array: any) -> string {// {{{
        SPACE : [256] rune = '\u2002'
        builder := strings.builder_make(allocator = window.tmp_alloc)
        type_info := reflect.type_info_base(type_info_of(array.id)).variant.(reflect.Type_Info_Matrix)
    
        iterator : int
        longest  := make([] int, type_info.column_count,  window.tmp_alloc)
        lengths  := make([] int, get_array_length(array), window.tmp_alloc)

        for j in 0..<type_info.row_count {
            for i in 0..<type_info.column_count {
                index  := j * type_info.row_count + i
                offset := type_info.elem_size * index
                value := to_any(ptr_add(array.data, uintptr(offset)), type_info.elem.id)
                lengths[index] = len(fmt.aprintf("%.2f", value, allocator = window.tmp_alloc))
                longest[i] = max(longest[i], lengths[index]) // this sucks ^
            }
        }

        for j in 0..<type_info.row_count {
            for i in 0..<type_info.column_count {
                index  := j * type_info.row_count + i
                offset := type_info.elem_size * index
                value := to_any(ptr_add(array.data, uintptr(offset)), type_info.elem.id)
                
                _, is_float := type_info.elem.variant.(reflect.Type_Info_Float)
                
                if is_float do fmt.sbprintf(&builder, "%s\u2002%.2f", SPACE[:longest[i] - lengths[index]], value, )
                else do        fmt.sbprintf(&builder, "%s\u2002%v",   SPACE[:longest[i] - lengths[index]], value, )
            }
            strings.write_rune(&builder, '\n')
        }
    
        return strings.to_string(builder)
    }// }}}

    format_struct :: proc(window: ^Window, value: any) -> string {// {{{
        builder := strings.builder_make(allocator = window.tmp_alloc)
    
        fields := reflect.struct_fields_zipped(value.id) 
        members := make([] string, len(fields), window.tmp_alloc)
    
        ignore_count: int
        for field, i in fields {
            if find(ignored[:], hash_string(field.name)) != -1 { 
                ignore_count += 1; continue
            }

            member := to_any(ptr_add(value.data, field.offset), field.type.id)
            members[i - ignore_count] = fmt.aprint(field.name, "=", format_value_small(window, member))
        }
        
        for member in members {
            fmt.sbprintln(&builder, member)
        }
    
        return strings.to_string(builder)
    }// }}}

    format_union :: proc(window: ^Window, value: any) -> string {// {{{
        builder := strings.builder_make(window.tmp_alloc)
        fmt.sbprintfln(&builder, "(%v)", reflect.union_variant_type_info(value))
        strings.write_string(&builder, format_value_big(window, reflect.get_union_variant(value)))
        return strings.to_string(builder)
    }// }}}

    format_map :: proc(window: ^Window, value: any) -> string {// {{{
        builder := strings.builder_make(window.tmp_alloc)
        length  := get_array_length(value)
        if length == 0 do return "[ empty map ]"

        pairs := make([dynamic] string, 0, length, window.tmp_alloc)

        iterator: int
        for k, v in reflect.iterate_map(value, &iterator) {
            if find(ignored[:], hash_any_string(k)) != -1 do continue
            key   := format_value_small(window, k)
            value := format_value_small(window, v)

            append(&pairs, strings.concatenate({ key, " = " , value }, window.tmp_alloc))
        }

        // quick-enough sort
        for i in 0..<len(pairs) {
            for j in i+1..<len(pairs) {
                if pairs[i] > pairs[j] do pairs[i], pairs[j] = pairs[j], pairs[i]
            }
        }

        for pair, i in pairs {
            strings.write_string(&builder, pair)
            if i != len(pairs) - 1 do strings.write_string(&builder, ", ")
        }

        return strings.to_string(builder)
    }// }}}

    return text
}// }}}

// the window is used for its allocators
format_value_binary :: proc(window: ^Window, value: any, level := 0) -> string {// {{{
    if value.data == nil do return "??"
    if level > 15 do return "<self>"
    text : string

    the_type := reflect.type_info_base(type_info_of(value.id))
    switch real_type in the_type.variant {
    case reflect.Type_Info_Any:              text = format_value_binary(window, collapse_any(window, value), level + 1)

    case reflect.Type_Info_Named:            text = format_basic(window, value)
    case reflect.Type_Info_Float:            text = format_basic(window, value) 
    case reflect.Type_Info_Complex:          text = format_basic(window, value) 
    case reflect.Type_Info_Quaternion:       text = format_basic(window, value) 
    case reflect.Type_Info_Boolean:          text = format_basic(window, value) 
    case reflect.Type_Info_Type_Id:          text = format_basic(window, value)
    case reflect.Type_Info_Enum:             text = format_basic(window, value) 
    case reflect.Type_Info_Bit_Set:          text = format_basic(window, value) 
    case reflect.Type_Info_Bit_Field:        text = format_basic(window, value) 
    case reflect.Type_Info_Procedure:        text = format_basic(window, value)
    case reflect.Type_Info_Integer:          text = format_basic(window, value) 
    case reflect.Type_Info_Rune:             text = format_basic(window, value)
    case reflect.Type_Info_Soa_Pointer:      text = format_basic(window, value) 
    case reflect.Type_Info_Array:            text = format_basic(window, value) 
    case reflect.Type_Info_Enumerated_Array: text = format_basic(window, value)
    case reflect.Type_Info_Simd_Vector:      text = format_basic(window, value) 
    case reflect.Type_Info_Matrix:           text = format_basic(window, value) 
    case reflect.Type_Info_Union:            text = format_basic(window, value)
    case reflect.Type_Info_Struct:           text = format_basic(window, value)
    case reflect.Type_Info_Parameters:       text = format_basic(window, value)

    case reflect.Type_Info_Pointer:          text = format_pointer(window, value, level) 
    case reflect.Type_Info_Multi_Pointer:    text = format_multi_pointer(window, value, level) 

    case reflect.Type_Info_Dynamic_Array:    text = format_array(window, value)
    case reflect.Type_Info_Slice:            text = format_array(window, value) 
    case reflect.Type_Info_String:           text = format_array(window, value) 

    case reflect.Type_Info_Map:              text = format_map(window, value)
    }
    
    write_byte :: proc(builder: ^strings.Builder, num: byte) { // {{{
        out: [3] byte = { '0', '0', ' ' }
        hi := num / 16
        lo := num % 16
        
        hi += '0' if hi < 10 else ('A' - 10)
        lo += '0' if lo < 10 else ('A' - 10)
        
        out[0] = hi; out[1] = lo;
        strings.write_bytes(builder, out[:])
    }// }}}

    format_bytes :: proc(window: ^Window, mem: [] byte) -> string { // {{{
        builder := strings.builder_make(window.tmp_alloc)

        for b in mem {
            write_byte(&builder, b)
        }

        strings.write_string(&builder, "\n\n")
        return strings.to_string(builder)
        
    }// }}}

    format_many_bytes :: proc(window: ^Window, list: [][]byte) -> string { // {{{
        builder := strings.builder_make(window.tmp_alloc)

        for block in list {
            for b in block {
                write_byte(&builder, b)
            }
            // strings.write_string(&builder, "\n\n")
        }
        return strings.to_string(builder)
    
    }// }}}

    format_basic :: proc(window: ^Window, value: any) -> string { // {{{
        data := mem.any_to_bytes(value)
        return format_bytes(window, data)
    }// }}}

    format_pointer :: proc(window: ^Window, value: any, level: int) -> string { // {{{
        a := mem.any_to_bytes(value)
        
        can_access  := ODIN_OS == .Linux
        can_access &&= value.data != nil
        can_access &&= is_memory_safe(((^rawptr)(value.data))^, reflect.size_of_typeid(value.id), window.tmp_alloc)
        b := mem.any_to_bytes(reflect.deref(value)) if can_access else {}

        return format_many_bytes(window, { a, b })
    } // }}} 

    format_multi_pointer :: proc(window: ^Window, value: any, level: int) -> string { // {{{
        a := mem.any_to_bytes(value)

        length, ok := get_linked_len(value)
        if !ok do return format_pointer(window, value, level)

        start := ((^rawptr)(value.data))^
        size  := length * get_array_stride(value)
        b := (transmute([^]byte) start)[:size]

        can_access  := ODIN_OS == .Linux
        can_access &&= value.data != nil
        can_access &&= is_memory_safe(((^rawptr)(value.data))^, reflect.size_of_typeid(value.id), window.tmp_alloc)

        return format_many_bytes(window, { a, b if can_access else {} })
    } // }}} 


    format_array :: proc(window: ^Window, value: any) -> string { // {{{
        a := mem.any_to_bytes(value)

        start := ((^rawptr)(value.data))^
        size  := get_array_length(value) * get_array_stride(value)
        b := (transmute([^]byte) start)[:size]

        can_access  := ODIN_OS == .Linux
        can_access &&= value.data != nil
        can_access &&= is_memory_safe(((^rawptr)(value.data))^, reflect.size_of_typeid(value.id), window.tmp_alloc)

        return format_many_bytes(window, { a, b if can_access else {} })
    } // }}} 

    format_map :: proc(window: ^Window, value: any) -> string {// {{{
        // TODO
        return format_basic(window, value)
    }// }}}

    return text
}// }}}

// the window is used for its allocators
hash :: proc(value: any, state: HashState, level := 0) -> u32 {// {{{
    original_state := state
    state := state
    if state.hash == nil do state.hash, _ = xxhash.XXH32_create_state(state.window.tmp_alloc) 

    if level > 4 {
        assert(original_state.hash != nil)
        return 0
    }

    the_type := reflect.type_info_base(type_info_of(value.id))
    switch type in the_type.variant {
    case reflect.Type_Info_Integer:          hash_basic(state, value)  
    case reflect.Type_Info_Rune:             hash_basic(state, value)  
    case reflect.Type_Info_Float:            hash_basic(state, value)  
    case reflect.Type_Info_Complex:          hash_basic(state, value)  
    case reflect.Type_Info_Quaternion:       hash_basic(state, value)  
    case reflect.Type_Info_Boolean:          hash_basic(state, value)  
    case reflect.Type_Info_Type_Id:          hash_basic(state, value)  
    case reflect.Type_Info_Procedure:        hash_basic(state, value)  
    case reflect.Type_Info_Enum:             hash_basic(state, value)  
    case reflect.Type_Info_Bit_Set:          hash_basic(state, value)  
    case reflect.Type_Info_Array:            hash_basic(state, value)  
    case reflect.Type_Info_Enumerated_Array: hash_basic(state, value)   
    case reflect.Type_Info_Simd_Vector:      hash_basic(state, value)  
    case reflect.Type_Info_Matrix:           hash_basic(state, value)  
    case reflect.Type_Info_Bit_Field:        hash_basic(state, value) 

    case reflect.Type_Info_Pointer:          hash_pointer(state, value, level + 1)
    case reflect.Type_Info_Multi_Pointer:    hash_pointer(state, value, level + 1)  

    case reflect.Type_Info_String:           hash_array(state, value, level + 1)  
    case reflect.Type_Info_Slice:            hash_array(state, value, level + 1)  
    case reflect.Type_Info_Dynamic_Array:    hash_array(state, value, level + 1)  

    case reflect.Type_Info_Any:              hash(value, state, level + 1) 
    case reflect.Type_Info_Map:              hash_map(state, value, level + 1)
    case reflect.Type_Info_Struct:           hash_struct(state, value, level + 1) 
    case reflect.Type_Info_Union:            hash(to_any(value.data, type.tag_type.id), state, level + 1)  

    // todo, I guess
    case reflect.Type_Info_Soa_Pointer:      hash_basic(state, value)
    case reflect.Type_Info_Named:            hash_basic(state, value) 
    case reflect.Type_Info_Parameters:       hash_basic(state, value)   
    }

    hash_basic :: proc(state: HashState, value: any, caller := #caller_location) {
        update_hash(state.hash, mem.any_to_bytes(value))
    }

    hash_pointer :: proc(state: HashState, value: any, level: int) {
        can_access  := ODIN_OS == .Linux
        can_access &&= (^rawptr)(value.data) != nil
        can_access &&= is_memory_safe(((^rawptr)(value.data))^, reflect.size_of_typeid(value.id), state.window.tmp_alloc)

        if can_access do hash_array(state, value, level + 1) 
        else do          hash_basic(state, value) 
    }

    hash_array :: proc(state: HashState, value: any, level: int) {
        hash_basic(state, value)
        iterator: int
        for value in reflect.iterate_array(value, &iterator) { 
            if reflect.is_procedure(type_info_of(value.id)) do continue
            hash(value, state, level + 1) 
        }
    }
    hash_map :: proc(state: HashState, value: any, level: int) {
        hash_basic(state, value)
        iterator: int
        for k, v in reflect.iterate_map(value, &iterator) { 
            hash(k, state, level + 1) 
            hash(v, state, level + 1) 
        }
    }

    hash_struct :: proc(state: HashState, value: any, level: int) {
        for field in reflect.struct_fields_zipped(value.id) {
            field_type, ok := field.type.variant.(runtime.Type_Info_Named)
            if field_type.name == "Allocator" do continue

            hash(reflect.struct_field_value(value, field), state, level + 1)
        }
    }

    if original_state.hash == nil do return xxhash.XXH32_digest(state.hash)
    else do return 0
}// }}}

@private hash_string :: proc(str: string) -> u32 {// {{{
    return xxhash.XXH32(transmute([] byte) str)
}// }}}

@private hash_any_string :: proc(value: any) -> u32 {// {{{
    return xxhash.XXH32(transmute([] byte) eat(reflect.as_string(value)))
}// }}} 

@private update_lhs :: proc(window: ^Window) {// {{{
    window.lhs.hidden = false
    lhs_clear(window)
    free_all(window.lhs_alloc)
    value := window.lhs.viewed
    lhs_add(window, back(window.lhs.parent_names), "", "", nil, window.lhs_alloc)

    the_type := reflect.type_info_base(type_info_of(value.id))
    #partial switch real_type in the_type.variant {

    case reflect.Type_Info_Struct:
        ignore_count: int
        for field, i in reflect.struct_fields_zipped(value.id) {
            if find(ignored[:], hash_string(field.name)) != -1 {
                ignore_count += 1; continue
            }

            v    := to_any(ptr_add(value.data, field.offset), field.type.id)
            name := fmt.aprint(field.name, allocator = window.tmp_alloc)
            type := soft_up_to(fmt.aprint(field.type, allocator = window.tmp_alloc), 24)
            data := format_value_small(window, v)

            lhs_add(window, name, type, data, v, window.lhs_alloc)

            if i + 1 - ignore_count == window.lhs.cursor { 
                window.rhs.viewed = {
                    name = strings.clone(field.name, window.lhs_alloc),
                    type = soft_up_to(fmt.aprint(field.type, allocator = window.lhs_alloc), 24),
                    value = to_any(ptr_add(value.data, field.offset), field.type.id) 
                }
            }
        }

    case reflect.Type_Info_Map:
        lhs_comment(window, "(sorted by frigg)")
        Entry :: struct {
            name : string,
            data : string,
            value: any,
        }
        results := make([dynamic] Entry, window.tmp_alloc)

        iterator: int
        for k, v in reflect.iterate_map(value, &iterator) {
            if find(ignored[:], hash_any_string(k)) != -1 do continue 

            name := format_value_small(window, k)
            data := format_value_small(window, v)

            insertion_point := 0
            for result, i in results {
                if result.name > name {
                    insertion_point = i
                    break
                }
            }
            inject_at(&results, insertion_point, Entry { name, data, v })

        }

        // quick-enough sort
        for i in 0..<len(results) {
            for j in i+1..<len(results) {
                if results[i].name > results[j].name do results[i], results[j] = results[j], results[i]
            }
        }

        for result, i in results {
            lhs_add(window, result.name, "", result.data, result.value, window.lhs_alloc)
            if i + 1 == window.lhs.cursor { 
                window.rhs.viewed = {
                    name  = strings.clone(result.name, window.lhs_alloc),
                    type  = soft_up_to(fmt.aprint(real_type.key.id, "<->", real_type.value.id, allocator = window.lhs_alloc), 24),
                    value = result.value
                }
            }
        }

    case reflect.Type_Info_Slice, reflect.Type_Info_Array, reflect.Type_Info_Dynamic_Array,
        reflect.Type_Info_Matrix, reflect.Type_Info_Simd_Vector:
        max_len, ok := get_linked_len(value); if !ok do max_len = max(int)
        iterator: int
        for elem, i in iterate_array(value, &iterator, max_len) {
            name  := fmt.aprint(i, allocator = window.tmp_alloc)
            value := format_value_small(window, elem)
            lhs_add(window, name, "", value, elem, window.lhs_alloc)

            if i + 1 == window.lhs.cursor { 
                window.rhs.viewed = {
                    name = name,
                    type = soft_up_to(fmt.aprint(elem.id, allocator = window.lhs_alloc), 24),
                    value = elem,   
                }
            }
        }
    case reflect.Type_Info_Enumerated_Array:
        max_len, ok := get_linked_len(value); if !ok do max_len = max(int)
        iterator: int
        ignore_count: int
        for elem, i in iterate_array(value, &iterator, max_len) {
            name  := reflect.enum_name_from_value_any(to_any(&iterator, real_type.index.id)) or_else "BAD ENUM"
            index := fmt.aprint(i, allocator = window.tmp_alloc)
            value := format_value_small(window, elem)

            if find(ignored[:], hash_string(name)) != -1 { 
                ignore_count += 1; continue
            }

            lhs_add(window, name, index, value, elem, window.lhs_alloc)

            if i + 1 - ignore_count == window.lhs.cursor { 
                window.rhs.viewed = {
                    name = name,
                    type = soft_up_to(fmt.aprint(elem.id, allocator = window.lhs_alloc), 24),
                    value = elem,   
                }
            }
        }

    case reflect.Type_Info_Multi_Pointer:
        max_len, ok := get_linked_len(value); 
        if !ok { window.lhs.hidden = false; break }
        iterator: int
        for elem, i in iterate_array(value, &iterator, max_len) {
            the_index := i
            name  := fmt.aprint(i, allocator = window.tmp_alloc)
            value := format_value_small(window, elem)
            lhs_add(window, name, "", value, elem, window.lhs_alloc)

            if i + 1 == window.lhs.cursor { 
                window.rhs.viewed = {
                    name = name,
                    type = soft_up_to(fmt.aprint(elem.id, allocator = window.lhs_alloc), 24),
                    value = elem,   
                }
            }
        }

    case reflect.Type_Info_Pointer:

        for i in 0..<15 {
            if !can_deref(window, value) {
                window.lhs.viewed = value
                break   
            }

            value = reflect.deref(value)

            if !reflect.is_pointer(type_info_of(value.id)) { 
                if value != nil do window.lhs.viewed = value
                update_lhs(window)
                return
            }

            window.lhs.viewed = value
        }

        window.lhs.hidden = true

    case reflect.Type_Info_Any:

        for i in 0..<15 {
            value = collapse_any(window, value)
            if value == nil {
                window.lhs.viewed = value
                break   
            
            }

            if !reflect.is_any(type_info_of(value.id)) { 
                if value != nil do window.lhs.viewed = value
                update_lhs(window)
                return
            }

            window.lhs.viewed = value
        }

        window.lhs.hidden = true


    case reflect.Type_Info_Union: 
        window.lhs.viewed = reflect.get_union_variant(value)
        update_lhs(window)

    case: 
        window.lhs.viewed = value
        lhs_add(window, "", "", "", nil, window.lhs_alloc) 
        
        window.rhs.viewed = {
            name = back(window.lhs.parent_names),
            type = soft_up_to(fmt.aprint(value.id, allocator = window.lhs_alloc), 24),
            value = value,
        }
        
        window.lhs.hidden = true
    }
}// }}}

@private update_rhs :: proc(window: ^Window) {// {{{
    free_all(window.rhs_alloc)

    cursor := window.lhs.cursor
    field  := window.rhs.viewed
    value  := field.value

    window.rhs.name = strings.clone(field.name, window.rhs_alloc)
    window.rhs.type = strings.clone(field.type, window.rhs_alloc)
    window.rhs.value = strings.clone(format_value_big(window, value), window.rhs_alloc)
    window.rhs.binary = strings.clone(format_value_binary(window, value), window.rhs_alloc)   

}// }}}


// ==================================== utility functions ====================================


@private eat :: proc(v: $T, e: any) -> T { return v }

@private intersects :: proc(a, b, bsize: Vector) -> bool {// {{{
    return  a.x >= b.x && a.x <= b.x + bsize.x && 
            a.y >= b.y && a.y <= b.y + bsize.y     
}// }}}

@private make_arena :: proc() -> Allocator {// {{{
    arena := new(virtual.Arena)
    _ = virtual.arena_init_growing(arena)
    return virtual.arena_allocator(arena) 
}// }}}

@private soft_up_to :: proc(str: string, max_len: int) -> string {// {{{
    if len(str) <= max_len do return str

    curly := strings.last_index(str[:max_len], "{")
    if curly != -1 do return str[:curly]

    space := strings.last_index(str[:max_len], " ")
    if space == -1 do return str[:max_len]

    return str[:space]
}// }}}

@private ptr_add :: proc(a: rawptr, b: uintptr) -> rawptr {// {{{
    return rawptr(uintptr(a) + b)
}// }}}

@private to_any :: proc(ptr: rawptr, type: typeid) -> any {// {{{
    return transmute(any) runtime.Raw_Any { data = ptr, id = type }
}// }}}

@private collapse_any :: proc(window: ^Window, anyany: any) -> any {// {{{
    if !can_deref(window, anyany) do return nil  
    data := (^any)(anyany.data)^
    return to_any(rawptr(data.data), data.id)
}// }}}

@private back :: proc(array: [dynamic] $T) -> T {// {{{
    return array[len(array) - 1]
} // }}}

@private find :: proc "c" (array: [] $T, elem: T) -> int {// {{{
    for e, i in array do if e == elem do return i
    return -1
}// }}}

@private hsl_to_rgb :: proc(h, s, l: f32) -> (rgb: [4] f32) {// {{{
    hue_to_rgb :: proc(p, q, t: f32) -> f32 {
        p := p; q := q; t := t
        if t < 0    do t += 1
        if t > 1    do t -= 1
        if t < 1./6 do return p + (q - p) * 6 * t
        if t < 1./2 do return q
        if t < 2./3 do return p + (q - p) * (2./3 - t) * 6
        return p
    }

    if s == 0 { return { l, l, l, 1 } }
    
    q := l * (1 + s) if l < 0.5 else l + s - l * s;
    p := 2 * l - q;

    rgb.r = hue_to_rgb(p, q, h + 1./3)
    rgb.g = hue_to_rgb(p, q, h)
    rgb.b = hue_to_rgb(p, q, h - 1./3)
    rgb.a = 1

    return
}// }}}

@private color_stack: [dynamic] f32
@private color_upper: bool = false
@private color_level: int  = 2
@private make_color_palette :: proc(window: ^Window) {// {{{
    h: f32

    get_next_color :: proc() -> f32 {
        delta := 1 / f32(color_level)
        return color_stack[0] + (delta if color_upper else -delta)
    }


    if len(color_stack) == 0 {
        append(&color_stack, 1)
    }

    h = get_next_color()
    append(&color_stack, h)
    
    if !color_upper {
        pop_front(&color_stack)
        color_level *= 2
    }
    
    color_upper = !color_upper

    window.bg  = hsl_to_rgb(h, 0.1, 0.05)
    window.hl  = hsl_to_rgb(h, 0.3, 0.25)
    window.fg  = hsl_to_rgb(h, 0.6, 0.95)
    window.bin = hsl_to_rgb(get_next_color(), 0.4, 0.7 )

}// }}}

// ==================================== reflection utility ====================================

@private get_linked_len :: proc(array: any) -> (length: int, ok: bool) {// {{{
    raw_length := len_links[array.data]      or_return
    length      = reflect.as_int(raw_length) or_return
    return length, true

    // This, currently, is not necessary because of the static type asserts in link()
    // if reflect.is_pointer(type_info_of(raw_length.id)) {
    //     if !can_deref_small(raw_length) do return
    //     raw_length = reflect.deref(raw_length)
    // }
}// }}}

@private is_memory_safe :: proc(pointer: rawptr, size: int, allocator: Allocator) -> bool {// {{{
    if pointer == nil do return false
    page_size := uintptr(os.get_page_size())

    // align to page by setting all (non relevant) bits to 0. "&~" is "and-not"
    // '.. - 1' is to get a bunch of 0x111 instead of 0x1000
    aligned_pointer := uintptr(pointer) &~ (page_size - 1)
    size := size + int(uintptr(pointer) - aligned_pointer)
    
    when ODIN_OS == .Linux {
        pages := make([] b8, (size/int(page_size)) + 1, allocator)
        error := linux.mincore(rawptr(aligned_pointer), uint(size), pages)

        for page in pages {
            if !page do return false
        }
    }

    // on windows there (in theory) is QueryWorkingSet
    // fuck virtual machines and windows.
    // if anyone wants to make a PR for this, please do

    return true
}// }}}

@private can_deref :: proc(window: ^Window, value: any) -> bool {// {{{
    can_access  := ODIN_OS == .Linux
    can_access &&= value.data != nil
    can_access &&= (^rawptr)(value.data)^ != nil
    is_invalid := !is_memory_safe(((^rawptr)(value.data))^, reflect.size_of_typeid(value.id), window.tmp_alloc)
    can_access &&= !is_invalid
    return can_access
}// }}}

@private can_deref_small :: proc(value: any) -> bool {// {{{
    can_access  := ODIN_OS == .Linux
    can_access &&= value.data != nil
    can_access &&= (^rawptr)(value.data)^ != nil
    is_invalid := !is_memory_safe(((^rawptr)(value.data))^, reflect.size_of_typeid(value.id), context.temp_allocator)
    can_access &&= !is_invalid
    return can_access
}// }}}

@(require_results)
@private iterate_array :: proc(val: any, it: ^int, max_len := max(int)) -> (elem: any, index: int, ok: bool) {// {{{
	if val == nil || it == nil {
		return
	}
    
	ti := reflect.type_info_base(type_info_of(val.id))
	#partial switch info in ti.variant {
    case reflect.Type_Info_Enumerated_Array:
		if it^ < min(max_len, info.count) {
			elem.data = rawptr(uintptr(val.data) + uintptr(it^ * info.elem_size))
			elem.id = info.elem.id
			ok = true
			index = it^
			it^ += 1
		}
    case reflect.Type_Info_Simd_Vector:
		if it^ < min(max_len, info.count) {
			elem.data = rawptr(uintptr(val.data) + uintptr(it^ * info.elem_size))
			elem.id = info.elem.id
			ok = true
			index = it^
			it^ += 1
		}
    case reflect.Type_Info_Matrix:
		if it^ < min(max_len, info.column_count * info.row_count) {
			elem.data = rawptr(uintptr(val.data) + uintptr(it^ * info.elem_size))
			elem.id = info.elem.id
			ok = true
			index = it^
			it^ += 1
		}
    case reflect.Type_Info_Multi_Pointer:
		if it^ < max_len && max_len != max(int) {
			elem.data = rawptr(uintptr((^rawptr)(val.data)^) + uintptr(it^ * info.elem.size))
			elem.id = info.elem.id
			ok = true
			index = it^
			it^ += 1
		}
        
	case reflect.Type_Info_Array:
		if it^ < min(max_len, info.count) {
			elem.data = rawptr(uintptr(val.data) + uintptr(it^ * info.elem_size))
			elem.id = info.elem.id
			ok = true
			index = it^
			it^ += 1
		}
	case reflect.Type_Info_Slice:
		array := (^runtime.Raw_Slice)(val.data)
		if it^ < min(max_len, array.len) {
			elem.data = rawptr(uintptr(array.data) + uintptr(it^ * info.elem_size))
			elem.id = info.elem.id
			ok = true
			index = it^
			it^ += 1
		}
	case reflect.Type_Info_Dynamic_Array:
		array := (^runtime.Raw_Dynamic_Array)(val.data)
		if it^ < min(max_len, array.len) {
			elem.data = rawptr(uintptr(array.data) + uintptr(it^ * info.elem_size))
			elem.id = info.elem.id
			ok = true
			index = it^
			it^ += 1
		}

	case reflect.Type_Info_Pointer:
		if ptr := (^rawptr)(val.data)^; ptr != nil {
			return iterate_array(any{ptr, info.elem.id}, it, max_len)
		}

    case: panic("type unsuported in iterate_array")
    }

    return
}// }}}

@private is_zero_array :: proc(array: any, max_len := max(int)) -> bool {// {{{
    all_zeros := true
    iterator: int
    for item, i in iterate_array(array, &iterator, max_len) {
        if !mem.check_zero(mem.any_to_bytes(item)) {
            all_zeros = false
            break
        }
    }
    return all_zeros
}// }}}

@private get_array_length :: proc(array: any) -> int {// {{{
    slice_len :: proc(array: any) -> int {
        return (transmute(^runtime.Raw_Slice) array.data).len
    }
    map_len :: proc(the_map: any) -> int {
        return auto_cast (transmute(^runtime.Raw_Map) the_map.data).len
    }
    string_len :: proc(str: any) -> int {
        if reflect.is_cstring(type_info_of(str.id)) {
            the_cstring := ((^cstring)(str.data))^
            return len(the_cstring)
        } else {
            return slice_len(str)
        }
    }

    the_type := reflect.type_info_base(type_info_of(array.id))
    #partial switch real_type in the_type.variant {
    case reflect.Type_Info_Map:              return map_len(array)
    case reflect.Type_Info_Array:            return real_type.count
    case reflect.Type_Info_Slice:            return slice_len(array)
    case reflect.Type_Info_String:           return string_len(array)
    case reflect.Type_Info_Matrix:           return real_type.column_count * real_type.row_count
    case reflect.Type_Info_Simd_Vector:      return real_type.count
    case reflect.Type_Info_Dynamic_Array:    return slice_len(array)
    case reflect.Type_Info_Enumerated_Array: return real_type.count
    case:
    }
    return 0
}// }}}

@private get_array_stride :: proc(array: any) -> int {// {{{
    the_type := reflect.type_info_base(type_info_of(array.id))
    #partial switch type_info in the_type.variant {
    case reflect.Type_Info_Map:              panic("I don't know...")
    case reflect.Type_Info_Slice:            return (transmute(^runtime.Raw_Slice) array.data).len
    case reflect.Type_Info_String:           return (transmute(^runtime.Raw_Slice) array.data).len
    case reflect.Type_Info_Dynamic_Array:    return (transmute(^runtime.Raw_Slice) array.data).len
    case reflect.Type_Info_Array:            return type_info.elem_size
    case reflect.Type_Info_Matrix:           return type_info.elem_size
    case reflect.Type_Info_Simd_Vector:      return type_info.elem_size
    case reflect.Type_Info_Enumerated_Array: return type_info.elem_size
    case:
    }
    return 0
}// }}}

@private are_we_wayland :: proc() -> bool {// {{{
    result := os.get_env("WAYLAND_DISPLAY")
    defer delete_string(result)
    return result != ""
}// }}}

// TRASH

/* // "oklab" more like "ok, I need a lab to figure out how tf to use this".
oklab_to_rgb :: proc(L, a, b: f32) -> [4] f32 {
    l_ := L + 0.3963377774 * a + 0.2158037573 * b
    m_ := L - 0.1055613458 * a - 0.0638541728 * b
    s_ := L - 0.0894841775 * a - 1.2914855480 * b

    l := l_ * l_ * l_
    m := m_ * m_ * m_
    s := s_ * s_ * s_

    return {
        +4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
        1
    } 
}

oklch_to_rgb :: proc(L, a, r: f32) -> [4] f32 {
    L := L
    b, a := math.sincos(a)
    b *= r; a *= r
    return oklab_to_rgb(L, a, b)
}

make_color_palette :: proc(window: ^Window) {
    L := rand.float32() / 16
    a := rand.float32() * math.TAU
    r := rand.float32() * 0.4 / 8

    dL := rand.float32() / 16 + 0.38
    dr := rand.float32() /  6 + 0.15

    window.palette.bg = oklch_to_rgb(L + 0.12, a, r + 0.15)
    window.palette.hl = oklch_to_rgb(L +   dL, a, r +   dr)
    window.palette.fg = oklch_to_rgb(L + 3*dL, a, r + 2*dr)

    window.palette.bin = oklch_to_rgb(L + dL, a + 0.15, r + 2*dr)

    window.fg.r = min(window.fg.r, 0.95)
    window.fg.g = min(window.fg.g, 0.95)
    window.fg.b = min(window.fg.b, 0.95)

    window.bin.r = min(window.bin.r, 0.95)
    window.bin.g = min(window.bin.g, 0.95)
    window.bin.b = min(window.bin.b, 0.95)
}
*/

/// This is memoized in window.lhs.real_values
// index_anything :: proc(window: ^Window, value: any, index: int) -> any {
// 	if value == nil { return nil }
// 
// 	ti := reflect.type_info_base(type_info_of(value.id))
// 	#partial switch info in ti.variant {
// 
//     case reflect.Type_Info_Enumerated_Array,
//          reflect.Type_Info_Simd_Vector,
//          reflect.Type_Info_Matrix,
//          reflect.Type_Info_Multi_Pointer,
// 	     reflect.Type_Info_Array,
// 	     reflect.Type_Info_Slice,
// 	     reflect.Type_Info_Dynamic_Array,
// 	     reflect.Type_Info_Pointer:
// 
//         index := index
//         value, _, ok := iterate_array(value, &index)
//         if ok do return value
// 
//     case reflect.Type_Info_Map:
//         
// 
//     }
// 
//     return nil
// }

/// I could do this for statically typed things, but in arrays and maps, it doesn't really make sense.
// save_state : struct {
//     operations  : strings.Builder,
//     // window's path "var1.var2.var3" constructed from parent_names
//     window_data : map [string] struct {
//         pos  : Vector,
//         size : Vector,
// 
//         scroll_pos : [enum{ LHS, RHS, BIN }] Vector,
//         lhs_cursor : int,
//     }
// }
// 
// MACROS : [enum { ENTER, LEAVE, NEW_WINDOW, EXIT_WINDOW }] string = {
//     .ENTER = "ENTER",           .LEAVE = "LEAVE", 
//     .NEW_WINDOW = "NEW_WINDOW", .EXIT_WINDOW = "EXIT_WINDOW"
// }
// 
// record :: proc(op: string, var: string) {
//     if (op == MACROS[.ENTER] || op == MACROS[.NEW_WINDOW]) && var == "" do return 
//     fmt.sbprintfln(&save_state.operations, "%s %s", op, var)
// }
// 
// try_playback :: proc() {
// 
// 
// }


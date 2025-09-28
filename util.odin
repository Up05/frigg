package main

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "base:runtime"
import "core:reflect"
import "core:strings"
import "core:time"
import "core:os"

import "core:math/rand"
import "core:math"

import "core:sys/linux"

Allocator :: mem.Allocator
Duration  :: time.Duration
Tick      :: time.Tick

now   :: time.tick_now
diff  :: time.tick_diff
sleep :: time.sleep
ms    :: time.Millisecond
cstr  :: strings.clone_to_cstring

eat :: proc(v: $T, e: any) -> T { return v }

// box <-> box collision detection (used for rendering text only when box is visible on screen)
AABB :: proc(a, a_size, b, b_size: Vector) -> bool {// {{{
    return  (a.x <= b.x + b_size.x && a.x + a_size.x >= b.x) &&
            (a.y <= b.y + b_size.y && a.y + a_size.y >= b.y)
}// }}}

intersects :: proc(a, b, bsize: Vector) -> bool {// {{{
    return  a.x >= b.x && a.x <= b.x + bsize.x && 
            a.y >= b.y && a.y <= b.y + bsize.y     
}// }}}

max_vector :: proc(a, b: Vector) -> Vector {// {{{
    return { max(a.x, b.x), max(a.y, b.y) }
}// }}}

make_arena :: proc() -> Allocator {// {{{
    arena := new(virtual.Arena)
    _ = virtual.arena_init_growing(arena)
    return virtual.arena_allocator(arena) 
}// }}}

// convert hex to [4] u8 (actually sdl.Color)
rgba :: proc(hex: u32) -> Color {// {{{
    r : u8 = u8( (hex & 0xFF000000) >> 24 )
    g : u8 = u8( (hex & 0x00FF0000) >> 16 )
    b : u8 = u8( (hex & 0x0000FF00) >>  8 )
    a : u8 = u8( (hex & 0x000000FF) )
    return { r, g, b, a }
}// }}}

soft_up_to :: proc(str: string, max_len: int) -> string {// {{{
    if len(str) <= max_len do return str

    curly := strings.last_index(str[:max_len], "{")
    if curly != -1 do return str[:curly]

    space := strings.last_index(str[:max_len], " ")
    if space == -1 do return str[:max_len]

    return str[:space]
}// }}}

ptr_add :: proc(a: rawptr, b: uintptr) -> rawptr {// {{{
    return rawptr(uintptr(a) + b)
}// }}}

to_any :: proc(ptr: rawptr, type: typeid) -> any {// {{{
    return transmute(any) runtime.Raw_Any { data = ptr, id = type }
}// }}}

back :: proc(array: [dynamic] $T) -> T {// {{{
    return array[len(array) - 1]
} // }}}

find :: proc "c" (array: [] $T, elem: T) -> int {// {{{
    for e, i in array do if e == elem do return i
    return -1
}// }}}

hsl_to_rgb :: proc(h, s, l: f32) -> (rgb: [4] f32) {// {{{
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

color_stack: [dynamic] f32
color_upper: bool = false
color_level: int  = 2
make_color_palette :: proc(window: ^Window) {// {{{
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

// ====================================================================

get_linked_len :: proc(array: any) -> (length: int, ok: bool) {// {{{
    raw_length := len_links[array.data]      or_return
    length      = reflect.as_int(raw_length) or_return
    return length, true

    // This, currently, is not necessary because of the static type asserts in link()
    // if reflect.is_pointer(type_info_of(raw_length.id)) {
    //     if !can_deref_small(raw_length) do return
    //     raw_length = reflect.deref(raw_length)
    // }
}// }}}

is_memory_safe :: proc(pointer: rawptr, size: int, allocator: Allocator) -> bool {// {{{
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

can_deref :: proc(window: ^Window, value: any) -> bool {// {{{
    can_access  := ODIN_OS == .Linux
    can_access &&= value.data != nil
    can_access &&= (^rawptr)(value.data)^ != nil
    is_invalid := !is_memory_safe(((^rawptr)(value.data))^, reflect.size_of_typeid(value.id), window.tmp_alloc)
    can_access &&= !is_invalid
    return can_access
}// }}}

can_deref_small :: proc(value: any) -> bool {// {{{
    can_access  := ODIN_OS == .Linux
    can_access &&= value.data != nil
    can_access &&= (^rawptr)(value.data)^ != nil
    is_invalid := !is_memory_safe(((^rawptr)(value.data))^, reflect.size_of_typeid(value.id), context.temp_allocator)
    can_access &&= !is_invalid
    return can_access
}// }}}

@(require_results)
iterate_array :: proc(val: any, it: ^int, max_len := max(int)) -> (elem: any, index: int, ok: bool) {// {{{
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

is_zero_array :: proc(array: any, max_len := max(int)) -> bool {// {{{
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

get_array_length :: proc(array: any) -> int {// {{{
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

get_array_stride :: proc(array: any) -> int {// {{{
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

are_we_wayland :: proc() -> bool {
    result := os.get_env("WAYLAND_DISPLAY")
    defer delete_string(result)
    return result != ""
}

// TRASH

/* // oklab my balls.
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







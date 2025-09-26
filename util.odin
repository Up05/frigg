package main

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "base:runtime"
import "core:reflect"
import "core:strings"
import "core:time"
import "core:os"

import "core:sys/linux"

Allocator :: mem.Allocator
Duration  :: time.Duration
Tick      :: time.Tick

now   :: time.tick_now
diff  :: time.tick_diff
sleep :: time.sleep
ms    :: time.Millisecond
cstr  :: strings.clone_to_cstring

// box <-> box collision detection (used for rendering text only when box is visible on screen)
AABB :: proc(a, a_size, b, b_size: Vector) -> bool {
    return  (a.x <= b.x + b_size.x && a.x + a_size.x >= b.x) &&
            (a.y <= b.y + b_size.y && a.y + a_size.y >= b.y)
}

intersects :: proc(a, b, bsize: Vector) -> bool {
    return  a.x >= b.x && a.x <= b.x + bsize.x && 
            a.y >= b.y && a.y <= b.y + bsize.y     
}

max_vector :: proc(a, b: Vector) -> Vector {
    return { max(a.x, b.x), max(a.y, b.y) }
}

make_arena :: proc() -> Allocator {
    arena := new(virtual.Arena)
    _ = virtual.arena_init_growing(arena)
    return virtual.arena_allocator(arena) 
}

// convert hex to [4] u8 (actually sdl.Color)
rgba :: proc(hex: u32) -> Color {
    r : u8 = u8( (hex & 0xFF000000) >> 24 )
    g : u8 = u8( (hex & 0x00FF0000) >> 16 )
    b : u8 = u8( (hex & 0x0000FF00) >>  8 )
    a : u8 = u8( (hex & 0x000000FF) )
    return { r, g, b, a }
}

find :: proc "c" (array: [] $T, elem: T) -> int {
    for e, i in array do if e == elem do return i
    return -1
}

// ====================================================================

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

@(require_results)
iterate_array :: proc(val: any, it: ^int) -> (elem: any, index: int, ok: bool) {// {{{
	if val == nil || it == nil {
		return
	}
    
	ti := reflect.type_info_base(type_info_of(val.id))
	#partial switch info in ti.variant {
    case reflect.Type_Info_Enumerated_Array:
		if it^ < info.count {
			elem.data = rawptr(uintptr(val.data) + uintptr(it^ * info.elem_size))
			elem.id = info.elem.id
			ok = true
			index = it^
			it^ += 1
		}
    case reflect.Type_Info_Simd_Vector:
		if it^ < info.count {
			elem.data = rawptr(uintptr(val.data) + uintptr(it^ * info.elem_size))
			elem.id = info.elem.id
			ok = true
			index = it^
			it^ += 1
		}
    case reflect.Type_Info_Matrix:
		if it^ < info.column_count * info.row_count {
			elem.data = rawptr(uintptr(val.data) + uintptr(it^ * info.elem_size))
			elem.id = info.elem.id
			ok = true
			index = it^
			it^ += 1
		}
    case:
        return reflect.iterate_array(val, it)
    }

    return
}// }}}

is_zero_array :: proc(array: any) -> bool {// {{{
    all_zeros := true
    iterator: int
    for item, i in iterate_array(array, &iterator) {
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

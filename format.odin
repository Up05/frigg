package main

import "core:fmt"
import "core:mem"
import "core:strings"
import "base:runtime"
import "core:reflect"
import "core:hash/xxhash"

lhs_clear :: proc(window: ^Window) {// {{{
    clear(&window.lhs.names)      
    clear(&window.lhs.types)      
    clear(&window.lhs.small_values)
    clear(&window.lhs.real_values)
}// }}}
lhs_add :: proc(window: ^Window, name, type, value: string, real_value: any, allocator: Allocator) {// {{{
    append(&window.lhs.names,        strings.clone(name,  allocator))
    append(&window.lhs.types,        strings.clone(type,  allocator))
    append(&window.lhs.small_values, strings.clone(value, allocator))
    append(&window.lhs.real_values,  real_value)
}// }}}
lhs_comment :: proc(window: ^Window, comment: string) {// {{{
    if len(window.lhs.small_values) == 0 do return
    window.lhs.small_values[0] = strings.clone(comment, window.lhs_alloc)
}// }}}

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
        builder := strings.builder_make(allocator = window.alloc)

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
        builder := strings.builder_make(allocator = window.alloc)
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
        builder := strings.builder_make(allocator = window.alloc)

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
        builder := strings.builder_make(allocator = window.alloc)

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
        builder := strings.builder_make(allocator = window.alloc)
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
        builder := strings.builder_make(allocator = window.alloc)
    
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

format_value_binary :: proc(window: ^Window, value: any, level := 0) -> string {// {{{
    if value.data == nil do return "??"
    if level > 15 do return "<self>"
    text : string

    the_type := reflect.type_info_base(type_info_of(value.id))
    switch real_type in the_type.variant {
    case reflect.Type_Info_Any:              text = format_value_small(window, value, level + 1)

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
    case reflect.Type_Info_Multi_Pointer:    text = format_pointer(window, value, level) 

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

HashState :: struct {
    window : ^Window,
    hash   : ^xxhash.XXH32_state,
}

update_hash ::  xxhash.XXH32_update 
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

hash_string :: proc(str: string) -> u32 {// {{{
    return xxhash.XXH32(transmute([] byte) str)
}// }}}

hash_any_string :: proc(value: any) -> u32 {// {{{
    return xxhash.XXH32(transmute([] byte) eat(reflect.as_string(value)))
}// }}} 

update_lhs :: proc(window: ^Window) {// {{{
    if !window.refresh && window.frame % (TARGET_FPS / 6) != 0 do return
    window.lhs.hidden = false
    lhs_clear(window)
    free_all(window.lhs_alloc)
    value := window.lhs.viewed
    lhs_add(window, window.lhs.parent_names[len(window.lhs.parent_names) - 1], "", "", nil, window.lhs_alloc)

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
                    name = strings.clone(field.name, window.alloc),
                    type = soft_up_to(fmt.aprint(field.type, allocator = window.alloc), 24),
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
                    name  = strings.clone(result.name, window.alloc),
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
        lhs_add(window, "", "", "", nil, window.lhs_alloc) 
        window.lhs.hidden = true
    }
}// }}}

update_rhs :: proc(window: ^Window) {// {{{
    if !window.refresh && window.frame % (TARGET_FPS / 6) != 0 do return
    free_all(window.rhs_alloc)

    cursor := window.lhs.cursor
    field  := window.rhs.viewed
    value  := field.value

    window.rhs.name = strings.clone(field.name, window.rhs_alloc)
    window.rhs.type = strings.clone(field.type, window.rhs_alloc)
    window.rhs.value = strings.clone(format_value_big(window, value), window.rhs_alloc)
    window.rhs.binary = strings.clone(format_value_binary(window, value), window.rhs_alloc)   

}// }}}




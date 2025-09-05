package main

import "core:fmt"
import "core:mem"
import "core:math"
import "core:slice"
import "core:strings"
import "base:runtime"
import "core:reflect"
import "core:hash/xxhash"

test : struct {
    a: [enum{ A, B, C}] int,
    b: #simd [8] f16,
    c: matrix [3,3] int,
    d: union { int, f32, string },
    e: map [string] f32,
    f: int,
    g: string,
    h: ^int,
    i: cstring,
    j: [256] int,
    k: struct {
        l, m, n: f32,
        o, p, r: [4] bool
    }

}

lhs_clear :: proc() {
    clear(&window.lhs.names)      
    clear(&window.lhs.types)      
    clear(&window.lhs.small_values)
}

lhs_add :: proc(name, type, value: string, allocator: Allocator) {// {{{
    append(&window.lhs.names,        strings.clone(name,  allocator))
    append(&window.lhs.types,        strings.clone(type,  allocator))
    append(&window.lhs.small_values, strings.clone(value, allocator))
}// }}}

format_value_small :: proc(value: any, level := 0) -> string {// {{{
    if value.data == nil do return "<nil>"
    if level > 15 do return "<self>"

    text : string

    the_type := reflect.type_info_base(type_info_of(value.id))
    switch real_type in the_type.variant {
    case reflect.Type_Info_Any:              text = format_value_small(value, level + 1)

    case reflect.Type_Info_Named:            text = format_basic(value)
    case reflect.Type_Info_Integer:          text = format_basic(value) 
    case reflect.Type_Info_Float:            text = format_basic(value) 
    case reflect.Type_Info_Complex:          text = format_basic(value) 
    case reflect.Type_Info_Quaternion:       text = format_basic(value) 
    case reflect.Type_Info_Boolean:          text = format_basic(value) 
    case reflect.Type_Info_Type_Id:          text = format_basic(value)
    case reflect.Type_Info_Enum:             text = format_basic(value) 
    case reflect.Type_Info_Bit_Set:          text = format_basic(value) 
    case reflect.Type_Info_Bit_Field:        text = format_basic(value) 
    case reflect.Type_Info_Procedure:        text = format_basic("proc")

    case reflect.Type_Info_Rune:             text = format_string(value)
    case reflect.Type_Info_String:           text = format_string(value) 

    case reflect.Type_Info_Pointer:          text = format_pointer(value) 
    case reflect.Type_Info_Soa_Pointer:      text = format_pointer(value) 
    case reflect.Type_Info_Multi_Pointer:    text = format_pointer(value) 

    case reflect.Type_Info_Array:            text = format_array(value) 
    case reflect.Type_Info_Enumerated_Array: text = format_array(value)
    case reflect.Type_Info_Dynamic_Array:    text = format_array(value)
    case reflect.Type_Info_Slice:            text = format_array(value) 
    case reflect.Type_Info_Simd_Vector:      text = format_array(value) 
    case reflect.Type_Info_Matrix:           text = format_array(value) 

    case reflect.Type_Info_Struct:           text = format_struct(value)
    case reflect.Type_Info_Union:            text = format_union(value)
    case reflect.Type_Info_Map:              text = format_map(value)
    case reflect.Type_Info_Parameters:       text = "proc parameters"
    }

    format_basic :: proc(value: any) -> string {// {{{
        return fmt.aprint(value, allocator = window.tmp_alloc)
    }// }}}

    format_string :: proc(value: any) -> string {// {{{
        return fmt.aprintf("%q", value, allocator = window.tmp_alloc)
    }// }}}

    format_pointer :: proc(value: any) -> string {// {{{
        return fmt.aprintf("%p", value, allocator = window.tmp_alloc)
    }// }}}

    format_array :: proc(array: any) -> string {// {{{
        builder := strings.builder_make(allocator = window.alloc)

        length := get_array_length(array)

        if length == 0 {
            strings.write_string(&builder, "[]")
            return strings.to_string(builder)
        }

        if is_zero_array(array) {
            fmt.sbprintf(&builder, "[0*%d]", length)
            return strings.to_string(builder)
        }

        strings.write_string(&builder, "[ ")

        iterator: int
        for item, i in iterate_array(array, &iterator) {
            formatted := format_value_small(item)
            if len(formatted) + len(builder.buf) > window.small_value_limit {
                strings.write_string(&builder, "..")
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

    format_struct :: proc(value: any) -> string {// {{{
        builder := strings.builder_make(allocator = window.alloc)
        strings.write_string(&builder, "{ ")

        fields := reflect.struct_fields_zipped(value.id) 
        for field, i in fields {
            member := reflect.struct_field_value(value, field)
            formatted := format_value_small(member)
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

    format_union :: proc(value: any) -> string {// {{{
        builder := strings.builder_make(window.tmp_alloc)
        fmt.sbprintf(&builder, "(%v) ", reflect.union_variant_type_info(value))
        strings.write_string(&builder, format_value_small(reflect.get_union_variant(value)))
        return strings.to_string(builder)
    }// }}}

    format_map :: proc(value: any) -> string {// {{{
        builder := strings.builder_make(window.tmp_alloc)
        length  := get_array_length(value)
        if length == 0 do return "[]"

        strings.write_string(&builder, "[ ")

        overall_length: int
        pairs := make([dynamic] string, 0, length, window.tmp_alloc)

        iterator: int
        for k, v in reflect.iterate_map(value, &iterator) {
            key   := format_value_small(k)
            value := format_value_small(v)

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

format_value_big :: proc(value: any, level := 0) -> string {// {{{
    if value.data == nil do return "<nil>"
    if level > 15 do return "<self>"
    text : string

    the_type := reflect.type_info_base(type_info_of(value.id))
    switch real_type in the_type.variant {
    case reflect.Type_Info_Any:              text = format_value_small(value, level + 1)

    case reflect.Type_Info_Named:            text = format_basic(value)
    case reflect.Type_Info_Float:            text = format_basic(value) 
    case reflect.Type_Info_Complex:          text = format_basic(value) 
    case reflect.Type_Info_Quaternion:       text = format_basic(value) 
    case reflect.Type_Info_Boolean:          text = format_basic(value) 
    case reflect.Type_Info_Type_Id:          text = format_basic(value)
    case reflect.Type_Info_Enum:             text = format_basic(value) 
    case reflect.Type_Info_Bit_Set:          text = format_basic(value) 
    case reflect.Type_Info_Bit_Field:        text = format_basic(value) 
    case reflect.Type_Info_Procedure:        text = format_basic("proc")

    case reflect.Type_Info_Integer:          text = format_integer(value) 
    case reflect.Type_Info_Rune:             text = format_string(value)
    case reflect.Type_Info_String:           text = format_string(value) 

    case reflect.Type_Info_Pointer:          text = format_pointer(value, level) 
    case reflect.Type_Info_Soa_Pointer:      text = format_pointer(value, level) 
    case reflect.Type_Info_Multi_Pointer:    text = format_pointer(value, level) 

    case reflect.Type_Info_Array:            text = format_array(value) 
    case reflect.Type_Info_Enumerated_Array: text = format_array(value)
    case reflect.Type_Info_Dynamic_Array:    text = format_array(value)
    case reflect.Type_Info_Slice:            text = format_array(value) 
    case reflect.Type_Info_Simd_Vector:      text = format_array(value) 
    case reflect.Type_Info_Matrix:           text = format_matrix(value) 

    case reflect.Type_Info_Struct:           text = format_struct(value)
    case reflect.Type_Info_Union:            text = format_union(value)
    case reflect.Type_Info_Map:              text = format_map(value)
    case reflect.Type_Info_Parameters:       text = "proc parameters"
    }

    format_basic :: proc(value: any) -> string {// {{{
        return fmt.aprint(value, allocator = window.tmp_alloc)
    }// }}}

    format_integer :: proc(value: any) -> string {// {{{
        return fmt.aprintf("dec: %d\nhex: %x\noct: %o\nbin: %08b", value, value, value, value, allocator = window.tmp_alloc)
    }// }}}

    format_string :: proc(value: any) -> string {// {{{
        return fmt.aprintf("%q \n===\n%s\n===", value, value, allocator = window.tmp_alloc)
    }// }}}

    format_pointer :: proc(value: any, level := 0) -> string {// {{{
        can_access  := ODIN_OS == .Linux
        can_access &&= value.data != nil
        is_invalid := !is_memory_safe(((^rawptr)(value.data))^, reflect.size_of_typeid(value.id), window.tmp_alloc)
        can_access &&= !is_invalid
        
        if is_invalid  do return fmt.aprintf("%p\n<invalid pointer>", value, allocator = window.tmp_alloc)
        if !can_access do return fmt.aprintf("%p", value, allocator = window.tmp_alloc)
        builder := strings.builder_make(window.tmp_alloc)    
        fmt.sbprintf(&builder, "%p\n", value)
        
        strings.write_string(&builder, format_value_big(reflect.deref(value), level + 1))

        return strings.to_string(builder)
    }// }}}

    format_array :: proc(array: any) -> string {// {{{
        builder := strings.builder_make(allocator = window.alloc)

        length := get_array_length(array)

        if length == 0 {
            strings.write_string(&builder, "[]")
            return strings.to_string(builder)
        }

        if is_zero_array(array) {
            fmt.sbprintf(&builder, "[0*%d]", length)
            return strings.to_string(builder)
        }

        strings.write_string(&builder, "[ ")

        iterator: int
        for item, i in iterate_array(array, &iterator) {
            formatted := format_value_small(item)
            if len(formatted) + len(builder.buf) > window.small_value_limit {
                strings.write_string(&builder, "..")
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

    format_matrix :: proc(array: any) -> string {// {{{
        SPACE : [256] rune = ' '
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
                
                if is_float do fmt.sbprintf(&builder, "%s %.2f", SPACE[:longest[i] - lengths[index]], value, )
                else do        fmt.sbprintf(&builder, "%s %v",   SPACE[:longest[i] - lengths[index]], value, )
            }
            strings.write_rune(&builder, '\n')
        }
    
        return strings.to_string(builder)
    }// }}}

    format_struct :: proc(value: any) -> string {// {{{
        builder := strings.builder_make(allocator = window.alloc)
    
        fields := reflect.struct_fields_zipped(value.id) 
        members := make([] string, len(fields), window.tmp_alloc)
    
        for field, i in fields {
            member := to_any(ptr_add(value.data, field.offset), field.type.id)
            members[i] = fmt.aprint(field.name, "=", format_value_small(member))
        }
        
        for member in members {
            fmt.sbprintln(&builder, member)
        }
    
        return strings.to_string(builder)
    }// }}}

    format_union :: proc(value: any) -> string {// {{{
        builder := strings.builder_make(window.tmp_alloc)
        fmt.sbprintfln(&builder, "(%v)", reflect.union_variant_type_info(value))
        strings.write_string(&builder, format_value_big(reflect.get_union_variant(value)))
        return strings.to_string(builder)
    }// }}}

    format_map :: proc(value: any) -> string {// {{{
        builder := strings.builder_make(window.tmp_alloc)
        length  := get_array_length(value)
        if length == 0 do return "[ empty map ]"

        pairs := make([dynamic] string, 0, length, window.tmp_alloc)

        iterator: int
        for k, v in reflect.iterate_map(value, &iterator) {
            key   := format_value_small(k)
            value := format_value_small(v)

            append(&pairs, strings.concatenate({ key, " = " , value }, window.tmp_alloc))
        }

        slice.sort(pairs[:])

        for pair, i in pairs {
            strings.write_string(&builder, pair)
            if i != len(pairs) - 1 do strings.write_string(&builder, ", ")
        }

        return strings.to_string(builder)
    }// }}}

    return text
}// }}}

format_value_binary :: proc(value: any, level := 0) -> string {// {{{
    if value.data == nil do return "??"
    if level > 15 do return "<self>"
    text : string

    the_type := reflect.type_info_base(type_info_of(value.id))
    switch real_type in the_type.variant {
    case reflect.Type_Info_Any:              text = format_value_small(value, level + 1)

    case reflect.Type_Info_Named:            text = format_basic(value)
    case reflect.Type_Info_Float:            text = format_basic(value) 
    case reflect.Type_Info_Complex:          text = format_basic(value) 
    case reflect.Type_Info_Quaternion:       text = format_basic(value) 
    case reflect.Type_Info_Boolean:          text = format_basic(value) 
    case reflect.Type_Info_Type_Id:          text = format_basic(value)
    case reflect.Type_Info_Enum:             text = format_basic(value) 
    case reflect.Type_Info_Bit_Set:          text = format_basic(value) 
    case reflect.Type_Info_Bit_Field:        text = format_basic(value) 
    case reflect.Type_Info_Procedure:        text = format_basic(value)
    case reflect.Type_Info_Integer:          text = format_basic(value) 
    case reflect.Type_Info_Rune:             text = format_basic(value)
    case reflect.Type_Info_Soa_Pointer:      text = format_basic(value) 
    case reflect.Type_Info_Array:            text = format_basic(value) 
    case reflect.Type_Info_Enumerated_Array: text = format_basic(value)
    case reflect.Type_Info_Simd_Vector:      text = format_basic(value) 
    case reflect.Type_Info_Matrix:           text = format_basic(value) 
    case reflect.Type_Info_Union:            text = format_basic(value)
    case reflect.Type_Info_Struct:           text = format_basic(value)
    case reflect.Type_Info_Parameters:       text = format_basic(value)

    case reflect.Type_Info_Pointer:          text = format_pointer(value, level) 
    case reflect.Type_Info_Multi_Pointer:    text = format_pointer(value, level) 

    case reflect.Type_Info_Dynamic_Array:    text = format_array(value)
    case reflect.Type_Info_Slice:            text = format_array(value) 
    case reflect.Type_Info_String:           text = format_array(value) 

    case reflect.Type_Info_Map:              text = format_map(value)
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

    format_bytes :: proc(mem: [] byte) -> string { // {{{
        builder := strings.builder_make(window.tmp_alloc)

        for b in mem {
            write_byte(&builder, b)
        }

        strings.write_string(&builder, "\n\n")
        return strings.to_string(builder)
        
    }// }}}

    format_many_bytes :: proc(list: [][]byte) -> string { // {{{
        builder := strings.builder_make(window.tmp_alloc)

        for block in list {
            for b in block {
                write_byte(&builder, b)
            }
            strings.write_string(&builder, "\n\n")
        }
        return strings.to_string(builder)
    
    }// }}}

    format_basic :: proc(value: any) -> string { // {{{
        data := mem.any_to_bytes(value)
        return format_bytes(data)
    }// }}}

    format_pointer :: proc(value: any, level: int) -> string { // {{{
        a := mem.any_to_bytes(value)
        
        can_access  := ODIN_OS == .Linux
        can_access &&= value.data != nil
        can_access &&= is_memory_safe(((^rawptr)(value.data))^, reflect.size_of_typeid(value.id), window.tmp_alloc)
        b := mem.any_to_bytes(reflect.deref(value)) if can_access else {}

        return format_many_bytes({ a, b })
    } // }}} 

    format_array :: proc(value: any) -> string { // {{{
        a := mem.any_to_bytes(value)

        start := ((^rawptr)(value.data))^
        size  := get_array_length(value) * get_array_stride(value)
        b := (transmute([^]byte) start)[:size]

        can_access  := ODIN_OS == .Linux
        can_access &&= value.data != nil
        can_access &&= is_memory_safe(((^rawptr)(value.data))^, reflect.size_of_typeid(value.id), window.tmp_alloc)

        return format_many_bytes({ a, b if can_access else {} })
    } // }}} 

    format_map :: proc(value: any) -> string {// {{{
        // TODO
        return format_basic(value)
    }// }}}

    return text
}// }}}

HashState   :: ^xxhash.XXH32_state
update_hash ::  xxhash.XXH32_update 
hash :: proc(value: any, state: HashState = nil, level := 0) -> u32 {// {{{
    original_state := state
    state := state
    if state == nil do state, _ = xxhash.XXH32_create_state(window.tmp_alloc) 

    if level > 4 {
        assert(original_state != nil)
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
        update_hash(state, mem.any_to_bytes(value))
    }

    hash_pointer :: proc(state: HashState, value: any, level: int) {
        can_access  := ODIN_OS == .Linux
        can_access &&= (^rawptr)(value.data) != nil
        can_access &&= is_memory_safe(((^rawptr)(value.data))^, reflect.size_of_typeid(value.id), window.tmp_alloc)

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

    if original_state == nil do return xxhash.XXH32_digest(state)
    else do return 0
}// }}}



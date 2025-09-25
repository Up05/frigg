package main

import "core:fmt"

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

main :: proc() {

    test.a[.B] = 4
    test.b = 4
    test.d = "str"

    for i in 0..<64 { test.e[fmt.aprintf("test key #%d", i)] = 3.14159 * f32(i) }
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
    watch(test, &window)

    // start_rendering()


}

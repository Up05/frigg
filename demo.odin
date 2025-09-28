package main

import "core:fmt"

test : struct {
    z: [2048] int,
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
        o, p, r: [4] bool,
        big: [1024] int
    },
    m: ^struct {
        n: ^struct {
            o: int,
        }
    },
    n: int,
    o: [^] int,
    p: any,
}

main :: proc() {

    test.a[.B] = 4
    test.b = 4
    test.d = "str"

    for i in 0..<640 { test.e[fmt.aprintf("test key #%d", i)] = 3.14159 * f32(i) }
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
    test.m = new(type_of(test.m^))
    // test.m.n = new(type_of(test.m.n^))

    link(test.o, &test.n)
    link(test.z, &test.n)
    unlink(test.z)

    ignore("a", "test key #103")

    test.n = 5
    test.o = make([^] int, 5)
    for i in 0..<5 do test.o[i] = i * 3

    test.p = test.c

    window := watch(test, false)

    for !render_frame_for_all() { test.z[1] += 1 }


}

/*
    - handle SIMD stuff EVENTUALLY!
*/



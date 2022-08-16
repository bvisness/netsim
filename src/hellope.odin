package main

import "core:fmt"
import "core:mem"
import "core:runtime"



main :: proc() {
    fmt.println("Hellope")
}

@export
foo :: proc "contextless" (s: string) {
    context = runtime.default_context()
    fmt.println("foo", s)
    log(4)
}

@export
tempAllocate :: proc(n: int) -> rawptr {
    return mem.alloc(n, mem.DEFAULT_ALIGNMENT, context.temp_allocator)
}

foreign import "js"

foreign js {
    log :: proc(x: any) ---
}

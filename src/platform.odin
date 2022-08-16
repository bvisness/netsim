package main

@export
mouse_move :: proc "contextless" (x, y: int) {}

@export
mouse_down :: proc "contextless" (x, y: int) {}

@export
mouse_up :: proc "contextless" (x, y: int) {}

@export
scroll :: proc "contextless" (x, y: int) {}

@export
key_down :: proc "contextless" (key: int) {}

@export
key_up :: proc "contextless" (key: int) {}

@export
text_input :: proc "contextless" () {}

@export
blur :: proc "contextless" () {}

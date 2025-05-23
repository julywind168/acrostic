import gleam/erlang/charlist.{type Charlist}
import gleam/int

/// logic shift right
pub fn lsr(n: Int, bits: Int) -> Int {
  int.bitwise_shift_right(n, bits)
}

/// logic shift left
pub fn lsl(n: Int, bits: Int) -> Int {
  int.bitwise_shift_left(n, bits)
}

@external(erlang, "os", "cmd")
fn do_cmd(_: Charlist) -> String {
  panic
}

@target(erlang)
pub fn cmd(command: String) -> String {
  do_cmd(charlist.from_string(command))
}

@target(javascript)
pub fn cmd(_: String) -> String {
  panic
}

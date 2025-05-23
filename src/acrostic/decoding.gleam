import acrostic/wire.{type WireType}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result

pub type Key {
  Key(field_number: Int, wire_type: WireType)
}

const wire_type_mask = 0b111

pub fn read_key(binary: BitArray) -> Result(#(Key, BitArray), String) {
  use r <- result.try(read_varint_bytes(binary))
  use n <- result.try(decode_to_int(r.readed))
  let wire_type = int.bitwise_and(n, wire_type_mask)
  let field_number = int.bitwise_shift_right(n - wire_type, 3)
  use wire_type <- result.try(wire.from_int(wire_type))
  Ok(#(Key(field_number, wire_type), r.rest))
}

pub fn to_varint(binary: BitArray, acc: Int) -> Int {
  reverted_to_variant(binary, acc, bit_array.byte_size(binary))
}

fn reverted_to_variant(binary: BitArray, acc: Int, sum_len: Int) -> Int {
  let len = bit_array.byte_size(binary)
  case binary {
    <<byte, rest:bits>> -> {
      reverted_to_variant(
        rest,
        int.bitwise_shift_left(
          int.bitwise_and(byte, 0x7F),
          { sum_len - len } * 7,
        )
          + acc,
        sum_len,
      )
    }
    _ -> acc
  }
}

pub fn decode_to_int(binary: BitArray) -> Result(Int, String) {
  Ok(to_varint(binary, 0))
}

pub fn decode_to_bool(binary: BitArray) -> Result(Bool, String) {
  case to_varint(binary, 0) {
    0 -> Ok(False)
    1 -> Ok(True)
    _ ->
      Error("Decode to bool failed: " <> bit_array.base64_encode(binary, False))
  }
}

pub fn decode_to_i32(binary: BitArray) -> Result(Float, String) {
  case binary {
    <<f:float-little-size(32)>> -> Ok(f)
    _ ->
      Error("Decode to i32 failed: " <> bit_array.base64_encode(binary, False))
  }
}

pub fn decode_to_i64(binary: BitArray) -> Result(Float, String) {
  case binary {
    <<f:float-little-size(64)>> -> Ok(f)
    _ ->
      Error("Decode to i64 failed: " <> bit_array.base64_encode(binary, False))
  }
}

pub fn decode_to_string(binary: BitArray) -> Result(String, String) {
  case binary |> bit_array.to_string {
    Ok(s) -> Ok(s)
    Error(_) ->
      Error(
        "Decode to string failed: " <> bit_array.base64_encode(binary, False),
      )
  }
}

pub type BasicDecoder(value) =
  fn(BitArray) -> Result(value, String)

pub type FieldDecoder(value) {
  FieldDecoder(wire_type: WireType, decode: BasicDecoder(value))
}

pub fn decode_field(
  binary: BitArray,
  wire_type: WireType,
  decoder: FieldDecoder(a),
) -> Result(#(a, BitArray), String) {
  case wire_type {
    wire.VarInt -> {
      use r <- result.try(read_varint_bytes(binary))
      use n <- result.try(decoder.decode(r.readed))
      Ok(#(n, r.rest))
    }
    wire.I64 -> {
      use r <- result.try(read_some_bytes(binary, 8))
      use n <- result.try(decoder.decode(r.readed))
      Ok(#(n, r.rest))
    }
    wire.I32 -> {
      use r <- result.try(read_some_bytes(binary, 4))
      use n <- result.try(decoder.decode(r.readed))
      Ok(#(n, r.rest))
    }
    wire.Len -> {
      // length
      use r <- result.try(read_varint_bytes(binary))
      use l <- result.try(decode_to_int(r.readed))
      // value
      use r <- result.try(read_some_bytes(r.rest, l))
      use v <- result.try(decoder.decode(r.readed))
      Ok(#(v, r.rest))
    }
  }
}

pub fn decode_repeated_field(
  binary: BitArray,
  wire_type: WireType,
  decoder: FieldDecoder(a),
) -> Result(#(List(a), BitArray), String) {
  case wire_type {
    wire.VarInt -> {
      use r <- result.try(read_varint_bytes(binary))
      use n <- result.try(decoder.decode(r.readed))
      Ok(#([n], r.rest))
    }
    wire.I64 -> {
      use r <- result.try(read_some_bytes(binary, 8))
      use n <- result.try(decoder.decode(r.readed))
      Ok(#([n], r.rest))
    }
    wire.I32 -> {
      use r <- result.try(read_some_bytes(binary, 4))
      use n <- result.try(decoder.decode(r.readed))
      Ok(#([n], r.rest))
    }
    wire.Len -> {
      // length
      use r <- result.try(read_varint_bytes(binary))
      use l <- result.try(decode_to_int(r.readed))
      // value
      use r <- result.try(read_some_bytes(r.rest, l))

      case decoder.wire_type == wire.Len {
        // string | struct
        True -> {
          use v <- result.try(decoder.decode(r.readed))
          Ok(#([v], r.rest))
        }
        // packed numbers
        False -> {
          use numbers <- result.try(
            decode_packed_numbers(r.readed, decoder, []),
          )
          Ok(#(list.reverse(numbers), r.rest))
        }
      }
    }
  }
}

fn decode_packed_numbers(
  binary: BitArray,
  decoder: FieldDecoder(a),
  results: List(a),
) -> Result(List(a), String) {
  case binary {
    <<>> -> Ok(results)
    _ -> {
      use r <- result.try({
        case decoder.wire_type {
          wire.VarInt -> read_varint_bytes(binary)
          wire.I64 -> read_some_bytes(binary, 8)
          wire.I32 -> read_some_bytes(binary, 4)
          _ -> Error("Decode packed numbers failed: invalid wire_type")
        }
      })
      use n <- result.try(decoder.decode(r.readed))
      decode_packed_numbers(r.rest, decoder, [n, ..results])
    }
  }
}

// basic field decoders
pub const int_field_decoder = FieldDecoder(
  wire_type: wire.VarInt,
  decode: decode_to_int,
)

pub const bool_field_decoder = FieldDecoder(
  wire_type: wire.VarInt,
  decode: decode_to_bool,
)

pub const i64_field_decoder = FieldDecoder(
  wire_type: wire.I64,
  decode: decode_to_i64,
)

pub const i32_field_decoder = FieldDecoder(
  wire_type: wire.I32,
  decode: decode_to_i32,
)

pub const string_field_decoder = FieldDecoder(
  wire_type: wire.Len,
  decode: decode_to_string,
)

// utils
type ReadResult {
  ReadResult(readed: BitArray, rest: BitArray)
}

fn read_some_bytes(binary: BitArray, length: Int) -> Result(ReadResult, String) {
  case bit_array.byte_size(binary) >= length {
    True -> {
      let readed =
        bit_array.slice(binary, 0, length) |> result.lazy_unwrap(fn() { panic })
      let rest =
        bit_array.slice(binary, length, bit_array.byte_size(binary) - length)
        |> result.lazy_unwrap(fn() { panic })
      Ok(ReadResult(readed, rest))
    }
    False -> Error("Read bytes failed")
  }
}

fn read_varint_bytes(binary: BitArray) -> Result(ReadResult, String) {
  read_varint_byte(binary, <<>>)
}

fn read_varint_byte(binary: BitArray, r: BitArray) -> Result(ReadResult, String) {
  case binary {
    <<byte, binary:bits>> -> {
      let r = <<r:bits, byte:size(8)>>
      case int.bitwise_and(byte, 0x80) {
        0 -> {
          case bit_array.byte_size(r) > 10 {
            True -> Error("Invalid varint, over 10 bytes")
            False -> Ok(ReadResult(r, binary))
          }
        }
        _ -> read_varint_byte(binary, r)
      }
    }
    _ -> Error("Invalid ended of varint")
  }
}

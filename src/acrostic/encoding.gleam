import acrostic/internal/helper.{lsr}
import acrostic/wire.{type WireType}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/order

pub type BasicEncoder(value) =
  fn(value) -> BitArray

pub fn encode_varint(n: Int) -> BitArray {
  case int.compare(n, 0x80) {
    order.Gt -> {
      bit_array.append(
        <<{ n |> int.bitwise_and(0x7F) |> int.bitwise_or(0x80) }>>,
        encode_varint(lsr(n, 7)),
      )
    }
    _ -> <<int.bitwise_and(n, 0x7F)>>
  }
}

pub fn encode_bool(b: Bool) -> BitArray {
  encode_varint({
    case b {
      True -> 1
      False -> 0
    }
  })
}

pub fn encode_i32(n: Float) {
  <<n:float-little-size(32)>>
}

pub fn encode_i64(n: Float) {
  <<n:float-little-size(64)>>
}

pub fn encode_string(s: String) {
  <<s:utf8>>
}

pub type FieldEncoder(value) {
  FieldEncoder(wire_type: WireType, encode: BasicEncoder(value))
}

pub fn encode_field(
  field_num: Int,
  value: value,
  encoder: FieldEncoder(value),
) -> BitArray {
  let key = encode_key(field_num, encoder.wire_type |> wire.to_int)
  let body = encoder.encode(value)
  let length = case encoder.wire_type == wire.Len {
    True -> encode_varint(bit_array.byte_size(body))
    False -> <<>>
  }
  key |> bit_array.append(length) |> bit_array.append(body)
}

// list field
pub fn encode_repeated_field(
  field_num: Int,
  list: List(value),
  encoder: FieldEncoder(value),
) -> BitArray {
  case list {
    [] -> <<>>
    _ -> {
      let packed = encoder.wire_type != wire.Len
      case packed {
        True -> {
          let key = encode_key(field_num, wire.Len |> wire.to_int)
          let body =
            list
            |> list.map(fn(v) { encoder.encode(v) })
            |> list.fold(<<>>, bit_array.append)
          let length = encode_varint(bit_array.byte_size(body))

          key |> bit_array.append(length) |> bit_array.append(body)
        }
        False -> {
          list
          |> list.map(fn(v) { encode_field(field_num, v, encoder) })
          |> list.fold(<<>>, bit_array.append)
        }
      }
    }
  }
}

fn encode_key(field_number: Int, wire_type: Int) -> BitArray {
  let key =
    field_number |> int.bitwise_shift_left(3) |> int.bitwise_or(wire_type)
  encode_varint(key)
}

// basic field encoders
pub const int_field_encoder = FieldEncoder(
  wire_type: wire.VarInt,
  encode: encode_varint,
)

pub const bool_field_encoder = FieldEncoder(
  wire_type: wire.VarInt,
  encode: encode_bool,
)

pub const i64_field_encoder = FieldEncoder(
  wire_type: wire.I64,
  encode: encode_i64,
)

pub const i32_field_encoder = FieldEncoder(
  wire_type: wire.I32,
  encode: encode_i32,
)

pub const string_field_encoder = FieldEncoder(
  wire_type: wire.Len,
  encode: encode_string,
)

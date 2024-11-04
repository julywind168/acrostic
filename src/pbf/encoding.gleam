import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import pbf/helper.{lsr}

// int32, int64, uint32, uint64, bool, enum
pub const varint_type = 0

// fixed64, sfixed64, double
pub const i64_type = 1

// string, bytes, embedded messages, repeated fields
pub const len_type = 2

// deprecated
// pub const sgroup_type = 3
// pub const egroup_type = 4

// fixed32, sfixed32, float
pub const i32_type = 5

// const mask32bit = 0xFFFFFFFF

const mask64bit = 0xFFFFFFFFFFFFFFFF

pub fn encode_key(
  buf: BitArray,
  field_number field_number: Int,
  wire_type wire_type: Int,
) -> BitArray {
  let key =
    field_number |> int.bitwise_shift_left(3) |> int.bitwise_or(wire_type)
  buf |> bit_array.append(encode_varint(key))
}

pub fn encode_i64(n: Float) -> BitArray {
  <<n:float-little-size(64)>>
}

pub fn encode_i32(n: Float) -> BitArray {
  <<n:float-little-size(32)>>
}

pub fn encode_varint(n: Int) -> BitArray {
  case int.bitwise_and(n, mask64bit) {
    x if x >= 0x80 -> {
      bit_array.append(
        <<{ n |> int.bitwise_and(0x7F) |> int.bitwise_or(0x80) }>>,
        encode_varint(lsr(x, 7)),
      )
    }
    x -> <<int.bitwise_and(x, 0x7F)>>
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

pub fn encode_string(s: String) -> BitArray {
  <<s:utf8>>
}

// encode field
pub fn encode_int_field(
  buf: BitArray,
  field_number: Int,
  value: Int,
) -> BitArray {
  case value == 0 {
    True -> buf
    False -> {
      buf
      |> encode_key(field_number, varint_type)
      |> bit_array.append(encode_varint(value))
    }
  }
}

pub fn encode_float_field(
  buf: BitArray,
  field_number: Int,
  value: Float,
  // i32_type, i64_type
  wire_type: Int,
) -> BitArray {
  case wire_type == i32_type || wire_type == i64_type {
    True -> {
      case value == 0.0 {
        True -> buf
        False -> {
          buf
          |> encode_key(field_number, wire_type)
          |> bit_array.append(case wire_type == i32_type {
            True -> encode_i32(value)
            False -> encode_i64(value)
          })
        }
      }
    }
    False -> panic as { "Invalid int wire_type, " <> int.to_string(wire_type) }
  }
}

pub fn encode_bool_field(buf: BitArray, field_number: Int, b: Bool) -> BitArray {
  encode_int_field(buf, field_number, bool.to_int(b))
}

pub fn encode_len_field(
  buf: BitArray,
  field_number: Int,
  child: a,
  encoder: fn(a) -> BitArray,
) -> BitArray {
  let data = encoder(child)
  let length = bit_array.byte_size(data)
  case length == 0 {
    True -> buf
    False -> {
      buf
      |> encode_key(field_number, len_type)
      |> bit_array.append(encode_varint(length))
      |> bit_array.append(data)
    }
  }
}

pub fn encode_repeated_field(
  buf: BitArray,
  field_number: Int,
  children: List(a),
  encoder: fn(a) -> BitArray,
  packed: Bool,
) -> BitArray {
  case packed {
    // [key + len + data + data2 ...]
    True -> {
      let data =
        children
        |> list.map(fn(a) { encoder(a) })
        |> list.fold(<<>>, bit_array.append)

      let length = bit_array.byte_size(data)
      buf
      |> encode_key(field_number, len_type)
      |> bit_array.append(encode_varint(length))
      |> bit_array.append(data)
    }
    // [(key + len + data), (key + len2 + data2), ...]
    False -> {
      let data =
        children
        |> list.map(fn(a) {
          let data = encoder(a)
          let length = bit_array.byte_size(data)
          <<>>
          |> encode_key(field_number, len_type)
          |> bit_array.append(encode_varint(length))
          |> bit_array.append(data)
        })
        |> list.fold(<<>>, bit_array.append)

      buf |> bit_array.append(data)
    }
  }
}

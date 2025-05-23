import acrostic/decoding
import acrostic/encoding
import gleam/int
import gleam/list
import gleam/string
import gleeunit/should

pub fn varint_encode_test() {
  encoding.encode_varint(137)
  |> should.equal(<<137, 1>>)
}

pub fn varint_decode_test() {
  decoding.decode_to_int(<<137, 1>>)
  |> should.be_ok()
  |> should.equal(137)
}

pub fn varint_test() {
  encoding.encode_varint(123_456_789)
  |> decoding.decode_to_int
  |> should.be_ok()
  |> should.equal(123_456_789)
}

pub fn string_test() {
  encoding.encode_string("hello")
  |> decoding.decode_to_string()
  |> should.be_ok()
  |> should.equal("hello")
}

pub fn long_string_test() {
  let input = string.repeat("ha", 1000)
  encoding.encode_string(input)
  |> decoding.decode_to_string()
  |> should.be_ok()
  |> should.equal(input)
}

pub fn i32_test() {
  encoding.encode_i32(12.0)
  |> decoding.decode_to_i32()
  |> should.be_ok()
  |> should.equal(12.0)
}

pub fn negative_i32_test() {
  let input = -0.5
  encoding.encode_i32(input)
  |> decoding.decode_to_i32()
  |> should.be_ok()
  |> should.equal(input)
}

pub fn i64_test() {
  let assert Ok(input) = int.power(65, 2.0)
  encoding.encode_i64(input)
  |> decoding.decode_to_i64
  |> should.be_ok()
  |> should.equal(input)
}

pub fn negative_i64_test() {
  let assert Ok(input) = int.power(65, 2.0)
  let input = input *. -1.0
  encoding.encode_i64(input)
  |> decoding.decode_to_i64
  |> should.be_ok()
  |> should.equal(input)
}

pub fn true_bool_test() {
  encoding.encode_bool(True)
  |> decoding.decode_to_bool
  |> should.be_ok()
  |> should.equal(True)
}

pub fn false_bool_test() {
  encoding.encode_bool(False)
  |> decoding.decode_to_bool
  |> should.be_ok()
  |> should.equal(False)
}

pub fn field_test() {
  let input = string.repeat("ha", 1000)
  let encoded = encoding.encode_field(1, input, encoding.string_field_encoder)
  let #(key, binary) = decoding.read_key(encoded) |> should.be_ok()
  let #(output, _) =
    decoding.decode_field(binary, key.wire_type, decoding.string_field_decoder)
    |> should.be_ok()
  output |> should.equal(input)
}

pub fn repeated_field_test() {
  let input = list.repeat(123_456_789, times: 2)
  let encoded =
    encoding.encode_repeated_field(1, input, encoding.int_field_encoder)

  let #(key, binary) = decoding.read_key(encoded) |> should.be_ok()
  let #(output, _) =
    decoding.decode_repeated_field(
      binary,
      key.wire_type,
      decoding.int_field_decoder,
    )
    |> should.be_ok()
}

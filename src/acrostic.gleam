import acrostic/internal/helper
import acrostic/internal/parser
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/regexp
import gleam/result
import gleam/string
import nibble
import nibble/lexer
import simplifile
import sprinkle.{format}

type Message {
  Message(id: Int, name: String, fields: List(parser.PbMessageField))
}

pub type Flags {
  Flags(enum_to_int: Bool, int_to_enum: Bool)
}

@target(erlang)
pub fn gen(protos: List(String), to out_path: String, flags flags: Flags) {
  protos
  |> list.map(fn(filepath) {
    case simplifile.read(from: filepath) {
      Ok(content) -> content
      Error(e) -> panic as string.inspect(e)
    }
  })
  |> list.fold("", string.append)
  |> generate_proto(out_path, flags)

  io.println("done")
}

@target(javascript)
pub fn gen(_: List(String), to _: String, flags _: Flags) {
  panic as "Code generation is not supported for javascript"
}

fn generate_proto(text: String, out_path: String, flags: Flags) {
  let #(lexer, message_parser, enum_parser) = parser.parser()
  let enums = get_enums(text, lexer, enum_parser)
  let structs =
    get_structs(text, lexer, message_parser)
    |> list.map(fn(a) {
      Message(id: a.0, name: { a.1 }.name, fields: { a.1 }.fields)
    })
  let messages =
    get_messages(text, lexer, message_parser)
    |> list.map(fn(a) {
      Message(id: a.0, name: { a.1 }.name, fields: { a.1 }.fields)
    })

  let assert Ok(_) =
    "
    import gleam/list
    import gleam/bit_array
    import acrostic/wire
    import acrostic/encoding.{type FieldEncoder, FieldEncoder}
    import acrostic/decoding.{type FieldDecoder, FieldDecoder}
    import gleam/result
    import gleam/int
    "
    |> simplifile.write(to: out_path)

  write_enums(enums, out_path, flags)
  // write structs
  let _ = case list.length(structs) > 0 {
    True -> {
      let _ =
        simplifile.append(
          to: out_path,
          contents: "// struct start -----------------------------------\n",
        )
      write_structs(structs, out_path)
    }
    _ -> Nil
  }
  // write messages
  let _ = case list.length(messages) > 0 {
    True -> {
      let _ =
        simplifile.append(
          to: out_path,
          contents: "// messages start -----------------------------------\n",
        )
      let _ = write_messages(messages, out_path)
      Nil
    }
    _ -> Nil
  }

  helper.cmd("gleam format " <> out_path)
}

// pub type Message {
//   Ping(msg: String)
//   Pong(msg: String)
// }

// f.name <> ": " <> to_gleam_ty(f.ty, f.repeated)
fn write_messages(messages: List(Message), out_path: String) {
  let assert Ok(_) =
    simplifile.append(to: out_path, contents: "pub type Message {\n")
  let assert Ok(_) =
    messages
    |> list.map(
      message_to_string(_, fn(field) {
        field.name <> ": " <> to_gleam_ty(field.ty, field.repeated)
      }),
    )
    |> list.fold("", string.append)
    |> simplifile.append(to: out_path)

  let assert Ok(_) = simplifile.append(to: out_path, contents: "}\n\n")

  // encoding gen
  let body =
    messages
    |> list.map(fn(msg) {
      format(
        "
          {message} -> {
        {fields}
          }
        ",
        [
          #("message", message_to_string(msg, fn(f) { f.name })),
          #(
            "fields",
            msg.fields
              |> list.map(get_field_encoding(_, ""))
              |> list.fold(
                "<<" <> int.to_string(msg.id) <> ":big-size(16)>>\n",
                string.append,
              ),
          ),
        ],
      )
    })
    |> list.fold("", string.append)

  let assert Ok(_) =
    "
    pub fn encode(msg: Message) -> BitArray {
    case msg {
        {body}
    }
  }
  "
    |> format([#("body", body)])
    |> simplifile.append(to: out_path)

  // decoding
  let assert Ok(_) =
    messages
    |> list.map(fn(msg) { get_message_case_code(msg) })
    |> list.fold(
      "
        pub fn decode_to_message(binary: BitArray, msg: Message) -> Result(Message, String) {
        case binary {
          <<>> -> Ok(msg)
        _ -> case msg {
      ",
      string.append,
    )
    |> string.append(
      "
            }
          }
        }
      ",
    )
    |> simplifile.append(to: out_path)

  // pub const empty_hello = Hello(1,2,3)
  messages
  |> list.each(fn(msg) {
    let assert Ok(_) =
      "pub const empty_{name} = {value}\n"
      |> format([
        #("name", pascal_to_snake(msg.name)),
        #(
          "value",
          msg.fields
            |> list.map(fn(f) { get_default_value(f.ty, f.repeated) })
            |> list.fold(msg.name <> "(", fn(a, b) { a <> b <> "," })
            |> string.append(")"),
        ),
      ])
      |> simplifile.append(to: out_path)
  })

  write_decode(messages, out_path)
}

fn write_decode(messages: List(Message), out_path: String) {
  let assert Ok(_) =
    messages
    |> list.map(fn(msg) {
      format("{id} -> decode_to_message(binary, {default})\n", [
        #("id", int.to_string(msg.id)),
        #("default", "empty_" <> pascal_to_snake(msg.name)),
      ])
    })
    |> list.fold(
      "
      pub fn decode(binary: BitArray) -> Result(Message, String) {
        let assert <<id:big-size(16), binary:bits>> = binary
        case id { 
    ",
      string.append,
    )
    |> string.append(
      "x -> Error(\"Invalid msgid: \" <> int.to_string(x))
        }
      }
    ",
    )
    |> simplifile.append(to: out_path)
}

fn get_message_case_code(msg: Message) -> String {
  msg.fields
  |> list.map(fn(f) {
    format(
      "
        {field_number} -> {
          use #({field_name}, binary) <- {reader}
          decode_to_message(binary, {message})
        }",
      [
        #("reader", get_reader_string(f)),
        #("field_number", int.to_string(f.tag)),
        #("field_name", {
          case f.repeated {
            True -> "addit_" <> f.name
            False -> f.name
          }
        }),
        #(
          "message",
          message_to_string(msg, fn(f2) {
            case f.name == f2.name, f2.repeated {
              True, True ->
                format("list.append({field_name}, addit_{field_name})", [
                  #("field_name", f2.name),
                ])
              _, _ -> f2.name
            }
          }),
        ),
      ],
    )
  })
  |> list.fold(
    message_to_string(msg, fn(f) {
      case list.length(msg.fields) > 1 {
        True -> f.name
        False -> "_" <> f.name
      }
    })
      <> "
    -> {
      use #(key, binary) <- result.try(decoding.read_key(binary))
      case key.field_number {
  ",
    string.append,
  )
  |> string.append(
    "   _ -> Error(\"Invalid field_number\")
      }
    }
  ",
  )
}

// pub type Item {
//   Item(id: Int, num: Int)
// }
fn write_structs(structs: List(Message), out_path: String) {
  structs
  |> list.each(fn(struct) {
    // define gen
    let assert Ok(_) =
      simplifile.append(
        to: out_path,
        contents: "pub type " <> struct.name <> " {\n",
      )
    let assert Ok(_) =
      simplifile.append(
        to: out_path,
        contents: message_to_string(struct, fn(field) {
          field.name <> ": " <> to_gleam_ty(field.ty, field.repeated)
        })
          <> "}\n\n",
      )

    // default
    // pub const empty_item = Item(0, 0)
    let assert Ok(_) =
      "pub const empty_{name} = {value}\n"
      |> format([
        #("name", pascal_to_snake(struct.name)),
        #(
          "value",
          struct.fields
            |> list.map(fn(f) { get_default_value(f.ty, f.repeated) })
            |> list.fold(struct.name <> "(", fn(a, b) { a <> b <> "," })
            |> string.append(")"),
        ),
      ])
      |> simplifile.append(to: out_path)
    // encoding gen
    let assert Ok(_) =
      format(
        "
          pub fn encode_{name}({name}: {type}) -> BitArray {
            {body}
          }
       ",
        [
          #("name", pascal_to_snake(struct.name)),
          #("type", struct.name),
          #(
            "body",
            struct.fields
              |> list.map(get_field_encoding(
                _,
                pascal_to_snake(struct.name) <> ".",
              ))
              |> list.fold("<<>>\n", string.append),
          ),
        ],
      )
      |> simplifile.append(to: out_path)
    // decoding gen
    let assert Ok(_) =
      format(
        "
      pub fn decode_to_{name}(binary: BitArray, {name}: {typename}) -> Result({typename}, String) {
        case binary {
          <<>> -> Ok({name})
          _ -> {
            use #(key, binary) <- result.try(decoding.read_key(binary))
            case key.field_number {
              {body}
                _ -> Error(\"Invalid field_number\")
              }
            }
          }
        }
      ",
        [
          #("name", pascal_to_snake(struct.name)),
          #("typename", struct.name),
          #(
            "body",
            struct.fields
              |> list.map(fn(f) {
                format(
                  "
                  {field_number} -> {
                    use #({var_name}, binary) <- {reader}
                    decode_to_{name}(binary, {typename}(..{name}, {field_name}: {field_value}))
                  }",
                  [
                    #("name", pascal_to_snake(struct.name)),
                    #("typename", struct.name),
                    #("reader", get_reader_string(f)),
                    #("field_number", int.to_string(f.tag)),
                    #("field_name", f.name),
                    #("var_name", {
                      case f.repeated {
                        True -> "addit_" <> f.name
                        False -> f.name
                      }
                    }),
                    #("field_value", {
                      case f.repeated {
                        True ->
                          format(
                            "list.append({name}.{field_name}, addit_{field_name})",
                            [
                              #("name", pascal_to_snake(struct.name)),
                              #("field_name", f.name),
                            ],
                          )
                        False -> f.name
                      }
                    }),
                  ],
                )
              })
              |> list.fold("", string.append),
          ),
        ],
      )
      |> simplifile.append(to: out_path)

    write_struct_field_encoder(struct, out_path)
    write_struct_field_decoder(struct, out_path)
  })
}

fn write_struct_field_decoder(struct: Message, out_path: String) {
  let assert Ok(_) =
    format(
      "
      fn {name}_field_decoder() {
        FieldDecoder(wire.Len, decode_to_{name}(_, empty_{name}))
      }
    ",
      [#("name", pascal_to_snake(struct.name))],
    )
    |> simplifile.append(to: out_path)
  Nil
}

fn write_struct_field_encoder(struct: Message, out_path: String) {
  let assert Ok(_) =
    format(
      "
      pub const {name}_field_encoder = FieldEncoder(
        {wire_type},
        {encoder}
      )
    ",
      [
        #("name", pascal_to_snake(struct.name)),
        #("wire_type", "wire.Len"),
        #("encoder", "encode_" <> pascal_to_snake(struct.name)),
      ],
    )
    |> simplifile.append(to: out_path)
  Nil
}

fn get_reader_string(field: parser.PbMessageField) -> String {
  let s = case field.ty {
    "string" ->
      "
          result.try(decoding.decode_field(
            binary,
            key.wire_type,
            decoding.string_field_decoder,
          ))"
    "int32" | "int64" | "uint32" | "uint64" ->
      "
          result.try(decoding.decode_field(
            binary,
            key.wire_type,
            decoding.int_field_decoder,
          ))"
    "bool" ->
      "
          result.try(decoding.decode_field(
            binary,
            key.wire_type,
            decoding.bool_field_decoder,
         ))"
    "fixed64" | "sfixed64" | "double" ->
      "
          result.try(decoding.decode_field(
            binary,
            key.wire_type,
            decoding.i64_field_decoder,
         ))"
    "fixed32" | "sfixed32" | "float" ->
      "
          result.try(decoding.decode_field(
            binary,
            key.wire_type,
            decoding.i32_field_decoder,
         ))"
    // Custom Type (Enum | Struct)
    ty -> "
            result.try(decoding.decode_field(
              binary,
              key.wire_type,
              " <> pascal_to_snake(ty) <> "_field_decoder(),
          ))"
  }

  case field.repeated {
    True -> {
      s |> string.replace("decode_field", "decode_repeated_field")
    }
    False -> s
  }
}

fn get_default_value(ty: String, repeated: Bool) -> String {
  case to_gleam_ty(ty, False) {
    _any if repeated -> "[]"
    "Int" -> "0"
    "Bool" -> "False"
    "Float" -> "0.0"
    "String" -> "\"\""
    // Enum or Struct
    x -> "empty_" <> pascal_to_snake(x)
  }
}

// |> bit_array.append(encoding.encode_field(1, 1, encoding.int_field_encoder))
fn get_field_encoding(
  field: parser.PbMessageField,
  field_prefix: String,
) -> String {
  format(
    "|> bit_array.append(encoding.{encode_field}({tag}, {value}, {field_encoder}))",
    [
      #("encode_field", case field.repeated {
        True -> "encode_repeated_field"
        False -> "encode_field"
      }),
      #("tag", int.to_string(field.tag)),
      #("value", field_prefix <> field.name),
      #("field_encoder", {
        case field.ty {
          // string
          "string" -> "encoding.string_field_encoder"
          // varint
          "int32" | "int64" | "uint32" | "uint64" ->
            "encoding.int_field_encoder"
          "bool" -> "encoding.bool_field_encoder"
          // i64
          "fixed64" | "sfixed64" | "double" -> "encoding.i64_field_encoder"
          // i32
          "fixed32" | "sfixed32" | "float" -> "encoding.i32_field_encoder"
          // Custom Type (Struct | Enum)
          x -> pascal_to_snake(x) <> "_field_encoder"
        }
      }),
    ],
  )
}

fn write_enums(enums: List(parser.PbEnum), out_path: String, flags: Flags) {
  enums
  |> list.each(fn(enum) {
    // define gen
    let assert Ok(_) =
      simplifile.append(
        to: out_path,
        contents: "pub type " <> enum.name <> " {\n",
      )
    enum.fields
    |> list.each(fn(field) {
      let assert Ok(_) =
        simplifile.append(to: out_path, contents: "  " <> field.name <> "\n")
    })
    let assert Ok(_) = simplifile.append(to: out_path, contents: "}\n\n")

    // default value
    // pub const empty_user_status = Idle
    let assert Ok(_) =
      "pub const empty_{name} = {value}\n"
      |> format([
        #("name", pascal_to_snake(enum.name)),
        #("value", case enum.fields |> list.first {
          Ok(f) -> f.name
          _ -> panic as { "Invalid empty enum: " <> enum.name }
        }),
      ])
      |> simplifile.append(to: out_path)

    // encoding gen
    // pub fn encode_item(item: Item) -> BitArray {
    //   ...
    // }
    let assert Ok(_) =
      format(
        "
          pub fn encode_{name}({name}: {type}) -> BitArray {
            {body}
          }
        ",
        [
          #("name", pascal_to_snake(enum.name)),
          #("type", enum.name),
          #(
            "body",
            enum.fields
              |> list.map(fn(f) {
                format("    {key} -> encoding.encode_varint({value})\n", [
                  #("key", f.name),
                  #("value", int.to_string(f.tag)),
                ])
              })
              |> list.fold(
                "case " <> pascal_to_snake(enum.name) <> " {\n",
                string.append,
              )
              |> string.append("  }"),
          ),
        ],
      )
      |> simplifile.append(to: out_path)
    // decoding gen

    write_enum_decode(enum, out_path)

    // enum_to_int
    let _ = case flags.enum_to_int {
      True -> write_enum_to_int(enum, out_path)
      _ -> Nil
    }

    // int_to_enum
    let _ = case flags.int_to_enum {
      True -> write_int_to_enum(enum, out_path)
      _ -> Nil
    }

    // field encoder
    write_enum_field_encoder(enum, out_path)
    write_enum_field_decoder(enum, out_path)
  })
}

fn write_enum_field_decoder(enum: parser.PbEnum, out_path: String) {
  let assert Ok(_) =
    format(
      "
      fn {name}_field_decoder() {
        FieldDecoder(wire.VarInt, decode_to_{name})
      }
    ",
      [#("name", pascal_to_snake(enum.name))],
    )
    |> simplifile.append(to: out_path)
  Nil
}

fn write_enum_decode(enum: parser.PbEnum, out_path: String) {
  let assert Ok(_) =
    format(
      "
      fn decode_to_{name}(binary: BitArray) -> Result({typename}, String) {
        case decoding.to_varint(binary, 0) {
          {body} _ ->
            Error(\"Decode to {name} failed: \" <> bit_array.base64_encode(binary, False))
        }
      }",
      [
        #("name", pascal_to_snake(enum.name)),
        #("typename", enum.name),
        #(
          "body",
          enum.fields
            |> list.map(fn(f) {
              int.to_string(f.tag) <> " -> Ok(" <> f.name <> ")\n"
            })
            |> list.fold("", string.append),
        ),
      ],
    )
    |> simplifile.append(to: out_path)
  Nil
}

fn write_enum_field_encoder(enum: parser.PbEnum, out_path: String) {
  let assert Ok(_) =
    format(
      "
      pub const {name}_field_encoder = FieldEncoder(
        {wire_type},
        {encoder}
      )
    ",
      [
        #("name", pascal_to_snake(enum.name)),
        #("wire_type", "wire.VarInt"),
        #("encoder", "encode_" <> pascal_to_snake(enum.name)),
      ],
    )
    |> simplifile.append(to: out_path)
  Nil
}

fn write_int_to_enum(enum: parser.PbEnum, out_path: String) {
  let head =
    format(
      "
          pub fn int_to_{name}(n: Int) -> {typename} {
            case n {
        ",
      [#("name", pascal_to_snake(enum.name)), #("typename", enum.name)],
    )

  let assert Ok(_) =
    enum.fields
    |> list.map(fn(f) {
      format("{key} -> {value}\n", [
        #("key", int.to_string(f.tag)),
        #("value", f.name),
      ])
    })
    |> list.fold(head, string.append)
    |> string.append(
      "
        _ -> panic
      }}
      ",
    )
    |> simplifile.append(to: out_path)

  Nil
}

fn write_enum_to_int(enum: parser.PbEnum, out_path: String) {
  let head =
    format(
      "
          pub fn {name}_to_int({name}: {typename}) -> Int {
            case {name} {
        ",
      [#("name", pascal_to_snake(enum.name)), #("typename", enum.name)],
    )

  let assert Ok(_) =
    enum.fields
    |> list.map(fn(f) {
      format("{key} -> {value}\n", [
        #("key", f.name),
        #("value", int.to_string(f.tag)),
      ])
    })
    |> list.fold(head, string.append)
    |> string.append(
      "
      }}
      ",
    )
    |> simplifile.append(to: out_path)

  Nil
}

fn get_enums(text: String, lexer, parser) {
  let assert Ok(re) = regexp.from_string("enum\\s+\\w+\\s*\\{[^{}]*\\}")
  regexp.scan(re, text)
  |> list.map(fn(a) {
    let assert Ok(tokens) = lexer.run(a.content, lexer)
    let assert Ok(enum) = nibble.run(tokens, parser)
    enum
  })
}

fn get_structs(text: String, lexer, parser) {
  let assert Ok(re) =
    regexp.from_string(
      "//\\s*@gleam\\s+record\\s*\nmessage\\s+\\w+\\s*\\{([^{}]*)\\}",
    )
  regexp.scan(re, text)
  |> list.map(fn(a) {
    let assert Ok(tokens) = lexer.run(a.content, lexer)
    let assert Ok(message) = nibble.run(tokens, parser)
    #(0, message)
  })
}

fn get_messages(text: String, lexer, parser) {
  let assert Ok(re) =
    regexp.from_string(
      "//\\s*@gleam\\s+msgid\\s*=\\s*(\\d+)\\s*\nmessage\\s+\\w+\\s*\\{([^{}]*)\\}",
    )
  regexp.scan(re, text)
  |> list.map(fn(a) {
    let assert Ok(tokens) = lexer.run(a.content, lexer)
    let assert Ok(msg) = nibble.run(tokens, parser)
    let msgid =
      a.submatches
      |> list.first
      |> result.lazy_unwrap(fn() { panic })
      |> option.lazy_unwrap(fn() { panic })
      |> int.parse
      |> result.lazy_unwrap(fn() { panic })
    #(msgid, msg)
  })
}

// "  Item(id: Int, num: Int)\n"
fn message_to_string(
  message: Message,
  convert: fn(parser.PbMessageField) -> String,
) -> String {
  case list.length(message.fields) > 0 {
    True -> {
      format("  {name}({body})\n", [
        #("name", message.name),
        #("body", {
          message.fields
          |> list.map(convert)
          |> list.fold("", fn(a, b) { a <> b <> ", " })
          |> string.drop_end(2)
        }),
      ])
    }
    False -> "  " <> message.name <> "\n"
  }
}

// varint: int32, int64, uint32, uint64, bool, enum
// i64: fixed64, sfixed64, double
// i32: fixed32, sfixed32, float
fn to_gleam_ty(ty: String, repeated: Bool) -> String {
  let ty = case ty {
    // string
    "string" -> "String"
    // varint
    "int32" | "int64" | "uint32" | "uint64" -> "Int"
    "bool" -> "Bool"
    // i64
    "fixed64" | "sfixed64" | "double" -> "Float"
    // i32
    "fixed32" | "sfixed32" | "float" -> "Float"
    // Custom Type (Struct | Enum)
    x -> x
  }
  case repeated {
    True -> "List(" <> ty <> ")"
    False -> ty
  }
}

fn pascal_to_snake(ident: String) -> String {
  let assert Ok(re) = regexp.from_string("[A-Z][a-z]*")
  regexp.scan(re, ident)
  |> list.map(fn(a) { a.content })
  |> list.map(fn(a) { string.lowercase(a) })
  |> list.fold("", fn(a, b) { a <> "_" <> b })
  |> string.drop_start(1)
}

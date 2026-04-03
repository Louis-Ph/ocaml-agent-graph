open Yojson.Safe.Util

let member_string_option name json =
  match json |> member name with
  | `String value -> Some value
  | _ -> None

let member_int_option name json =
  match json |> member name with
  | `Int value -> Some value
  | `Intlit value -> Some (int_of_string value)
  | _ -> None

let resolve_relative_path ~base_dir path =
  if Filename.is_relative path then Filename.concat base_dir path else path

let load_text_file path =
  try Ok (Stdlib.In_channel.with_open_bin path Stdlib.In_channel.input_all)
  with Sys_error message -> Error (Fmt.str "Cannot read %s: %s" path message)

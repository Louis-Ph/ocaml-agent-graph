let starts_with ~prefix value =
  let prefix_length = String.length prefix in
  String.length value >= prefix_length
  && String.sub value 0 prefix_length = prefix

let trim = String.trim

let lowercase = String.lowercase_ascii

let without_fragment url =
  match String.index_opt url '#' with
  | None -> url
  | Some index -> String.sub url 0 index

let is_http_url url =
  starts_with ~prefix:"https://" url || starts_with ~prefix:"http://" url

let normalize url = url |> trim |> without_fragment

let host_bounds url =
  let skip_scheme prefix =
    if starts_with ~prefix url then Some (String.length prefix) else None
  in
  match skip_scheme "https://" with
  | Some start ->
      let stop =
        match String.index_from_opt url start '/' with
        | Some index -> index
        | None -> String.length url
      in
      Some (start, stop)
  | None ->
      (match skip_scheme "http://" with
       | Some start ->
           let stop =
             match String.index_from_opt url start '/' with
             | Some index -> index
             | None -> String.length url
           in
           Some (start, stop)
       | None -> None)

let host_of_url url =
  match host_bounds (normalize url) with
  | None -> None
  | Some (start, stop) ->
      let host = String.sub url start (stop - start) |> lowercase in
      Some
        (if starts_with ~prefix:"www." host then
           String.sub host 4 (String.length host - 4)
         else host)

let domain_of_url url = Option.value (host_of_url url) ~default:""

let scheme_and_host url =
  match host_bounds (normalize url) with
  | None -> None
  | Some (_, stop) -> Some (String.sub url 0 stop)

let directory_of_url url =
  match host_bounds (normalize url) with
  | None -> None
  | Some (_, host_stop) ->
      let path =
        if host_stop >= String.length url then "/"
        else String.sub url host_stop (String.length url - host_stop)
      in
      let directory =
        match String.rindex_opt path '/' with
        | None -> "/"
        | Some index -> String.sub path 0 (index + 1)
      in
      Some directory

let resolve_relative ~base_url href =
  let href = href |> trim in
  if href = "" then None
  else if starts_with ~prefix:"mailto:" href || starts_with ~prefix:"javascript:" href
  then None
  else if is_http_url href then Some (normalize href)
  else if starts_with ~prefix:"//" href then Some ("https:" ^ href)
  else
    match scheme_and_host base_url with
    | None -> None
    | Some scheme_host when starts_with ~prefix:"/" href ->
        Some (scheme_host ^ href)
    | Some scheme_host ->
        let directory =
          Option.value (directory_of_url base_url) ~default:"/"
        in
        Some (scheme_host ^ directory ^ href)

let ends_with value suffix =
  let value_length = String.length value in
  let suffix_length = String.length suffix in
  value_length >= suffix_length
  && String.sub value (value_length - suffix_length) suffix_length = suffix

let domain_matches patterns domain =
  let lowered_domain = lowercase domain in
  List.exists
    (fun pattern ->
      let lowered_pattern = lowercase pattern in
      lowered_domain = lowered_pattern
      || ends_with lowered_domain lowered_pattern)
    patterns

let encode_query value =
  let buffer = Buffer.create (String.length value * 3) in
  let push_hex character =
    Buffer.add_char buffer '%';
    Buffer.add_string buffer (Printf.sprintf "%02X" (Char.code character))
  in
  String.iter
    (function
      | 'A' .. 'Z'
      | 'a' .. 'z'
      | '0' .. '9'
      | '-'
      | '_'
      | '.'
      | '~' as character -> Buffer.add_char buffer character
      | ' ' -> Buffer.add_char buffer '+'
      | character -> push_hex character)
    value;
  Buffer.contents buffer

let terminal_width () =
  match Sys.getenv_opt "COLUMNS" with
  | Some raw -> (
      match int_of_string_opt raw with
      | Some width when width >= 48 -> width
      | _ -> 88)
  | None -> 88

let supports_color () =
  Unix.isatty Unix.stdout
  && (not
        (match Sys.getenv_opt "NO_COLOR" with Some _ -> true | None -> false))
  && match Sys.getenv_opt "TERM" with Some "dumb" -> false | _ -> true

module Style = struct
  let paint code text =
    if supports_color () then Fmt.str "\027[%sm%s\027[0m" code text else text

  let accent text = paint "36" text
  let muted text = paint "90" text
  let good text = paint "32" text
  let warning text = paint "33" text
  let danger text = paint "31" text
  let bold text = paint "1" text
end

let wrap_text ?(indent = 0) text =
  let width = max 40 (terminal_width () - indent) in
  let words =
    String.split_on_char ' ' text |> List.filter (fun word -> word <> "")
  in
  let rec fold current_length current_line acc = function
    | [] ->
        List.rev
          (if current_line = [] then acc
           else String.concat " " (List.rev current_line) :: acc)
    | word :: rest ->
        let word_length = String.length word in
        let next_length =
          if current_line = [] then word_length
          else current_length + 1 + word_length
        in
        if next_length <= width then
          fold next_length (word :: current_line) acc rest
        else if current_line = [] then fold word_length [ word ] acc rest
        else
          fold word_length [ word ]
            (String.concat " " (List.rev current_line) :: acc)
            rest
  in
  fold 0 [] [] words

let print_wrapped ?(indent = 0) text =
  let prefix = String.make indent ' ' in
  if String.trim text = "" then print_endline ""
  else
    wrap_text ~indent text
    |> List.iter (fun line -> print_endline (prefix ^ line))

let print_wrapped_styled ~style ?(indent = 0) text =
  let prefix = String.make indent ' ' in
  if String.trim text = "" then print_endline ""
  else
    wrap_text ~indent text
    |> List.iter (fun line -> print_endline (prefix ^ style line))

let print_wrapped_lines ?(indent = 0) lines =
  List.iter (print_wrapped ~indent) lines

let print_styled_lines ~style ?(indent = 0) lines =
  List.iter (print_wrapped_styled ~style ~indent) lines

let divider () =
  let width = min 96 (max 52 (terminal_width ())) in
  String.make width '='

let print_banner ~title ~subtitle badges =
  let line = divider () in
  print_endline (Style.accent line);
  print_endline (Style.bold title);
  print_wrapped subtitle;
  if badges <> [] then
    print_wrapped
      (Fmt.str "lanes: %s"
         (badges |> List.map Style.good |> String.concat " | "));
  print_endline (Style.accent line)

let print_section ?style title lines =
  print_endline (Style.accent title);
  match style with
  | Some style -> print_styled_lines ~style ~indent:2 lines
  | None -> print_wrapped_lines ~indent:2 lines

let print_label_value_rows ?style rows =
  let label_width =
    rows
    |> List.fold_left
         (fun max_width (label, _) -> max max_width (String.length label))
         0
  in
  rows
  |> List.iter (fun (label, value) ->
         let formatted = Fmt.str "%-*s  %s" label_width label value in
         match style with
         | Some style -> print_endline (style formatted)
         | None -> print_endline formatted)

(* Print a titled section without word-wrapping — preserves column alignment
   in pre-formatted lines (help tables, transport maps, etc.). *)
let print_section_verbatim ?style title lines =
  print_endline (Style.accent title);
  let emit line =
    match style with
    | Some f -> print_endline (f line)
    | None   -> print_endline line
  in
  List.iter emit lines

(* Prompt module for linenoise.
   OCaml linenoise 1.5.x does not honor \001/\002 zero-width markers,
   so ANSI codes in the prompt string shift the cursor to the right.
   The workaround: print the colored prompt manually to stdout, then
   pass an empty string to linenoise as the prompt. *)
module Prompt = struct
  let colored_prompt text =
    if supports_color () then
      Fmt.str "\027[1;32m%s\027[0m" text
    else text

  let emit_and_plain text =
    print_string (colored_prompt text);
    flush stdout;
    ""
end

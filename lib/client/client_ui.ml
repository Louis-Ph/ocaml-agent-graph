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
  let info text = paint "34" text
  let highlight text = paint "96" text
  let dim text = paint "2" text
  let title text = paint "1;36" text
  let label text = paint "1;34" text
  let subtle text = paint "38;5;245" text
end

module Badge = struct
  let make style text =
    if supports_color ()
    then Fmt.str " %s " (style text)
    else Fmt.str " [%s] " text

  let model text = make Style.accent text
  let file text = make Style.warning text
  let turn text = make Style.info text
  let success text = make Style.good text
  let error text = make Style.danger text
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

let thin_divider () =
  let width = min 96 (max 52 (terminal_width ())) in
  String.make width '-'

let print_banner ~title ~subtitle badges =
  let line = divider () in
  print_endline (Style.accent line);
  print_endline (Style.bold ("  " ^ title));
  print_wrapped ~indent:2 subtitle;
  if badges <> [] then
    print_wrapped ~indent:2
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

let print_section_verbatim ?style title lines =
  print_endline (Style.accent title);
  let emit line =
    match style with
    | Some f -> print_endline (f line)
    | None -> print_endline line
  in
  List.iter emit lines

(* ── Box drawing ──────────────────────────────────────────────────────── *)

module Box = struct
  let horizontal width =
    String.concat "" (List.init width (fun _ -> "─"))
  let top_left = "┌"
  let top_right = "┐"
  let bottom_left = "└"
  let bottom_right = "┘"
  let vertical = "│"
  let tee_right = "├"
  let tee_left = "┤"

  let border_width () =
    min 92 (max 48 (terminal_width () - 4))

  let print_box ?title ?(style = Style.accent) lines =
    let w = border_width () in
    let top =
      match title with
      | None ->
          style (top_left ^ horizontal w ^ top_right)
      | Some t ->
          let title_text = " " ^ t ^ " " in
          let tl = String.length title_text in
          let left_bar = max 1 ((w - tl) / 2) in
          let right_bar = max 1 (w - tl - left_bar) in
          style
            (top_left
            ^ horizontal left_bar
            ^ title_text
            ^ horizontal right_bar
            ^ top_right)
    in
    print_endline top;
    lines
    |> List.iter (fun line ->
           let padded =
             let len = String.length line in
             if len >= w then line else line ^ String.make (w - len) ' '
           in
           print_endline (style (vertical ^ " " ^ padded ^ " " ^ vertical)));
    print_endline (style (bottom_left ^ horizontal w ^ bottom_right))
end

(* ── Response formatting ──────────────────────────────────────────────── *)

let print_response_box ?(style = Style.highlight) lines =
  Box.print_box ~style lines

let print_suggested_command ~index (command : Client_assistant.command) =
  let command_line =
    match command.args with
    | [] -> command.command
    | args -> String.concat " " (command.command :: args)
  in
  print_endline "";
  print_endline
    (Style.label (Fmt.str "  [%d] %s" (index + 1) command_line));
  (match command.why with
  | Some why ->
      print_wrapped_styled ~style:Style.dim ~indent:4 why
  | None -> ());
  print_endline (Style.muted "       Run now? [y/N] ")

let print_status_bar ~route_model ~attachments ~conversation_turns =
  let parts =
    [ Badge.model route_model ]
    @ (if attachments > 0 then [ Badge.file (Fmt.str "%d files" attachments) ] else [])
    @ (if conversation_turns > 0 then [ Badge.turn (Fmt.str "turn %d" conversation_turns) ] else [])
  in
  let bar = String.concat "" parts in
  if supports_color () then print_string (bar ^ " ")

(* Prompt module for linenoise.
   OCaml linenoise 1.5.x does not honor \001/\002 zero-width markers,
   so ANSI codes in the prompt string shift the cursor to the right.
   The workaround: print the colored prompt manually to stdout, then
   pass an empty string to linenoise as the prompt. *)
module Prompt = struct
  let colored_prompt text =
    if supports_color () then Fmt.str "\027[1;32m%s\027[0m" text else text

  let emit_and_plain text =
    print_string (colored_prompt text);
    flush stdout;
    ""

  let emit_status_and_plain ~route_model ~attachments ~conversation_turns text =
    print_status_bar ~route_model ~attachments ~conversation_turns;
    print_string (colored_prompt text);
    flush stdout;
    ""
end

let replace_all pattern replacement text =
  Str.global_replace (Str.regexp pattern) replacement text

let compact_whitespace text =
  text
  |> replace_all "[ \t\r\n]+" " "
  |> String.trim

let decode_entities text =
  text
  |> replace_all "&nbsp;" " "
  |> replace_all "&amp;" "&"
  |> replace_all "&quot;" "\""
  |> replace_all "&#39;" "'"
  |> replace_all "&lt;" "<"
  |> replace_all "&gt;" ">"

let lowercase = String.lowercase_ascii

let extract_title html =
  let lowered = lowercase html in
  match Str.search_forward (Str.regexp "<title[^>]*>") lowered 0 with
  | exception Not_found -> None
  | opening_start ->
      let opening_end = Str.match_end () in
      (match Str.search_forward (Str.regexp "</title>") lowered opening_end with
       | exception Not_found -> None
       | closing_start ->
           let raw_title =
             String.sub html opening_end (closing_start - opening_end)
           in
           let title = raw_title |> decode_entities |> compact_whitespace in
           if title = "" then None else Some title)

let strip_non_visible_blocks html =
  html
  |> replace_all "<script[^>]*>\\(.\\|\n\\|\r\\)*?</script>" " "
  |> replace_all "<style[^>]*>\\(.\\|\n\\|\r\\)*?</style>" " "
  |> replace_all "<noscript[^>]*>\\(.\\|\n\\|\r\\)*?</noscript>" " "
  |> replace_all "<!--\\(.\\|\n\\|\r\\)*?-->" " "

let visible_text html =
  html
  |> strip_non_visible_blocks
  |> replace_all "<[^>]+>" " "
  |> decode_entities
  |> compact_whitespace

let href_pattern =
  Str.regexp_case_fold "href=[\"']\\([^\"'#]+\\)[\"']"

let extract_links ~base_url html =
  let rec loop start seen acc =
    match Str.search_forward href_pattern html start with
    | exception Not_found -> List.rev acc
    | _ ->
        let href = Str.matched_group 1 html |> String.trim in
        let next_start = Str.match_end () in
        (match Web_crawler_url.resolve_relative ~base_url href with
         | None -> loop next_start seen acc
         | Some url ->
             let normalized = Web_crawler_url.normalize url in
             if normalized = ""
                || not (Web_crawler_url.is_http_url normalized)
                || List.mem normalized seen
             then loop next_start seen acc
             else loop next_start (normalized :: seen) (normalized :: acc))
  in
  loop 0 [] []

let sentence_pattern = Str.regexp "[.!?][ \n\r]+"

let excerpt_from_text ~keywords text =
  let sentences =
    text
    |> Str.split sentence_pattern
    |> List.map compact_whitespace
    |> List.filter (fun sentence -> String.length sentence >= 24)
  in
  let ranked =
    sentences
    |> List.map (fun sentence ->
           Web_crawler_keywords.overlap_count keywords sentence, sentence)
    |> List.filter (fun (score, _) -> score > 0)
    |> List.sort (fun (left, _) (right, _) -> compare right left)
  in
  match ranked with
  | [] ->
      if String.length text <= 320 then text
      else String.sub text 0 320 ^ " ..."
  | _ ->
      ranked
      |> List.fold_left
           (fun (count, acc) (_, sentence) ->
             if count >= 3 then count, acc else count + 1, sentence :: acc)
           (0, [])
      |> snd
      |> List.rev
      |> String.concat " "
      |> compact_whitespace

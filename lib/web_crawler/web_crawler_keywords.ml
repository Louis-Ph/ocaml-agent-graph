module String_set = Set.Make (String)

let stopwords =
  [
    "a";
    "an";
    "and";
    "are";
    "as";
    "at";
    "be";
    "by";
    "for";
    "from";
    "how";
    "in";
    "into";
    "is";
    "it";
    "of";
    "on";
    "or";
    "that";
    "the";
    "their";
    "to";
    "use";
    "with";
  ]
  |> List.fold_left (fun set word -> String_set.add word set) String_set.empty

let normalize_character = function
  | 'A' .. 'Z' as character ->
      Char.lowercase_ascii character
  | 'a' .. 'z' | '0' .. '9' as character -> character
  | _ -> ' '

let tokenize text =
  let normalized =
    String.init (String.length text) (fun index ->
        normalize_character text.[index])
  in
  normalized
  |> String.split_on_char ' '
  |> List.filter (fun token ->
         let token = String.trim token in
         token <> ""
         && String.length token >= 3
         && not (String_set.mem token stopwords))

let unique tokens =
  let _, deduplicated =
    List.fold_left
      (fun (seen, acc) token ->
        if String_set.mem token seen then seen, acc
        else String_set.add token seen, token :: acc)
      (String_set.empty, [])
      tokens
  in
  List.rev deduplicated

let of_objective text = text |> tokenize |> unique

let overlap_count keywords text =
  let tokens =
    tokenize text |> List.fold_left (fun set token -> String_set.add token set) String_set.empty
  in
  List.fold_left
    (fun count keyword ->
      if String_set.mem keyword tokens then count + 1 else count)
    0
    keywords

let missing_keywords ~keywords ~texts =
  let covered =
    texts
    |> List.fold_left
         (fun set text ->
           tokenize text
           |> List.fold_left (fun inner token -> String_set.add token inner) set)
         String_set.empty
  in
  keywords
  |> List.filter (fun keyword -> not (String_set.mem keyword covered))

type t =
  | Planner
  | Summarizer
  | Validator

let all = [ Planner; Summarizer; Validator ]

let compare = Stdlib.compare

let equal left right = compare left right = 0

let hash = Hashtbl.hash

let to_string = function
  | Planner -> "planner"
  | Summarizer -> "summarizer"
  | Validator -> "validator"

let of_string = function
  | "planner" -> Ok Planner
  | "summarizer" -> Ok Summarizer
  | "validator" -> Ok Validator
  | other -> Error (Fmt.str "Unknown agent name: %s" other)

let pp formatter value = Format.pp_print_string formatter (to_string value)


open Yojson.Safe.Util

let parse_prompt_profile ~base_dir json =
  let route_model =
    match Config_support.member_string_option "route_model" json with
    | Some value -> value
    | None -> json |> member "model" |> to_string
  in
  let prompt_path =
    json
    |> member "prompt_file"
    |> to_string
    |> Config_support.resolve_relative_path ~base_dir
  in
  match Config_support.load_text_file prompt_path with
  | Error _ as error -> error
  | Ok prompt ->
      Ok
        {
          Web_crawler_types.route_model;
          prompt;
          max_tokens = Config_support.member_int_option "max_tokens" json;
        }

let parse_budget json =
  {
    Web_crawler_types.max_rounds = json |> member "max_rounds" |> to_int;
    max_queries_per_round =
      json |> member "max_queries_per_round" |> to_int;
    max_results_per_query =
      json |> member "max_results_per_query" |> to_int;
    max_pages_per_round =
      json |> member "max_pages_per_round" |> to_int;
    max_total_pages = json |> member "max_total_pages" |> to_int;
    max_followup_links_per_page =
      json |> member "max_followup_links_per_page" |> to_int;
    max_llm_calls = json |> member "max_llm_calls" |> to_int;
  }

let parse_ranking json =
  {
    Web_crawler_types.preferred_domain_bonus =
      json |> member "preferred_domain_bonus" |> to_float;
    blocked_domain_penalty =
      json |> member "blocked_domain_penalty" |> to_float;
    keyword_title_weight =
      json |> member "keyword_title_weight" |> to_float;
    keyword_url_weight =
      json |> member "keyword_url_weight" |> to_float;
    text_keyword_weight =
      json |> member "text_keyword_weight" |> to_float;
    link_depth_penalty =
      json |> member "link_depth_penalty" |> to_float;
    preferred_url_terms =
      json |> member "preferred_url_terms" |> to_list |> List.map to_string;
    penalized_url_terms =
      json |> member "penalized_url_terms" |> to_list |> List.map to_string;
  }

let parse_search json =
  {
    Web_crawler_types.provider = json |> member "provider" |> to_string;
    base_url = json |> member "base_url" |> to_string;
    user_agent = json |> member "user_agent" |> to_string;
    timeout_seconds = json |> member "timeout_seconds" |> to_float;
    preferred_domains =
      json |> member "preferred_domains" |> to_list |> List.map to_string;
    blocked_domains =
      json |> member "blocked_domains" |> to_list |> List.map to_string;
    blocked_url_terms =
      (match json |> member "blocked_url_terms" with
       | `List values -> List.map to_string values
       | _ -> []);
  }

let parse_stop_condition json =
  {
    Web_crawler_types.min_authoritative_pages =
      json |> member "min_authoritative_pages" |> to_int;
    min_distinct_domains =
      json |> member "min_distinct_domains" |> to_int;
  }

let parse_llm ~base_dir json =
  match parse_prompt_profile ~base_dir (json |> member "reflector") with
  | Error _ as error -> error
  | Ok reflector ->
      (match parse_prompt_profile ~base_dir (json |> member "reporter") with
       | Error _ as error -> error
       | Ok reporter ->
           Ok
             {
               Web_crawler_types.gateway_config_path =
                 json
                 |> member "gateway_config_path"
                 |> to_string
                 |> Config_support.resolve_relative_path ~base_dir;
               authorization_token_plaintext =
                 Config_support.member_string_option
                   "authorization_token_plaintext"
                   json;
               authorization_token_env =
                 Config_support.member_string_option
                   "authorization_token_env"
                   json;
               reflector;
               reporter;
             })

let load path =
  try
    let json = Yojson.Safe.from_file path in
    let base_dir = Filename.dirname path in
    match parse_llm ~base_dir (json |> member "llm") with
    | Error _ as error -> error
    | Ok llm ->
        let output_template =
          json
          |> member "output_template_file"
          |> function
          | `String relative_path ->
              let resolved =
                Config_support.resolve_relative_path ~base_dir relative_path
              in
              (match Config_support.load_text_file resolved with
               | Ok content -> Some content
               | Error _ -> None)
          | _ -> None
        in
        Ok
          {
            Web_crawler_types.scenario_name =
              json |> member "scenario_name" |> to_string;
            task_id = json |> member "task_id" |> to_string;
            objective = json |> member "objective" |> to_string;
            seed_queries =
              json |> member "seed_queries" |> to_list |> List.map to_string;
            seed_urls =
              (match json |> member "seed_urls" with
               | `List values -> List.map to_string values
               | _ -> []);
            llm;
            budget = json |> member "budget" |> parse_budget;
            ranking = json |> member "ranking" |> parse_ranking;
            search = json |> member "search" |> parse_search;
            stop_when = json |> member "stop_when" |> parse_stop_condition;
            output_template;
          }
  with
  | Sys_error message -> Error (Fmt.str "Cannot read %s: %s" path message)
  | Yojson.Json_error message ->
      Error (Fmt.str "Invalid JSON in %s: %s" path message)
  | Yojson.Safe.Util.Type_error (message, _) ->
      Error (Fmt.str "Invalid configuration shape in %s: %s" path message)

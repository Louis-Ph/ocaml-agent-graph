open Lwt.Infix

type invocation = {
  content : string;
  prompt_tokens : int;
  completion_tokens : int;
  total_tokens : int;
}

let create (config : Web_crawler_types.t) =
  match
    Llm_aegis_client.create_with_gateway
      ~gateway_config_path:config.llm.gateway_config_path
      ~authorization_token_plaintext:config.llm.authorization_token_plaintext
      ~authorization_token_env:config.llm.authorization_token_env
  with
  | Error _ as error -> error
  | Ok client ->
      (match
         Llm_aegis_client.validate_route_models
           client
           [ config.llm.reflector.route_model; config.llm.reporter.route_model ]
       with
       | Error _ as error -> error
       | Ok () -> Ok client)

let invoke_profile
    client
    (profile : Web_crawler_types.prompt_profile)
    user_content
  =
  let messages =
    ([
       ({ Aegis_lm.Openai_types.role = "system"; content = profile.prompt }
         : Aegis_lm.Openai_types.message);
       ({ role = "user"; content = user_content }
         : Aegis_lm.Openai_types.message);
     ]
      : Aegis_lm.Openai_types.message list)
  in
  Llm_aegis_client.invoke_messages
    client
    ~route_model:profile.route_model
    ~messages
    ~max_tokens:profile.max_tokens
  >|= function
  | Error _ as error -> error
  | Ok completion ->
      Ok
        {
          content = completion.content;
          prompt_tokens = completion.usage.prompt_tokens;
          completion_tokens = completion.usage.completion_tokens;
          total_tokens = completion.usage.total_tokens;
        }

let starts_with ~prefix value =
  let prefix_length = String.length prefix in
  String.length value >= prefix_length
  && String.sub value 0 prefix_length = prefix

let ends_with ~suffix value =
  let value_length = String.length value in
  let suffix_length = String.length suffix in
  value_length >= suffix_length
  && String.sub value (value_length - suffix_length) suffix_length = suffix

let strip_code_fence content =
  let trimmed = String.trim content in
  if starts_with ~prefix:"```" trimmed && ends_with ~suffix:"```" trimmed then
    match String.index_from_opt trimmed 3 '\n' with
    | None -> trimmed
    | Some first_newline ->
        let body_start = first_newline + 1 in
        let body_length = String.length trimmed - body_start - 3 in
        if body_length <= 0 then trimmed
        else String.sub trimmed body_start body_length |> String.trim
  else trimmed

let take count items =
  let rec loop remaining acc = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | item :: rest -> loop (remaining - 1) (item :: acc) rest
  in
  loop count [] items

let render_assessment (item : Web_crawler_types.assessment) =
  let title =
    Option.value item.page.title ~default:(Option.value item.candidate.title ~default:"untitled")
  in
  Fmt.str
    "- %.2f | %s | %s | hits=%d | %s"
    item.score
    item.page.domain
    title
    item.page.keyword_hits
    item.page.url

let reflection_request ~(config : Web_crawler_types.t) ~queries ~assessments ~missing_keywords =
  let top_assessments =
    assessments |> Web_crawler_ranker.sort_assessments |> take 6
  in
  Fmt.str
    "Objective:\n%s\n\nCurrent queries:\n%s\n\nTop findings:\n%s\n\nMissing keywords:\n%s\n\nReturn JSON only with keys action, critique, new_queries, preferred_domains, required_terms."
    config.objective
    (String.concat "\n" queries)
    (if top_assessments = [] then "none"
     else top_assessments |> List.map render_assessment |> String.concat "\n")
    (match missing_keywords with
     | [] -> "none"
     | _ -> String.concat ", " missing_keywords)

let parse_json_list name json =
  match Yojson.Safe.Util.member name json with
  | `List items -> items |> List.filter_map (function `String value -> Some value | _ -> None)
  | _ -> []

let reflection_of_json invocation json =
  let action =
    match Yojson.Safe.Util.member "action" json with
    | `String "stop" -> `Stop
    | _ -> `Continue
  in
  {
    Web_crawler_types.action;
    critique =
      (match Yojson.Safe.Util.member "critique" json with
       | `String value -> value
       | _ -> "No critique returned.");
    new_queries = parse_json_list "new_queries" json;
    preferred_domains = parse_json_list "preferred_domains" json;
    required_terms = parse_json_list "required_terms" json;
    prompt_tokens = invocation.prompt_tokens;
    completion_tokens = invocation.completion_tokens;
    total_tokens = invocation.total_tokens;
  }

let reflect client ~(config : Web_crawler_types.t) ~queries ~assessments ~missing_keywords =
  let request =
    reflection_request ~config ~queries ~assessments ~missing_keywords
  in
  invoke_profile client config.llm.reflector request
  >|= function
  | Error _ as error -> error
  | Ok invocation ->
      let content = strip_code_fence invocation.content in
      (match Yojson.Safe.from_string content with
       | json -> Ok (reflection_of_json invocation json)
       | exception _ ->
           Ok
             {
               Web_crawler_types.action = `Continue;
               critique = String.trim invocation.content;
               new_queries = [];
               preferred_domains = [];
               required_terms = [];
               prompt_tokens = invocation.prompt_tokens;
               completion_tokens = invocation.completion_tokens;
               total_tokens = invocation.total_tokens;
             })

let report_request ~(config : Web_crawler_types.t) assessments reflections =
  let top_assessments =
    assessments |> Web_crawler_ranker.sort_assessments |> take 6
  in
  Fmt.str
    "Objective:\n%s\n\nTemplate:\n%s\n\nBest sources:\n%s\n\nCritiques from earlier rounds:\n%s"
    config.objective
    (Option.value config.output_template ~default:"Concise report with summary, strengths, weaknesses, and best sources.")
    (if top_assessments = [] then "none"
     else top_assessments |> List.map render_assessment |> String.concat "\n")
    (if reflections = [] then "none" else String.concat "\n" reflections)

let report client ~(config : Web_crawler_types.t) ~assessments ~reflections =
  invoke_profile
    client
    config.llm.reporter
    (report_request ~config assessments reflections)

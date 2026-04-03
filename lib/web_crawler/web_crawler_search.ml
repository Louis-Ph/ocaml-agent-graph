open Lwt.Syntax

let title_marker = "title:\""
let url_marker = "\",url:\""

let deduplicate_by_url candidates =
  let seen = Hashtbl.create (List.length candidates) in
  candidates
  |> List.filter (fun (candidate : Web_crawler_types.candidate) ->
         if Hashtbl.mem seen candidate.url then false
         else (
          Hashtbl.add seen candidate.url ();
          true))

let take count items =
  let rec loop remaining acc = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | item :: rest -> loop (remaining - 1) (item :: acc) rest
  in
  loop count [] items

let find_marker marker text start =
  try Some (Str.search_forward (Str.regexp_string marker) text start)
  with Not_found -> None

let parse_results ~query html =
  let rec loop start acc =
    match find_marker title_marker html start with
    | None -> List.rev acc
    | Some title_marker_index ->
        let title_start = title_marker_index + String.length title_marker in
        (match find_marker url_marker html title_start with
         | None -> List.rev acc
         | Some url_marker_index ->
             let title =
               String.sub html title_start (url_marker_index - title_start)
               |> Web_crawler_html.decode_entities
             in
             let url_start = url_marker_index + String.length url_marker in
             (match String.index_from_opt html url_start '"' with
              | None -> List.rev acc
              | Some url_end ->
                  let url =
                    String.sub html url_start (url_end - url_start)
                    |> Web_crawler_url.normalize
                  in
                  let next_start = url_end + 1 in
                  if not (Web_crawler_url.is_http_url url) then loop next_start acc
                  else
                    let candidate =
                      {
                        Web_crawler_types.title = Some title;
                        url;
                        domain = Web_crawler_url.domain_of_url url;
                        snippet = None;
                        origin = Search_query query;
                        depth = 0;
                      }
                    in
                    loop next_start (candidate :: acc)))
  in
  loop 0 [] |> deduplicate_by_url

let run_query ~(config : Web_crawler_types.t) query =
  let search_url =
    Fmt.str
      "%s?q=%s&source=web"
      config.search.base_url
      (Web_crawler_url.encode_query query)
  in
  let* response =
    Web_crawler_http.fetch_text
      ~user_agent:config.search.user_agent
      ~timeout_seconds:config.search.timeout_seconds
      search_url
  in
  match response with
  | Error _ as error -> Lwt.return error
  | Ok html ->
      let results =
        parse_results ~query html
        |> List.filter (fun (candidate : Web_crawler_types.candidate) ->
               not
                 (Web_crawler_url.domain_matches
                    config.search.blocked_domains
                    candidate.domain)
               && not
                    (List.exists
                       (fun term ->
                         let pattern =
                           Str.regexp_string (String.lowercase_ascii term)
                         in
                         try
                           ignore
                             (Str.search_forward
                                pattern
                                (String.lowercase_ascii candidate.url)
                                0);
                           true
                         with Not_found -> false)
                       config.search.blocked_url_terms))
        |> fun results ->
        if List.length results > config.budget.max_results_per_query then
          take config.budget.max_results_per_query results
        else results
      in
      Lwt.return (Ok results)

open Lwt.Infix
open Lwt.Syntax

module String_set = Set.Make (String)

type state = {
  pending_queries : string list;
  searched_queries : String_set.t;
  preferred_domains : string list;
  required_terms : string list;
  must_continue : bool;
  follow_candidates : Web_crawler_types.candidate list;
  visited_urls : String_set.t;
  assessments : Web_crawler_types.assessment list;
  rounds : Web_crawler_types.round_trace list;
  reflections : string list;
  llm_calls : int;
  llm_total_tokens : int;
}

let take count items =
  let rec loop remaining acc = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | item :: rest -> loop (remaining - 1) (item :: acc) rest
  in
  loop count [] items

let unique_strings values =
  let _, deduplicated =
    List.fold_left
      (fun (seen, acc) value ->
        let normalized = String.trim value in
        if normalized = "" || String_set.mem normalized seen then seen, acc
        else String_set.add normalized seen, normalized :: acc)
      (String_set.empty, [])
      values
  in
  List.rev deduplicated

let merge_assessments current incoming =
  let table = Hashtbl.create (List.length current + List.length incoming) in
  let register (item : Web_crawler_types.assessment) =
    match Hashtbl.find_opt table item.page.url with
    | None -> Hashtbl.replace table item.page.url item
    | Some existing ->
        if item.score > existing.score then Hashtbl.replace table item.page.url item
  in
  List.iter register current;
  List.iter register incoming;
  Hashtbl.to_seq_values table |> List.of_seq |> Web_crawler_ranker.sort_assessments

let deduplicate_candidates candidates =
  let table = Hashtbl.create (List.length candidates) in
  let register (candidate : Web_crawler_types.candidate) =
    match Hashtbl.find_opt table candidate.url with
    | None -> Hashtbl.replace table candidate.url candidate
    | Some existing ->
        if candidate.depth < existing.depth then Hashtbl.replace table candidate.url candidate
  in
  List.iter register candidates;
  Hashtbl.to_seq_values table |> List.of_seq

let count_distinct_domains assessments =
  assessments
  |> List.fold_left
       (fun set (item : Web_crawler_types.assessment) ->
         String_set.add item.page.domain set)
       String_set.empty
  |> String_set.cardinal

let should_stop ~(config : Web_crawler_types.t) assessments =
  let authoritative_count =
    assessments
    |> List.filter (fun (item : Web_crawler_types.assessment) -> item.authoritative)
    |> List.length
  in
  authoritative_count >= config.stop_when.min_authoritative_pages
  && count_distinct_domains assessments >= config.stop_when.min_distinct_domains

let active_keywords ~(config : Web_crawler_types.t) state =
  Web_crawler_keywords.of_objective
    (String.concat " " (config.objective :: state.required_terms))

let dynamic_domain_bonus ~(config : Web_crawler_types.t) state domain =
  if Web_crawler_url.domain_matches state.preferred_domains domain then
    config.ranking.preferred_domain_bonus
  else 0.0

let blocked_url_term_match ~(config : Web_crawler_types.t) url =
  let lowered_url = String.lowercase_ascii url in
  List.exists
    (fun term ->
      let lowered_term = String.lowercase_ascii term in
      let pattern = Str.regexp_string lowered_term in
      try
        ignore (Str.search_forward pattern lowered_url 0);
        true
      with Not_found -> false)
    config.search.blocked_url_terms

let make_follow_candidates ~(config : Web_crawler_types.t) state new_assessments =
  let keywords = active_keywords ~config state in
  new_assessments
  |> List.concat_map (fun (assessment : Web_crawler_types.assessment) ->
         assessment.page.links
         |> List.filter_map (fun url ->
                let domain = Web_crawler_url.domain_of_url url in
                if domain = ""
                   || String_set.mem url state.visited_urls
                    || Web_crawler_url.domain_matches config.search.blocked_domains domain
                   || blocked_url_term_match ~config url
                then None
                else
                  let candidate =
                    {
                      Web_crawler_types.title = None;
                      url;
                      domain;
                      snippet = None;
                      origin = Follow_link assessment.page.url;
                      depth = assessment.candidate.depth + 1;
                    }
                  in
                  let score =
                    Web_crawler_ranker.candidate_score ~config ~keywords candidate
                  in
                  if score <= 0.0 then None else Some candidate)
         |> List.sort (fun left right ->
                let left_score =
                  Web_crawler_ranker.candidate_score ~config ~keywords left
                  +. dynamic_domain_bonus ~config state left.domain
                in
                let right_score =
                  Web_crawler_ranker.candidate_score ~config ~keywords right
                  +. dynamic_domain_bonus ~config state right.domain
                in
                Float.compare right_score left_score)
         |> take config.budget.max_followup_links_per_page)
  |> deduplicate_candidates

let heuristic_queries ~(config : Web_crawler_types.t) state missing_keywords =
  let missing = take 3 missing_keywords in
  let unhit_preferred_domains =
    config.search.preferred_domains
    |> List.filter (fun domain ->
           not
             (List.exists
                (fun (item : Web_crawler_types.assessment) ->
                  item.page.domain = domain)
                state.assessments))
  in
  let objective_tokens =
    Web_crawler_keywords.of_objective config.objective |> take 5
  in
  match missing with
  | [] -> []
  | _ ->
      let generic_query =
        String.concat " " (objective_tokens @ missing)
      in
      let site_queries =
        unhit_preferred_domains
        |> take 2
        |> List.map (fun domain ->
               Fmt.str "site:%s %s" domain generic_query)
      in
      unique_strings (generic_query :: site_queries)

let fetch_candidate
    ~(config : Web_crawler_types.t)
    ~keywords
    (candidate : Web_crawler_types.candidate)
  =
  let* response =
    Web_crawler_http.fetch_text
      ~user_agent:config.search.user_agent
      ~timeout_seconds:config.search.timeout_seconds
      candidate.Web_crawler_types.url
  in
  match response with
  | Error message ->
      Lwt.return
        (Error
           {
             Web_crawler_types.url = candidate.url;
             domain = candidate.domain;
             title = candidate.title;
             excerpt = "";
             links = [];
             keyword_hits = 0;
             note = message;
           })
  | Ok html ->
      let text = Web_crawler_html.visible_text html in
      let title =
        match Web_crawler_html.extract_title html with
        | Some _ as title -> title
        | None -> candidate.title
      in
      let excerpt = Web_crawler_html.excerpt_from_text ~keywords text in
      let page =
        {
          Web_crawler_types.url = candidate.url;
          domain = candidate.domain;
          title;
          excerpt;
          links = Web_crawler_html.extract_links ~base_url:candidate.url html;
          keyword_hits =
            Web_crawler_keywords.overlap_count
              keywords
              (String.concat
                 " "
                 (List.filter_map Fun.id [ title; Some excerpt ]));
          note = "ok";
        }
      in
      Lwt.return (Ok page)

let search_queries ~(config : Web_crawler_types.t) queries =
  let* results =
    Lwt_list.map_p
      (fun query ->
        let* result = Web_crawler_search.run_query ~config query in
        Lwt.return (query, result))
      queries
  in
  let collected =
    results
    |> List.filter_map (fun (_, result) ->
           match result with
           | Ok items -> Some items
           | Error _ -> None)
    |> List.concat
    |> deduplicate_candidates
  in
  Lwt.return collected

let next_queries state =
  state.pending_queries
  |> List.filter (fun query -> not (String_set.mem query state.searched_queries))

let select_candidates ~(config : Web_crawler_types.t) ~keywords state searched_candidates =
  let remaining_budget =
    max 0 (config.budget.max_total_pages - String_set.cardinal state.visited_urls)
  in
  if remaining_budget = 0 then []
  else
    searched_candidates @ state.follow_candidates
    |> deduplicate_candidates
    |> List.filter (fun (candidate : Web_crawler_types.candidate) ->
           not (String_set.mem candidate.url state.visited_urls)
           && not (blocked_url_term_match ~config candidate.url))
    |> List.sort (fun left right ->
           let left_score =
              Web_crawler_ranker.candidate_score ~config ~keywords left
              +. dynamic_domain_bonus ~config state left.domain
           in
           let right_score =
              Web_crawler_ranker.candidate_score ~config ~keywords right
              +. dynamic_domain_bonus ~config state right.domain
           in
           Float.compare right_score left_score)
    |> take (min config.budget.max_pages_per_round remaining_budget)

let reflect_if_needed client ~(config : Web_crawler_types.t) state queries =
  let keywords = active_keywords ~config state in
  let missing_keywords =
    Web_crawler_keywords.missing_keywords
      ~keywords
      ~texts:
        (state.assessments
        |> List.map (fun (item : Web_crawler_types.assessment) -> item.page.excerpt))
  in
  if state.llm_calls >= config.budget.max_llm_calls then
    Lwt.return (state, heuristic_queries ~config state missing_keywords, None)
  else
    match client with
    | None ->
        Lwt.return (state, heuristic_queries ~config state missing_keywords, None)
    | Some client ->
        let* reflection =
          Web_crawler_llm.reflect
            client
            ~config
            ~queries
            ~assessments:state.assessments
            ~missing_keywords
        in
        (match reflection with
         | Error message ->
             let updated_state =
               { state with reflections = message :: state.reflections }
             in
             Lwt.return
               (updated_state, heuristic_queries ~config state missing_keywords, None)
         | Ok reflection ->
             let preferred_domains =
               unique_strings (state.preferred_domains @ reflection.preferred_domains)
             in
             let required_terms =
               unique_strings (state.required_terms @ reflection.required_terms)
             in
             let updated_state =
               {
                 state with
                 preferred_domains;
                 required_terms;
                 reflections = reflection.critique :: state.reflections;
                 llm_calls = state.llm_calls + 1;
                 llm_total_tokens = state.llm_total_tokens + reflection.total_tokens;
               }
             in
             let fallback_queries =
               heuristic_queries ~config updated_state missing_keywords
             in
             let proposed_queries =
               match reflection.action with
               | `Stop -> []
               | `Continue ->
                   unique_strings (reflection.new_queries @ fallback_queries)
             in
             Lwt.return
               ( updated_state,
                 proposed_queries,
                 Some reflection.Web_crawler_types.critique ))

let build_summary assessments reflections =
  let top_sources = assessments |> Web_crawler_ranker.sort_assessments |> take 3 in
  let source_titles =
    top_sources
    |> List.map (fun (item : Web_crawler_types.assessment) ->
           Option.value item.page.title ~default:(Option.value item.candidate.title ~default:"untitled"))
  in
  let distinct_domains = count_distinct_domains assessments in
  let authoritative_count =
    assessments
    |> List.filter (fun (item : Web_crawler_types.assessment) -> item.authoritative)
    |> List.length
  in
  let source_lines =
    top_sources
    |> List.map (fun (item : Web_crawler_types.assessment) ->
           let title =
             Option.value item.page.title ~default:(Option.value item.candidate.title ~default:"untitled")
           in
           Fmt.str "- %s (%s)" title item.page.url)
  in
  let critique =
    match reflections with
    | [] -> "No LLM critique was recorded."
    | _ -> List.rev reflections |> String.concat "\n"
  in
  let summary =
    match top_sources with
    | [] -> "No convincing source was collected."
    | _ ->
        Fmt.str
          "Collected %d ranked pages across %d domains. The strongest source set combines %d authoritative pages, led by: %s."
          (List.length assessments)
          distinct_domains
          authoritative_count
          (String.concat "; " source_titles)
  in
  summary, critique, source_lines

let final_report client ~(config : Web_crawler_types.t) state =
  let heuristic_summary, critique, source_lines =
    build_summary state.assessments state.reflections
  in
  let _ = client in
  let _ = config in
  Lwt.return
    {
      Web_crawler_types.objective = config.objective;
      summary =
        String.concat
          "\n\n"
          [ heuristic_summary; "Best sources:\n" ^ String.concat "\n" source_lines ];
      critique;
      reflections = List.rev state.reflections;
      sources = take 6 state.assessments;
      rounds = List.rev state.rounds;
      llm_calls = state.llm_calls;
      llm_total_tokens = state.llm_total_tokens;
    }

let run ~(config : Web_crawler_types.t) () =
  let client =
    if config.budget.max_llm_calls <= 0 then Ok None
    else
      match Web_crawler_llm.create config with
      | Error _ as error -> error
      | Ok client -> Ok (Some client)
  in
  match client with
  | Error _ as error -> Lwt.return error
  | Ok client ->
      let initial_state =
        {
          pending_queries = config.seed_queries;
          searched_queries = String_set.empty;
          preferred_domains = config.search.preferred_domains;
          required_terms = [];
          must_continue = false;
          follow_candidates =
            config.seed_urls
            |> List.map (fun url ->
                   {
                     Web_crawler_types.title = None;
                     url;
                     domain = Web_crawler_url.domain_of_url url;
                     snippet = None;
                     origin = Seed_url;
                     depth = 0;
                   });
          visited_urls = String_set.empty;
          assessments = [];
          rounds = [];
          reflections = [];
          llm_calls = 0;
          llm_total_tokens = 0;
        }
      in
      let rec loop round_index state =
        if round_index > config.budget.max_rounds
           || (should_stop ~config state.assessments && not state.must_continue)
        then final_report client ~config state >|= fun report -> Ok report
        else
          let queries =
            next_queries state |> take config.budget.max_queries_per_round
          in
          let keywords = active_keywords ~config state in
          let* searched_candidates = search_queries ~config queries in
          let selected_candidates =
            select_candidates ~config ~keywords state searched_candidates
          in
          if selected_candidates = [] then
            final_report client ~config state >|= fun report -> Ok report
          else
            let* fetched =
              Lwt_list.map_p
                (fetch_candidate ~config ~keywords)
                selected_candidates
            in
            let new_assessments =
              fetched
              |> List.filter_map (function
                   | Error _ -> None
                   | Ok (page : Web_crawler_types.fetched_page) ->
                       let candidate =
                         List.find
                           (fun (candidate : Web_crawler_types.candidate) ->
                             candidate.url = page.url)
                           selected_candidates
                       in
                       Some
                         (Web_crawler_ranker.assessment
                            ~config
                            ~keywords
                            candidate
                            page))
              |> Web_crawler_ranker.sort_assessments
            in
            let assessments =
              merge_assessments state.assessments new_assessments
            in
            let visited_urls =
              selected_candidates
              |> List.fold_left
                   (fun visited (candidate : Web_crawler_types.candidate) ->
                     String_set.add candidate.url visited)
                   state.visited_urls
            in
            let base_state =
              {
                state with
                searched_queries =
                  List.fold_left
                    (fun searched query -> String_set.add query searched)
                    state.searched_queries
                    queries;
                visited_urls;
                assessments;
              }
            in
            let follow_candidates =
              make_follow_candidates ~config base_state new_assessments
            in
            let with_follow_candidates =
              { base_state with follow_candidates }
            in
            let* reflected_state, proposed_queries, critique =
              reflect_if_needed client ~config with_follow_candidates queries
            in
            let next_state =
              {
                reflected_state with
                must_continue = false;
                pending_queries =
                  unique_strings
                    (proposed_queries @ reflected_state.pending_queries);
                rounds =
                  {
                    Web_crawler_types.round_index;
                    queries;
                    fetched_urls =
                      selected_candidates
                      |> List.map (fun (candidate : Web_crawler_types.candidate) ->
                             candidate.url);
                    top_urls =
                      assessments
                      |> take 3
                      |> List.map (fun (item : Web_crawler_types.assessment) ->
                             item.page.url);
                    critique;
                  }
                  :: reflected_state.rounds;
              }
            in
            let next_state =
              match critique with
              | Some _ when proposed_queries <> [] -> { next_state with must_continue = true }
              | _ -> next_state
            in
            loop (round_index + 1) next_state
      in
      loop 1 initial_state

open Cmdliner

let scenario_path =
  let doc = "Path to the adaptive crawler scenario JSON file." in
  Arg.(
    value
    & opt string "demos/adaptive_webcrawler/scenario.json"
    & info [ "scenario" ] ~docv:"FILE" ~doc)

let objective =
  let doc = "Override the scenario objective." in
  Arg.(value & opt (some string) None & info [ "objective" ] ~docv:"TEXT" ~doc)

let query =
  let doc = "Override the seed query list with a single starting query." in
  Arg.(value & opt (some string) None & info [ "query" ] ~docv:"TEXT" ~doc)

let seed_queries
    ~objective
    ~query
    (config : Agent_graph.Web_crawler.Types.t)
  =
  match query with
  | Some query -> [ query; Fmt.str "%s official tutorial" query ]
  | None ->
      (match objective with
       | Some objective ->
           [ objective; Fmt.str "%s official source" objective ]
       | None -> config.seed_queries)

let render_round (round : Agent_graph.Web_crawler.Types.round_trace) =
  let critique =
    match round.critique with
    | None -> ""
    | Some critique -> Fmt.str "  critique: %s\n" critique
  in
  Fmt.str
    "round %d\n  queries: %s\n  fetched: %s\n  top: %s\n%s"
    round.round_index
    (String.concat " | " round.queries)
    (String.concat " | " round.fetched_urls)
    (String.concat " | " round.top_urls)
    critique

let render_source (item : Agent_graph.Web_crawler.Types.assessment) =
  let title =
    Option.value item.page.title ~default:(Option.value item.candidate.title ~default:"untitled")
  in
  Fmt.str
    "- %.2f | %s | %s\n  %s"
    item.score
    item.page.domain
    title
    item.page.url

let run scenario_path objective query =
  match Agent_graph.Web_crawler.Config.load scenario_path with
  | Error message -> `Error (false, message)
  | Ok config ->
      let config =
        {
          config with
          objective = Option.value objective ~default:config.objective;
          seed_queries = seed_queries ~objective ~query config;
        }
      in
      (match Lwt_main.run (Agent_graph.Web_crawler.Runner.run ~config ()) with
       | Error message -> `Error (false, message)
       | Ok report ->
           Fmt.pr "task_id: %s\n" config.task_id;
           Fmt.pr "objective: %s\n" report.objective;
           Fmt.pr "llm_calls: %d\n" report.llm_calls;
           Fmt.pr "llm_total_tokens: %d\n\n" report.llm_total_tokens;
           Fmt.pr "summary\n%s\n\n" report.summary;
           Fmt.pr "critique\n%s\n\n" report.critique;
           Fmt.pr
             "sources\n%s\n\n"
             (report.sources |> List.map render_source |> String.concat "\n");
           Fmt.pr
             "rounds\n%s\n"
             (report.rounds |> List.map render_round |> String.concat "\n");
           `Ok ())

let command =
  let doc = "Run the adaptive real-web crawler demo." in
  let info = Cmd.info "adaptive-webcrawler-demo" ~doc in
  Cmd.v info Term.(ret (const run $ scenario_path $ objective $ query))

let () = exit (Cmd.eval command)

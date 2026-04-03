let sum_floats values = List.fold_left ( +. ) 0.0 values

let float_of_int = Float.of_int

let contains_substring ~substring value =
  let pattern = Str.regexp_string substring in
  try
    ignore (Str.search_forward pattern value 0);
    true
  with Not_found -> false

let matches_preferred_domain config domain =
  Web_crawler_url.domain_matches config.Web_crawler_types.search.preferred_domains domain

let matches_blocked_domain config domain =
  Web_crawler_url.domain_matches config.Web_crawler_types.search.blocked_domains domain

let candidate_score
    ~(config : Web_crawler_types.t)
    ~keywords
    (candidate : Web_crawler_types.candidate)
  =
  let lowered_url = String.lowercase_ascii candidate.url in
  let title_score =
    match candidate.Web_crawler_types.title with
    | None -> 0.0
    | Some title ->
        float_of_int (Web_crawler_keywords.overlap_count keywords title)
        *. config.ranking.keyword_title_weight
  in
  let url_score =
    float_of_int (Web_crawler_keywords.overlap_count keywords candidate.url)
    *. config.ranking.keyword_url_weight
  in
  let preferred_url_bonus =
    config.ranking.preferred_url_terms
    |> List.fold_left
         (fun total term ->
           if contains_substring
                ~substring:(String.lowercase_ascii term)
                lowered_url
           then total +. 1.0
           else total)
         0.0
  in
  let penalized_url_penalty =
    config.ranking.penalized_url_terms
    |> List.fold_left
         (fun total term ->
           if contains_substring
                ~substring:(String.lowercase_ascii term)
                lowered_url
           then total +. 1.0
           else total)
         0.0
  in
  let domain_bonus =
    if matches_preferred_domain config candidate.domain then
      config.ranking.preferred_domain_bonus
    else 0.0
  in
  let blocked_penalty =
    if matches_blocked_domain config candidate.domain then
      config.ranking.blocked_domain_penalty
    else 0.0
  in
  let depth_penalty =
    float_of_int candidate.depth *. config.ranking.link_depth_penalty
  in
  sum_floats
    [
      title_score;
      url_score;
      domain_bonus;
      blocked_penalty;
      preferred_url_bonus;
      -.penalized_url_penalty;
      -.depth_penalty;
    ]

let assessment ~(config : Web_crawler_types.t) ~keywords candidate page =
  let text_score =
    float_of_int page.Web_crawler_types.keyword_hits
    *. config.ranking.text_keyword_weight
  in
  let candidate_pre_score = candidate_score ~config ~keywords candidate in
  let authoritative =
    matches_preferred_domain config candidate.domain && page.keyword_hits > 0
  in
  let reasons =
    [
      (if authoritative then Some "preferred_domain" else None);
      (if page.keyword_hits > 0 then
         Some (Fmt.str "keyword_hits=%d" page.keyword_hits)
       else None);
      (match candidate.origin with
       | Seed_url -> Some "seed_url"
       | Search_query query -> Some (Fmt.str "search=%s" query)
       | Follow_link parent -> Some (Fmt.str "follow=%s" parent));
    ]
    |> List.filter_map Fun.id
  in
  {
    Web_crawler_types.candidate;
    page;
    score = candidate_pre_score +. text_score;
    authoritative;
    reasons;
  }

let sort_assessments items =
  List.sort
    (fun left right ->
      match Float.compare right.Web_crawler_types.score left.score with
      | 0 ->
          String.compare
            left.page.Web_crawler_types.url
            right.page.Web_crawler_types.url
      | other -> other)
    items

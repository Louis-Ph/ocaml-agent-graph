type prompt_profile = {
  model : string;
  prompt : string;
  max_tokens : int option;
}

type llm_config = {
  gateway_config_path : string;
  authorization_token_plaintext : string option;
  authorization_token_env : string option;
  reflector : prompt_profile;
  reporter : prompt_profile;
}

type budget = {
  max_rounds : int;
  max_queries_per_round : int;
  max_results_per_query : int;
  max_pages_per_round : int;
  max_total_pages : int;
  max_followup_links_per_page : int;
  max_llm_calls : int;
}

type ranking = {
  preferred_domain_bonus : float;
  blocked_domain_penalty : float;
  keyword_title_weight : float;
  keyword_url_weight : float;
  text_keyword_weight : float;
  link_depth_penalty : float;
  preferred_url_terms : string list;
  penalized_url_terms : string list;
}

type search_config = {
  provider : string;
  base_url : string;
  user_agent : string;
  timeout_seconds : float;
  preferred_domains : string list;
  blocked_domains : string list;
  blocked_url_terms : string list;
}

type stop_condition = {
  min_authoritative_pages : int;
  min_distinct_domains : int;
}

type t = {
  scenario_name : string;
  task_id : string;
  objective : string;
  seed_queries : string list;
  seed_urls : string list;
  llm : llm_config;
  budget : budget;
  ranking : ranking;
  search : search_config;
  stop_when : stop_condition;
  output_template : string option;
}

type discovery_origin =
  | Seed_url
  | Search_query of string
  | Follow_link of string

type candidate = {
  title : string option;
  url : string;
  domain : string;
  snippet : string option;
  origin : discovery_origin;
  depth : int;
}

type fetched_page = {
  url : string;
  domain : string;
  title : string option;
  excerpt : string;
  links : string list;
  keyword_hits : int;
  note : string;
}

type assessment = {
  candidate : candidate;
  page : fetched_page;
  score : float;
  authoritative : bool;
  reasons : string list;
}

type reflection = {
  action : [ `Continue | `Stop ];
  critique : string;
  new_queries : string list;
  preferred_domains : string list;
  required_terms : string list;
  prompt_tokens : int;
  completion_tokens : int;
  total_tokens : int;
}

type round_trace = {
  round_index : int;
  queries : string list;
  fetched_urls : string list;
  top_urls : string list;
  critique : string option;
}

type run_report = {
  objective : string;
  summary : string;
  critique : string;
  reflections : string list;
  sources : assessment list;
  rounds : round_trace list;
  llm_calls : int;
  llm_total_tokens : int;
}

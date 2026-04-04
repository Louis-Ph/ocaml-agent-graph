(lang dune 3.21)

(name ocaml-agent-graph)

(generate_opam_files true)

(package
 (name ocaml-agent-graph)
 (synopsis "Typed multi-agent orchestration in OCaml")
 (license "Apache-2.0")
 (authors "Louis-Ph")
 (maintainers "Louis-Ph")
 (homepage "https://github.com/Louis-Ph/ocaml-agent-graph")
 (bug_reports "https://github.com/Louis-Ph/ocaml-agent-graph/issues")
 (description
  "Modular LangGraph/CrewAI-inspired orchestration runtime in OCaml with Lwt, typed routing, retries, timeouts, and tests.")
 (depends
  (ocaml
   (>= 5.2.0))
  (dune
   (>= 3.21))
  lwt
  yojson
  fmt
  aegis_lm
  cmdliner
  (alcotest :with-test)))

# reqweaver: Software Design Document

## 1. Introduction

reqweaver is a schedule planner for high school students who want to
bank college credit before college starts. This document specifies the
system design: the data model, the planning engine, the scoring layer,
the frontend, and the storage service. The audience is anyone
implementing or reviewing the system.

Glossary:

- DAG: directed acyclic graph. Courses are nodes; prerequisite edges
  point from a course to the courses it requires.
- Dual enrollment: a high school student taking courses at a partner
  college for both high school and college credit.
- Articulation: the mapping from an exam score (AP, IB, or any
  registered exam system) or a college course to a specific
  requirement of a college major.
- Specsheet: a YAML file describing one school's catalog or one
  major's requirements. Specsheets are the only source of school- and
  major-specific behavior.
- Banked credit: college credit a student holds before matriculating,
  earned through exams or dual enrollment.

## 2. Product overview

Course catalogs, prerequisite chains, graduation requirements, and
transfer rules together form a planning problem that students and
counselors solve by hand, usually badly: a prerequisite skipped in
grade 9 can silently cost an AP course in grade 12. reqweaver solves
the problem mechanically. The student picks their high school and
enters where they stand: courses completed (including courses taken
before grade 9, such as a language sequence or Algebra and Geometry
finished in middle school), courses in progress this term, exam
scores, and any future courses they have already committed to. The
planner treats all of that as fixed and builds around it. The student
then optionally picks a target major, chooses an objective, sets a
rigor preference (0 to 1: from the gentlest track that meets
requirements to the most intense variant prerequisites allow), opts
in or out of summer terms per year, and receives a small set of
complete term-by-term plans.

Real schools grant exceptions the catalog cannot express: placement
tests, counselor approval, doubling up. The planner is strict by
default but never final. A pinned course is always honored even when
it breaks a rule (the broken rule becomes a warning to take to a
counselor), and a waiver marks a course whose prerequisites the
school has excused. As terms finish, the student records what
happened and re-solves; a plan is a living document, not a one-shot
output.

The four objectives, selected by the student:

- Maximize banked credits: earn the most college credit before
  matriculating.
- Maximize major progress: cover the most of the chosen major's
  requirement checklist, weighted by credits, whether or not that
  maximizes raw credit.
- Fastest college finish: plan high school so the eventual degree
  completes in the fewest college terms.
- Early high school graduation: finish high school graduation
  requirements in the fewest terms, tie-broken by banked credit.

The system works for any school. There is no school-specific code
anywhere; every behavior that differs between schools comes from data
(section 3.1), and a school not yet covered can be added by writing
one file (section 4.4).

Non-goals for v1:

- Timetabling. reqweaver plans which courses go in which term, not
  which period or section. Section times, lunch conflicts, and teacher
  assignments are out of scope.
- Email. Accounts are a username and a password, nothing else: no
  email collection, no verification mail, no recovery mail
  (section 9.4).
- Policy modeling beyond the specsheet. Unwritten local rules
  (counselor approval, seat limits) are not modeled; plans are
  proposals to bring to a counselor, and the UI says so.

## 3. System architecture

Three parts:

1. A static frontend on Cloudflare Pages, written in LiveScript. All
   planning computation runs in the browser; the app is fully
   functional without the backend except for saving and sharing.
2. A Cloudflare Worker for accounts and saved-plan storage, backed by
   Workers KV (plan blobs) and D1 (accounts, sessions, plan
   ownership). The future AI advisor (section 14.2) adds a proxy
   route here.
3. A public community data repository of YAML specsheets, compiled to
   JSON at build time and served as static Pages assets.

```
  specsheets repo (GitHub) --merge--> build step --JSON--> Cloudflare Pages
                                                               |
                                              static app + data chunks
                                                               |
                                                           browser
                                              (DAG build, search, scoring)
                                                               |
                                                    save / load / share
                                                               |
                                                     Cloudflare Worker
                                                               |
                                                      Workers KV + D1
```

The frontend-only compute model is a deliberate choice: the solver's
inputs are small (one school catalog, one or two college catalogs, one
major sheet), the search fits comfortably in a browser (section 11),
and keeping student data out of the server is a privacy feature
(section 12).

### 3.1 Data-driven core

The engine is generic; the data is specific. Code implements a small
fixed vocabulary: courses with credits, prerequisite and corequisite
edges, a term calendar, availability and grade windows, load caps,
requirement predicates, exams, and articulation. Every concrete
instance of those concepts is data interpreted through that
vocabulary: which terms exist and in what order, what course levels
mean, which exam systems exist, what a credit unit is, and what any
particular school or major requires.

The rule this implies: adding a school, a college, a major, an exam
system (AP, IB, CLEP, A-levels), a term calendar (semester,
trimester, quarter, block), or a credit unit is a data contribution
and changes no code. If a proposed feature needs a school name, exam
name, or term name in code, the design is wrong; the concept behind
it belongs in the vocabulary and the instance belongs in a specsheet
or registry. Section 13 makes this rule a tested invariant.

## 4. Data model and specsheet formats

Two specsheet kinds live in one public repository: school sheets and
major sheets. Both carry `schema_version` (an integer; the app
declares the range it supports, and breaking changes bump it) and
`catalog_year` (content versioning; a school may have one file per
year). Saved plans pin the exact data revision they were built
against (section 9.3).

### 4.1 School specsheet

One file per institution. High schools and colleges share the format;
`kind` distinguishes them, and college sheets omit the fields that
only make sense for high schools. This shared format is what lets the
future college optimizer (section 14.1) consume the same data with no
migration.

```yaml
specsheet: school
schema_version: 1
catalog_year: 2026
id: us/tx/austin/westlake-hs
kind: high_school            # high_school | college
name: Westlake High School
credit_unit: carnegie        # id from registry/credit-units.yaml
terms_per_year:              # the calendar is data, not an enum
  - { id: fall,   sequence: 1 }
  - { id: spring, sequence: 2 }
  - { id: summer, sequence: 3, optional: true }
grade_levels: [9, 10, 11, 12]
max_credits_per_term: 4.0
pre_hs_credit:               # courses completed before grade 9
  satisfies_prereqs: true
  counts_toward_grad: true   # district policy; some award prereq standing only

grad_requirements:            # high_school only
  - id: english
    label: English
    credits: 4.0
    satisfied_by: { tag: english }
  - id: math
    label: Mathematics
    credits: 4.0
    satisfied_by: { tag: math }

courses:
  - id: ALG2
    name: Algebra II
    description: Extends linear and quadratic reasoning to polynomial,
      rational, exponential, and logarithmic functions.
    credits: 1.0
    tags: [math]
    level: regular            # id from registry/levels.yaml
    difficulty: 3             # 1-5, contributor estimate, scorer input only
    offered_terms: [fall, spring]   # ids from terms_per_year
    grade_levels: [10, 11, 12]
    prereqs:
      all_of: [GEOM]
      any_of: []              # nests one level: [[A, B], C] = (A or B) and C
    coreqs: []
  - id: AP-CALC-AB
    name: AP Calculus AB
    credits: 1.0
    tags: [math]
    level: ap
    exam: AP_CALC_AB          # canonical id from registry/exams.yaml
    offered_terms: [fall]
    grade_levels: [11, 12]
    prereqs: { all_of: [PRECAL] }

dual_enrollment:
  partners:
    - college: us/tx/austin/austin-cc
      min_grade_level: 11
      max_courses_per_term: 2
      eligible_courses: all   # or an explicit list of college course ids
```

Rules:

- Unlock edges are never stored. "What does this course unlock" is the
  reverse of the prerequisite relation and is derived at load time;
  storing both invites contradiction.
- Corequisites are symmetric. The data pipeline normalizes them and
  rejects asymmetric pairs.
- `difficulty` feeds only the soft scorer (section 7). It never
  affects feasibility.
- Term ids are defined by the sheet's own `terms_per_year` and mean
  nothing outside it. The engine sees an ordered calendar with
  optional terms; "fall" and "spring" are contributor vocabulary, and
  a trimester or block-schedule school defines a different list.
- `level` and `credit_unit` are references into the registries
  (section 4.3). The engine never matches on a level id; it reads the
  attributes the registry attaches to it.
- Graduation requirement predicates are data, and each requirement
  tracks its own credits: a tag match as shown, an explicit course
  list (`satisfied_by: { courses: [...] }`), or content groups
  (`satisfied_by: { content: [...] }`), which express
  course-specific sequences like "English 9 through 12" while letting
  every placement tier of a slot satisfy it. New predicate kinds
  extend the schema, not any school's code path, because no school
  has one.
- `pre_hs_credit` is the district's policy on courses completed
  before grade 9. Prerequisite standing always transfers (a student
  who finished Geometry in middle school is eligible for Algebra II);
  whether those credits also count toward graduation requirements
  varies by district, and the flag records it.
- Every course carries a free-text `description` taken from the
  catalog. It is display material and context for the AI advisor
  (section 14.2); the engine never parses it and it has no effect on
  feasibility or scoring.
- Per-term load caps can be expressed in credits
  (`max_credits_per_term`), in courses (`max_courses_per_term`), or
  both; the engine enforces whichever are present.
- Courses sharing an optional `content` group id are variants of the
  same material at different rigor tiers (2YR, regular, and honors
  Algebra 2). A plan takes at most one course per content group, and
  the student's rigor preference picks which variant ranks first.
- An optional `excludes` list handles variant shapes a content group
  cannot: where a prerequisite chain connects two variants (the first
  year of 2YR Algebra 2 versus the one-year courses), listing ids in
  `excludes` keeps them from ever co-occurring in a plan. The engine
  treats the exclusion as symmetric.
- Content groups also carry prerequisite standing: a prerequisite
  naming one variant is satisfied by any completed course in the same
  group. Catalogs write "Prerequisite: English 11" but the scrape
  resolves it to a single id; without this rule a student who took AP
  Language for the English 11 slot could never take English 12.
- Prerequisites come in two forms. The compact `prereqs` shape
  (all_of plus one-level any_of groups) covers most catalogs. A course
  may instead carry `requires`, a recursive boolean tree for
  irregular shapes like "a or (c and (b or d))":
  `requires: { any: [A, { all: [C, { any: [B, D] }] }] }`.
- A term entry in `terms_per_year` may declare `any_offering: true`,
  marking an open term (summer school) whose course list varies year
  to year: the planner may place any course there and warns the
  student to verify the offering. `max_courses` on a term entry caps
  that term alone.
- Engine tuning (search width, objective weights, candidate priority
  weights) ships in `weights/engine.yaml`; the code carries matching
  defaults but the file is the tuning surface.

### 4.2 Major specsheet

One file per (institution, major, catalog year).

```yaml
specsheet: major
schema_version: 1
catalog_year: 2026
id: us/tx/ut-austin/cs-bs
name: Computer Science BS
institution: us/tx/ut-austin
total_credits: 120
typical_term_load: 15         # used by the fastest-college-finish estimator

requirements:
  - id: calc1
    label: Calculus I
    credits: 4
    satisfied_by:
      - course: { school: us/tx/austin/austin-cc, id: MATH-2413 }
      - exam:   { id: AP_CALC_AB, min_score: 4 }
      - exam:   { id: AP_CALC_BC, min_score: 3 }
  - id: cs1
    label: Intro Programming
    credits: 4
    satisfied_by:
      - course: { school: us/tx/austin/austin-cc, id: COSC-1436 }
      - exam:   { id: AP_CS_A, min_score: 4 }
  - id: free-electives
    label: Free Electives
    credits: 12
    satisfied_by:
      - any_transferable: { min_credits: 1 }
```

Articulation is exactly the `satisfied_by` list: exam entries map an
exam score to a requirement, course entries map a dual-enrollment
course to a requirement, and `any_transferable` accepts overflow.

Consumption rule: a single course or exam satisfies at most one named
requirement. When a course could satisfy several, the planner assigns
it where it helps the objective most; credit not consumed by a named
requirement spills into `any_transferable` slots. This rule is the
subtlest part of the data model; implementations must not double-count
one course against two named requirements.

Each articulation entry may carry `verified: true` when a contributor
confirmed it against the institution's published transfer tables.
Unverified entries render as estimates in the UI (section 15, risk 2).

### 4.3 Canonical registries

Registries are the shared vocabulary between specsheets, and they are
data like everything else:

- `registry/exams.yaml`: canonical exam ids, grouped by exam system
  (AP, IB, CLEP, A-levels, ...), each with its score scale. Adding an
  exam system is a registry pull request.
- `registry/tags.yaml`: canonical subject tags used by courses and
  graduation requirement predicates.
- `registry/levels.yaml`: course level ids with the attributes the
  engine and scorer consume: `exam_bearing` (the course targets a
  registry exam), `college_credit` (credit banks directly), and
  `intensity_weight` (scorer input). The engine reads attributes, not
  level names, so a new level (a national curriculum's honors tier, a
  cambridge level) is a registry entry.
- `registry/credit-units.yaml`: credit unit ids (carnegie unit,
  semester credit hour, ...) with conversion factors to a common
  base, so plans that mix a high school's units with a college's sum
  correctly.

Specsheets reference registry ids; the pipeline rejects unknown ones.
Registries keep "AP Calculus AB" from appearing under five spellings
across five schools.

### 4.4 Works for any school

Adding a school means adding one YAML file; nothing else in the
system changes, whatever the school's calendar, credit system, level
scheme, or exam offerings, because all four are expressed through the
vocabulary of section 3.1. To serve students whose school has no
sheet yet, the app also
loads a local specsheet directly: paste or upload YAML, validated in
the browser against the same JSON Schema the pipeline uses. A locally
loaded sheet behaves identically to a published one, and the app
prompts the student to contribute it upstream as a pull request.

## 5. Community data pipeline

Repository layout:

```
schools/us/tx/austin/westlake-hs.yaml
schools/us/tx/austin/austin-cc.yaml     # colleges are schools with kind: college
majors/us/tx/ut-austin/cs-bs.yaml
registry/exams.yaml
registry/tags.yaml
registry/levels.yaml
registry/credit-units.yaml
schemas/school.v1.json
schemas/major.v1.json
```

Pull request CI validates every changed file: YAML parse, JSON Schema
validation (ajv), referential integrity (every prereq, coreq, partner
college, and articulation reference resolves, including cross-file
references), prerequisite acyclicity, corequisite symmetry, and
registry membership for exam ids and tags. CODEOWNERS follows the
geographic path so contributors near a school review changes to it.
Schema migrations ship as scripts in this repository and run in CI
over the whole tree, so a version bump never strands contributor
files.

Semantic assets ship separately from the app bundle. Per-school course
embeddings (about 1.3 MB each) are static Pages assets beside the
catalog and load with the school. The MiniLM weight export (86 MB)
exceeds the Pages per-file limit, so it lives in a Cloudflare R2
bucket exposed on the site's own domain: R2 egress is free, the blob
rides the same CDN cache, and a content-hashed filename with an
immutable cache header means a browser fetches it at most once and
the edge usually already has it. The app fetches the model lazily,
only the first time a profile states a free-text goal; everything
else works without it. At student-scale traffic the whole arrangement
stays inside Cloudflare's free tiers.

Distribution is a build step, not a runtime fetch. On merge (via
repository_dispatch) and on a daily cron, the app's build pulls the
data repository, re-runs validation, compiles the YAML into one JSON
chunk per school and per major plus a small directory index, and
publishes them as static assets in the Pages deploy. This keeps YAML
parsing out of the client, avoids GitHub rate limits and uptime
coupling, and versions the data atomically with the app. The cost is
freshness on the order of hours, which is acceptable for course
catalogs.

Until that repository exists, `npm run build:web` stages the
specsheets, registries, and weights files of this repository under
`public/data/` with a generated school index, and the client parses the
YAML. The index is what the app offers in its school picker, so adding
a sheet under `specsheets/schools/` is enough to make it selectable.

## 6. Core planning engine

The engine is symbolic and exact about feasibility. It runs in a Web
Worker and is written, like the rest of the app, in LiveScript with no
solver dependency.

### 6.1 Problem framing

A plan assigns courses to terms t = 1..T. The term sequence is the
school's `terms_per_year` calendar unrolled over its grade span;
optional terms (a summer session, an intersession block) join the
sequence where the student opts in, per year, so a student can take
the summer after grade 10 and skip the others. Summer opt-in is the
acceleration lever: a sequence course cleared in an optional term
frees a regular-term slot and pulls every downstream course earlier.
Hard constraints:

- Every prerequisite is assigned to a strictly earlier term or already
  satisfied by the student's profile (completed courses, placement).
- Corequisites share a term.
- A course is only assigned to a term whose id appears in its
  `offered_terms`.
- Per-term credit caps: the school cap, the student's own limit, and
  the dual-enrollment partner's per-term course cap.
- Grade-level windows and dual-enrollment minimum grade level.
- Courses in progress this term and courses the student pinned to a
  future term keep those assignments. The search plans around them,
  and they consume their term's caps like anything else. A pin is an
  override: it is always honored, and any school rule it breaks is
  reported as a warning to check with a counselor, never a refusal.
  Only a pin that cannot mean anything (an unknown course id, a
  course already taken) is skipped, with a warning.
- A profile waiver stands in for a course's prerequisites (placement
  test, teacher recommendation); the other rules still apply to the
  waived course.
- At most one course per `content` group (section 4.1), and explicit
  `excludes` pairs never co-occur; variants of the same material
  never both earn credit.
- High school graduation requirements are fully covered by the final
  term.

### 6.2 Preprocessing

Once per student profile:

1. Merge the school catalog with partner college catalogs, normalize
   credits to a common base via the credit-unit registry, apply
   dual-enrollment eligibility, and build the DAG. Re-check
   acyclicity defensively even though CI enforces it.
2. Collapse corequisite groups into super-nodes whose credits sum and
   whose availability is the intersection of members.
3. Compute each node's earliest feasible term (forward topological
   pass over grade windows and availability) and latest useful term
   (backward pass: the last term where taking it can still contribute
   to any objective). Prune nodes with an empty window.
4. Compute static node potentials: critical-path length (longest
   downstream prerequisite chain to an objective-relevant course),
   unlock count (reachable descendants), credit yield (banked credit
   via articulation), and a requirement-coverage vector against the
   chosen major.
5. Seed the initial search state from the profile: completed courses,
   including those finished before grade 9 (these always satisfy
   prerequisites; they carry graduation credit only where the
   school's `pre_hs_credit` policy grants it), the current term's
   in-progress courses as a fixed assignment, and any pinned future
   assignments. The search begins from this partial plan rather than
   an empty one.

### 6.3 Objective functions

All objectives are exact symbolic scores over a complete plan:

- Maximize banked credits: sum of dual-enrollment credits plus exam
  articulation credits. Exam credit counts only when the major sheet
  articulates the exam; without a chosen major, a conservative global
  default table applies and the result is labeled an estimate.
- Maximize major progress: credit-weighted count of named requirement
  slots satisfied, under the consumption rule of section 4.2.
- Fastest college finish: compute residual major requirements after
  articulation, then estimate remaining college terms by greedy
  bin-packing residual credits into terms of `typical_term_load`,
  respecting the college-side prerequisite DAG. This is a fast lower
  bound, not a full solve; the UI labels it an estimate, and the
  college optimizer (section 14.1) replaces exactly this function.
- Early graduation: search shortened horizons T' < T, accept only
  plans that cover graduation requirements, prefer minimal T',
  tie-break by banked credits.

For the two time-oriented objectives, the longest remaining
prerequisite chain among still-needed courses is an admissible lower
bound on remaining terms and drives pruning.

### 6.4 Search: heuristic-guided beam search

The engine uses term-by-term beam search. Alternatives considered and
rejected: an ILP or CP formulation needs a WASM solver measured in
megabytes, is hard to make interactive and anytime, and expresses the
learned soft score poorly; pure greedy per-term selection is myopic
and never takes the unrewarding grade 9 prerequisite whose payoff
lands in grade 12. Beam search is anytime, bounded in memory,
deterministic with stable sorting, and gives the soft scorer a natural
slot. Greedy priority ordering survives inside candidate generation.

State: (term index, completed-course set, requirement coverage,
accumulated objective value). The beam holds W states (default 100,
exposed to the user as a search-effort setting).

Expanding one state:

1. Candidates for the next term: available, eligible, prerequisites
   met, still within the latest-useful-term window.
2. Rank candidates by a mix of critical-path urgency, unlock value,
   objective yield, requirement coverage (courses carrying a tag with
   an unmet graduation requirement outrank electives), continuation
   (a course whose prerequisite was taken in the immediately
   preceding term ranks up, so semester halves stay consecutive), and
   closeness to the student's rigor target; keep the top K
   (default 14). Unlock
   value is the gateway rule: a course that many later courses
   require ranks ahead of an equal-credit leaf, so the most-required
   courses clear as early as possible and each term keeps the most
   options open for the terms after it.
3. Enumerate feasible subsets of those K under the credit and
   dual-enrollment caps by depth-first search with pruning, treating
   coreq super-nodes as atomic. Cap subsets per state at M (default
   40), preferring maximal subsets for the credit and progress
   objectives and requirement-critical subsets for the time
   objectives.
4. Score each successor as g + h: the exact objective so far plus an
   optimistic admissible remainder (attainable credits still in
   window, or negative remaining critical path). The soft score
   (section 7) is a secondary sort key applied only among states whose
   g + h values fall within an epsilon band, so it breaks ties without
   steering the search away from the objective.
5. Keep the top W successors under that lexicographic order.

After the final term, deduplicate complete feasible plans by
assignment signature, take the top N (default 20) by objective value,
hand those to the scorer for final ranking, and render the top 3 to 5
with human-readable diffs ("Plan B trades one AP course for a lighter
junior year").

Determinism: seeded tie-breaking and stable sorts, so identical inputs
always produce identical plans. Share links and bug reports depend on
this.

## 7. Plan scoring

The scorer orders plans that are already feasible. It is a function
from a feature vector to a scalar, and that interface never changes
across backends.

Invariant: the scorer can never make an infeasible plan visible or a
feasible plan invisible. The symbolic engine selects the top-N plans
by objective before the scorer sees anything, and every hard
constraint is checked before scoring.

### 7.1 Features

About twenty per-plan features, each normalized to [0, 1]. The set
includes: per-term credit-load variance; the maximum count of
exam-bearing courses in any single term; difficulty-weighted load
variance; final-year slack; count of terms with more than two hard
courses;
articulation confidence (fraction of banked credit backed by verified
`satisfied_by` entries rather than default estimates); major-fit ratio
(credit applied to named requirements versus `any_transferable`);
clustering of dual-enrollment courses into fewer terms; and
prerequisite slack (how many alternative paths remain if one course
is failed or unavailable). The full list is appendix C.

Features follow the data-driven rule of section 3.1: they are
computed from registry attributes (`exam_bearing`,
`intensity_weight`, `optional` terms), never from level, exam, or
term names, so they apply unchanged to any school.

### 7.2 Backends

Phase 0, shipping in v1: a hand-tuned linear model. Weights live in a
versioned `scorer-weights.yaml`; the forward pass is a dot product.
Tuning the product's taste means editing a JSON file, not code.

Phase 1: learned weights from implicit preferences. When the student
saves one of several shown plans, an optional anonymous event records
the pairwise preference (section 9.2). Offline training in Python fits
a Bradley-Terry pairwise ranking model, first refitting the linear
weights, later a small MLP (20 -> 16 -> 8 -> 1, on the order of 500
parameters), exported to the same weights file. The client forward
pass for either
backend is about fifty lines of LiveScript: dot products and ReLU.

onnxruntime-web was considered and rejected: a multi-megabyte WASM
dependency to execute a model this size is not justified when a
hand-written forward pass is smaller and auditable. If training data
never accumulates, the linear model stands on its own; the MLP is
upside, not a dependency.

### 7.3 Semantic goal matching

The one place a pretrained model earns its keep is understanding what
courses are about. The data pipeline embeds every course's name and
description once at compile time with an open-source sentence encoder
(all-MiniLM-L6-v2), shipping one vector per course in an
`embeddings.<school>.json` file beside the school's specsheet. The student states a free-text goal ("quantum
theory and theoretical physics research"); the app encodes it with a
LiveScript implementation of the same encoder's forward pass
(tokenizer, six transformer layers, mean pooling), whose weights are
exported to a binary blob and fetched lazily the first time a goal is
entered. A parity test holds the LiveScript encoder to the reference
implementation's output.

At plan time everything is cosine similarity: a goal-affinity term in
candidate priority steers free capacity toward goal-relevant courses
(a physics AP over a music elective for a physics-bound student), and
a goal-match scorer feature ranks whole plans. Both are inert when a
school has no embeddings or a profile no goal, and neither can affect
feasibility.

## 8. Frontend application

LiveScript modules, compiled to JS at build time:

```
src/ui/app.ls           # entry, data loading, state wiring
src/ui/state.ls         # profile + UI state, localStorage, YAML export/import
src/ui/data.ls          # school index and specsheet fetch
src/ui/catalog.ls       # read-only views over a specsheet
src/ui/dom.ls           # element helpers
src/ui/chip.ls          # course chips, searchable course picker
src/ui/course.ls        # course detail dialog with profile actions
src/ui/profile.ls       # profile editor sections
src/ui/plans.ls         # term grid, requirement checklist, warnings, diffs
src/ui/solver.ls        # worker client
src/ui/index.html       # page shell
src/ui/styles.css       # the whole stylesheet
src/worker.ls           # Web Worker entry wrapping engine + scoring
src/engine/dag.ls       # DAG build, coreq collapse, window passes, constraints
src/engine/search.ls    # beam search, objectives, heuristics
src/scoring/features.ls # feature extraction
src/scoring/scorer.ls   # weight-file forward pass
src/tools/webdata.ls    # stages public/, generates the school index
src/tools/serve.ls      # static server for local testing
```

`npm run build:web` compiles the LiveScript, stages the static assets,
and bundles two files with esbuild: the page and the worker. The engine
and scoring modules are the same files the command line planner uses.

Two designed modules do not exist yet: the account client and the
client-side schema validation of an imported specsheet, both of which
wait on the storage service (section 9).

The solver runs in a Web Worker; messages carry plain
structured-clone objects. The worker loads the specsheet, the
registries, and the weights itself, reports the phase it is in, and
posts the ranked plans back when the search finishes; starting a new
solve replaces the worker, which is how cancelling works. Beam search
is anytime, so streaming improving partial results is available to
take: it needs a callback in the search loop, and until that exists the
UI shows the phase rather than a partial plan.

The student's profile (grade, completed courses including pre-grade-9
credit, in-progress courses, pinned assignments, exam scores, summer
opt-ins, load preference, objective) persists to localStorage on
every change. The
app is usable with no network after first load, except save/share.

Every rendered claim carries provenance: a credit total, a satisfied
requirement, or an availability restriction links to the specsheet
entry that justifies it. With crowdsourced data, showing the source is
what makes the output trustworthy and makes errors reportable.

## 9. Persistence and sharing

### 9.1 Storage choice

Saved plans are self-contained JSON blobs under 64 KB, fetched by id.
Workers KV holds them: cheap, simple, and globally cached for
read-mostly share links. Accounts are relational (a user row, a
session lookup, a per-user plan index), so they live in a small D1
database with three tables: users (id, username, password hash,
recovery-code hash), sessions (token hash, user id, expiry), and
plan_owners (plan id, user id). D1 stores only ids and hashes; plan
content stays in KV and its format does not change. Durable Objects
add nothing because there is no concurrent multi-writer coordination.
KV's eventual consistency (propagation up to about a minute) is
acceptable; the share UI copies the link only after the write
succeeds, and any stale read self-heals.

### 9.2 Worker endpoints

```
POST   /api/signup         -> { userId, recoveryCode }    username + password
POST   /api/login          -> { sessionToken }
POST   /api/logout         -> invalidate session
POST   /api/recover        -> set new password with recovery code
GET    /api/me/plans       -> plan index for the session's user
POST   /api/plans          -> { planId, writeToken }      create
GET    /api/plans/:id      -> plan JSON                   read (public)
PUT    /api/plans/:id      -> update   (Bearer writeToken)
DELETE /api/plans/:id      -> delete   (Bearer writeToken)
POST   /api/events         -> anonymous preference event  (phase 1, flagged)
```

Signup takes a username and a password and nothing else. Passwords
are hashed with PBKDF2 via the Workers WebCrypto API; a session is a
random bearer token stored hashed in D1 with an expiry. When a
logged-in user creates a plan, the Worker adds a plan_owners row, so
GET /api/me/plans lists their plans on any device. Plan creation
works without a session too: the app is fully usable without an
account, with the plan list held in localStorage as before.

Request bodies cap at 64 KB. Cloudflare rules rate-limit all
endpoints, with tighter limits on signup and login. Plans untouched
for two years expire via KV TTL, refreshed on write; plans owned by
an account do not expire. The events endpoint ships behind a feature
flag and records only plan-feature vectors and a chosen-versus-shown
marker, never profile contents.

### 9.3 Plan record

Key `plan:{planId}`:

```json
{
  "v": 1,
  "createdAt": "2026-08-11T00:00:00Z",
  "updatedAt": "2026-08-11T00:00:00Z",
  "writeTokenHash": "sha256:...",
  "payload": {
    "specsheetPins": [
      { "id": "us/tx/austin/westlake-hs", "catalogYear": 2026, "rev": "git-sha" }
    ],
    "profile": {
      "startYear": 2026,
      "completed": ["ALG1", "GEOM", "SPAN1", "SPAN2", "SPAN3"],
      "inProgress": ["ALG2"],
      "pinned": [{ "term": "2027-fall", "courses": ["AP-CS-A"] }],
      "optionalTerms": ["2027-summer"],
      "waivers": [],
      "rigor": 0.8,
      "apScores": {},
      "limits": {}
    },
    "objective": "max_credits",
    "assignments": [
      { "term": "2026-fall", "courses": ["ALG2", "AP-CS-A"] }
    ],
    "scores": { "symbolic": 34.0, "soft": 0.71 }
  }
}
```

`specsheetPins` let a shared plan render exactly as it was built. On
load, the app re-validates the plan against current specsheets and
shows drift warnings ("this course is no longer offered in spring")
instead of silently re-solving.

### 9.4 Accounts without email; capability URLs for sharing

An account is a username and a password. The users are mostly minors,
and holding no email, no name, and no other identity data keeps the
PII surface as close to zero as an account system allows. The
trade-off of having no email is that there is no reset mail: signup
returns a one-time recovery code (stored server-side as a hash) that
the user is told to save, and /api/recover exchanges it for a new
password. Losing both the password and the code loses the account;
the plans themselves remain reachable through their capability links.

Sharing does not involve accounts at all. `planId` is a random
128-bit base58 string and is the read capability; the share link is
`https://reqweaver.app/p/{planId}` and is read-only by construction.
`writeToken` is a second random secret returned once at creation,
held client-side, sent as a bearer header for mutations, and stored
server-side only as a hash. An account adds cross-device plan listing
on top of this; it does not replace the token model, and a user
without an account keeps the localStorage plan list and
export/import.

## 10. Data flow

1. The app fetches the directory index, the student picks a school,
   and the app fetches that school's chunk, its partner-college
   chunks, and the chosen major's chunk. All are pre-validated JSON.
2. The student fills in the profile (completed courses including any
   finished before grade 9, in-progress courses, pins, exam scores,
   summer opt-ins) and picks an objective; state persists to
   localStorage continuously.
3. The Web Worker builds the DAG: merge catalogs, resolve
   dual-enrollment eligibility, collapse coreqs, run the window
   passes, prune.
4. The worker computes candidate sets and node potentials, then runs
   beam search, streaming partial results.
5. The top-N feasible plans are scored; the top 3 to 5 return with
   per-term breakdowns, a banked-credit ledger, requirement checklist
   deltas, and warnings.
6. The main thread renders plan cards and the term grid, with
   provenance links on every claim.
7. Saving posts to the Worker; sharing hands out the capability URL;
   opening a shared link fetches the record, re-validates against
   current data, and surfaces drift.
8. At the end of each term the student marks what happened; completed
   and in-progress courses become fixed points and the app re-solves
   the remaining terms around them.

## 11. Performance targets

The reference workload is a combined catalog of about 300 course
nodes over 8 semesters. With the default parameters (beam 100, top-K
14, 40 subsets per expansion) the search performs on the order of
tens of thousands of expansions with linear-time constraint checks.

Targets: an interactive solve completes in under 3 seconds on a
low-end 2018-class Chromebook, the common device in the audience, and
well under 1 second on a current laptop. Memory stays under 100 MB.
The repository carries a benchmark fixture catalog at reference scale,
and changes to the engine run against it.

Beam parameters are the safety valve for larger catalogs: quality
degrades gracefully as W, K, and M shrink, and the search-effort
setting exposes the trade to the user.

## 12. Security and privacy

- No emails, no names, no third-party identity. An account is a
  username plus hashed credentials; the server stores plan blobs,
  hashed tokens, and the D1 rows of section 9.1, nothing else.
- Profile data lives in localStorage and inside saved plan payloads
  the student explicitly creates. A saved plan contains course history
  and is reachable by anyone holding its link; the share UI says so.
- Write access requires the bearer token; tokens are stored hashed;
  ids and tokens are 128-bit random values.
- Telemetry (phase 1) is opt-in, anonymous, and carries feature
  vectors only, never profile contents. Its endpoint ships dark until
  the flag flips.
- The Worker validates payload size and shape; KV entries expire after
  two years untouched.

## 13. Testing strategy

- Golden-plan fixtures: for each fixture catalog and profile, the
  expected plan set is checked in; engine changes diff against it.
  Determinism (section 6.4) is what makes this possible.
- Property tests on the constraint layer: no emitted plan ever
  violates a prerequisite, coreq, cap, window, or graduation
  requirement, over randomized catalogs and profiles.
- Consumption-rule tests: one course never satisfies two named
  requirements; overflow lands in `any_transferable`.
- Data-driven conformance fixture: an atypical school sheet (a
  trimester calendar with an optional intersession, a non-US exam
  system, a different credit unit) plans end to end against the
  unmodified engine. This test enforces the section 3.1 rule; a
  change that breaks it has leaked a concrete school notion into
  code.
- Specsheet CI (section 5) is itself part of the test surface; the
  schemas and validators are shared between the pipeline and the
  client-side import path, tested once.
- The benchmark fixture (section 11) runs in CI with a time budget.

## 14. Future phases

### 14.1 College schedule optimizer

Once the student is in college, the same machinery plans college
terms. The design keeps this cheap:

- College catalogs already exist as school specsheets with
  `kind: college`, in the same course schema. No data migration.
- The engine's constraint layer and search are school-agnostic; the
  college phase supplies different caps and windows.
- The fastest-college-finish estimator (section 6.3) is the seam: its
  interface is "residual requirements and college DAG in, term count
  out". The college optimizer replaces the greedy bin-pack behind that
  interface with a full solve, which also sharpens the high school
  planner's third objective.

Deferred until then: college registration realities (section times,
waitlists, seat caps), multi-institution transfer chains, and minors
or double majors.

### 14.2 AI schedule advisor (paid)

A paid conversational assistant that helps the student rationalize
and tune their plan: explain why a plan looks the way it does ("why
is AP Chemistry in junior year"), answer what-if questions ("what
happens if I drop the summer term"), and turn stated preferences ("I
want an easier senior year, and I hate having two APs in one term")
into concrete solver inputs.

The design keeps the neurosymbolic invariant intact. The model never
edits a plan and never asserts feasibility. It acts only through the
same levers the student has: objective choice, pins, summer opt-ins,
load limits, and scorer-weight adjustments. Every change goes through
the symbolic engine, which re-solves and remains the sole authority
on what is valid; the model then narrates the result with provenance,
citing the same specsheet entries the UI links to.

Architecture: the browser owns the conversation loop; the solver is
already there. A new Worker route proxies each turn to the Claude API
(Messages API, model `claude-opus-5`, streaming, adaptive thinking),
injecting the server-held API key, verifying the session's paid
entitlement, and enforcing per-request and per-day token budgets. The
model receives the compiled plan, profile, and requirement state plus
a tool set (`set_objective`, `pin_course`, `set_optional_terms`,
`adjust_weights`, `solve`); tool calls execute in the browser's
solver Web Worker and the results return as tool results through the
proxy. The stable system prompt and specsheet context carry
`cache_control` breakpoints so repeated turns bill mostly cache
reads.

Payments run through Stripe Checkout; the Worker stores only an
entitlement flag and period on the user row, never card data. The
feature requires an account (section 9.4) so the entitlement has
something to attach to.

Privacy: using the advisor sends the plan and profile to the Claude
API for the duration of the conversation. The feature is opt-in, the
disclosure is shown before the first message, and the Worker does not
persist conversation content.

Deferred with the rest of this phase: model and pricing tiers, free
trial mechanics, and whether advisor-suggested weight changes feed
the section 7 training data.

## 15. Risks and open questions

1. Data cold start. The product is empty without specsheets. Seed 5
   to 10 schools and 3 to 5 majors by hand before launch; a
   contributor web form that validates and emits a pull request is
   the near-term roadmap answer.
2. Articulation correctness. Students may make real decisions on
   wrong transfer data. Mitigations: provenance links on every claim,
   the verified/estimate flag on articulation entries, and a
   prominent recommendation to confirm plans with a counselor.
3. Combinatorial blowup at large catalogs (an urban school plus a
   large community college). Beam parameters bound the cost; the
   benchmark fixture keeps the engine within targets.
4. LiveScript ecosystem staleness. The compiler is stable but barely
   maintained; the risk is tooling friction, not runtime behavior.
   Accepted, and mitigated by the near-zero dependency footprint the
   no-solver and no-ONNX decisions already give.
5. Training data scarcity. Preference data may never exceed what the
   linear model needs. Acceptable: the linear model is the product,
   the MLP is upside.
6. Schema evolution over crowdsourced content. Migrations must run
   over hundreds of contributor files; the migration script lives in
   data-repo CI from day one.
7. Unwritten local rules. Real schools have counselor approvals and
   scheduling conflicts the specsheet cannot express. v1 plans terms,
   not timetables, and says so. Open question: whether specsheets
   should carry free-text local notes per course.
8. The fastest-college-finish number is an estimate until the college
   optimizer exists; the UI labels it as such.
9. Save-then-share can race KV propagation; mitigated in section 9.1,
   and the failure mode is a transient stale read.
10. Open question: two partner colleges at once, and mid-plan school
    transfers. The schema and search handle both (more nodes), but
    the UX is undesigned.
11. Account recovery without email. A user who loses both password
    and recovery code loses the account permanently. Mitigations: the
    signup flow makes saving the code hard to skip, plans stay
    reachable via capability links, and passkeys can be added later
    without changing the data model.
12. AI advisor cost and trust (section 14.2). Token spend is bounded
    by per-request and per-day budgets enforced in the Worker, and
    the feasibility invariant means a wrong explanation can never
    produce an invalid plan; explanations still need provenance links
    so students can check claims against the specsheet.

## 16. Appendices

### A. Full specsheet examples

The examples in sections 4.1 and 4.2 are complete and validate
against `schemas/school.v1.json` and `schemas/major.v1.json`.

### B. Plan record example

Section 9.3 shows a complete KV record.

### C. Scorer feature list

Initial feature set for `scorer-weights.yaml`, all normalized to
[0, 1]:

1. Per-term credit-load variance
2. Maximum exam-bearing courses in any single term
3. Difficulty-weighted load variance
4. Difficulty-weighted total load
5. Final-year slack (credits below cap in the final year)
6. Count of terms with more than two hard courses
7. Articulation confidence (verified fraction of banked credit)
8. Major-fit ratio (named-requirement credit / total banked credit)
9. Dual-enrollment term clustering
10. Dual-enrollment course count
11. Prerequisite slack (alternative-path redundancy)
12. Earliest-heavy balance (hard courses front-loaded vs spread)
13. Optional-term usage
14. Consecutive-term subject continuity (e.g. math every term)
15. Graduation-requirement margin (credits beyond minimums)
16. Banked-credit total (normalized)
17. Requirement checklist coverage fraction
18. Estimated college terms remaining (normalized)
19. Count of single-offering courses relied on
20. Plan length (terms used / terms available)
21. Gateway front-loading (unlock-weighted credits cleared in the
    first half of the plan)
22. Rigor match (credit-weighted closeness of course intensity to the
    student's rigor target)
23. Interest match (credit share of courses tagged with the student's
    stated interests)
24. Goal match (credit-weighted embedding similarity between the
    student's free-text goal and course descriptions; section 7.3)

Weights ship in `scorer-weights.yaml` with a version field; the file
is the tuning surface for both the hand-tuned and learned backends.

# reqweaver

A schedule planner for high school students who want to bank college
credit before college starts.

Course catalogs, prerequisite chains, and graduation requirements form
a planning problem most students solve by hand, badly. reqweaver solves
it mechanically: describe your school as a YAML specsheet, enter what
you have completed and what you are taking, pick an objective, and get
complete term-by-term plans.

## Quick start

```
npm install
npm test
npm run plan -- --school test/fixtures/tiny-school.yaml --profile examples/profile-example.yaml
```

For the browser app:

```
npm run build:web
npm run serve
```

Then open http://localhost:8080.

For semantic goal matching (a free-text `goal` in the profile steering
plans toward relevant courses), generate the embedding data once:

```
npm run embed          # per-course description vectors (compile time)
npm run export-model   # encoder weights for the offline fallback
```

A goal typed in the browser is encoded by the API in `workers/api`,
which also stores saved plans. The site deploys as one Worker serving
the page and the API together, so `api_base` in `siteconfig.yaml` is
empty and the app calls `/encode` and `/api/plans` on its own origin;
set it only when the API lives somewhere else. Served without that API
(`npm run serve`, for instance) the planner works as always: goals a
school precompiled still steer plans, any other wording is reported as
not applied, and saving says the API is not reachable.

## What it does

- Plans terms with a beam search over the course prerequisite graph.
  Hard rules (prerequisites, offerings, grade windows, load caps) are
  never violated; a soft scorer ranks the feasible plans.
- Objectives: maximize banked college credit, or graduate early.
- Builds around your reality: completed courses (including credit
  earned before grade 9), courses in progress, pinned choices, and
  per-year summer term opt-in.
- A rigor preference (0 to 1) picks between variants of the same
  content: 2YR Algebra 2 at one end, the honors/AP track at the other.
- Strict by default, never final: a pinned course is always honored
  even when it breaks a school rule (the rule becomes a warning), and
  waivers record prerequisites the school has excused.
- Everything school-specific is data. A school is one YAML file
  (`specs/`); course levels and their attributes are a registry
  (`registry/levels.yaml`); scorer weights are a tuning file
  (`weights/scorer-weights.yaml`).

## The app

The browser app is a schedule you build by hand, with the planner one
button away. Your school is the address: search for it on the front
page and you land on `/us/md/mcps/wchs`, a link you can keep. There
you get the school's full catalog on one side and your grade-by-term
grid on the other. Drag courses onto terms and every placement is
checked as it lands: an unmet prerequisite, a course outside its
offered term or grade window, two variants of the same content, or a
term over its period cap gets a marker saying what is wrong. Nothing
is ever blocked; you may know an exception the catalog does not, and
the markers are what you take to a counselor. The graduation
checklist and the banked-credit estimate fill in as the grid does.
Every course on screen opens its catalog entry, so you can check the
description and the prerequisites behind any placement, and mark it
completed, pin it, or waive its prerequisites from there.

When you want help, "Auto-plan" fills the grid: say what you have
completed (including credit earned before grade 9), what you are
taking now, and what you want, and it searches out the best plans and
lands them in the same grid, still editable, with the alternatives a
tab away. "Fill around this grid" keeps every course you placed where
it sits and plans the rest. A rigor preference steers it, and you can
say in a sentence what you want to study; courses whose catalog
descriptions match it rank higher, and the plan says when a goal
steered it. Alongside its plans sit the warnings the engine raised
for a counselor to confirm and hints worth considering, such as what
a summer term would be worth to you. Each course it placed says why
it is there: the requirement it covers, the later course it unlocks,
the credit it banks, or nothing at all, which marks it as yours to
swap. Courses a catalog splits into A and B halves stay linked across
the two terms and move as one. Tell the app where you are now, and
the terms behind that point become your record. Your grid and profile
stay in your browser, and the profile exports as the same YAML the
command line planner reads.

Saving a plan puts it on the reqweaver API and hands you a link like
`/s/aB3kf...`. There is no account and no password: the link is the
plan, and anyone holding it can read it, course history included, so
share it with the people you mean to. Your browser keeps a write token
alongside the link, and that token is what lets you update the plan to
whatever is on screen now, or delete it. The link opens a read-only
page: the grid, the graduation checklist, the banked-credit estimate,
and the catalog it was built against.

## Limitations

- Banked credit is an estimate until major specsheets exist;
  articulation to a specific college major is not wired up yet.
- The fastest-college-finish objective is designed but not built.
- Sharing is by link only. Accounts, and a shared plan re-checked
  against a newer catalog, are designed but not built.

Design details are in docs/SDD.md.

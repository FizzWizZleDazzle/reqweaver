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
npm run export-model   # MiniLM weights for runtime goal encoding
```

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
  (`specsheets/`); course levels and their attributes are a registry
  (`registry/levels.yaml`); scorer weights are a tuning file
  (`weights/scorer-weights.yaml`).

## The app

The browser app is the planner with a face on it. You pick your school,
say what you have completed (including credit earned before grade 9),
what you are taking now, what you have already committed to, and what
you want; it plans in the background and shows the best plans as a
grade-by-term grid you can read at a glance. Every course on screen
opens its catalog entry, so you can check the description and the
prerequisites behind any placement, and mark it completed, pin it, or
waive its prerequisites from there. Alongside each plan sit the
graduation checklist, the banked-credit estimate, and the warnings the
engine raised for a counselor to confirm. Your profile stays in your
browser, and exports as the same YAML the command line planner reads.

## Limitations

- Banked credit is an estimate until major specsheets exist;
  articulation to a specific college major is not wired up yet.
- The fastest-college-finish objective is designed but not built.
- The app plans, and nothing else: saving, sharing, and accounts need
  the storage service, which is designed but not built.

Design details are in docs/SDD.md.

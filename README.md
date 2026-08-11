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

## Limitations

- Banked credit is an estimate until major specsheets exist;
  articulation to a specific college major is not wired up yet.
- The fastest-college-finish objective and the browser frontend are
  designed but not built.

Design details are in docs/SDD.md.

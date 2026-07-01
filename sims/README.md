# chomp/sims

Scripted-battle harness over the transpiled engine (`../transpiler/ts-output`), for validating
specific move/mechanic claims deterministically.

## Use

`src/harness.ts` exposes `makeSimContext({ monsPerTeam })`, `buildMon`, `startBattle`, `executeTurn`.
Battles are **scripted** — you pass explicit move indices per side (no CPU), so there is no
peek/prediction confound. Turn 0 is a NO_OP lead-in; turns 1+ run real moves. Supports 1v1 and 4v4.

To validate a change: edit the move mockup under `../transpiler/ts-output/mons/<mon>/*.ts`, write a
throwaway scenario file next to this README, run `bun <file>.ts`, then revert the mockup.

`src/util/` builds mons from `../drool/*.csv` (`loadRoster`, `buildMonConfig`) and packs inline moves.

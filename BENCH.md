# chomp bot benchmark

Write a bot that plays Stomp. 

Score it against a ladder of built-in opponents!

## Quick start

```bash
./bench.sh setup                    # generate the engine + build (~35s on 8 cores)
./bench.sh run --bot greedy         # score a built-in bot
./bench.sh run --bot example        # the worked example you'll copy
```

Requires `python3` (3.11+) and a Rust toolchain. The engine is generated from the Solidity
source rather than committed, which is why there's a build step.

## Writing a bot

Copy [`transpiler/strategies-rs/src/example_bot.rs`](transpiler/strategies-rs/src/example_bot.rs).
It is a complete, registered, working bot in about 60 lines — one-ply search over the
forward model — and it beats `random` 96% and `heuristic` 54%.

The interface is one method:

```rust
pub trait Bot: Send {
    fn name(&self) -> &'static str;
    fn modes(&self) -> &'static [BattleMode] { &[BattleMode::Singles] }
    fn reset(&mut self) {}
    fn decide(&mut self, ctx: &mut DecisionCtx<'_>) -> Action;
}
```

`ctx` gives you:

| field | what it is |
|---|---|
| `ctx.sim` | the live battle — fork it and play hypotheticals forward |
| `ctx.seat` | which side you're piloting |
| `ctx.mode` | `Singles` or `Doubles` |
| `ctx.view` | position snapshot (singles only; `None` in doubles — read `ctx.sim`) |
| `ctx.peek` | the opponent's move, or `None` in blind mode |
| `ctx.rng` | your private random stream |

To register: add `pub mod my_bot;` to `src/lib.rs`, then a name constant and one `build` arm
in `src/bots.rs`. Then `./bench.sh run --bot my-bot`.

`./bench.sh test` runs a smoke test that plays one game with every registered bot. If your
bot is in the registry, it is covered.

### Guidelines

**Draw only from `ctx.rng`.** Salts are drawn from a
separate one derived from the seed alone, so however much you draw, the battle itself is
unchanged.

**Read the opponent's move only through `ctx.peek`.** In blind mode it is `None`, so a bot
written against the interface cannot accidentally depend on seeing a reveal.

Beyond that, do what you like. Search deep, cache, hand-tune tables, hard-code matchups.

Every game is an **independent 4v4 draft**, redrawn from the mon roster.

## Existing Ladder

 Your row from `./bench.sh run --bot yours` is directly comparable

**Singles**, blind mode, seed `0xbeefcafe`. Intervals ±0.5% to ±3.0%.

| bot | drafts | vs `random` | vs `greedy` | vs `heuristic` | vs `override` | vs `nopeek` | vs `search-d1` |
|---|---|---|---|---|---|---|---|
| `random` | 4000 | 50.7% *(self)* | 4.5% | 5.9% | 4.3% | 3.2% | 5.5% |
| `example` | 4000 | 95.4% | 46.7% | 55.3% | 50.6% | 44.9% | 37.5% |
| `greedy` | 4000 | 96.1% | 50.2% *(self)* | 57.3% | 54.4% | 45.9% | 39.3% |
| `heuristic` | 4000 | 94.1% | 40.4% | 49.4% *(self)* | 44.5% | 39.2% | 34.0% |
| `override` | 4000 | 96.2% | 44.5% | 55.0% | 50.8% *(self)* | 41.4% | 37.9% |
| `nopeek` | 4000 | 96.6% | 53.8% | 59.6% | 56.3% | 50.3% *(self)* | 33.1% |
| `nopeek-wc` | 4000 | 95.6% | 63.7% | 67.4% | 62.8% | 67.7% | 51.9% |
| `search-d1` | 4000 | 94.6% | 61.3% | 66.4% | 61.2% | 66.5% | 50.1% *(self)* |
| `search-d2` | 1000 | 97.0% | 72.2% | 73.8% | 71.1% | 74.6% | 62.3% |

**Doubles**, seed `0xbeefcafe`. Intervals ±0.8% to ±6.8%.

| bot | drafts | vs `doubles-easy` | vs `doubles-medium` | vs `doubles-hard` | vs `doubles-search-d1` |
|---|---|---|---|---|---|
| `doubles-easy` | 4000 | 49.9% *(self)* | 34.1% | 17.3% | 7.8% |
| `doubles-medium` | 4000 | 66.7% | 49.7% *(self)* | 30.6% | 15.6% |
| `doubles-hard` | 4000 | 83.5% | 69.5% | 49.3% *(self)* | 27.6% |
| `doubles-search-d1` | 2000 | 93.3% | 84.6% | 69.9% | 50.2% *(self)* |
| `doubles-search-d2` | 200 | 93.0% | 84.5% | 76.0% | 61.0% |

Check the `drafts` column before comparing rows — `search-d2` costs ~25× `greedy` per
decision, so it gets fewer, and `doubles-search-d2` (200 drafts, ±6.8%) is indicative only.

### Information modes

- `--info blind` (default) — genuinely simultaneous. Neither side sees the other's move.
  This is what production play looks like.
- `--info rotate` — one side sees the opponent's move, alternating each game so both seats
  peek equally often. This is for beating up human players :>

### Doubles

```bash
./bench.sh run --bot doubles-hard --mode doubles
```

Two active mons per side; your bot returns `Action::Slots([move, move])` and declares
`modes()` as `Doubles`. Doubles is the mode the shipped CPU actually plays, so improvements
there transfer most directly.

## Measuring mons, not just bots

The same harness answers balance questions. These read `drool/*.csv` and `src/mons/*.json` at
run time from `$CHOMP_ROOT`, so a stat or move edit takes effect on the next run with no rebuild
— point `CHOMP_ROOT` at a scratch copy of the repo to run ablations without touching your tree.

```bash
cd transpiler/rs-output
CHOMP_ROOT=../.. ./target/release/analyze  --games 6000 [--mode doubles] [--p0 greedy --p1 greedy]
CHOMP_ROOT=../.. ./target/release/montrace --mon Mulong --games 800
CHOMP_ROOT=../.. ./target/release/teams    --games-per-team 150
```

- **`analyze`** — per-mon win%, active turns, KOs dealt/taken, and the mon-vs-mon KO matrix.
  `--p0`/`--p1` pin the pilots; results shift a lot with bot strength, so state which you used.
- **`montrace`** — one mon's doubles diagnostic: move usage, survival, and KOs per 100 active
  turns for its *teammates* and *opponents* against a no-target control. That last one separates
  "this mon kills things" from "this mon makes its partner's kills happen".
- **`teams`** — the exhaustive team search and main effect described above.

### Watching a long run

`analyze` and `teams` accept `--progress`, which streams the ranked table to **stderr** every 5%
while stdout stays a single clean result table:

```
[ 10% 300/3000] Mulong 61.9 · Volthare 56.2 · Malalien 55.4 · Ekineki 54.7 · …
```

Slicing only moves scheduling boundaries — every game is independently seeded, so output is
byte-identical with and without the flag. `teams` walks a strided permutation when streaming,
because its specs are team-major and consecutive slices would otherwise give a badly biased
partial main effect rather than a merely noisy one.

## Research directions

Some ideas for you to try out:

### Archetype pilots

The bots above all evaluate positions the same way and differ only in search. None of them
plays a **strategy** in the way a human does.

- **Stall.** Stamina is a real resource and resting is a legal action — win by exhausting
  the opponent rather than out-damaging them. The search only learned to rest at all after a
  bug fix, and it gained ~12 points when it did, so this axis is under-explored.
- **Setup sweep.** Stat boosts are multiplicative per source. Find the turn where a boost
  pays for the tempo it costs, then commit.

`override_cpu.rs` is the substrate — it already runs scripted per-mon rules (preferred move,
switch-in move, setup move) with a heuristic fallback.

### Synergy-aware play

`./bench.sh` aside, the tree has an exhaustive team analyser: all C(15,4) = 1365 teams
evaluated against the random-draft field, with synergy read as the *interaction* beyond each
mon's main effect (`src/bin/teams.rs`). Overclock lifting slower attackers shows up there.

Read the main effect with its harness in mind: `teams.rs` pilots **both sides with `greedy` at
depth 0**, so it measures how much a mon lifts a team *against unsophisticated play*, which is
not the same question as `analyze`'s win rate. A mon can be ordinary in one and dominant in the
other — Glob's free once-per-battle damage absorb is worth +25 main-effect points against
`greedy` and ~3 win-rate points against `heuristic`, because only the smarter bot plays around
it.

No bot currently reads its own roster and plays to it. A bot that recognises it drafted a
speed-control core, or a specific two-mon combo, and sequences toward it, is open ground.

### Wall / check exploitation

`src/bin/matrix.rs` computes the static damage-to-KO matrix — who *checks* whom (2HKO and
out-damages) and who *walls* whom (needs 3+ and out-damaged). `src/bin/faceoff.rs` finds the
behavioural version, including walls that never show up as KOs at all: sleep-and-drain and
stamina denial.

Both are offline analyses. A bot that consults that structure mid-game — pivoting to its
check instead of clicking damage — doesn't exist yet.

### Bots humans enjoy losing to

Strength and fun are different targets, and the current difficulty tiers conflate them: easy
and medium are just `hard` taking a random legal action some of the time, so they feel
*erratic* rather than *beatable*. A weak bot that plays a coherent but narrow plan is far
more satisfying to beat than one that flails.

- **Unexploitable rather than strong.** Nash mixing over the per-turn matrix game already
  exists (`--mixed`, regret matching). Measured against fixed bots it *loses* to plain
  maximin — but that is the point: it cannot be pattern-read, which matters against a human
  who plays fifty games and not one.
- **Personality bots.** A pilot that always leads the same mon, always sets up first, or
  always preserves its last mon. Predictable in a way a human can discover and counter,
  which is a better difficulty knob than injecting randomness.
- **Yomi-aware.** `src/bin/yomi.rs` scores how much a position's outcome hinges on guessing
  right. Bluff where it matters, play straight where it doesn't.

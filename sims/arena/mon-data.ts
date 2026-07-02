// Entry shim so `bun arena/mon-data.ts` (run from sims/) reaches the real script under src/arena.
// process.argv is global, so flags pass straight through.
import '../src/arena/mon-data.ts';

# Phase 2C: Convert Mon.moves from Dynamic to Fixed-Size Array

## Goal
Change `IMoveSet[] moves` in the `Mon` struct to `IMoveSet[4] moves`. This eliminates dynamic array overhead (1 length slot + N data slots) per Mon stored in battle config. For 12 mons in a 6v6 battle, this saves ~60 storage slots on first battle.

## Working Directory
`/root/clawd/projects/stomp-optimized/`

## ⚠️ THIS IS A LARGE CASCADING CHANGE
This modifies the core `Mon` struct which is used everywhere. Be methodical.

## Step-by-Step

### Step 1: Change the struct (`src/Structs.sol`)
```solidity
// BEFORE:
struct Mon {
    MonStats stats;
    IAbility ability;
    IMoveSet[] moves;
}

// AFTER:
struct Mon {
    MonStats stats;
    IAbility ability;
    IMoveSet[4] moves;
}
```

### Step 2: Fix Engine.sol
Search for ALL references to `Mon` and `.moves` in Engine.sol. Key patterns to fix:

**Reading moves by index** — these should work as-is since `mon.moves[i]` works for both dynamic and fixed arrays.

**Getting moves length** — any `mon.moves.length` needs to become `4` or a constant:
```bash
grep -n "\.moves\.length" src/Engine.sol
```

**Storing teams** — When Engine copies teams from memory to storage, with fixed arrays the storage layout changes. Each Mon now has predictable slot locations. The existing `config.p0Team[j] = p0Team[j]` assignment should still work for struct-to-struct copy.

### Step 3: Fix ITeamRegistry and implementations
```bash
grep -rn "IMoveSet\[\]" src/teams/ src/gacha/
```

Key files:
- `src/teams/ITeamRegistry.sol` — interface, return types
- `src/teams/DefaultTeamRegistry.sol` — uses `IMoveSet[][]` for moves param
- `src/teams/DefaultMonRegistry.sol` — uses `IMoveSet[]` for move lists
- `src/teams/GachaTeamRegistry.sol` 
- `src/teams/LookupTeamRegistry.sol` — constructs Mon with moves

**For DefaultTeamRegistry:** The `createTeam` function takes `IMoveSet[][] memory moves` — each inner array is the moves for one mon. Change to `IMoveSet[4][] memory moves` or keep `IMoveSet[][] memory` and copy into fixed array.

**For LookupTeamRegistry:** Currently does `new IMoveSet[](MOVES_PER_MON)` — change to construct with fixed size.

### Step 4: Fix test files
This is the biggest part. There are ~190 instances of `new IMoveSet[]()` in tests.

**Pattern 1: `new IMoveSet[](N)` assigned to `mon.moves`**
```solidity
// BEFORE:
mon.moves = new IMoveSet[](4);
mon.moves[0] = moveA;

// AFTER (can't assign dynamic to fixed):
mon.moves[0] = moveA;
mon.moves[1] = IMoveSet(address(0)); // pad unused slots
mon.moves[2] = IMoveSet(address(0));
mon.moves[3] = IMoveSet(address(0));
```

**Pattern 2: `IMoveSet[] memory moves = new IMoveSet[](N)` then `mon.moves = moves`**
```solidity
// BEFORE:
IMoveSet[] memory moves = new IMoveSet[](1);
moves[0] = attack;
mon.moves = moves;

// AFTER:
mon.moves[0] = attack;
// slots 1-3 already default to address(0)
```

**Pattern 3: Mon literal with `moves: new IMoveSet[](0)`**
```solidity
// BEFORE:
Mon({stats: s, ability: IAbility(address(0)), moves: new IMoveSet[](0)})

// AFTER — need a helper or explicit array:
Mon({stats: s, ability: IAbility(address(0)), moves: [IMoveSet(address(0)), IMoveSet(address(0)), IMoveSet(address(0)), IMoveSet(address(0))]})
```

**Tip:** Create a helper function in BattleHelper.sol:
```solidity
function _emptyMoves() internal pure returns (IMoveSet[4] memory) {
    return [IMoveSet(address(0)), IMoveSet(address(0)), IMoveSet(address(0)), IMoveSet(address(0))];
}
```

### Step 5: Fix any remaining references
```bash
grep -rn "IMoveSet\[\]" src/ test/ | grep -v "interface\|//\|IMoveSet\[4\]"
```

### Step 6: Handle `DefaultValidator` move count validation
The validator checks `MOVES_PER_MON` — verify it still works with fixed array.

### Step 7: Handle `moves.length` references everywhere
```bash
grep -rn "\.moves\.length" src/ test/
```
With fixed `IMoveSet[4]`, `.length` always returns 4. But some code may check if a move slot is actually set (not address(0)). Verify this doesn't break validation.

## Important Constraints
- Some tests create Mons with 0, 1, or 2 moves. With fixed array, unused slots are `IMoveSet(address(0))`. Make sure Engine/Validator handles address(0) moves correctly (it likely already does since it checks `MOVES_PER_MON`).
- The `DefaultMonRegistry.validateMon()` checks `m.moves.length` — this needs updating.
- `GachaTeamRegistry` and other registries need careful handling.

## Verification
```bash
export PATH="$HOME/.foundry/bin:$PATH"
forge build 2>&1 | tail -5
forge test 2>&1 | tail -10
```
Must compile and pass 223 tests.

## Output
Write changes directly to files. Write summary to `/root/clawd/projects/stomp-optimized/PHASE2-CHANGES-fixedmoves.md`

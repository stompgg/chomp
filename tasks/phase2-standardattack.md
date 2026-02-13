# Phase 2A: StandardAttack — Convert Storage Variables to Immutable

## Goal
Convert StandardAttack's 10 private storage variables to `immutable` (all except `_name` which is a string and can't be immutable). This eliminates 10 SSTORE operations per deployment and converts 10 SLOAD reads to bytecode reads (~2100→3 gas each).

## Working Directory
`/root/clawd/projects/stomp-optimized/`

## Files to Modify

### 1. `src/moves/StandardAttack.sol`
Change these private storage vars to immutable:
```solidity
// BEFORE:
uint32 private _basePower;
uint32 private _stamina;
uint32 private _accuracy;
uint32 private _priority;
Type private _moveType;
uint32 private _effectAccuracy;
MoveClass private _moveClass;
uint32 private _critRate;
uint32 private _volatility;
IEffect private _effect;
string private _name;  // KEEP AS STORAGE — string can't be immutable

// AFTER:
uint32 private immutable _basePower;
uint32 private immutable _stamina;
uint32 private immutable _accuracy;
uint32 private immutable _priority;
Type private immutable _moveType;
uint32 private immutable _effectAccuracy;
MoveClass private immutable _moveClass;
uint32 private immutable _critRate;
uint32 private immutable _volatility;
IEffect private immutable _effect;
string private _name;  // unchanged
```

The constructor already sets these from params — no constructor changes needed.

**IMPORTANT:** The `changeVar()` function writes to these storage variables. Since immutable variables can't be written after construction, you must either:
- Remove `changeVar()` entirely, OR
- Keep only the `_name` case in `changeVar()` (case 9 for _effect becomes impossible, etc.)
- **Safest approach:** Remove `changeVar()` entirely. If admin needs to change params, they redeploy. This is the recommended pattern for MegaETH.

Also update the getter functions to be `pure` instead of `view` where possible:
- `priority()` → stays `view` if it's `virtual` and some overrides read storage
- `stamina()`, `moveType()`, `moveClass()`, `critRate()`, `volatility()`, `basePower()`, `accuracy()`, `effect()`, `effectAccuracy()` → These return immutable values. In Solidity, reading immutable IS allowed in `view` functions. They can stay `view` — don't change to `pure` as they still technically read bytecode.

### 2. `src/moves/StandardAttackStructs.sol` — No changes needed

### 3. All 23 inheriting contracts — Check for any that call `changeVar()`
These contracts inherit StandardAttack. Check if any override `changeVar()` or call `super.changeVar()`. If so, handle those cases.

Inheriting contracts (all in `src/mons/`):
- aurox/BullRush.sol, aurox/VolatilePunch.sol
- ekineki/BubbleBop.sol, ekineki/Overflow.sol
- embursa/SetAblaze.sol
- ghouliath/InfernalFlame.sol, ghouliath/Osteoporosis.sol, ghouliath/WitherAway.sol
- gorillax/Blow.sol, gorillax/PoundGround.sol, gorillax/ThrowPebble.sol
- iblivion/(check for any StandardAttack inheritors)
- inutia/BigBite.sol, inutia/HitAndDip.sol
- malalien/FederalInvestigation.sol, malalien/InfiniteLove.sol, malalien/NegativeThoughts.sol
- pengym/ChillOut.sol, pengym/PistolSquat.sol
- sofabbi/UnexpectedCarrot.sol
- volthare/DualShock.sol, volthare/Electrocute.sol, volthare/RoundTrip.sol
- xmon/VitalSiphon.sol

Search for ALL contracts that extend StandardAttack:
```bash
grep -rn "is StandardAttack\|is.*StandardAttack" src/mons/ | grep -v "//"
```

### 4. Test files — Check for any tests that call `changeVar()`
```bash
grep -rn "changeVar" test/
```
If any tests call `changeVar`, they need to be updated (either removed or restructured to redeploy instead).

## Verification
```bash
export PATH="$HOME/.foundry/bin:$PATH"
forge build 2>&1 | tail -5
forge test 2>&1 | tail -10
```
Must compile and pass 223 tests (0 failures).

## Output
Write changes directly to files. Write summary to `/root/clawd/projects/stomp-optimized/PHASE2-CHANGES-standardattack.md`

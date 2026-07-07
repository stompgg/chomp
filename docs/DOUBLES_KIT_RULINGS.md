# Doubles kit rulings (D23 audit)

How every existing kit behaves in 2-slot battles, and the general rules the per-kit calls
derive from. Singles behavior is unchanged in every case (the rules all degenerate to "the
opposing active" when each side has one slot).

## General rules

- **Targeted moves follow their chosen slot.** A move's damage, applied status, and any
  side-derived logic bind to `targetBits`' slot — including ally slots (D4). The defender's
  *side* is derived from the slot, never hardcoded as "the opponent".
- **Mirror-slot rule** for effects/abilities that act on "the opposing active" with no target
  context (switch-in chips, KO-triggered debuffs, per-turn punishments): the effect lands on
  the slot directly opposite its owner's slot, falling back to the other opposing slot when the
  mirror lane is vacant, and fizzling when the opposing side is empty. Occupancy only — a KO'd
  occupant is still selected (the action then no-ops).
- **"Both actives" moves become caster + chosen target** (not all four slots): Contagious
  Slumber, Honey Bribe, Grave Affliction keep their singles cost/benefit shape.
- **Move-decision reads are per-slot.** Effects observing a mon's committed move resolve the
  mon's slot (`TargetLib.slotOfMon`) and read `getMoveDecisionForSlot`; a benched observer
  treats the read as non-matching.
- **Pivot moves address their slot.** Self-switches vacate the caster's slot; forced switches
  vacate the targeted slot (`switchActiveMonForSlot`). A random replacement pick that collides
  with the ally slot's occupant no-ops (the pivot fizzles).
- **Side-scoped resources stay side-scoped** (D11, accepted stacking surface): one sleeper per
  side, Chain Expansion's shared charges, Nine Nine Nine's crit prime, Somniphobia's tax.

## Per-kit calls

| Kit | Ruling |
|---|---|
| Eternal Grudge | Debuff follows the chosen target slot (may be the ally, D4). |
| Contagious Slumber / Honey Bribe / Grave Affliction | Caster + chosen target slot. |
| Q5 | Armed against the slot the cast aimed at; detonates on that slot's occupant at D-day (slot-bound, D3 — a switch redirects onto the replacement). Countdown ticks only on full turns (round effects don't run on switch-only turns, matching singles). |
| Heat Beacon / Deep Freeze / Vital Siphon / Volatile Punch / Mega Star Blast / Gachachacha (KO bands) / Invoke Taboo (brand) | Targeted-slot rule (mechanical Pattern A). |
| Interweaving | Swap-in and swap-out debuffs land on Inutia's mirror slot. |
| Preemptive Shock | Unchanged (dispatch resolves the implied singles bit in singles; in doubles it chips the target resolved by its dispatch call — slot 0 of the opposing side; acceptable until a kit pass gives it a chosen target). |
| Actus Reus | Arms when EITHER opposing occupant is KO'd after Malalien's move; the death-trigger speed halving lands on Malalien's mirror slot. |
| Night Terrors | Each tick lands on Xmon's mirror slot (re-evaluated per round end). |
| Rock Pull | The punisher *stance* (priority bump) arms if either opposing slot committed a switch (priority() has no target context); the punish damage still requires the *targeted* slot to be switching, else the usual self-hit. |
| Hard Reset | Rest detection is per-slot (the Resting mon's own committed move); the forced swap vacates that mon's slot. |
| Tinderclaws | Rest detection reads Embursa's own slot. |
| Sleep / Zap | The move rewrite / skip check binds to the sleeper's own slot; a benched victim is untouched that round. |
| Overclock / Dual Shock | Boost applies to every occupied lane of the summoner's side and is removed from both at expiry (side-scoped by design, D11). |
| Pivots (Hit And Dip, Round Trip, Pistol Squat, Hard Reset) | Slot-addressed switches per the pivot rule above. |
| Sneak Attack / Guest Feature / Gilded Recovery / Savior Complex | Roster-index domains unchanged in Doubles (own/opposing team is the side roster). Multi's per-seat quarters are a validation concern for the Multi phase. |
| Self-scoped kits (Baselight line, Iron Wall, Up Only, Dreamcatcher, Chronoffense, Rise From The Grave, Triple Think, Angery, Snack Break, Carrot Harvest...) | No ruling needed; ally hits feeding them (D4) work through the normal per-mon hooks. |
| Adaptor | Latches the first damage source as before — an ally's move can be the latched source (D4, accepted). |
| External StaminaRegen effect | Singles test scaffolding only; prod inline regen is slot-aware. |

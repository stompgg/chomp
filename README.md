# C.H.O.M.P. (credibly hackable on-chain monster pvp)

on-chain turn-based pvp battling game, (heavily) inspired by pokemon showdown x mugen

![ghouliath back img](drool/imgs/ghouliath_back.gif)
![ghouliath front img](drool/imgs/ghouliath_front.gif)

designed to be highly extensible!

write your own moves!

your own mons!

your own effects!

your own hooks!

your own CPU! — see **[BENCH.md](BENCH.md)**: write a bot, score it against a ladder of
built-in opponents, with the real battle engine as your forward model.

general flow of the game is: 
- each turn, players simultaneously choose a move on their active mon.
- moves can alter stats, do damage, or generally mutate game state in some way.
- this continues until one player has all their mons KO'ed

(think normal pokemon style)

mechanical differences are:
- extensible engine, write your own Effects or Moves or Hooks
- far greater support for state-based moves / mechanics
- stamina-based resource system instead of PP for balancing moves

## getting started

This repo uses [foundry](https://book.getfoundry.sh/getting-started/installation).

To get started:

`forge install`

`forge test`

## game data

mon stats, move rows, and CPU teams live in `drool/mons.csv`, `drool/moves.csv`, and
`script/cpu-teams.json`.

There's a local visual editor at:

`python processing/editData.py`

## solidity components

### Engine.sol
Main entry point for creating/advancing Battles.
Handles executing moves to advance battle state.
Stores global state / data available to all players.

## Game Flow
General flow of battle:
- p0 commits hash of a Move
- p1 reveals their choice
- p0 reveals their preimage
- execute to advance game state
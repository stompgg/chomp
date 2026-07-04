//! Native CPU strategies + game loop over the transpiled engine.
//!
//! Rust port of the arena decision stack (`sims/src/cpu/*` + the
//! `sims/src/arena/game.ts` loop), 1:1 with the TS reference: every
//! branch, threshold, float operation and RNG draw happens in the same
//! order, so identical (seed, teams, strategies) produce identical games.
//! All three arena strategies — `hard`, `greedy`, `override` — are
//! ported; TS-only helpers they never call are deliberately absent.
//!
//! The two stacks are peers: Rust is the fast experimentation substrate
//! and may run ahead while testing strategy changes, but anything that
//! ships to the game's CPU mode must be ported back to TS — the
//! `strategy_lockstep` gate defines the sync point between them.
//!
//! Seat convention: strategies are written as if the CPU is p1 and the
//! opponent p0 (inherited from the on-chain CPUs). The p0 seat plays
//! through [`view::Seat`] translation — the Rust equivalent of the TS
//! `transposeEngine` proxy (flip player indices on the engine-read
//! surface, swap hypothetical-fork submissions, flip the switch flag).

#![allow(non_snake_case)] // engine call sites keep Solidity spelling

pub mod evaluator;
pub mod game;
pub mod greedy;
pub mod hard;
pub mod jsrng;
pub mod native;
pub mod override_cpu;
pub mod shared;
pub mod sim;
pub mod view;

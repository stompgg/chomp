//! Native CPU strategies + game loop over the transpiled engine.
//!
//! Rust port of the arena decision stack (`sims/src/cpu/*` + the
//! `sims/src/arena/game.ts` loop). All three arena strategies — `hard`,
//! `greedy`, `override` — were ported 1:1 against the TS reference and
//! verified move-for-move by the (since retired) lockstep gates; the
//! JS-exact rng/float mirroring in here is frozen heritage from that
//! era, not an ongoing constraint.
//!
//! The stacks are decoupled: Rust is the fast experimentation substrate
//! and may diverge freely; anything shipping to the game's CPU mode is
//! ported back to TS on its own terms (no bit-for-bit requirement).
//!
//! Seat convention: strategies are written as if the CPU is p1 and the
//! opponent p0 (inherited from the on-chain CPUs). The p0 seat plays
//! through [`view::Seat`] translation — the Rust equivalent of the TS
//! `transposeEngine` proxy (flip player indices on the engine-read
//! surface, swap hypothetical-fork submissions, flip the switch flag).

#![allow(non_snake_case)] // engine call sites keep Solidity spelling

pub mod roster;
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

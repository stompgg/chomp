//! Native CPU strategies + game loop over the transpiled engine.
//!
//! This crate is the origin of the CPU stack. It began as a 1:1 port of a
//! since-deleted TS arena, verified move-for-move by the (retired) lockstep
//! gates; the JS-exact rng/float mirroring in here is frozen heritage from
//! that era, not an ongoing constraint.
//!
//! Rust is the experimentation substrate and may diverge freely. Strategies
//! that ship to the game's CPU mode are hand-ported into munch
//! (`../munch/src/app/services/cpu/`) and gated on win-rate direction rather
//! than bit-identicality — see `sim-tests/arena/cpu-reference.json` there.
//!
//! Seat convention: strategies are written as if the CPU is p1 and the
//! opponent p0 (inherited from the on-chain CPUs). The p0 seat plays
//! through [`view::Seat`] translation — the Rust equivalent of the TS
//! `transposeEngine` proxy (flip player indices on the engine-read
//! surface, swap hypothetical-fork submissions, flip the switch flag).

#![allow(non_snake_case)] // engine call sites keep Solidity spelling

pub mod bot;
pub mod example_bot;
pub mod bots;
pub mod roster;
pub mod analysis;
pub mod arena;
pub mod breadth;
pub mod doubles;
pub mod evaluator;
pub mod faceoff;
pub mod game;
pub mod greedy;
pub mod heuristic;
pub mod jsrng;
pub mod matrix;
pub mod mock;
pub mod mock2;
pub mod native;
pub mod nopeek;
pub mod override_cpu;
pub mod replay;
pub mod search;
pub mod shared;
pub mod sim;
pub mod teams;
pub mod view;
pub mod yomi;

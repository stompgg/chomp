//! chomp-ffi — cdylib surface for bun:ffi.
//!
//! Phase 5 adds the batch API (`run_games(teams, seeds, cfg) -> outcomes`,
//! one FFI crossing per batch). Until then this crate exists to keep the
//! cdylib building against the generated engine from Phase 0 onward, plus a
//! probe function so a bun-side smoke test can verify the round-trip.

/// ABI/version probe: returns (major << 16 | minor). bun:ffi smoke tests
/// call this to prove symbol resolution + calling convention.
#[no_mangle]
pub extern "C" fn chomp_ffi_version() -> u32 {
    (0u32 << 16) | 1u32
}

/// Cheap end-to-end proof that the emitted engine code is linked in and
/// executes across the FFI boundary: type effectiveness lookup.
#[no_mangle]
pub extern "C" fn chomp_type_effectiveness(attacker: u8, defender: u8, base_power: u32) -> u32 {
    use chomp_engine::Enums::Type;
    chomp_engine::types::TypeCalcLib::getTypeEffectiveness(
        Type::from_u8(attacker),
        Type::from_u8(defender),
        base_power,
    )
}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

/// @notice Supplemental metadata for moves whose `extraDataType()` is `InclusiveRange`.
///         The move's `extraData` is constrained to `[lo, hi]` inclusive. UIs and CPUs
///         enumerate the valid choices via this range; the move itself is responsible
///         for handling out-of-range or already-spent values defensively.
interface IMoveSetWithRange {
    function extraDataRange() external view returns (uint16 lo, uint16 hi);
}

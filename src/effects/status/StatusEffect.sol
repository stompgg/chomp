// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {BasicEffect} from "../BasicEffect.sol";

/// @dev Marker base for exclusive statuses (one per mon). Exclusivity, re-apply routing, and
///      lane bookkeeping are Engine-native, keyed off the class id each status folds into its
///      getStepsBitmap() (bits 10-13): the Engine gates adds on the per-mon status lane before
///      any external call, sets the lane on apply, and clears it on removal. Statuses with
///      EXTRA apply conditions (SleepStatus's single-sleeper rule) override shouldApply and
///      must not set ALWAYS_APPLIES_BIT; all others set the bit and are gated by the lane
///      alone. Escalating statuses (BurnStatus) set HAS_REAPPLY_BIT and implement
///      IStatusEffect.onReapply.
abstract contract StatusEffect is BasicEffect {}

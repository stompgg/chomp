// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

/// @notice Marker interface for matchmakers. The Engine's only matchmaker interaction is the
///         `isMatchmakerFor` authorization gate: a player approving a matchmaker IS the trust
///         grant (a callback could always return true unconditionally, so it added no security),
///         and every in-repo matchmaker validates its own offers/proposals before calling
///         startBattle. The old `validateMatch` callback was removed on that basis.
interface IMatchmaker {}

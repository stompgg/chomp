// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IEngine} from "../IEngine.sol";

import {IPhantomTeamRegistry} from "../game-layer/IPhantomTeamRegistry.sol";
import {IMatchmaker} from "../matchmaker/IMatchmaker.sol";
import {CPUMoveManager} from "./CPUMoveManager.sol";

import {Battle, CustomBattleProposal, ProposedBattle} from "../Structs.sol";

/// @notice On-chain CPU host: self-registers as an approved matchmaker, hosts PvE battles, and
///         relays client-computed CPU moves through the engine (see CPUMoveManager). Move decisions
///         are computed off-chain, so there is no on-chain strategy here.
contract CPU is CPUMoveManager, IMatchmaker {
    constructor(IEngine engine) CPUMoveManager(engine) {}

    /// @dev Singles-only by design: ProposedBattle is the legacy 2-seat shape with no mode
    ///      field. Doubles PvE goes through startCustomBattle (battleMode in the proposal).
    function startBattle(ProposedBattle memory proposal) external returns (bytes32 battleKey) {
        (battleKey,) = ENGINE.computeBattleKey(proposal.p0, proposal.p1);
        ENGINE.startBattle(
            Battle({
                p0: proposal.p0,
                p0TeamIndex: proposal.p0TeamIndex,
                p1: proposal.p1,
                p1TeamIndex: proposal.p1TeamIndex,
                p2: address(0),
                p2TeamIndex: 0,
                p3: address(0),
                p3TeamIndex: 0,
                teamRegistry: proposal.teamRegistry,
                rngOracle: proposal.rngOracle,
                ruleset: proposal.ruleset,
                engineHooks: proposal.engineHooks,
                moveManager: proposal.moveManager,
                matchmaker: proposal.matchmaker
            })
        );
    }

    /// @notice Bundle the caller's phantom team-config write with battle start. p1 is this CPU
    /// and p1TeamIndex is the caller's phantom slot — both filled in here so callers can't write
    /// to other users' slots. The registry must implement IPhantomTeamRegistry; the relay gate
    /// enforces that only whitelisted CPUs (i.e. this contract once added) can land the write.
    function startCustomBattle(CustomBattleProposal calldata p) external returns (bytes32 battleKey) {
        IPhantomTeamRegistry(address(p.teamRegistry))
            .setOpponentTeamFor(p.p0, p.monIndices, p.facetIds, p.moveSelections);

        uint96 p1TeamIndex = uint96(uint16(uint160(p.p0)));
        (battleKey,) = ENGINE.computeBattleKey(p.p0, address(this));
        ENGINE.startBattleWithMode(
            Battle({
                p0: p.p0,
                p0TeamIndex: p.p0TeamIndex,
                p1: address(this),
                p1TeamIndex: p1TeamIndex,
                p2: address(0),
                p2TeamIndex: 0,
                p3: address(0),
                p3TeamIndex: 0,
                teamRegistry: p.teamRegistry,
                rngOracle: p.rngOracle,
                ruleset: p.ruleset,
                engineHooks: p.engineHooks,
                moveManager: p.moveManager,
                matchmaker: p.matchmaker
            }),
            p.battleMode
        );
    }
}

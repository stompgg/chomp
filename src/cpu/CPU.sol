// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IEngine} from "../IEngine.sol";

import {IPhantomTeamRegistry} from "../game-layer/IPhantomTeamRegistry.sol";
import {IMatchmaker} from "../matchmaker/IMatchmaker.sol";
import {CPUMoveManager} from "./CPUMoveManager.sol";

import {BATTLE_MODE_MULTI} from "../Constants.sol";
import {
    Battle,
    CustomBattleProposal,
    CustomMultiBattleProposal,
    ProposedBattle,
    SeatPhantomConfig
} from "../Structs.sol";
import {ITeamRegistry} from "../game-layer/ITeamRegistry.sol";

/// @notice On-chain CPU host: self-registers as an approved matchmaker, hosts PvE battles, and
///         relays client-computed CPU moves through the engine (see CPUMoveManager).
contract CPU is CPUMoveManager, IMatchmaker {
    constructor(IEngine engine, address[] memory matchmakers) CPUMoveManager(engine, matchmakers) {}

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

    /// @notice 4-seat analog of startCustomBattle: writes each CPU seat's phantom config for
    /// p0 (own seat via the relay entry, other whitelisted seats via the peer entry) and
    /// starts the Multi battle, all in one tx.
    function startCustomMultiBattle(CustomMultiBattleProposal calldata p) external returns (bytes32 battleKey) {
        uint96 phantomKey = uint96(uint16(uint160(p.p0)));
        uint96 p1TeamIndex = _configureSeat(p.teamRegistry, p.p0, p.p1, p.seatConfigs[0], p.p1TeamIndex, phantomKey);
        uint96 p2TeamIndex = _configureSeat(p.teamRegistry, p.p0, p.p2, p.seatConfigs[1], p.p2TeamIndex, phantomKey);
        uint96 p3TeamIndex = _configureSeat(p.teamRegistry, p.p0, p.p3, p.seatConfigs[2], p.p3TeamIndex, phantomKey);

        (battleKey,) = ENGINE.computePartyKey(p.p0, p.p1, p.p2, p.p3);
        ENGINE.startBattleWithMode(
            Battle({
                p0: p.p0,
                p0TeamIndex: p.p0TeamIndex,
                p1: p.p1,
                p1TeamIndex: p1TeamIndex,
                p2: p.p2,
                p2TeamIndex: p2TeamIndex,
                p3: p.p3,
                p3TeamIndex: p3TeamIndex,
                teamRegistry: p.teamRegistry,
                rngOracle: p.rngOracle,
                ruleset: p.ruleset,
                engineHooks: p.engineHooks,
                moveManager: p.moveManager,
                matchmaker: p.matchmaker
            }),
            BATTLE_MODE_MULTI
        );
    }

    /// @dev Human seats pass through untouched. CPU (whitelisted) seats get their phantom
    ///      config written for `user` — skipped when monIndices is empty — and their team
    ///      index forced to the user's phantom key (so callers can't point a CPU seat at
    ///      another user's slot).
    function _configureSeat(
        ITeamRegistry registry,
        address user,
        address seat,
        SeatPhantomConfig calldata cfg,
        uint96 suppliedTeamIndex,
        uint96 phantomKey
    ) private returns (uint96) {
        if (!registry.isWhitelistedOpponent(seat)) {
            return suppliedTeamIndex;
        }
        if (cfg.monIndices.length != 0) {
            if (seat == address(this)) {
                IPhantomTeamRegistry(address(registry))
                    .setOpponentTeamFor(user, cfg.monIndices, cfg.facetIds, cfg.moveSelections);
            } else {
                IPhantomTeamRegistry(address(registry))
                    .setOpponentTeamForPeer(user, seat, cfg.monIndices, cfg.facetIds, cfg.moveSelections);
            }
        }
        return phantomKey;
    }
}

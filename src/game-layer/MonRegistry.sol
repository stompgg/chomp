// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Structs.sol";
import {EnumerableSetLib} from "../lib/EnumerableSetLib.sol";
import {Ownable} from "../lib/Ownable.sol";
import {ITeamRegistry} from "./ITeamRegistry.sol";

/// @notice Owner-managed mon catalog. Mon ids are assigned sequentially by `createMon` so
/// downstream packed mappings (exp buckets, facet buckets) stay dense.
abstract contract MonRegistry is ITeamRegistry, Ownable {
    using EnumerableSetLib for *;

    error MonAlreadyCreated();
    error MonNotyetCreated();
    error NonSequentialMonId();
    error TooManyMoves();
    error TooManyAbilities();

    /// @dev Catalog move-row width. Flat rows replace the old per-mon EnumerableSets: reading a
    ///      mon's full moveset is CATALOG_MOVE_LANES SLOADs with no lazy-length word and no
    ///      per-value position slots (9 -> 5 cold SLOADs per distinct mon in getTeams, ~8.4k).
    ///      Zero lane = empty (move words are addresses/packed-inline data, never zero). Raising
    ///      the width for a bigger catalog is a registry redeploy — the catalog is re-seeded by
    ///      the deploy scripts, never migrated.
    uint256 internal constant CATALOG_MOVE_LANES = 4;

    EnumerableSetLib.Uint256Set internal monIds;
    mapping(uint256 monId => MonStats) public monStats;
    mapping(uint256 monId => uint256[CATALOG_MOVE_LANES]) internal monMoveRows;
    /// @dev Single primary-ability slot (0 = unset). Every catalog mon has exactly one ability;
    ///      createMon/modifyMon enforce it rather than silently dropping extras.
    mapping(uint256 monId => uint256) internal monAbility;
    mapping(uint256 monId => mapping(bytes32 => bytes32)) internal monMetadata;

    function createMon(
        uint256 monId,
        MonStats memory _monStats,
        uint256[] memory allowedMoves,
        uint256[] memory allowedAbilities,
        bytes32[] memory keys,
        bytes32[] memory values
    ) external onlyOwner {
        // Sequential monIds required so packedExpForMon / facetData buckets stay dense.
        if (monId != monIds.length()) revert NonSequentialMonId();
        MonStats storage existingMon = monStats[monId];
        // No mon has 0 hp and 0 stamina
        if (existingMon.hp != 0 && existingMon.stamina != 0) {
            revert MonAlreadyCreated();
        }
        monIds.add(monId);
        monStats[monId] = _monStats;
        uint256 numMoves = allowedMoves.length;
        if (numMoves > CATALOG_MOVE_LANES) revert TooManyMoves();
        uint256[CATALOG_MOVE_LANES] storage row = monMoveRows[monId];
        for (uint256 i; i < numMoves; ++i) {
            row[i] = allowedMoves[i];
        }
        uint256 numAbilities = allowedAbilities.length;
        if (numAbilities > 1) revert TooManyAbilities();
        if (numAbilities == 1) {
            monAbility[monId] = allowedAbilities[0];
        }
        _modifyMonMetadata(monId, keys, values);
    }

    function modifyMon(
        uint256 monId,
        MonStats memory _monStats,
        uint256[] memory movesToAdd,
        uint256[] memory movesToRemove,
        uint256[] memory abilitiesToAdd,
        uint256[] memory abilitiesToRemove
    ) external onlyOwner {
        MonStats storage existingMon = monStats[monId];
        if (existingMon.hp == 0 && existingMon.stamina == 0) {
            revert MonNotyetCreated();
        }
        monStats[monId] = _monStats;
        // Rebuild the move row in memory (owner-only cold path — clarity over micro-gas):
        // drop removals, keep order, append additions, then write all lanes back.
        {
            uint256[] memory current = _moveRowValues(monId);
            uint256 n = current.length;
            uint256 numMovesToRemove = movesToRemove.length;
            for (uint256 i; i < numMovesToRemove; ++i) {
                for (uint256 j; j < n; ++j) {
                    if (current[j] == movesToRemove[i]) {
                        for (uint256 k = j + 1; k < n; ++k) {
                            current[k - 1] = current[k];
                        }
                        --n;
                        break;
                    }
                }
            }
            uint256 numMovesToAdd = movesToAdd.length;
            if (n + numMovesToAdd > CATALOG_MOVE_LANES) revert TooManyMoves();
            uint256[CATALOG_MOVE_LANES] storage row = monMoveRows[monId];
            for (uint256 i; i < CATALOG_MOVE_LANES; ++i) {
                if (i < n) {
                    row[i] = current[i];
                } else if (i < n + numMovesToAdd) {
                    row[i] = movesToAdd[i - n];
                } else {
                    row[i] = 0;
                }
            }
        }
        {
            if (abilitiesToAdd.length > 1 || (abilitiesToAdd.length == 1 && abilitiesToRemove.length == 0 && monAbility[monId] != 0))
            {
                revert TooManyAbilities();
            }
            uint256 numAbilitiesToRemove = abilitiesToRemove.length;
            for (uint256 i; i < numAbilitiesToRemove; ++i) {
                if (monAbility[monId] == abilitiesToRemove[i]) {
                    monAbility[monId] = 0;
                }
            }
            if (abilitiesToAdd.length == 1) {
                monAbility[monId] = abilitiesToAdd[0];
            }
        }
    }

    function modifyMonMetadata(uint256 monId, bytes32[] memory keys, bytes32[] memory values) external onlyOwner {
        _modifyMonMetadata(monId, keys, values);
    }

    function _modifyMonMetadata(uint256 monId, bytes32[] memory keys, bytes32[] memory values) internal {
        mapping(bytes32 => bytes32) storage metadata = monMetadata[monId];
        for (uint256 i; i < keys.length; ++i) {
            metadata[keys[i]] = values[i];
        }
    }

    function getMonMetadata(uint256 monId, bytes32 key) external view override returns (bytes32) {
        return monMetadata[monId][key];
    }

    function validateMon(Mon memory m, uint256 monId) public view virtual override returns (bool) {
        // No stat-equality check: getTeams folds facet ±5% deltas into stats, so a passing team
        // legitimately diverges from monStats[monId]. The Engine's only source of teams is the
        // registry's getTeams, so caller-supplied stats can't be smuggled in here anyway.
        uint256[] memory row = _moveRowValues(monId);
        for (uint256 i; i < m.moves.length; ++i) {
            bool found;
            for (uint256 j; j < row.length; ++j) {
                if (row[j] == m.moves[i]) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                return false;
            }
        }
        uint256 ability = monAbility[monId];
        if (!(ability != 0 && m.ability == ability)) {
            return false;
        }
        return true;
    }

    function validateMonBatch(Mon[] calldata mons, uint256[] calldata ids) external view override returns (bool) {
        uint256 len = mons.length;
        for (uint256 i; i < len;) {
            if (!validateMon(mons[i], ids[i])) {
                return false;
            }
            unchecked { ++i; }
        }
        return true;
    }

    function getMonData(uint256 monId)
        external
        view
        override
        returns (MonStats memory _monStats, uint256[] memory moves, uint256[] memory abilities)
    {
        _monStats = monStats[monId];
        moves = _moveRowValues(monId);
        abilities = _abilityValues(monId);
    }

    function getMonDataBatch(uint256[] calldata ids)
        external
        view
        override
        returns (MonStats[] memory stats, uint256[][] memory moves, uint256[][] memory abilities)
    {
        return _getMonDataBatch(ids);
    }

    function _getMonDataBatch(uint256[] memory ids)
        internal
        view
        returns (MonStats[] memory stats, uint256[][] memory moves, uint256[][] memory abilities)
    {
        uint256 len = ids.length;
        stats = new MonStats[](len);
        moves = new uint256[][](len);
        abilities = new uint256[][](len);
        for (uint256 i; i < len;) {
            uint256 monId = ids[i];
            stats[i] = monStats[monId];
            moves[i] = _moveRowValues(monId);
            abilities[i] = _abilityValues(monId);
            unchecked { ++i; }
        }
    }

    /// @dev Materialize a move row's nonzero lanes, order-preserving. Constant-index reads on
    ///      purpose — dynamic-index access into a fixed array can make via-IR emit an extra
    ///      SLOAD-bearing helper per lane (see Engine.startBattle's unroll note).
    function _moveRowValues(uint256 monId) internal view returns (uint256[] memory vals) {
        uint256[CATALOG_MOVE_LANES] storage row = monMoveRows[monId];
        uint256 m0 = row[0];
        uint256 m1 = row[1];
        uint256 m2 = row[2];
        uint256 m3 = row[3];
        uint256 n;
        if (m0 != 0) ++n;
        if (m1 != 0) ++n;
        if (m2 != 0) ++n;
        if (m3 != 0) ++n;
        vals = new uint256[](n);
        uint256 w;
        if (m0 != 0) vals[w++] = m0;
        if (m1 != 0) vals[w++] = m1;
        if (m2 != 0) vals[w++] = m2;
        if (m3 != 0) vals[w++] = m3;
    }

    function _abilityValues(uint256 monId) internal view returns (uint256[] memory vals) {
        uint256 ability = monAbility[monId];
        if (ability == 0) {
            return new uint256[](0);
        }
        vals = new uint256[](1);
        vals[0] = ability;
    }

    function getMonIds(uint256 start, uint256 end) external view override returns (uint256[] memory) {
        if (start == end) {
            uint256[] memory allIds = new uint256[](monIds.length());
            for (uint256 i; i < monIds.length(); ++i) {
                allIds[i] = monIds.at(i);
            }
            return allIds;
        }
        uint256[] memory ids = new uint256[](end - start);
        for (uint256 i; i < end - start; ++i) {
            ids[i] = monIds.at(start + i);
        }
        return ids;
    }

    function getMonStats(uint256 monId) external view override returns (MonStats memory) {
        return monStats[monId];
    }

    function isValidMove(uint256 monId, uint256 moveSlot) external view override returns (bool) {
        if (moveSlot == 0) return false;
        uint256[CATALOG_MOVE_LANES] storage row = monMoveRows[monId];
        return row[0] == moveSlot || row[1] == moveSlot || row[2] == moveSlot || row[3] == moveSlot;
    }

    function isValidAbility(uint256 monId, uint256 ability) external view override returns (bool) {
        return ability != 0 && monAbility[monId] == ability;
    }

    function getMonCount() external view override returns (uint256) {
        return monIds.length();
    }
}

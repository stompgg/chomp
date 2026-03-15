// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Structs.sol";
import "./IMonRegistry.sol";

import {EnumerableSetLib} from "../lib/EnumerableSetLib.sol";
import {Ownable} from "../lib/Ownable.sol";

contract DefaultMonRegistry is IMonRegistry, Ownable {
    using EnumerableSetLib for *;

    EnumerableSetLib.Uint256Set private monIds;
    mapping(uint256 monId => MonStats) public monStats;
    mapping(uint256 monId => EnumerableSetLib.Uint256Set) private monMoves;
    mapping(uint256 monId => EnumerableSetLib.AddressSet) private monAbilities;
    mapping(uint256 monId => mapping(bytes32 => bytes32)) private monMetadata;

    error MonAlreadyCreated();
    error MonNotyetCreated();

    constructor() {
        _initializeOwner(msg.sender);
    }

    function createMon(
        uint256 monId,
        MonStats memory _monStats,
        uint256[] memory allowedMoves,
        IAbility[] memory allowedAbilities,
        bytes32[] memory keys,
        bytes32[] memory values
    ) external onlyOwner {
        MonStats storage existingMon = monStats[monId];
        // No mon has 0 hp and 0 stamina
        if (existingMon.hp != 0 && existingMon.stamina != 0) {
            revert MonAlreadyCreated();
        }
        monIds.add(monId);
        monStats[monId] = _monStats;
        EnumerableSetLib.Uint256Set storage moves = monMoves[monId];
        uint256 numMoves = allowedMoves.length;
        for (uint256 i; i < numMoves; ++i) {
            moves.add(allowedMoves[i]);
        }
        EnumerableSetLib.AddressSet storage abilities = monAbilities[monId];
        uint256 numAbilities = allowedAbilities.length;
        for (uint256 i; i < numAbilities; ++i) {
            abilities.add(address(allowedAbilities[i]));
        }
        _modifyMonMetadata(monId, keys, values);
    }

    function modifyMon(
        uint256 monId,
        MonStats memory _monStats,
        uint256[] memory movesToAdd,
        uint256[] memory movesToRemove,
        IAbility[] memory abilitiesToAdd,
        IAbility[] memory abilitiesToRemove
    ) external onlyOwner {
        MonStats storage existingMon = monStats[monId];
        if (existingMon.hp == 0 && existingMon.stamina == 0) {
            revert MonNotyetCreated();
        }
        monStats[monId] = _monStats;
        EnumerableSetLib.Uint256Set storage moves = monMoves[monId];
        {
            uint256 numMovesToAdd = movesToAdd.length;
            for (uint256 i; i < numMovesToAdd; ++i) {
                moves.add(movesToAdd[i]);
            }
        }
        {
            uint256 numMovesToRemove = movesToRemove.length;
            for (uint256 i; i < numMovesToRemove; ++i) {
                moves.remove(movesToRemove[i]);
            }
        }
        EnumerableSetLib.AddressSet storage abilities = monAbilities[monId];
        {
            uint256 numAbilitiesToAdd = abilitiesToAdd.length;
            for (uint256 i; i < numAbilitiesToAdd; ++i) {
                abilities.add(address(abilitiesToAdd[i]));
            }
        }
        {
            uint256 numAbilitiesToRemove = abilitiesToRemove.length;
            for (uint256 i; i < numAbilitiesToRemove; ++i) {
                abilities.remove(address(abilitiesToRemove[i]));
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

    function getMonMetadata(uint256 monId, bytes32 key) external view returns (bytes32) {
        return monMetadata[monId][key];
    }

    function validateMon(Mon memory m, uint256 monId) public view returns (bool) {
        // Check that the mon's stats match the current mon ID's stats
        if (
            m.stats.attack != monStats[monId].attack || m.stats.defense != monStats[monId].defense
                || m.stats.specialAttack != monStats[monId].specialAttack
                || m.stats.specialDefense != monStats[monId].specialDefense || m.stats.speed != monStats[monId].speed
                || m.stats.hp != monStats[monId].hp || m.stats.stamina != monStats[monId].stamina
        ) {
            return false;
        }
        // Check that the mon's moves are valid for the current mon ID
        for (uint256 i; i < m.moves.length; ++i) {
            if (!monMoves[monId].contains(m.moves[i])) {
                return false;
            }
        }
        // Check that the mon's ability is valid for the current mon ID
        if (!monAbilities[monId].contains(address(m.ability))) {
            return false;
        }
        return true;
    }

    function validateMonBatch(Mon[] calldata mons, uint256[] calldata ids) external view returns (bool) {
        uint256 len = mons.length;
        for (uint256 i; i < len;) {
            if (!validateMon(mons[i], ids[i])) {
                return false;
            }
            unchecked {
                ++i;
            }
        }
        return true;
    }

    function getMonData(uint256 monId)
        external
        view
        returns (MonStats memory _monStats, uint256[] memory moves, address[] memory abilities)
    {
        _monStats = monStats[monId];
        moves = monMoves[monId].values();
        abilities = monAbilities[monId].values();
    }

    function getMonDataBatch(uint256[] calldata ids)
        external
        view
        returns (MonStats[] memory stats, uint256[][] memory moves, address[][] memory abilities)
    {
        uint256 len = ids.length;
        stats = new MonStats[](len);
        moves = new uint256[][](len);
        abilities = new address[][](len);
        for (uint256 i; i < len;) {
            uint256 monId = ids[i];
            stats[i] = monStats[monId];
            moves[i] = monMoves[monId].values();
            abilities[i] = monAbilities[monId].values();
            unchecked {
                ++i;
            }
        }
    }

    function getMonIds(uint256 start, uint256 end) external view returns (uint256[] memory) {
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

    function getMonStats(uint256 monId) external view returns (MonStats memory) {
        return monStats[monId];
    }

    function isValidMove(uint256 monId, uint256 moveSlot) external view returns (bool) {
        return monMoves[monId].contains(moveSlot);
    }

    function isValidAbility(uint256 monId, IAbility ability) external view returns (bool) {
        return monAbilities[monId].contains(address(ability));
    }

    function getMonCount() external view returns (uint256) {
        return monIds.length();
    }
}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IOwnableMon} from "../gacha/IOwnableMon.sol";
import {Ownable} from "../lib/Ownable.sol";
import "./LookupTeamRegistry.sol";

contract GachaTeamRegistry is LookupTeamRegistry, Ownable {
    IOwnableMon immutable OWNER_LOOKUP;

    error NotOwner();

    constructor(Args memory args, IOwnableMon _OWNER_LOOKUP) LookupTeamRegistry(args) {
        OWNER_LOOKUP = _OWNER_LOOKUP;
        _initializeOwner(msg.sender);
    }

    function _validateOwnership(uint256[] memory monIndices) internal view {
        if (!OWNER_LOOKUP.isOwnerBatch(msg.sender, monIndices)) {
            revert NotOwner();
        }
    }

    function createTeam(uint256[] memory monIndices) public override {
        _validateOwnership(monIndices);
        super.createTeam(monIndices);
    }

    function createTeamForUser(address user, uint256[] memory monIndices) external onlyOwner {
        _createTeamForUser(user, monIndices);
    }

    // TODO: For prod we won't want this
    function updateTeamForUser(uint256[] memory newMonIndices) external {
        uint256[] memory teamMonIndicesToOverride = new uint256[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; i++) {
            teamMonIndicesToOverride[i] = i;
        }
        super.updateTeam(0, teamMonIndicesToOverride, newMonIndices);
    }

    function updateTeam(uint256 teamIndex, uint256[] memory teamMonIndicesToOverride, uint256[] memory newMonIndices)
        public
        override
    {
        _validateOwnership(newMonIndices);
        super.updateTeam(teamIndex, teamMonIndicesToOverride, newMonIndices);
    }
}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {CreateX} from "./CreateX.sol";
import {EffectBitmap} from "./EffectBitmap.sol";
import {EffectStep} from "../Enums.sol";

/// @title EffectDeployer
/// @notice Helper library for deploying Effect contracts via CREATE3 with bitmap-encoded addresses
/// @dev Uses CreateX to deploy effects at addresses where the MSB encodes which EffectSteps they run at.
///      Salts must be pre-mined using the effect-miner CLI tool.
library EffectDeployer {
    /// @notice Error thrown when deployed address doesn't match expected bitmap
    error BitmapMismatch(address deployed, uint16 expectedBitmap, uint16 actualBitmap);

    /// @notice Deploy an effect contract via CREATE3 and verify its address bitmap
    /// @param createX The CreateX factory contract
    /// @param salt The pre-mined salt that produces an address with the correct bitmap
    /// @param initCode The contract creation bytecode (including constructor args)
    /// @param expectedBitmap The expected bitmap value for verification
    /// @return deployed The deployed contract address
    function deploy(
        CreateX createX,
        bytes32 salt,
        bytes memory initCode,
        uint16 expectedBitmap
    ) internal returns (address deployed) {
        deployed = createX.deployCreate3(salt, initCode);

        // Verify the deployed address has the expected bitmap
        uint16 actualBitmap = EffectBitmap.extractBitmap(deployed);
        if (actualBitmap != expectedBitmap) {
            revert BitmapMismatch(deployed, expectedBitmap, actualBitmap);
        }
    }

    /// @notice Deploy an effect without bitmap verification (use with caution)
    /// @param createX The CreateX factory contract
    /// @param salt The salt for CREATE3 deployment
    /// @param initCode The contract creation bytecode
    /// @return deployed The deployed contract address
    function deployUnchecked(
        CreateX createX,
        bytes32 salt,
        bytes memory initCode
    ) internal returns (address deployed) {
        deployed = createX.deployCreate3(salt, initCode);
    }

    /// @notice Compute the address that would be deployed with a given salt
    /// @param createX The CreateX factory contract
    /// @param salt The salt for CREATE3 deployment
    /// @return The computed address
    function computeAddress(CreateX createX, bytes32 salt) internal view returns (address) {
        return createX.computeCreate3Address(salt);
    }

    /// @notice Compute the bitmap for a given CREATE3 salt
    /// @param createX The CreateX factory contract
    /// @param salt The salt for CREATE3 deployment
    /// @return The bitmap that the deployed address would have
    function computeBitmap(CreateX createX, bytes32 salt) internal view returns (uint16) {
        address addr = createX.computeCreate3Address(salt);
        return EffectBitmap.extractBitmap(addr);
    }
}

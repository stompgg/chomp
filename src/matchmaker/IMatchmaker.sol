// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

interface IMatchmaker {
    function validateMatch(bytes32 battleKey, address p0, address p1) external returns (bool);
}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

/// @dev Return shape of every deploy script; processing/deploy.py parses it out of forge's output.
struct DeployData {
    string name;
    address contractAddress;
}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

// Status class id reserved for test-only statuses: prod ids are 1..14 (validateEffectBitmaps.py
// rejects 15 in src/), so mocks can never collide with a deployed status. Mocks share this id;
// if a test ever needs two distinct mock statuses in one battle, extend the reservation to a band.
uint256 constant TEST_STATUS_CLASS = 15;

// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

/// @notice Reentrancy protection for smart contracts
abstract contract ReentrancyGuard {
    uint256 private reentrancyLock = 1;

    modifier nonReentrant() virtual {
        require(reentrancyLock == 1);
        reentrancyLock = 2;

        _;

        reentrancyLock = 1;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @author philogy <https://github.com/philogy>
/// @author KONFeature <https://github.com/KONFeature>
library Ops {
    uint256 internal constant MASK_OP = 0xf0;

    uint256 internal constant SWAP = 0x00;
    uint256 internal constant SWAP_DIR = 0x01;

    uint256 internal constant ADD_LIQ = 0x10;
    uint256 internal constant RM_LIQ = 0x20;
    uint256 internal constant SEND = 0x30;
    uint256 internal constant RECEIVE = 0x40;

    uint256 internal constant SWAP_HEAD = 0x50;

    uint256 internal constant SWAP_HOP = 0x60;

    /// @dev Send all the token due to a user from the pool
    uint256 internal constant SEND_ALL = 0x70;

    /// @dev Same as before but should be used with native token from a given pool
    uint256 internal constant SEND_ALL_AND_UNWRAP = 0x80;

    /// @dev Ask the user to give the required amount of token to the pool (using the IGiver interface)
    uint256 internal constant RECEIVE_ALL = 0x90;

    /// @dev Pull all the user token using the safeTransFrom erc20 function
    uint256 internal constant PULL_ALL = 0xA0;

    /// @dev Permit token withdraw via EIP-2612 signature
    uint256 internal constant PERMIT_VIA_SIG = 0xB0;

    /// @dev Claim all the fees available
    uint256 internal constant CLAIM_ALL_FEES = 0xC0;

    /// @dev The minimum amount of token for the `ALL` operations
    uint256 internal constant ALL_MIN_BOUND = 0x01;
    /// @dev The maximum amount of token for the `ALL` operations
    uint256 internal constant ALL_MAX_BOUND = 0x02;

    /// @dev Receive custom options
    uint256 internal constant RECEIVE_NATIVE_TOKEN = 0x01;
}

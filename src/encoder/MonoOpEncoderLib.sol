// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ops} from "../Ops.sol";

/// @title MonoOpEncoderLib
/// @author philogy <https://github.com/philogy>
/// @author KONFeature <https://github.com/KONFeature>
/// @notice Library for decoding operations
library MonoOpEncoderLib {
    /**
     * @notice Appends a swap operations in the pool with 'token' for 'amount' and 'zeroForOne' direction
     * @param self The encoded operations
     * @param token The token to swap
     * @param zeroForOne The direction of the swap
     * @param amount The amount to swap
     * @return The updated encoded operations
     */
    function appendSwap(bytes memory self, address token, bool zeroForOne, uint256 amount)
        internal
        pure
        returns (bytes memory)
    {
        uint256 op = Ops.SWAP | (zeroForOne ? Ops.SWAP_DIR : 0);
        assembly ("memory-safe") {
            let length := mload(self)
            mstore(self, add(length, 37))
            let initialOffset := add(add(self, 0x20), length)

            mstore(initialOffset, shl(248, op))
            mstore(add(initialOffset, 1), shl(96, token))
            mstore(add(initialOffset, 21), shl(128, amount))
        }

        return self;
    }

    /**
     * @notice Appends the add liquidity operation to the encoded operations
     * @param self The encoded operations
     * @param token The token to add liquidity for
     * @param to The recipient of the liquidity tokens
     * @param maxAmount0 The maximum amount of baseToken to add
     * @param maxAmount1 The maximum amount of targetToken to add
     * @return The updated encoded operations
     */
    function appendAddLiquidity(bytes memory self, address token, address to, uint256 maxAmount0, uint256 maxAmount1)
        internal
        pure
        returns (bytes memory)
    {
        // 73 = 1 byte for the op code + 2 addresses + 2 uint256s
        uint256 op = Ops.ADD_LIQ;
        assembly ("memory-safe") {
            // Increase the length of the bytes array by 73 bytes
            let length := mload(self)
            mstore(self, add(length, 73))
            // Get the address of the start of the new bytes
            let initialOffset := add(add(self, 0x20), length)

            // Write the add liquidity operation to the new bytes
            mstore(initialOffset, shl(248, op))
            mstore(add(initialOffset, 1), shl(96, token))
            mstore(add(initialOffset, 21), shl(96, to))
            mstore(add(initialOffset, 41), shl(128, maxAmount0))
            mstore(add(initialOffset, 57), shl(128, maxAmount1))
        }

        return self;
    }

    /**
     * @notice Appends the remove liquidity operation to the encoded operations
     * @param self The encoded operations
     * @param token The token to remove liquidity for
     * @param liquidity The amount of liquidity to remove
     * @return The updated encoded operations
     */
    function appendRemoveLiquidity(bytes memory self, address token, uint256 liquidity)
        internal
        pure
        returns (bytes memory)
    {
        uint256 op = Ops.RM_LIQ;

        assembly ("memory-safe") {
            let length := mload(self)
            mstore(self, add(length, 53))
            let initialOffset := add(add(self, 0x20), length)

            mstore(initialOffset, shl(248, op))
            mstore(add(initialOffset, 1), shl(96, token))
            mstore(add(initialOffset, 21), liquidity)
        }

        return self;
    }

    /**
     * @notice Appends the send operation to the encoded operations
     * @dev Will ask the user to send his `token` to the pool defined by the token
     * @param self The encoded operations
     * @param token The token to send from the user to the pool
     * @param to The recipient of the tokens
     * @param amount The amount of tokens to send
     * @return The updated encoded operations
     */
    function appendSend(bytes memory self, address token, address to, uint256 amount)
        internal
        pure
        returns (bytes memory)
    {
        uint256 op = Ops.SEND;
        assembly ("memory-safe") {
            let length := mload(self)
            mstore(self, add(length, 57))
            let initialOffset := add(add(self, 0x20), length)

            mstore(initialOffset, shl(248, op))
            mstore(add(initialOffset, 1), shl(96, token))
            mstore(add(initialOffset, 21), shl(96, to))
            mstore(add(initialOffset, 41), shl(128, amount))
        }

        return self;
    }

    /**
     * @notice Appends the send all operation to the encoded operations
     * @param self The encoded operations
     * @param token The token to send from the pool
     * @param to The recipient of the tokens
     * @return The updated encoded operations
     */
    function appendSendAll(bytes memory self, address token, address to) internal pure returns (bytes memory) {
        uint256 op = Ops.SEND_ALL;
        assembly ("memory-safe") {
            let length := mload(self)
            mstore(self, add(length, 41))
            let initialOffset := add(add(self, 0x20), length)

            mstore(initialOffset, shl(248, op))
            mstore(add(initialOffset, 1), shl(96, token))
            mstore(add(initialOffset, 21), shl(96, to))
        }

        return self;
    }

    /**
     * @notice Appends the send all operation to the encoded operations
     * @param self The encoded operations
     * @param token The token to send from the pool
     * @param to The recipient of the tokens
     * @param minAmount The min amount of token to send
     * @param maxAmount The max amount of token to send
     * @return The updated encoded operations
     */
    function appendSendAllWithLimit(bytes memory self, address token, address to, uint256 minAmount, uint256 maxAmount)
        internal
        pure
        returns (bytes memory)
    {
        uint256 op = Ops.SEND_ALL + Ops.ALL_MIN_BOUND + Ops.ALL_MAX_BOUND;
        assembly ("memory-safe") {
            let length := mload(self)
            mstore(self, add(length, 73))
            let initialOffset := add(add(self, 0x20), length)

            mstore(initialOffset, shl(248, op))
            mstore(add(initialOffset, 1), shl(96, token)) // address -> bytes20
            mstore(add(initialOffset, 21), shl(128, minAmount)) // uint128 -> bytes16
            mstore(add(initialOffset, 37), shl(128, maxAmount)) // uint128 -> bytes16
            mstore(add(initialOffset, 53), shl(96, to)) // address -> bytes20
        }

        return self;
    }

    /**
     * @notice Appends the send all & unwrap operation to the encoded operations
     * @param self The encoded operations
     * @param token The token to send from the pool
     * @param to The recipient of the tokens
     * @return The updated encoded operations
     */
    function appendSendAllAndUnwrap(bytes memory self, address token, address to)
        internal
        pure
        returns (bytes memory)
    {
        uint256 op = Ops.SEND_ALL_AND_UNWRAP;
        assembly ("memory-safe") {
            let length := mload(self)
            mstore(self, add(length, 41))
            let initialOffset := add(add(self, 0x20), length)

            mstore(initialOffset, shl(248, op))
            mstore(add(initialOffset, 1), shl(96, token))
            mstore(add(initialOffset, 21), shl(96, to))
        }

        return self;
    }

    /**
     * @notice Appends the receive operation to the encoded operations
     * @param self The encoded operations
     * @param token The token to be received by the user
     * @param amount The amount of tokens to receive
     * @param isNative Do we want to receive the native token or not?
     * @return The updated encoded operations
     */
    function appendReceive(bytes memory self, address token, uint256 amount, bool isNative)
        internal
        pure
        returns (bytes memory)
    {
        uint256 op = Ops.RECEIVE;
        if (isNative) {
            op = op + Ops.RECEIVE_NATIVE_TOKEN;
        }
        assembly ("memory-safe") {
            let length := mload(self)
            mstore(self, add(length, 37))
            let initialOffset := add(add(self, 0x20), length)

            mstore(initialOffset, shl(248, op))
            mstore(add(initialOffset, 1), shl(96, token))
            mstore(add(initialOffset, 21), shl(128, amount))
        }

        return self;
    }

    /**
     * @notice Appends the receive all operation to the encoded operations
     * @param self The encoded operations
     * @param token The token to be received by the user
     * @return The updated encoded operations
     */
    function appendReceiveAll(bytes memory self, address token) internal pure returns (bytes memory) {
        uint256 op = Ops.RECEIVE_ALL;
        assembly ("memory-safe") {
            let length := mload(self)
            mstore(self, add(length, 21))
            let initialOffset := add(add(self, 0x20), length)

            mstore(initialOffset, shl(248, op))
            mstore(add(initialOffset, 1), shl(96, token))
        }

        return self;
    }

    /**
     * @notice Appends the pull all operation to the encoded operations
     * @param self The encoded operations
     * @param token The token that was sent by the user
     * @return The updated encoded operations
     */
    function appendPullAll(bytes memory self, address token) internal pure returns (bytes memory) {
        uint256 op = Ops.PULL_ALL;
        assembly ("memory-safe") {
            let length := mload(self)
            mstore(self, add(length, 21))
            let initialOffset := add(add(self, 0x20), length)

            mstore(initialOffset, shl(248, op))
            mstore(add(initialOffset, 1), shl(96, token))
        }

        return self;
    }

    /**
     * @notice Appends a allowance via a EIP-2612 permit signature to the encoded operations
     * @param self The encoded operations
     * @param token The token which we need to allow
     * @param amount The amount that need to be allowed (uint128)
     * @param deadline The deadline for the permit signature (uint48 behind the scene, max possible value for a realistic seconds timestamp)
     * @param v The v value of the permit signature (uint8)
     * @param r The r value of the permit signature (bytes32)
     * @param s The s value of the permit signature (bytes32)
     * @return The updated encoded operations
     */
    function appendPermitViaSig(
        bytes memory self,
        address token,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal pure returns (bytes memory) {
        uint256 op = Ops.PERMIT_VIA_SIG;
        assembly ("memory-safe") {
            let length := mload(self)
            mstore(self, add(length, 108))
            let initialOffset := add(add(self, 0x20), length)

            mstore(initialOffset, shl(248, op))
            mstore(add(initialOffset, 1), shl(96, token)) // bytes20
            mstore(add(initialOffset, 21), shl(128, amount)) // uint128 -> bytes16
            mstore(add(initialOffset, 37), shl(208, deadline)) // uint48 -> bytes6
            mstore(add(initialOffset, 43), shl(248, v)) // uint8 -> bytes1
            mstore(add(initialOffset, 44), r) // bytes32
            mstore(add(initialOffset, 76), s) // bytes32
        }

        return self;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title OpDecoderLib
/// @author philogy <https://github.com/philogy>
/// @author KONFeature <https://github.com/KONFeature>
/// @notice Library for decoding operations
library OpDecoderLib {
    function readAddress(uint256 self) internal pure returns (uint256 newPtr, address addr) {
        uint256 rawVal;
        (newPtr, rawVal) = readUint(self, 20);
        addr = address(uint160(rawVal));
    }

    function readUint(uint256 self, uint256 size) internal pure returns (uint256 newPtr, uint256 x) {
        require(size >= 1 && size <= 32);
        assembly {
            newPtr := add(self, size)
            x := shr(shl(3, sub(32, size)), calldataload(self))
        }
    }
}

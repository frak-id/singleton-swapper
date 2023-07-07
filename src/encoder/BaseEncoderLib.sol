// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ops} from "../Ops.sol";

/// @title BaseEncoderLib
/// @author philogy <https://github.com/philogy>
/// @author KONFeature <https://github.com/KONFeature>
/// @notice Library with the base encoding options
library BaseEncoderLib {
    function init(uint256 hashMapSize) internal pure returns (bytes memory program) {
        require(hashMapSize <= 0xffff);
        assembly ("memory-safe") {
            program := mload(0x40)
            mstore(0x40, add(program, 0x22))
            mstore(add(program, 2), hashMapSize)
            mstore(program, 2)
        }
    }

    // This code is used to return a value
    // from a function. It is used in the
    // function done in this contract.
    //
    // NOTE: This code is not optimized for
    // gas efficiency. It is only intended
    // to be used for security purposes.
    function done(bytes memory self) internal pure returns (bytes memory) {
        assembly ("memory-safe") {
            let freeMem := mload(0x40)
            mstore(0x40, add(freeMem, mload(self)))
        }
        return self;
    }
}

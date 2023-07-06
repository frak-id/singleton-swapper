// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IGiver} from "src/interfaces/IGiver.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @author KONFeature <https://github.com/KONFeature>
contract MockGiver is IGiver {
    using SafeTransferLib for address;

    function give(address token, uint256 amount) external returns (bytes4) {
        token.safeTransfer(msg.sender, amount);
        return IGiver.give.selector;
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {IWrappedNativeToken} from "src/interfaces/IWrappedNativeToken.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @author KONFeature <https://github.com/KONFeature>
/// @dev Simply copy from https://polygonscan.com/token/0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270#code
contract MockWNative is ERC20("Mock Wrapped Native Token", "wMCK"), IWrappedNativeToken {
    using SafeTransferLib for address;

    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    function deposit() public payable {
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) public {
        _burn(msg.sender, wad);
        msg.sender.safeTransferETH(wad);
        emit Withdrawal(msg.sender, wad);
    }
}

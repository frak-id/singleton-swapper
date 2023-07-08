// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @dev Wrapped native token interface
/// @author KONFeature <https://github.com/KONFeature>
interface IWrappedNativeToken {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

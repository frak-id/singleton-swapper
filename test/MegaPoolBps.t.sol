// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";
import {MegaPool} from "src/MegaPool.sol";
import {EncoderLib} from "src/utils/EncoderLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {MockGiver} from "./mock/MockGiver.sol";

/// @title MegaPoolTest
/// @author KONFeature <https://github.com/KONFeature>
/// @notice Test contract for MegaPool with a BPS value
contract MegaPoolBpsTest is Test {
    using SafeTransferLib for address;
    using EncoderLib for bytes;

    MegaPool private pool;

    uint256 private bps = 0.5e3;

    function setUp() public {
        pool = new MegaPool(bps);
    }

    /**
     * @notice Test swap with single operation
     */
    function testMain() public {
        MockERC20 token0 = _newToken("token_0");
        MockERC20 token1 = _newToken("token_1");

        if (token0 >= token1) (token0, token1) = (token1, token0);

        address liquidityProvider = address(_newGiver("liquidityProvider"));
        address swapUser = address(_newGiver("swapUser"));

        token0.mint(liquidityProvider, 100e18);
        token1.mint(liquidityProvider, 100e18);

        // Append initial liquidity to the pool
        bytes memory program = EncoderLib.init(64).appendAddLiquidity(
            address(token0), address(token1), liquidityProvider, 10e18, 10e18
        ).appendReceive(address(token0), 10e18).appendReceive(address(token1), 10e18).done();

        vm.prank(liquidityProvider);
        pool.execute(program);

        (uint128 reserves0, uint128 reserves1, uint256 totalLiquidity) = pool.getPool(address(token0), address(token1));
        console.log("=== Post add liquidity ===");
        console.log("reserves0: %s", reserves0);
        console.log("reserves1: %s", reserves1);
        console.log("totalLiquidity: %s", totalLiquidity);
        console.log("");

        // Perform a first swap
        token0.mint(swapUser, 0.1e18);
        _swap0to1(address(token0), address(token1), swapUser, 0.1e18);
        _swap1to0(address(token0), address(token1), swapUser, 0.09e18);
    }

    function _swap0to1(address token0, address token1, address user, uint256 toSwap) internal {
        (uint128 reserves0, uint128 reserves1, uint256 totalLiquidity) = pool.getPool(token0, token1);

        // Perform a second swap
        uint256 inAmount = toSwap;

        // Compute the out amount
        uint256 outAmount = reserves1 - (reserves0 * reserves1) / (reserves0 + inAmount * (1e4 - bps) / 1e4);

        // Build the swap op
        bytes memory operations = EncoderLib.init(64).appendSwap(token0, token1, true, inAmount).appendReceive(
            token0, inAmount
        ).appendSend(token1, user, outAmount).done();

        // Send it
        vm.prank(user);
        pool.execute(operations);

        (reserves0, reserves1, totalLiquidity) = pool.getPool(token0, token1);
        console.log("= Post 0->1 swap of %s =", toSwap);
        _postSwapAmountLog(inAmount, outAmount);
        _postSwapBalanceLog(token0, token1, user);
        _postSwapReserveLog(token0, token1);
        console.log("");
    }

    function _swap1to0(address token0, address token1, address user, uint256 toSwap) internal {
        (uint128 reserves0, uint128 reserves1, uint256 totalLiquidity) = pool.getPool(token0, token1);

        // Perform a second swap
        uint256 inAmount = toSwap;

        // Compute the out amount
        uint256 outAmount = reserves0 - (reserves0 * reserves1) / (reserves1 + inAmount * (1e4 - bps) / 1e4);

        // Build the swap op
        bytes memory operations = EncoderLib.init(64).appendSwap(token0, token1, false, inAmount).appendReceive(
            token1, inAmount
        ).appendSend(token0, user, outAmount).done();
        vm.prank(user);
        pool.execute(operations);

        (reserves0, reserves1, totalLiquidity) = pool.getPool(token0, token1);
        console.log("= Post 1->0 swap of %s =", toSwap);
        _postSwapAmountLog(inAmount, outAmount);
        _postSwapBalanceLog(token0, token1, user);
        _postSwapReserveLog(token0, token1);
        console.log("");
    }

    function _postSwapAmountLog(uint256 in, uint256 out) internal {
        console.log("=== Swap ===");
        console.log(" inAmount: %s", in);
        console.log("outAmount: %s", out);
    }

    function _postSwapReserveLog(address token0, address token1) internal {
        (uint128 reserves0, uint128 reserves1, uint256 totalLiquidity) = pool.getPool(token0, token1);
        console.log("=== Pool ===");
        console.log("reserves0: %s", reserves0);
        console.log("reserves1: %s", reserves1);
        console.log("totalLiquidity: %s", totalLiquidity);
    }

    function _postSwapBalanceLog(address token0, address token1, address user) internal {
        console.log("=== User Balances ===");
        console.log("token0: %s", ERC20(token0).balanceOf(user));
        console.log("token1: %s", ERC20(token1).balanceOf(user));
    }

    function _newToken(string memory label) internal returns (MockERC20 newToken) {
        newToken = new MockERC20();
        vm.label(address(newToken), label);
    }

    function _newGiver(string memory label) internal returns (MockGiver newGiver) {
        newGiver = new MockGiver();
        vm.label(address(newGiver), label);
    }
}

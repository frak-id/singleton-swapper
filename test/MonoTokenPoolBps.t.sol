// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";
import {MonoTokenPool} from "src/MonoTokenPool.sol";
import {MonoOpEncoderLib} from "src/encoder/MonoOpEncoderLib.sol";
import {BaseEncoderLib} from "src/encoder/BaseEncoderLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {MockGiver} from "./mock/MockGiver.sol";

/// @title MonoTokenPoolBpsTest
/// @author KONFeature <https://github.com/KONFeature>
/// @notice Test contract for MonoTokenPool with a BPS value
contract MonoTokenPoolBpsTest is Test {
    using SafeTransferLib for address;
    using BaseEncoderLib for bytes;
    using MonoOpEncoderLib for bytes;

    MonoTokenPool private pool;

    // 0.5e3 = 0.5%
    uint256 private bps = 1e3;

    MockERC20 private baseToken;

    function setUp() public {
        baseToken = _newToken("baseToken");
        pool = new MonoTokenPool(address(baseToken), bps);
    }

    /**
     * @notice Test swap with single operation
     */
    function testMain() public {
        MockERC20 targetToken = _newToken("targetToken");

        address liquidityProvider = address(_newGiver("liquidityProvider"));
        address swapUser = address(_newGiver("swapUser"));

        uint256 initialDepositToken0 = 10e18;
        uint256 initialDepositToken1 = 10e18;

        baseToken.mint(liquidityProvider, initialDepositToken0);
        targetToken.mint(liquidityProvider, initialDepositToken1);

        // Append initial liquidity to the pool
        // forgefmt: disable-next-item
        bytes memory program = BaseEncoderLib.init(4)
            .appendAddLiquidity(address(targetToken), liquidityProvider, initialDepositToken0, initialDepositToken1)
            .appendReceive(address(baseToken), initialDepositToken0, false)
            .appendReceive(address(targetToken), initialDepositToken1, false)
            .done();

        vm.prank(liquidityProvider);
        pool.execute(program);

        console.log("= Post add liquidity =");
        _postSwapReserveLog(address(targetToken));
        console.log("");

        // Perform a few swap
        baseToken.mint(swapUser, 0.1e18);
        _swap0to1(address(targetToken), swapUser, baseToken.balanceOf(swapUser));
        _swap1to0(address(targetToken), swapUser, targetToken.balanceOf(swapUser));
        _swap0to1(address(targetToken), swapUser, baseToken.balanceOf(swapUser));
        _swap1to0Pull(address(targetToken), swapUser, targetToken.balanceOf(swapUser));

        // Tell the liquidityProvider to withdraw of all his founds
        // forgefmt: disable-next-item
        program = BaseEncoderLib.init(4)
            .appendRemoveLiquidity(address(targetToken), 10e18)
            .appendSendAll(address(baseToken), liquidityProvider)
            .appendSendAll(address(targetToken), liquidityProvider)
            .done();

        vm.prank(liquidityProvider);
        pool.execute(program);

        // Log the final state
        console.log("= Post remove liquidity =");
        _postSwapReserveLog(address(targetToken));
        console.log("");

        // Ensure that the liquidity provider has all his founds
        uint256 newBalanceToken0 = baseToken.balanceOf(liquidityProvider);
        uint256 newBalanceToken1 = targetToken.balanceOf(liquidityProvider);
        console.log("liquidity provider new global balance: %s", newBalanceToken0 + newBalanceToken1);
        console.log(
            "liquidity provider profit: %s",
            (newBalanceToken0 + newBalanceToken1) - (initialDepositToken0 + initialDepositToken1)
        );
        assertGt(newBalanceToken0 + newBalanceToken1, initialDepositToken0 + initialDepositToken1);
    }

    function _swap0to1(address token, address user, uint256 toSwap) internal {
        (uint128 reserves0, uint128 reserves1,) = pool.getPool(token);

        // Perform a second swap
        uint256 inAmount = toSwap;

        // Compute the out amount
        uint256 outAmount = reserves1 - (reserves0 * reserves1) / (reserves0 + inAmount * (1e4 - bps) / 1e4);

        // Build the swap op
        // forgefmt: disable-next-item
        bytes memory operations = BaseEncoderLib.init(4)
            .appendSwap(token, true, inAmount)
            .appendReceive(address(baseToken), inAmount, false)
            .appendSend(token, user, outAmount)
            .done();

        // Send it
        vm.prank(user);
        pool.execute(operations);

        console.log("= Post 0->1 swap of %s =", toSwap);
        _postSwapAmountLog(inAmount, outAmount);
        _postSwapBalanceLog(token, user);
        _postSwapReserveLog(token);
        console.log("");
    }

    function _swap1to0(address token, address user, uint256 toSwap) internal {
        (uint128 reserves0, uint128 reserves1,) = pool.getPool(token);

        // Perform a second swap
        uint256 inAmount = toSwap;

        // Compute the out amount
        uint256 outAmount = reserves0 - (reserves0 * reserves1) / (reserves1 + inAmount * (1e4 - bps) / 1e4);

        // Build the swap op
        // forgefmt: disable-next-item
        bytes memory operations = BaseEncoderLib.init(4)
            .appendSwap(token, false, inAmount)
            .appendReceive(token, inAmount, false)
            .appendSend(address(baseToken), user, outAmount)
            .done();

        vm.prank(user);
        pool.execute(operations);

        console.log("= Post 1->0 swap of %s =", toSwap);
        _postSwapAmountLog(inAmount, outAmount);
        _postSwapBalanceLog(token, user);
        _postSwapReserveLog(token);
        console.log("");
    }

    function _swap1to0Pull(address token, address user, uint256 toSwap) internal {
        (uint128 reserves0, uint128 reserves1,) = pool.getPool(token);

        // Perform a second swap
        uint256 inAmount = toSwap;

        // Compute the out amount
        uint256 outAmount = reserves0 - (reserves0 * reserves1) / (reserves1 + inAmount * (1e4 - bps) / 1e4);

        // Transfer the in amount
        vm.prank(user);
        ERC20(token).increaseAllowance(address(pool), inAmount);

        // Build the swap op
        // forgefmt: disable-next-item
        bytes memory operations = BaseEncoderLib.init(4)
            .appendSwap(token, false, inAmount)
            .appendPullAll(token)
            .appendSend(address(baseToken), user, outAmount)
            .done();

        vm.prank(user);
        pool.execute(operations);

        console.log("= Post 1->0 swap via pull of %s =", toSwap);
        _postSwapAmountLog(inAmount, outAmount);
        _postSwapBalanceLog(token, user);
        _postSwapReserveLog(token);
        console.log("");
    }

    function _postSwapAmountLog(uint256 inAmount, uint256 outAmount) internal view {
        console.log("=== Swap ===");
        console.log(" inAmount: %s", inAmount);
        console.log("outAmount: %s", outAmount);
    }

    function _postSwapReserveLog(address token) internal view {
        (uint128 reserves0, uint128 reserves1, uint256 totalLiquidity) = pool.getPool(token);
        console.log("=== Pool ===");
        console.log("reserves0: %s", reserves0);
        console.log("reserves1: %s", reserves1);
        console.log("totalLiquidity: %s", totalLiquidity);
    }

    function _postSwapBalanceLog(address token, address user) internal view {
        console.log("=== User Balances ===");
        console.log("token0: %s", baseToken.balanceOf(user));
        console.log("token1: %s", ERC20(token).balanceOf(user));
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

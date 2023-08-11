// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";
import {MonoTokenPool} from "src/MonoTokenPool.sol";
import {MonoOpEncoderLib} from "src/encoder/MonoOpEncoderLib.sol";
import {BaseEncoderLib} from "src/encoder/BaseEncoderLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {MockPermitERC20} from "../mock/MockPermitERC20.sol";
import {MockWNative} from "../mock/MockWNative.sol";

/// @title MonoTokenNativePool.t
/// @author KONFeature <https://github.com/KONFeature>
/// @notice Test contract for MonoTokenPool with native token swap
contract MonoTokenNativePool is Test {
    using SafeTransferLib for address;
    using BaseEncoderLib for bytes;
    using MonoOpEncoderLib for bytes;

    /// @dev The pool to test
    MonoTokenPool private pool;

    // 0.5e3 = 0.5%
    uint256 private bps = 1e3;

    /// @dev The base token
    MockPermitERC20 private baseToken;

    /// @dev The wrapped native token mock
    MockWNative private wNativeToken;

    /// @dev Our liquidity provider user
    address private liquidityProvider;

    /// @dev The permit typehash
    bytes32 private constant _PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function setUp() public {
        baseToken = _newToken("baseToken");
        wNativeToken = _newWrappedNativeToken("wrappedNativeToken");
        pool = new MonoTokenPool(address(baseToken), bps, address(13), 20);

        vm.prank(address(13));
        pool.updateFeeReceiver(address(0), 0);

        // Create a liquidity provider user
        liquidityProvider = address(_newUser("liquidityProvider"));

        // Create the initial pool
        _createPoolAndAddLiquidity();
    }

    /// @dev Create the native pool and add liquidity
    function _createPoolAndAddLiquidity() internal {
        // Initial deposit to the pool
        uint256 initialDepositToken0 = 100e18;
        uint256 initialDepositToken1 = 100e18;

        // Mint the initial tokens to the liquidity provider
        baseToken.mint(liquidityProvider, initialDepositToken0);
        // Add some fake eth to our user
        vm.deal(liquidityProvider, initialDepositToken1);
        // Wrap them into wNativeToken
        vm.prank(liquidityProvider);
        wNativeToken.deposit{value: initialDepositToken1}();

        // Authorise the pool to spend our tokens
        vm.startPrank(liquidityProvider);
        baseToken.approve(address(pool), initialDepositToken0);
        wNativeToken.approve(address(pool), initialDepositToken1);
        vm.stopPrank();

        // Build the program to execute
        // forgefmt: disable-next-item
        bytes memory program = BaseEncoderLib.init(4)
            .appendAddLiquidity(address(wNativeToken), liquidityProvider, initialDepositToken0, initialDepositToken1)
            .appendPullAll(address(baseToken))
            .appendPullAll(address(wNativeToken))
            .done();

        // Execute it
        vm.prank(liquidityProvider);
        pool.execute(program);
    }

    /// @dev Test the swap method with native token
    function test_swapNativeViaPullOk() public {
        // Create our swap user
        address swapUser = _newUser("swapUser");

        // Amount of native token to swap
        uint256 amountToSwap = 1e18;

        // Allow the pool to access the user founds
        vm.deal(swapUser, amountToSwap);
        vm.startPrank(swapUser);
        wNativeToken.deposit{value: amountToSwap}();
        wNativeToken.approve(address(pool), amountToSwap);
        vm.stopPrank();

        // Print initial state
        console.log("=== Before swap ===");
        _postSwapReserveLog();
        _postSwapBalanceLog(swapUser);

        // Build the swap operations
        // forgefmt: disable-next-item
        bytes memory program = BaseEncoderLib.init(4)
            .appendSwap(address(wNativeToken), false, amountToSwap)
            .appendPullAll(address(wNativeToken))
            .appendSendAll(address(baseToken), swapUser)
            .done();

        // Execute the swap
        vm.prank(swapUser);
        pool.execute(program);

        // Print final pool state
        console.log("=== Final Pool State ===");
        _postSwapReserveLog();
        _postSwapBalanceLog(swapUser);

        // Ensure the user has no more native token
        assertEq(wNativeToken.balanceOf(swapUser), 0);
        // Ensure the user has received the base token, but the fees are taken
        assertGt(baseToken.balanceOf(swapUser), 0);
        assertLt(baseToken.balanceOf(swapUser), amountToSwap);
    }

    /// @dev Test the swap method with native token
    function test_swapNativeViaReceiveOk() public {
        // Create our swap user
        address swapUser = _newUser("swapUser");

        // Amount of native token to swap
        uint256 amountToSwap = 1e18;

        // Allow the pool to access the user founds
        vm.deal(swapUser, amountToSwap);
        vm.startPrank(swapUser);
        vm.stopPrank();

        // Print initial state
        console.log("=== Before swap ===");
        _postSwapReserveLog();
        _postSwapBalanceLog(swapUser);

        // Build the swap operations
        // forgefmt: disable-next-item
        bytes memory program = BaseEncoderLib.init(4)
            .appendSwap(address(wNativeToken), false, amountToSwap)
            .appendReceive(address(wNativeToken), amountToSwap, true)
            .appendSendAll(address(baseToken), swapUser)
            .done();

        // Execute the swap
        vm.prank(swapUser);
        pool.execute{value: amountToSwap}(program);

        // Print final pool state
        console.log("=== Final Pool State ===");
        _postSwapReserveLog();
        _postSwapBalanceLog(swapUser);

        // Ensure the user has no more native token
        assertEq(wNativeToken.balanceOf(swapUser), 0);
        // Ensure the user has received the base token, but the fees are taken
        assertGt(baseToken.balanceOf(swapUser), 0);
        assertLt(baseToken.balanceOf(swapUser), amountToSwap);
    }

    /// @dev Test the swap method with native token
    function test_swapNativeWithSendLimitOk() public {
        // Create our swap user
        address swapUser = _newUser("swapUser");

        // Amount of native token to swap
        uint256 amountToSwap = 1e18;

        // Allow the pool to access the user founds
        vm.deal(swapUser, amountToSwap);
        vm.startPrank(swapUser);
        vm.stopPrank();

        // Print initial state
        console.log("=== Before swap ===");
        _postSwapReserveLog();
        _postSwapBalanceLog(swapUser);

        // Slippage max of 0.5%, so estimate amount result
        uint256 estimateAmount = pool.estimateSwap(address(wNativeToken), amountToSwap, false);
        // Then, 0.5% of estimate amount for min and max
        uint256 minAmount = (estimateAmount * 95) / 100;
        uint256 maxAmount = (estimateAmount * 105) / 100;

        console.log("=== Estimation ===");
        console.log("- Estimation: %s", estimateAmount);
        console.log("- Min amount: %s", minAmount);
        console.log("- Max amount: %s", maxAmount);

        // Build the swap operations
        // forgefmt: disable-next-item
        bytes memory program = BaseEncoderLib.init(4)
            .appendSwap(address(wNativeToken), false, amountToSwap)
            .appendReceive(address(wNativeToken), amountToSwap, true)
            .appendSendAllWithLimit(address(baseToken), swapUser, minAmount, maxAmount)
            .done();
        // From: 106661
        // To  : 9223372036854754743

        // Execute the swap
        vm.prank(swapUser);
        pool.execute{value: amountToSwap}(program);

        // Print final pool state
        console.log("=== Final Pool State ===");
        _postSwapReserveLog();
        _postSwapBalanceLog(swapUser);

        // Ensure the user has no more native token
        assertEq(wNativeToken.balanceOf(swapUser), 0);
        // Ensure the user has received the base token, but the fees are taken
        assertGt(baseToken.balanceOf(swapUser), 0);
        assertLt(baseToken.balanceOf(swapUser), amountToSwap);
    }

    /// @dev Test the swap method with native token
    function test_swapTokenViaPermitOk() public {
        // Create our swap user
        (address swapUser, uint256 privateKey) = _newUserWithPrivKey("swapUser");

        // Amount of base token to swap
        uint256 amountToSwap = 1e18;

        // Mint a few to our swapUser
        baseToken.mint(swapUser, amountToSwap);

        // Generate the permit signature
        uint256 deadline = block.timestamp + 100;
        uint256 nonce = baseToken.nonces(swapUser);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    baseToken.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(_PERMIT_TYPEHASH, swapUser, address(pool), amountToSwap, nonce, deadline))
                )
            )
        );

        // Permit params print
        console.log("=== Permit Params ===");
        console.log(" - deadline: %s", deadline);
        console.log(" - nonce: %s", nonce);
        console.log(" - v: %s", uint256(v));
        console.log(" - r: %s", uint256(r));
        console.log(" - s: %s", uint256(s));

        // Print initial state
        console.log("=== Before swap ===");
        _postSwapReserveLog();
        _postSwapBalanceLog(swapUser);

        // Build the swap operations
        // forgefmt: disable-next-item
        bytes memory program = BaseEncoderLib.init(4)
            .appendSwap(address(wNativeToken), true, amountToSwap)
            .appendPermitViaSig(address(baseToken), amountToSwap, deadline, v, r, s)
            .appendPullAll(address(baseToken))
            .appendSendAllAndUnwrap(address(wNativeToken), swapUser)
            .done();

        // Execute the swap
        vm.prank(swapUser);
        pool.execute(program);

        // Print final pool state
        console.log("=== Final Pool State ===");
        _postSwapReserveLog();
        _postSwapBalanceLog(swapUser);

        // Ensure the user has no more native token
        assertEq(baseToken.balanceOf(swapUser), 0);
        // Ensure the user has received the base token, but the fees are taken
        assertGt(swapUser.balance, 0);
        assertLt(swapUser.balance, amountToSwap);
    }

    function _postSwapReserveLog() internal view {
        (uint128 reserves0, uint128 reserves1, uint256 totalLiquidity, uint128 feeToken0, uint128 feeToken1) =
            pool.getPool(address(wNativeToken));
        console.log("- Pool");
        console.log(" - reserves0: %s", reserves0);
        console.log(" - reserves1: %s", reserves1);
        console.log(" - feeToken0: %s", feeToken0);
        console.log(" - feeToken1: %s", feeToken1);
        console.log(" - totalLiquidity: %s", totalLiquidity);
    }

    function _postSwapBalanceLog(address user) internal view {
        console.log("- User Balances");
        console.log(" - token base: %s", baseToken.balanceOf(user));
        console.log(" - token wrap: %s", wNativeToken.balanceOf(user));
        console.log(" - blockchain: %s", user.balance);
    }

    function _newToken(string memory label) internal returns (MockPermitERC20 newToken) {
        newToken = new MockPermitERC20();
        vm.label(address(newToken), label);
    }

    function _newWrappedNativeToken(string memory label) internal returns (MockWNative newToken) {
        newToken = new MockWNative();
        vm.label(address(newToken), label);
    }

    function _newUser(string memory label) internal returns (address swapUser) {
        swapUser = address(bytes20(keccak256(abi.encode(label))));
        vm.label(swapUser, label);
    }

    function _newUserWithPrivKey(string memory label) internal returns (address swapUser, uint256 privKey) {
        privKey = uint256(keccak256(abi.encode(label)));
        swapUser = vm.addr(privKey);
        vm.label(swapUser, label);
    }
}

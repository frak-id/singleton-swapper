// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.20;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {IERC20Permit} from "openzeppelin/token/ERC20/extensions/IERC20Permit.sol";
import {Pool} from "./libs/PoolLib.sol";
import {Accounter} from "./libs/AccounterLib.sol";
import {BPS} from "./libs/SwapLib.sol";
import {Ops} from "./Ops.sol";

import {IGiver} from "./interfaces/IGiver.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";
import {OpDecoderLib} from "./encoder/OpDecoderLib.sol";

/// @title MonoTokenPool
/// @author philogy <https://github.com/philogy>
/// @notice Same as the original MegaTokenPool, but with a single ERC_20 base token (useful for project that want a pool for their internal swap)
/// @dev baseToken as 0 and 1 as target pool token
/// @dev Every delta, reserves and liquidity follow this rule
contract MonoTokenPool is ReentrancyGuard {
    using SafeTransferLib for address;
    using SafeCastLib for uint256;
    using OpDecoderLib for uint256;

    /// @dev Native token address placeholder
    address private constant NATIVE_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    /* -------------------------------------------------------------------------- */
    /*                                   Storage                                  */
    /* -------------------------------------------------------------------------- */

    /// @dev The fee that will be taken from each swaps
    uint256 public immutable FEE_BPS;

    /// @dev The base token we will use for all the pools
    address private immutable baseToken;

    /// @dev The mapping of all the pools per target token
    mapping(address token => Pool pool) internal pools;

    /// @dev The mapping of our reserves per tokens
    mapping(address token => uint256 totalReserve) public totalReservesOf;

    /* -------------------------------------------------------------------------- */
    /*                               Custom error's                               */
    /* -------------------------------------------------------------------------- */

    error InvalidOp(uint256 op);
    error LeftoverDelta();
    error InvalidGive();
    error NegativeAmount();
    error NegativeReceive();
    error AmountOutsideBounds();

    constructor(address token, uint256 feeBps) {
        require(feeBps < BPS);
        require(token != address(0));
        baseToken = token;
        FEE_BPS = feeBps;
    }

    /**
     * @notice In memory state to handle the accounting for the execution of a program.
     */
    struct State {
        Accounter tokenDeltas;
        address lastToken;
    }

    /* -------------------------------------------------------------------------- */
    /*                           External write method's                          */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Execute a program of operations on pools. The `program` is a serialized list of operations, encoded in a specific format.
     * @dev This function uses a non-ABI encoding to ensure a custom set of operations, each taking on a different amount of data while keeping calldata size minimal. It is not reentrant.
     * @param program Serialized list of operations, with each operation consisting of an 8-bit operation specifier and parameters. The structure is as follows:
     *  2 bytes: accounting hash map size (in tokens) e.g. 0x0040 => up to 64 key, value pairs in the accounting map
     *  For every operation:
     *    1 byte:  8-bit operation (4-bits operation id and 4-bits flags)
     *    n bytes: opcode data
     * Refer to the function documentation for details on individual operations.
     */
    function execute(bytes calldata program) external nonReentrant {
        (uint256 ptr, uint256 endPtr) = _getPc(program);

        State memory state;
        {
            uint256 hashMapSize;
            (ptr, hashMapSize) = ptr.readUint(2);
            state.tokenDeltas.init(hashMapSize);
        }

        uint256 op;
        while (ptr < endPtr) {
            unchecked {
                (ptr, op) = ptr.readUint(1);

                ptr = _interpretOp(state, ptr, op);
            }
        }

        if (state.tokenDeltas.totalNonZero != 0) revert LeftoverDelta();
    }

    /* -------------------------------------------------------------------------- */
    /*                           Internal write method's                          */
    /* -------------------------------------------------------------------------- */

    function _interpretOp(State memory state, uint256 ptr, uint256 op) internal returns (uint256) {
        uint256 mop = op & Ops.MASK_OP;
        if (mop == Ops.SWAP) {
            ptr = _swap(state, ptr, op);
        } else if (mop == Ops.SEND_ALL) {
            ptr = _sendAll(state, ptr, op);
        } else if (mop == Ops.PULL_ALL) {
            ptr = _pullAll(state, ptr, op);
        } else if (mop == Ops.SEND) {
            ptr = _send(state, ptr);
        } else if (mop == Ops.RECEIVE) {
            ptr = _receive(state, ptr);
        } else if (mop == Ops.RECEIVE_ALL) {
            ptr = _receiveAll(state, ptr, op);
        } else if (mop == Ops.PERMIT_VIA_SIG) {
            ptr = _permitViaSig(state, ptr, op);
        } else if (mop == Ops.ADD_LIQ) {
            ptr = _addLiquidity(state, ptr);
        } else if (mop == Ops.RM_LIQ) {
            ptr = _removeLiquidity(state, ptr);
        } else {
            revert InvalidOp(op);
        }

        return ptr;
    }

    function _swap(State memory state, uint256 ptr, uint256 op) internal returns (uint256) {
        address token;
        uint256 amount;
        (ptr, token) = ptr.readAddress();
        bool zeroForOne = (op & Ops.SWAP_DIR) != 0;
        (ptr, amount) = ptr.readUint(16);

        (int256 delta0, int256 delta1) = _getPool(token).swap(zeroForOne, amount, FEE_BPS);

        state.tokenDeltas.accountChange(baseToken, delta0);
        state.tokenDeltas.accountChange(token, delta1);

        return ptr;
    }

    function _addLiquidity(State memory state, uint256 ptr) internal returns (uint256) {
        address token;
        address to;
        uint256 maxAmount0;
        uint256 maxAmount1;
        (ptr, token) = ptr.readAddress();
        (ptr, to) = ptr.readAddress();
        (ptr, maxAmount0) = ptr.readUint(16);
        (ptr, maxAmount1) = ptr.readUint(16);

        (, int256 delta0, int256 delta1) = _getPool(token).addLiquidity(to, maxAmount0, maxAmount1);

        state.tokenDeltas.accountChange(baseToken, delta0);
        state.tokenDeltas.accountChange(token, delta1);

        return ptr;
    }

    function _removeLiquidity(State memory state, uint256 ptr) internal returns (uint256) {
        address token;
        uint256 liq;
        (ptr, token) = ptr.readAddress();
        (ptr, liq) = ptr.readFullUint();

        (int256 delta0, int256 delta1) = _getPool(token).removeLiquidity(msg.sender, liq);

        state.tokenDeltas.accountChange(baseToken, delta0);
        state.tokenDeltas.accountChange(token, delta1);

        return ptr;
    }

    function _send(State memory state, uint256 ptr) internal returns (uint256) {
        address token;
        address to;
        uint256 amount;

        (ptr, token) = ptr.readAddress();
        (ptr, to) = ptr.readAddress();
        (ptr, amount) = ptr.readUint(16);

        state.tokenDeltas.accountChange(token, amount.toInt256());
        token.safeTransfer(to, amount);
        totalReservesOf[token] -= amount;

        return ptr;
    }

    function _receive(State memory state, uint256 ptr) internal returns (uint256) {
        address token;
        uint256 amount;

        (ptr, token) = ptr.readAddress();
        (ptr, amount) = ptr.readUint(16);

        _receive(state, token, amount);

        return ptr;
    }

    function _sendAll(State memory state, uint256 ptr, uint256 op) internal returns (uint256) {
        address token;
        address to;

        (ptr, token) = ptr.readAddress();
        int256 delta = state.tokenDeltas.resetChange(token);
        if (delta > 0) revert NegativeAmount();

        uint256 minSend = 0;
        uint256 maxSend = type(uint128).max;

        if (op & Ops.ALL_MIN_BOUND != 0) (ptr, minSend) = ptr.readUint(16);
        if (op & Ops.ALL_MAX_BOUND != 0) (ptr, maxSend) = ptr.readUint(16);

        uint256 amount = uint256(-delta);
        if (amount < minSend || amount > maxSend) revert AmountOutsideBounds();

        (ptr, to) = ptr.readAddress();
        totalReservesOf[token] -= amount;
        token.safeTransfer(to, amount);

        return ptr;
    }

    function _receiveAll(State memory state, uint256 ptr, uint256 op) internal returns (uint256) {
        address token;

        (ptr, token) = ptr.readAddress();

        uint256 minReceive = 0;
        uint256 maxReceive = type(uint128).max;

        if (op & Ops.ALL_MIN_BOUND != 0) (ptr, minReceive) = ptr.readUint(16);
        if (op & Ops.ALL_MAX_BOUND != 0) (ptr, maxReceive) = ptr.readUint(16);

        int256 delta = state.tokenDeltas.getChange(token);
        if (delta < 0) revert NegativeReceive();

        uint256 amount = uint256(delta);
        if (amount < minReceive || amount > maxReceive) revert AmountOutsideBounds();

        _receive(state, token, amount);

        return ptr;
    }

    function _pullAll(State memory state, uint256 ptr, uint256 op) internal returns (uint256) {
        address token;

        (ptr, token) = ptr.readAddress();

        uint256 minReceive = 0;
        uint256 maxReceive = type(uint128).max;

        if (op & Ops.ALL_MIN_BOUND != 0) (ptr, minReceive) = ptr.readUint(16);
        if (op & Ops.ALL_MAX_BOUND != 0) (ptr, maxReceive) = ptr.readUint(16);

        int256 delta = state.tokenDeltas.getChange(token);
        if (delta < 0) revert NegativeReceive();

        uint256 amount = uint256(delta);
        if (amount < minReceive || amount > maxReceive) revert AmountOutsideBounds();

        token.safeTransferFrom(msg.sender, address(this), amount);
        _accountReceived(state, token);

        return ptr;
    }

    function _permitViaSig(State memory state, uint256 ptr, uint256 op) internal returns (uint256) {
        address token;
        uint256 amount;
        uint256 deadline;
        uint256 v;
        bytes32 r;
        bytes32 s;

        (ptr, token) = ptr.readAddress();
        (ptr, amount) = ptr.readUint(16);
        (ptr, deadline) = ptr.readUint(6);
        (ptr, v) = ptr.readUint(1);
        (ptr, r) = ptr.readFullBytes();
        (ptr, s) = ptr.readFullBytes();

        // TODO: Ensure valid sig?
        // TODO: Bette way to call permit function?
        // TODO: SOC another contract performing the permit and wrapping operations?
        // TODO: Like a pre swap hook? Or a pre swap execution layer with dedicated commands?
        IERC20Permit(token).permit(msg.sender, address(this), amount, deadline, uint8(v), r, s);

        return ptr;
    }

    function _receive(State memory state, address token, uint256 amount) internal {
        if (IGiver(msg.sender).give(token, amount) != IGiver.give.selector) {
            revert InvalidGive();
        }
        _accountReceived(state, token);
    }

    function _accountReceived(State memory state, address token) internal {
        uint256 reserves = totalReservesOf[token];
        uint256 directBalance = token.balanceOf(address(this));
        uint256 totalReceived = directBalance - reserves;

        state.tokenDeltas.accountChange(token, -totalReceived.toInt256());
        totalReservesOf[token] = directBalance;
    }

    /* -------------------------------------------------------------------------- */
    /*                           External view method's                           */
    /* -------------------------------------------------------------------------- */

    function getPool(address token)
        external
        view
        returns (uint128 reserves0, uint128 reserves1, uint256 totalLiquidity)
    {
        Pool storage pool = _getPool(token);
        reserves0 = pool.reserves0;
        reserves1 = pool.reserves1;
        totalLiquidity = pool.totalLiquidity;
    }

    function getPosition(address token, address owner) external view returns (uint256) {
        return _getPool(token).positions[owner];
    }

    /* -------------------------------------------------------------------------- */
    /*                        Internal pure helper method's                       */
    /* -------------------------------------------------------------------------- */

    function _getPc(bytes calldata program) internal pure returns (uint256 ptr, uint256 endPtr) {
        assembly ("memory-safe") {
            ptr := program.offset
            endPtr := add(ptr, program.length)
        }
    }

    /// @dev Returns the pool for the given 'token'.
    function _getPool(address token) internal pure returns (Pool storage pool) {
        assembly ("memory-safe") {
            mstore(0x00, pools.slot)
            mstore(0x20, token)
            pool.slot := keccak256(0x00, 0x40)
        }
    }
}

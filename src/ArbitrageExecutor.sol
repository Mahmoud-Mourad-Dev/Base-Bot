// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/// @title ArbitrageExecutor
/// @notice Owner-only, inventory-funded executor for atomic Uniswap V2-style routes.
/// @dev The hot `execute()` path consumes raw bytes appended after its 4-byte selector.
///      This deliberately avoids Solidity's dynamic ABI decoder. Amounts and routes are
///      computed off-chain; V2 pairs still enforce their own invariant during `swap`.
contract ArbitrageExecutor {
    // -------------------------------------------------------------------------
    // Storage layout: do not reorder. The owner is slot 0 and configuration is
    // exactly slots 1..7. The executor intentionally has no additional state.
    // -------------------------------------------------------------------------

    address public owner; // slot 0
    bytes32[7] private _configuration; // slots 1..7

    /// @dev Canonical wrapped native token on Base and other OP Stack deployments.
    address public constant WRAPPED_NATIVE = 0x4200000000000000000000000000000000000006;

    uint256 private constant HOP_SIZE = 57;
    uint256 private constant ADDRESS_MASK = type(uint160).max;

    bytes32 private constant ACCESS_DENIED = "access denied";
    bytes32 private constant BLINK_E = "Blink: E";
    bytes32 private constant BLINK_TF = "Blink: TF";
    bytes32 private constant BLINK_IT = "Blink: IT";
    bytes32 private constant SLICE_OVERFLOW = "slice_overflow";
    bytes32 private constant SLICE_OUT_OF_BOUNDS = "slice_outOfBounds";

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ConfigurationUpdated(uint8 indexed slot, bytes32 value);

    modifier onlyOwner() {
        if (msg.sender != owner) _revertString(ACCESS_DENIED, 13);
        _;
    }

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // -------------------------------------------------------------------------
    // Administration
    // -------------------------------------------------------------------------

    /// @notice Writes an opaque configuration word to one of storage slots 1..7.
    /// @dev Addresses should be right-aligned in the bytes32 word. The core route is
    ///      owner-gated, so these slots can represent factories, routers, or bot params.
    function setup(uint8 slot_, bytes32 value_) external onlyOwner {
        if (slot_ == 0 || slot_ > 7) _revertString(BLINK_E, 8);

        assembly ("memory-safe") {
            sstore(slot_, value_)
        }
        emit ConfigurationUpdated(slot_, value_);
    }

    /// @notice Reads one of the seven opaque configuration slots.
    function configuration(uint8 slot_) external view returns (bytes32 value) {
        if (slot_ == 0 || slot_ > 7) _revertString(BLINK_E, 8);

        assembly ("memory-safe") {
            value := sload(slot_)
        }
    }

    /// @notice Transfers control without introducing another storage slot.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) _revertString(BLINK_E, 8);

        address previousOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);
    }

    /// @notice Wraps native currency held by this contract into Base WETH.
    function wrapNative(uint256 amount) external onlyOwner {
        bool success;
        address wrapped = WRAPPED_NATIVE;

        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(224, 0xd0e30db0)) // deposit()
            success := and(gt(extcodesize(wrapped), 0), call(gas(), wrapped, amount, ptr, 4, 0, 0))
        }
        if (!success) _revertString(BLINK_E, 8);
    }

    /// @notice Unwraps Base WETH and forwards the resulting native currency.
    function unwrapNative(uint256 amount, address payable recipient) external onlyOwner {
        if (recipient == address(0)) _revertString(BLINK_E, 8);
        _unwrapTo(amount, recipient);
    }

    /// @notice Recovers an ERC20 using a return-data-tolerant low-level transfer.
    function withdrawToken(address token, address recipient, uint256 amount) external onlyOwner {
        if (token == address(0) || recipient == address(0)) _revertString(BLINK_IT, 9);
        _safeTransfer(token, recipient, amount);
    }

    /// @notice Recovers native currency from the executor.
    function withdrawNative(uint256 amount, address payable recipient) external onlyOwner {
        if (recipient == address(0)) _revertString(BLINK_E, 8);
        _safeNativeTransfer(recipient, amount);
    }

    // -------------------------------------------------------------------------
    // Hot path
    // -------------------------------------------------------------------------

    /// @notice Executes a packed, inventory-funded, multi-pair arbitrage route.
    /// @dev There are intentionally no ABI parameters. The packed payload starts at
    ///      calldata byte 4. See docs/OFFCHAIN_PAYLOAD.md for the byte-level format.
    ///
    ///      Each output is sent directly to the next pair. The final hop returns the
    ///      starting token to this contract. The transaction succeeds only when:
    ///          finalBalance >= startingBalance + minimumProfit.
    function execute() external onlyOwner {
        uint256 cursor = 4;
        uint256 end;
        assembly ("memory-safe") {
            end := calldatasize()
        }

        uint256 version;
        uint256 flags;
        uint256 hopCount;
        uint256 routeBytes;
        uint256 deadline;
        address startToken;
        uint256 amountIn;
        uint256 minimumProfit;

        (version, cursor) = _toUint8(cursor, end);
        (flags, cursor) = _toUint8(cursor, end);
        (hopCount, cursor) = _toUint8(cursor, end);
        (routeBytes, cursor) = _toUint16(cursor, end);
        (deadline, cursor) = _toUint32(cursor, end);
        (startToken, cursor) = _toAddress(cursor, end);
        (amountIn, cursor) = _toUint128(cursor, end);
        (minimumProfit, cursor) = _toUint128(cursor, end);

        // Version 1 defines only flag bit 0: unwrap and pay native profit to owner.
        if (version != 1 || flags > 1 || hopCount == 0) _revertString(BLINK_E, 8);
        if (deadline != 0 && block.timestamp > deadline) _revertString(BLINK_E, 8);
        if (startToken == address(0)) _revertString(BLINK_IT, 9);
        if (amountIn == 0) _revertString(BLINK_E, 8);
        if (routeBytes != hopCount * HOP_SIZE) _revertString(BLINK_E, 8);

        uint256 routeEnd = _sliceEnd(cursor, routeBytes, end);
        if (routeEnd != end) _revertString(BLINK_E, 8);

        uint256 startingBalance = _balanceOf(startToken, address(this));
        if (startingBalance < amountIn) _revertString(BLINK_TF, 9);

        // Seed the first pair once. Subsequent inputs arrive optimistically from the
        // preceding pair, avoiding intermediate transfers through this executor.
        address firstPair;
        (firstPair,) = _toAddress(cursor, end);
        if (firstPair == address(0)) _revertString(BLINK_E, 8);
        _safeTransfer(startToken, firstPair, amountIn);

        address currentToken = startToken;

        for (uint256 i; i < hopCount;) {
            address pair;
            address tokenOut;
            uint256 amountOut;
            uint256 direction;

            (pair, cursor) = _toAddress(cursor, end);
            (tokenOut, cursor) = _toAddress(cursor, end);
            (amountOut, cursor) = _toUint128(cursor, end);
            (direction, cursor) = _toUint8(cursor, end);

            if (pair == address(0) || amountOut == 0 || direction > 1) {
                _revertString(BLINK_E, 8);
            }
            if (tokenOut == address(0)) _revertString(BLINK_IT, 9);

            (address token0, address token1) = _pairTokens(pair);
            uint256 amount0Out;
            uint256 amount1Out;

            if (direction == 0) {
                // Request token0; therefore the input token must be token1.
                if (currentToken != token1 || tokenOut != token0) {
                    _revertString(BLINK_IT, 9);
                }
                amount0Out = amountOut;
            } else {
                // Request token1; therefore the input token must be token0.
                if (currentToken != token0 || tokenOut != token1) {
                    _revertString(BLINK_IT, 9);
                }
                amount1Out = amountOut;
            }

            address recipient;
            if (i + 1 < hopCount) {
                // The next packed field is the next pair address. Peeking avoids a
                // second in-memory route representation.
                (recipient,) = _toAddress(cursor, end);
                if (recipient == address(0)) _revertString(BLINK_E, 8);
            } else {
                recipient = address(this);
            }

            _pairSwap(pair, amount0Out, amount1Out, recipient);
            currentToken = tokenOut;

            unchecked {
                ++i;
            }
        }

        if (currentToken != startToken) _revertString(BLINK_IT, 9);

        uint256 finalBalance = _balanceOf(startToken, address(this));
        uint256 requiredBalance;
        unchecked {
            requiredBalance = startingBalance + minimumProfit;
        }
        if (requiredBalance < startingBalance || finalBalance < requiredBalance) {
            _revertString(BLINK_E, 8);
        }

        // Optional flag: unwrap only the realized profit, preserving WETH principal.
        if (flags == 1) {
            if (startToken != WRAPPED_NATIVE) _revertString(BLINK_IT, 9);
            uint256 realizedProfit = finalBalance - startingBalance;
            if (realizedProfit != 0) _unwrapTo(realizedProfit, payable(owner));
        }
    }

    // -------------------------------------------------------------------------
    // Packed calldata readers. All integer values are big-endian/network order.
    // -------------------------------------------------------------------------

    function _toUint8(uint256 cursor, uint256 end) private pure returns (uint256 value, uint256 next) {
        next = _sliceEnd(cursor, 1, end);
        assembly ("memory-safe") {
            value := byte(0, calldataload(cursor))
        }
    }

    function _toUint16(uint256 cursor, uint256 end) private pure returns (uint256 value, uint256 next) {
        next = _sliceEnd(cursor, 2, end);
        assembly ("memory-safe") {
            value := shr(240, calldataload(cursor))
        }
    }

    function _toUint32(uint256 cursor, uint256 end) private pure returns (uint256 value, uint256 next) {
        next = _sliceEnd(cursor, 4, end);
        assembly ("memory-safe") {
            value := shr(224, calldataload(cursor))
        }
    }

    function _toUint128(uint256 cursor, uint256 end) private pure returns (uint256 value, uint256 next) {
        next = _sliceEnd(cursor, 16, end);
        assembly ("memory-safe") {
            value := shr(128, calldataload(cursor))
        }
    }

    function _toAddress(uint256 cursor, uint256 end) private pure returns (address value, uint256 next) {
        next = _sliceEnd(cursor, 20, end);
        assembly ("memory-safe") {
            value := shr(96, calldataload(cursor))
        }
    }

    function _sliceEnd(uint256 start, uint256 length, uint256 end) private pure returns (uint256 next) {
        unchecked {
            next = start + length;
        }
        if (next < start) _revertString(SLICE_OVERFLOW, 14);
        if (next > end) _revertString(SLICE_OUT_OF_BOUNDS, 17);
    }

    // -------------------------------------------------------------------------
    // Low-level token and pair operations
    // -------------------------------------------------------------------------

    function _balanceOf(address token, address account) private view returns (uint256 result) {
        bool success;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(224, 0x70a08231)) // balanceOf(address)
            mstore(add(ptr, 4), account)
            success := and(gt(extcodesize(token), 0), staticcall(gas(), token, ptr, 36, ptr, 32))
            success := and(success, iszero(lt(returndatasize(), 32)))
            result := mload(ptr)
        }
        if (!success) _revertString(BLINK_TF, 9);
    }

    function _safeTransfer(address token, address recipient, uint256 amount) private {
        bool success;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(224, 0xa9059cbb)) // transfer(address,uint256)
            mstore(add(ptr, 4), recipient)
            mstore(add(ptr, 36), amount)

            let called := and(gt(extcodesize(token), 0), call(gas(), token, 0, ptr, 68, ptr, 32))
            let size := returndatasize()

            // Accept either no return data or exactly ABI-true in the first word.
            success := called
            if size {
                success := and(called, and(iszero(lt(size, 32)), eq(mload(ptr), 1)))
            }
        }
        if (!success) _revertString(BLINK_TF, 9);
    }

    function _pairTokens(address pair) private view returns (address token0, address token1) {
        token0 = _readPairAddress(pair, 0x0dfe1681); // token0()
        token1 = _readPairAddress(pair, 0xd21220a7); // token1()
        if (token0 == address(0) || token1 == address(0) || token0 == token1) {
            _revertString(BLINK_IT, 9);
        }
    }

    function _readPairAddress(address pair, uint256 selector) private view returns (address result) {
        bool success;
        uint256 raw;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(224, selector))
            success := and(gt(extcodesize(pair), 0), staticcall(gas(), pair, ptr, 4, ptr, 32))
            success := and(success, iszero(lt(returndatasize(), 32)))
            raw := mload(ptr)
        }
        if (!success || raw >> 160 != 0) _revertString(BLINK_E, 8);
        result = address(uint160(raw & ADDRESS_MASK));
    }

    function _pairSwap(address pair, uint256 amount0Out, uint256 amount1Out, address recipient) private {
        bool success;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(224, 0x022c0d9f)) // swap(uint256,uint256,address,bytes)
            mstore(add(ptr, 4), amount0Out)
            mstore(add(ptr, 36), amount1Out)
            mstore(add(ptr, 68), recipient)
            mstore(add(ptr, 100), 0x80) // dynamic bytes offset from args start
            mstore(add(ptr, 132), 0) // empty callback data

            success := and(gt(extcodesize(pair), 0), call(gas(), pair, 0, ptr, 164, 0, 0))
        }
        if (!success) _revertString(BLINK_E, 8);
    }

    function _unwrapTo(uint256 amount, address payable recipient) private {
        bool success;
        address wrapped = WRAPPED_NATIVE;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(224, 0x2e1a7d4d)) // withdraw(uint256)
            mstore(add(ptr, 4), amount)
            success := and(gt(extcodesize(wrapped), 0), call(gas(), wrapped, 0, ptr, 36, 0, 0))
        }
        if (!success) _revertString(BLINK_E, 8);
        _safeNativeTransfer(recipient, amount);
    }

    function _safeNativeTransfer(address payable recipient, uint256 amount) private {
        bool success;
        assembly ("memory-safe") {
            success := call(gas(), recipient, amount, 0, 0, 0, 0)
        }
        if (!success) _revertString(BLINK_TF, 9);
    }

    /// @dev Encodes the standard Error(string) payload without Solidity's allocator.
    function _revertString(bytes32 message, uint256 length) private pure {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(224, 0x08c379a0))
            mstore(add(ptr, 4), 0x20)
            mstore(add(ptr, 36), length)
            mstore(add(ptr, 68), message)
            revert(ptr, 100)
        }
    }

    receive() external payable { }

    fallback() external payable { }
}

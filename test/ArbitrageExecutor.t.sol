// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import { ArbitrageExecutor } from "../src/ArbitrageExecutor.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address recipient, uint256 amount) external {
        balanceOf[recipient] += amount;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        uint256 balance = balanceOf[msg.sender];
        require(balance >= amount, "balance");
        unchecked {
            balanceOf[msg.sender] = balance - amount;
            balanceOf[recipient] += amount;
        }
        return true;
    }
}

contract MockV2Pair {
    address public immutable token0;
    address public immutable token1;
    address public lastRecipient;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address recipient, bytes calldata data) external {
        require(data.length == 0, "callback");
        require((amount0Out == 0) != (amount1Out == 0), "output");
        lastRecipient = recipient;

        if (amount0Out != 0) {
            require(MockERC20(token0).transfer(recipient, amount0Out), "token0");
        } else {
            require(MockERC20(token1).transfer(recipient, amount1Out), "token1");
        }
    }
}

contract ExternalCaller {
    function forward(address target, bytes calldata data) external returns (bool, bytes memory) {
        return target.call(data);
    }
}

contract ArbitrageExecutorTest {
    uint256 private constant UNIT = 1 ether;

    ArbitrageExecutor private executor;
    MockERC20 private tokenA;
    MockERC20 private tokenB;
    MockV2Pair private firstPair;
    MockV2Pair private secondPair;

    function setUp() public {
        executor = new ArbitrageExecutor();
        tokenA = new MockERC20();
        tokenB = new MockERC20();

        // Both pairs expose token0=B and token1=A. Route directions are therefore
        // 0 for A->B, followed by 1 for B->A.
        firstPair = new MockV2Pair(address(tokenB), address(tokenA));
        secondPair = new MockV2Pair(address(tokenB), address(tokenA));

        tokenA.mint(address(executor), 100 * UNIT);
        tokenB.mint(address(firstPair), 20 * UNIT);
        tokenA.mint(address(secondPair), 11 * UNIT);
    }

    function testPackedRouteUsesOptimisticRecipientAndRealizesProfit() public {
        bytes memory payload = _payload(uint128(1 * UNIT), uint128(11 * UNIT), address(tokenB));
        (bool success, bytes memory returnData) =
            address(executor).call(abi.encodePacked(ArbitrageExecutor.execute.selector, payload));

        require(success, _asString(returnData));
        require(firstPair.lastRecipient() == address(secondPair), "not routed directly");
        require(secondPair.lastRecipient() == address(executor), "final recipient");
        require(tokenA.balanceOf(address(executor)) == 101 * UNIT, "profit mismatch");
        require(tokenA.balanceOf(address(firstPair)) == 10 * UNIT, "first input mismatch");
        require(tokenB.balanceOf(address(secondPair)) == 20 * UNIT, "second input mismatch");
    }

    function testRevertsWhenMinimumProfitIsNotMet() public {
        bytes memory payload = _payload(uint128(2 * UNIT), uint128(11 * UNIT), address(tokenB));
        (bool success, bytes memory returnData) =
            address(executor).call(abi.encodePacked(ArbitrageExecutor.execute.selector, payload));

        require(!success, "expected revert");
        require(keccak256(returnData) == keccak256(_error("Blink: E")), "wrong profit error");
        require(tokenA.balanceOf(address(executor)) == 100 * UNIT, "route was not atomic");
    }

    function testRevertsOnInvalidTokenChain() public {
        bytes memory payload = _payload(uint128(1 * UNIT), uint128(11 * UNIT), address(tokenA));
        (bool success, bytes memory returnData) =
            address(executor).call(abi.encodePacked(ArbitrageExecutor.execute.selector, payload));

        require(!success, "expected revert");
        require(keccak256(returnData) == keccak256(_error("Blink: IT")), "wrong token error");
    }

    function testRejectsUnauthorizedCallerBeforeParsing() public {
        ExternalCaller caller = new ExternalCaller();
        (bool success, bytes memory returnData) =
            caller.forward(address(executor), abi.encodePacked(ArbitrageExecutor.execute.selector));

        require(!success, "expected access revert");
        require(keccak256(returnData) == keccak256(_error("access denied")), "wrong access error");
    }

    function testReportsPackedSliceOutOfBounds() public {
        (bool success, bytes memory returnData) =
            address(executor).call(abi.encodePacked(ArbitrageExecutor.execute.selector));

        require(!success, "expected bounds revert");
        require(keccak256(returnData) == keccak256(_error("slice_outOfBounds")), "wrong bounds error");
    }

    function testConfigurationUsesExplicitSlots() public {
        bytes32 value = bytes32(uint256(uint160(address(firstPair))));
        executor.setup(3, value);
        require(executor.configuration(3) == value, "configuration mismatch");
    }

    function _payload(uint128 minimumProfit, uint128 finalAmountOut, address firstTokenOut)
        private
        view
        returns (bytes memory)
    {
        return abi.encodePacked(
            uint8(1),
            uint8(0),
            uint8(2),
            uint16(114),
            uint32(block.timestamp + 1 hours),
            address(tokenA),
            uint128(10 * UNIT),
            minimumProfit,
            address(firstPair),
            firstTokenOut,
            uint128(20 * UNIT),
            uint8(0),
            address(secondPair),
            address(tokenA),
            finalAmountOut,
            uint8(1)
        );
    }

    function _error(string memory message) private pure returns (bytes memory) {
        return abi.encodeWithSignature("Error(string)", message);
    }

    function _asString(bytes memory data) private pure returns (string memory) {
        return string(data);
    }
}

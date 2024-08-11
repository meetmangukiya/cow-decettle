pragma solidity ^0.8;

import {LibSignedSettlement, GPv2Trade, GPv2Interaction, IERC20} from "src/LibSignedSettlement.sol";
import {Test} from "forge-std/Test.sol";

library LibSignedSettlementProxy {
    function hashSettleData(
        IERC20[] memory tokens,
        uint256[] memory clearingPrices,
        GPv2Trade.Data[] calldata trades,
        GPv2Interaction.Data[] calldata preInteractions
    ) external pure returns (bytes32) {
        return LibSignedSettlement.hashSettleData(tokens, clearingPrices, trades, preInteractions);
    }

    function hashTrades(GPv2Trade.Data[] calldata trades, uint256 hashingRegionStart) external pure returns (bytes32) {
        return LibSignedSettlement.hashTrades(trades, hashingRegionStart);
    }

    function hashInteractions(GPv2Interaction.Data[] calldata interactions, uint256 hashingRegionStart)
        external
        pure
        returns (bytes32)
    {
        return LibSignedSettlement.hashInteractions(interactions, hashingRegionStart);
    }

    function readDeadlineAndSignature(
        address[] calldata tokens,
        uint256[] calldata clearingPrices,
        GPv2Trade.Data[] calldata trades,
        GPv2Interaction.Data[][3] calldata interactions
    ) external pure returns (uint256 deadline, uint256 r, uint256 s, uint256 v, uint256 lastByte) {
        (deadline, r, s, v, lastByte) =
            LibSignedSettlement.readDeadlineAndSignature(tokens, clearingPrices, trades, interactions);
    }
}

contract LibSignedSettlementTest is Test {
    // testing the final output of hashSettleData implies the hashInteractions and hashTrades
    // functions are correct too.
    // it is difficult to test them because of the hashing memory region and the library requiring
    // calldata parameters. we cannot allocate memory in the proxy.
    function testHashSettleData() external {
        IERC20[] memory tokens = new IERC20[](3);
        tokens[0] = IERC20(makeAddr("token1"));
        tokens[1] = IERC20(makeAddr("token2"));
        tokens[2] = IERC20(makeAddr("token3"));

        uint256[] memory clearingPrices = new uint256[](3);
        clearingPrices[0] = 10 ether;
        clearingPrices[1] = 5 ether;
        clearingPrices[2] = 5e6;

        bytes32 appData = keccak256("appData");

        GPv2Trade.Data[] memory trades = new GPv2Trade.Data[](3);

        trades[0] = GPv2Trade.Data({
            sellTokenIndex: 0,
            buyTokenIndex: 1,
            receiver: makeAddr("user1"),
            sellAmount: 1 ether,
            buyAmount: 0.5 ether,
            validTo: uint32(123456),
            appData: appData,
            feeAmount: 0,
            flags: 0x11,
            executedAmount: 1 ether,
            signature: hex"000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000555555555555555555555555555555555555555555555555550"
        });
        trades[1] = GPv2Trade.Data({
            sellTokenIndex: 0,
            buyTokenIndex: 2,
            receiver: makeAddr("user2"),
            sellAmount: 10 ether,
            buyAmount: 0.3 ether,
            validTo: uint32(78901234),
            appData: appData,
            feeAmount: 0,
            flags: 0x11,
            executedAmount: 1.5 ether,
            signature: hex"0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001010101010101010101010101010101010101010101010101010101010101010100000"
        });
        trades[2] = GPv2Trade.Data({
            sellTokenIndex: 2,
            buyTokenIndex: 1,
            receiver: makeAddr("user3"),
            sellAmount: 0.1 ether,
            buyAmount: 0.5 ether,
            validTo: uint32(567890),
            appData: appData,
            feeAmount: 0,
            flags: 0x11,
            executedAmount: 1.2 ether,
            signature: hex"0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323232323230000000000"
        });

        GPv2Interaction.Data[] memory interactions = new GPv2Interaction.Data[](2);
        interactions[0] = GPv2Interaction.Data({
            target: makeAddr("target1"),
            value: 0.1 ether,
            callData: hex"3434343434343434343434355555555555555555555555555555555554"
        });
        interactions[1] = GPv2Interaction.Data({
            target: makeAddr("target2"),
            value: 12 ether,
            callData: hex"666666666666666666666666666666666666666666666666663434343434343434343434355555555555555555555555555555555554"
        });
        bytes32 settleDataHash = LibSignedSettlementProxy.hashSettleData(tokens, clearingPrices, trades, interactions);
        assertEq(
            settleDataHash,
            0x6983ed0bbaae9f0b4a129ed5bebe89f329b3ec0d76076bff630c3fd8f52b7540,
            "settle data hash not as expected"
        );
    }

    function testReadDeadlineAndSignature(
        address[] calldata tokens,
        uint256[] calldata prices,
        GPv2Trade.Data[] calldata trades,
        GPv2Interaction.Data[][3] calldata interactions,
        uint256 deadline,
        uint256 r,
        uint256 s,
        uint8 v
    ) external {
        bytes memory cd = abi.encodeWithSelector(
            LibSignedSettlementProxy.readDeadlineAndSignature.selector, tokens, prices, trades, interactions
        );
        bytes memory cdWithParams = abi.encodePacked(cd, deadline, r, s, v);
        (bool success, bytes memory data) = address(LibSignedSettlementProxy).call(cdWithParams);
        require(success, "readDeadlineAndSignature call failed");
        (uint256 readDeadline, uint256 readR, uint256 readS, uint256 readV) =
            abi.decode(data, (uint256, uint256, uint256, uint256));
        assertEq(readDeadline, deadline, "read deadline not as expected");
        assertEq(readR, r, "read r not as expected");
        assertEq(readS, s, "read s not as expected");
        assertEq(readV, v, "read v not as expected");
    }
}

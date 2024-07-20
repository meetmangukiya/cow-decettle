pragma solidity 0.8.26;

import {GPv2Trade, IERC20} from "cowprotocol/libraries/GPv2Trade.sol";
import {GPv2Interaction} from "cowprotocol/libraries/GPv2Interaction.sol";

library LibSignedSettlement {
    bytes32 internal constant TRADE_DATA_TYPE_HASH = keccak256(
        "GPv2TradeData(uint256 sellTokenIndex,uint256 buyTokenIndex,address receiver,uint256 sellAmount,uint256 buyAmount,uint32 validTo,bytes32 appData,uint256 feeAmount,uint256 flags,uint256 executedAmount,bytes signature)"
    );
    bytes32 internal constant INTERACTION_DATA_TYPE_HASH =
        keccak256("GPv2InteractionData(address target,uint256 value,bytes callData)");
    bytes32 internal constant SETTLE_DATA_TYPE_HASH = keccak256(
        "SettleData(address[] tokens,uint256[] clearingPrices,GPv2TradeData[] trades,GPv2InteractionData[] preInteractions)GPv2InteractionData(address target,uint256 value,bytes callData)GPv2TradeData(uint256 sellTokenIndex,uint256 buyTokenIndex,address receiver,uint256 sellAmount,uint256 buyAmount,uint32 validTo,bytes32 appData,uint256 feeAmount,uint256 flags,uint256 executedAmount,bytes signature)"
    );

    function hashSettleData(
        IERC20[] memory tokens,
        uint256[] memory clearingPrices,
        GPv2Trade.Data[] calldata trades,
        GPv2Interaction.Data[] calldata preInteractions
    ) internal pure returns (bytes32 settleDataHash) {
        bytes32 tokensHash;
        bytes32 clearingPricesHash;

        uint256 hashingRegionStart = allocateHashingRegion(trades, preInteractions);
        bytes32 tradesHash = hashTrades(trades, hashingRegionStart);
        bytes32 interactionsHash = hashInteractions(preInteractions, hashingRegionStart);
        bytes32 settleDataTypeHash = SETTLE_DATA_TYPE_HASH;

        assembly ("memory-safe") {
            let len := mul(mload(tokens), 0x20)
            tokensHash := keccak256(add(tokens, 0x20), len)
            clearingPricesHash := keccak256(add(clearingPrices, 0x20), len)

            mstore(hashingRegionStart, settleDataTypeHash)
            mstore(add(hashingRegionStart, 0x20), tokensHash)
            mstore(add(hashingRegionStart, 0x40), clearingPricesHash)
            mstore(add(hashingRegionStart, 0x60), tradesHash)
            mstore(add(hashingRegionStart, 0x80), interactionsHash)

            settleDataHash := keccak256(hashingRegionStart, 0xa0)
        }
    }

    function hashTrades(GPv2Trade.Data[] calldata trades, uint256 hashingRegionStart) internal pure returns (bytes32) {
        bytes32 tradeTypehash = TRADE_DATA_TYPE_HASH;
        uint256 tradesHashArrayOffset = hashingRegionStart + (12 * 32);
        uint256 tradesHashArrayItemOffset = tradesHashArrayOffset;
        uint256 tradesLength = trades.length;

        for (uint256 i = 0; i < tradesLength;) {
            GPv2Trade.Data calldata trade = trades[i];
            bytes calldata signature = trade.signature;
            assembly ("memory-safe") {
                // copy the order signature to the end of memory, this is safe because
                // there are no memory allocations in this block before the copied memory gets used
                // for hashing
                let freeMemoryPtr := mload(0x40)
                let signatureLength := signature.length
                calldatacopy(freeMemoryPtr, signature.offset, signatureLength)
                let signatureHash := keccak256(freeMemoryPtr, signatureLength)

                // hash the trade
                mstore(hashingRegionStart, tradeTypehash)
                // copy the first 10 words, which are all the fields in the struct except the signature
                calldatacopy(add(hashingRegionStart, 0x20), trade, 320)
                // copy the signature hash
                mstore(add(hashingRegionStart, 0x160), signatureHash)
                let tradeHash := keccak256(hashingRegionStart, 0x180)

                // store the trade hash in array to rehash at the end of loop
                mstore(tradesHashArrayItemOffset, tradeHash)
                tradesHashArrayItemOffset := add(tradesHashArrayItemOffset, 0x20)
                i := add(i, 1)
            }
        }

        bytes32 tradesHash;
        assembly ("memory-safe") {
            tradesHash := keccak256(tradesHashArrayOffset, mul(tradesLength, 0x20))
        }

        return tradesHash;
    }

    function hashInteractions(GPv2Interaction.Data[] calldata interactions, uint256 hashingRegionStart)
        internal
        pure
        returns (bytes32)
    {
        bytes32 interactionTypeHash = INTERACTION_DATA_TYPE_HASH;
        uint256 interactionsLength = interactions.length;

        uint256 interactionsHashArrayOffset = hashingRegionStart + (12 * 32);
        uint256 interactionsHashArrayItemOffset = interactionsHashArrayOffset;

        for (uint256 i = 0; i < interactionsLength;) {
            GPv2Interaction.Data calldata interactionData = interactions[i];
            bytes calldata callData = interactionData.callData;
            assembly ("memory-safe") {
                let freeMemoryPtr := mload(0x40)
                let callDataLength := callData.length
                // copy the order signature to the end of memory, this is safe because
                // there are no memory allocations in this block before the copied memory gets used
                // for hashing
                calldatacopy(freeMemoryPtr, callData.offset, callDataLength)
                let callDataHash := keccak256(freeMemoryPtr, callDataLength)

                mstore(hashingRegionStart, interactionTypeHash)
                mstore(add(hashingRegionStart, 0x20), calldataload(interactionData))
                mstore(add(hashingRegionStart, 0x40), calldataload(add(interactionData, 0x20)))
                mstore(add(hashingRegionStart, 0x60), callDataHash)

                let interactionHash := keccak256(hashingRegionStart, 0x80)

                // store the interaction hash in array to rehash at the end of loop
                mstore(interactionsHashArrayItemOffset, interactionHash)
                interactionsHashArrayItemOffset := add(interactionsHashArrayItemOffset, 0x20)
                i := add(i, 1)
            }
        }

        bytes32 interactionsHash;
        assembly ("memory-safe") {
            interactionsHash := keccak256(interactionsHashArrayOffset, mul(interactionsLength, 0x20))
        }
        return interactionsHash;
    }

    function allocateHashingRegion(GPv2Trade.Data[] calldata trades, GPv2Interaction.Data[] calldata preInteractions)
        internal
        pure
        returns (uint256)
    {
        uint256 hashingRegionStart;
        // limit scope because all of these vars are never used again
        {
            uint256 tradesLength = trades.length;
            uint256 preInteractionsLength = preInteractions.length;
            uint256 tradeFieldsLength = 11 + 1; // 11 fields, 1 typehash field
            uint256 hashingRegionLength =
                tradeFieldsLength + (tradesLength > preInteractionsLength ? tradesLength : preInteractionsLength);
            // first 12 bytes are reserved for hashing single trade data and interaction data
            // remainder of the region is used for hashing the array
            bytes32[] memory hashingRegion = new bytes32[](hashingRegionLength);

            assembly ("memory-safe") {
                hashingRegionStart := add(hashingRegion, 0x20)
            }
        }
        return hashingRegionStart;
    }
}
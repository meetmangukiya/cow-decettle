pragma solidity 0.8.26;

import {GPv2Trade, IERC20} from "cowprotocol/libraries/GPv2Trade.sol";
import {GPv2Interaction} from "cowprotocol/libraries/GPv2Interaction.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";

library LibSignedSettlement {
    error LibSignedSettlement__InvalidExtraParamsFullySigned();
    error LibSignedSettlement__InvalidExtraParamsPartiallySigned();

    /// @dev Return calldata byte slice of last n bytes
    function readLastNBytes(uint256 n) internal pure returns (bytes calldata data) {
        uint256 offset = msg.data.length - n;
        assembly ("memory-safe") {
            data.offset := offset
            data.length := n
        }
    }

    /// @dev Deadline and signature is encoded at the end of the calldata. It is not just used directly
    ///      as a parameter to the function because that'd lead to the deadline getting
    ///      encoded inplace and messing up all the offets which'd mean we cannot directly
    ///      copy the calldata as-is for the call to the actual settlement contract.
    ///
    ///      Encoding for the appended data is expected to be `abi.encodePacked(deadline, r, s, v)`.
    ///      `v` is assumed to be uint8, while all others will encode to 32 byte words.
    function readExtraParamsFullySigned()
        internal
        pure
        returns (uint256 deadline, uint256 r, uint256 s, uint256 v, uint256 lastByte)
    {
        {
            bytes calldata extraBytes = readLastNBytes(97);
            assembly ("memory-safe") {
                deadline := calldataload(extraBytes.offset)
                r := calldataload(add(extraBytes.offset, 0x20))
                s := calldataload(add(extraBytes.offset, 0x40))
                v := and(calldataload(add(extraBytes.offset, 0x41)), 0xff)
                lastByte := extraBytes.offset
            }
        }
    }

    /// @dev Deadline, signature and offsets are encoded at the end of the calldata. It is not just used directly
    ///      as a parameter to the function because that'd lead to the deadline getting
    ///      encoded inplace and messing up all the offets which'd mean we cannot directly
    ///      copy the calldata as-is for the call to the actual settlement contract.
    ///
    ///      Encoding for the appended data is expected to be `abi.encodePacked(deadline, r, s, v, offsets)`.
    ///      `v` is assumed to be uint8, while all others will encode to full 32 byte word.
    ///      `offsets` is assumed to be `uint[3]`. `offsets` gives the number of interactions that were signed.
    function readExtraParamsPartiallySigned(GPv2Interaction.Data[][3] calldata interactions)
        internal
        pure
        returns (uint256 deadline, uint256 r, uint256 s, uint256 v, uint256[3] calldata offsets, uint256 lastByte)
    {
        {
            bytes calldata extraBytes = readLastNBytes(193);

            assembly ("memory-safe") {
                deadline := calldataload(extraBytes.offset)
                r := calldataload(add(extraBytes.offset, 0x20))
                s := calldataload(add(extraBytes.offset, 0x40))
                v := and(calldataload(add(extraBytes.offset, 0x41)), 0xff)
                offsets := add(extraBytes.offset, 0x61)
                lastByte := extraBytes.offset
            }

            // validate that the subset size is <= interactions length
            if (
                offsets[0] > interactions[0].length || offsets[1] > interactions[1].length
                    || offsets[2] > interactions[2].length
            ) {
                revert LibSignedSettlement__InvalidExtraParamsPartiallySigned();
            }
        }
    }

    /// @dev Reads params appended at the end, computes the digest for the fully signed message
    ///      and returns the memory slice where the calldata is encoded for the `GPv2Settlement.settle`
    ///      call.
    ///
    ///      The digest is assumed to be keccak256 hash of the following encoded data:
    ///      `abi.encodePacked(abi.encode(tokens, clearingPrices, trades, interactions), abi.encode(deadline, solver))`
    function getParamsDigestAndCalldataFullySigned()
        internal
        view
        returns (
            uint256 deadline,
            uint256 r,
            uint256 s,
            uint256 v,
            bytes32 digest,
            uint256 calldataStart,
            uint256 calldataSize
        )
    {
        {
            uint256 lastByte;
            (deadline, r, s, v, lastByte) = readExtraParamsFullySigned();

            assembly ("memory-safe") {
                let freePtr := mload(0x40)
                // Allocating one extra word to later write the function selector for the call
                let dataStart := add(freePtr, 0x20)
                // We want to copy the calldata 1-to-1 since the data is compatible
                // with a call to CoW Protocol's `settle`.
                // The only exception is the call selector, which here we ignore
                // lastByte - 4(method id) + 32(deadline)
                let nBytesToCopy := add(lastByte, 0x1c)
                // copy all the params including the extra param `deadline` appended to the calldata
                calldatacopy(dataStart, 0x04, nBytesToCopy)
                // store the solver after deadline
                mstore(add(dataStart, nBytesToCopy), caller())
                // hash the message abi.encode(tokens, clearingPrices, trades, interactions) | deadline | solver
                digest := keccak256(dataStart, add(nBytesToCopy, 0x20))
                // update the freePtr, 0x20 for the extra word for fn selector
                mstore(0x40, add(freePtr, add(nBytesToCopy, 0x20)))
                // store the GPv2Interaction.settle method selector
                mstore(freePtr, 0x13d79a0b)

                calldataStart := add(freePtr, 0x1c)
                calldataSize := lastByte
            }
        }
    }

    /// @dev Reads params appended at the end, computes the digest for the partially signed message
    ///      and returns the memory slice where the calldata is encoded for the `GPv2Settlement.settle`
    ///      call.
    ///
    ///      The digest is assumed to be keccak256 hash of the following encoded data:
    ///      `abi.encodePacked(abi.encode(tokens, clearingPrices, trades, partialInteractions), abi.encode(deadline, solver))`
    function getParamsDigestAndCalldataPartiallySigned(GPv2Interaction.Data[][3] calldata interactions)
        internal
        view
        returns (
            uint256 deadline,
            uint256 r,
            uint256 s,
            uint256 v,
            bytes32 digest,
            uint256 calldataStart,
            uint256 calldataSize
        )
    {
        {
            uint256 lastByte;
            uint256[3] calldata offsets;
            (deadline, r, s, v, offsets, lastByte) = readExtraParamsPartiallySigned(interactions);

            // the memory range to be copied for pre/intra/post interaction arrays' subset
            // starting at `dataSlices`
            // +--------------------+--------------------------------------------------------------------------------------+
            // |  dataSlices        | first pre interaction's offset in memory. this is where we start copying data from   |
            // |  dataSlices + 0x20 | number of bytes to copy to get the pre-interactions subset                           |
            // |  dataSlices + 0x40 | first intra interaction's offset in memory. this is where we start copying data from |
            // |  dataSlices + 0x60 | number of bytes to copy to get the intra-interactions subset                         |
            // |  dataSlices + 0x80 | first post interaction's offset in memory. this is where we start copying data from  |
            // |  dataSlices + 0xa0 | number of bytes to copy to get the post-interactions subset                          |
            // +--------------------+--------------------------------------------------------------------------------------+
            uint256 dataSlices;
            assembly ("memory-safe") {
                dataSlices := mload(0x40)
                mstore(0x40, add(dataSlices, 0xc0))
            }

            // compute the memory ranges to copy to get the subset of interactions
            storeSubsetOffets(interactions[0], dataSlices, offsets[0]);
            storeSubsetOffets(interactions[1], dataSlices + 0x40, offsets[1]);
            storeSubsetOffets(interactions[2], dataSlices + 0x80, offsets[2]);

            assembly ("memory-safe") {
                let freePtr := mload(0x40)
                // store the GPv2Settlement.settle data selector. setting at the bottom leads to stack too deep.
                mstore(freePtr, 0x13d79a0b)

                let dataStart := add(freePtr, 0x20)

                let nBytesToCopy := sub(interactions, 0x04)
                // copy all the settlement data excluding selector and interactions
                calldatacopy(dataStart, 0x04, nBytesToCopy)

                let interactionsStart := add(dataStart, nBytesToCopy)
                {
                    // keeps track of last byte written
                    let lastWrittenByte := interactionsStart

                    /// @dev copy offsets[i] number of interactions into memory and adjust the interaction array length
                    ///      and offsets in-place to get an ABI-compliant result of partially encoded settle call params.
                    function copyInteractionsSubset(
                        relativeOffset, offsets_, interactionsStart_, lastWrittenByte_, interactions_, dataSlices_
                    ) -> newLastWrittenByte {
                        let nSubset := calldataload(add(offsets_, relativeOffset))
                        let iOffset := sub(lastWrittenByte_, interactionsStart_)

                        // store the interaction offset
                        mstore(add(interactionsStart_, relativeOffset), iOffset)

                        // store pre interaction subset length
                        mstore(lastWrittenByte_, nSubset)
                        lastWrittenByte_ := add(lastWrittenByte_, 0x20)

                        // copy the interaction offsets
                        let nInteractions :=
                            calldataload(add(interactions_, calldataload(add(interactions_, relativeOffset))))
                        let firstInteractionOffset :=
                            add(add(interactions_, calldataload(add(interactions_, relativeOffset))), 0x20)
                        let offsetsCutShort := mul(sub(nInteractions, nSubset), 0x20)
                        for { let i := 0 } lt(i, nSubset) { i := add(i, 1) } {
                            mstore(
                                lastWrittenByte_,
                                sub(calldataload(add(firstInteractionOffset, mul(i, 0x20))), offsetsCutShort)
                            )
                            lastWrittenByte_ := add(lastWrittenByte_, 0x20)
                        }

                        // copy the interactions subset
                        let interactionBytesStart := mload(add(dataSlices_, mul(relativeOffset, 2)))
                        let nInteractionBytes := mload(add(add(dataSlices_, mul(relativeOffset, 2)), 0x20))
                        mstore(0x00, interactionBytesStart)
                        mstore(0x20, nInteractionBytes)
                        calldatacopy(lastWrittenByte_, interactionBytesStart, nInteractionBytes)
                        lastWrittenByte_ := add(lastWrittenByte_, nInteractionBytes)
                        newLastWrittenByte := lastWrittenByte_
                    }

                    // copy the interaction subsets

                    // We reserve the first three bytes for storing the offsets.
                    // Actual writing takes place in `copyInteractionsSubset`.
                    lastWrittenByte := add(lastWrittenByte, 0x60)
                    lastWrittenByte :=
                        copyInteractionsSubset(0x00, offsets, interactionsStart, lastWrittenByte, interactions, dataSlices)
                    lastWrittenByte :=
                        copyInteractionsSubset(0x20, offsets, interactionsStart, lastWrittenByte, interactions, dataSlices)
                    lastWrittenByte :=
                        copyInteractionsSubset(0x40, offsets, interactionsStart, lastWrittenByte, interactions, dataSlices)

                    // store the deadline
                    mstore(lastWrittenByte, deadline)
                    lastWrittenByte := add(lastWrittenByte, 0x20)
                    // store the solver
                    mstore(lastWrittenByte, caller())
                    lastWrittenByte := add(lastWrittenByte, 0x20)
                    let nBytesToHash := sub(lastWrittenByte, dataStart)
                    // compute the digest
                    digest := keccak256(dataStart, nBytesToHash)
                }

                // overwrite the interactions with original data to get the full calldata for the settle call
                calldatacopy(interactionsStart, interactions, sub(lastByte, interactions))
                calldataSize := lastByte
                calldataStart := sub(dataStart, 0x04)

                // update the free memory ptr
                mstore(0x40, add(dataStart, sub(lastByte, 0x04)))
            }
        }
    }

    /// @dev stores the memory offsets and size at memory slots `memoryOffset` and `memoryOffset + 20`
    function storeSubsetOffets(GPv2Interaction.Data[] calldata interactions, uint256 memoryOffset, uint256 subsetLen)
        internal
        pure
    {
        {
            uint256 len = interactions.length;
            if (len == 0 || subsetLen == 0) {
                assembly ("memory-safe") {
                    mstore(memoryOffset, 0)
                    mstore(add(memoryOffset, 0x20), 0)
                }
            } else {
                GPv2Interaction.Data calldata firstPreInteraction = interactions[0];
                GPv2Interaction.Data calldata lastPreInteraction = interactions[subsetLen - 1];
                uint256 lastByte = getLastByteInteraction(lastPreInteraction);
                assembly ("memory-safe") {
                    mstore(memoryOffset, firstPreInteraction)
                    mstore(add(memoryOffset, 0x20), sub(lastByte, firstPreInteraction))
                }
            }
        }
    }

    /// @dev gets the last byte of given interaction in calldata
    function getLastByteInteraction(GPv2Interaction.Data calldata interaction)
        internal
        pure
        returns (uint256 lastByte)
    {
        uint256 offset;
        assembly ("memory-safe") {
            offset := interaction
        }
        uint256 cdLen = interaction.callData.length;
        uint256 cdWords = (cdLen + 31) / 32;
        lastByte = offset
            + (
                1 // target
                    + 1 // value
                    + 1 // callData offset
                    + 1 // callData length
                        // n words for callData
                    + cdWords
            ) * 32;
    }
}

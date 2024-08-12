pragma solidity 0.8.26;

import {GPv2Trade, IERC20} from "cowprotocol/libraries/GPv2Trade.sol";
import {GPv2Interaction} from "cowprotocol/libraries/GPv2Interaction.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";

library LibSignedSettlement {
    error LibSignedSettlement__InvalidDeadline();
    error LibSignedSettlement__InvalidExtraParamsFullySigned();
    error LibSignedSettlement__InvalidExtraParamsPartiallySigned();

    function readExtraBytes(
        address[] calldata,
        uint256[] calldata,
        GPv2Trade.Data[] calldata,
        GPv2Interaction.Data[][3] calldata interactions
    ) internal pure returns (bytes calldata remainderBytes, uint256 lastByte) {
        {
            uint256 lenPostInteractions = interactions[2].length;
            if (lenPostInteractions > 0) {
                GPv2Interaction.Data calldata lastInteraction = interactions[2][lenPostInteractions - 1];
                uint256 offset;
                assembly ("memory-safe") {
                    offset := lastInteraction
                }
                uint256 cdlen = lastInteraction.callData.length;
                uint256 cdWords = (cdlen % 32 == 0 ? cdlen / 32 : (cdlen / 32) + 1);
                lastByte = offset
                    + (
                        1 // target
                            + 1 // value
                            + 1 // callData offset
                            + 1 // callData length
                                // n words for callData
                            + cdWords
                    ) * 32;
            } else {
                GPv2Interaction.Data[] calldata postInteractions = interactions[2];
                assembly ("memory-safe") {
                    lastByte := postInteractions.offset
                }
            }

            assembly ("memory-safe") {
                remainderBytes.offset := lastByte
                remainderBytes.length := sub(calldatasize(), lastByte)
            }
        }
    }

    /// @dev Deadline and signature is encoded at the end of the calldata. It is not just used directly
    ///      as a parameter to the function because that'd lead to the deadline getting
    ///      encoded inplace and messing up all the offets which'd mean we cannot directly
    ///      copy the calldata as-is for the call to the actual settlement contract.
    ///
    ///      Instead of reading the last 32 bytes directly with `calldataload(sub(calldatasize(), 32))`
    ///      we determine the expected byteoffset to read based on the last post interaction. Acts as a
    ///      a validation that a deadline was infact encoded at the end of calldata and not accidentally
    ///      reading a word from the last interaction's encoded data.
    function readExtraParamsFullySigned(
        address[] calldata tokens,
        uint256[] calldata clearingPrices,
        GPv2Trade.Data[] calldata trades,
        GPv2Interaction.Data[][3] calldata interactions
    ) internal pure returns (uint256 deadline, uint256 r, uint256 s, uint256 v, uint256 lastByte) {
        {
            bytes calldata extraBytes;
            (extraBytes, lastByte) = readExtraBytes(tokens, clearingPrices, trades, interactions);

            if (lastByte != msg.data.length - 97) {
                revert LibSignedSettlement__InvalidExtraParamsFullySigned();
            }

            assembly ("memory-safe") {
                deadline := calldataload(lastByte)
                r := calldataload(add(lastByte, 32))
                s := calldataload(add(lastByte, 64))
                v := and(calldataload(add(lastByte, 65)), 0xff)
            }
        }
    }

    error A(uint256, uint256);

    function readExtraParamsPartiallySigned(
        address[] calldata tokens,
        uint256[] calldata clearingPrices,
        GPv2Trade.Data[] calldata trades,
        GPv2Interaction.Data[][3] calldata interactions
    )
        internal
        pure
        returns (uint256 deadline, uint256 r, uint256 s, uint256 v, uint256[3] calldata offsets, uint256 lastByte)
    {
        {
            bytes calldata extraBytes;
            (extraBytes, lastByte) = readExtraBytes(tokens, clearingPrices, trades, interactions);

            if (lastByte != msg.data.length - 193) {
                revert A(lastByte, msg.data.length - 193);
                revert LibSignedSettlement__InvalidExtraParamsPartiallySigned();
            }

            assembly ("memory-safe") {
                deadline := calldataload(lastByte)
                r := calldataload(add(lastByte, 0x20))
                s := calldataload(add(lastByte, 0x40))
                v := and(calldataload(add(lastByte, 0x41)), 0xff)
                offsets := add(lastByte, 0x61)
            }

            if (
                offsets[0] > interactions[0].length || offsets[1] > interactions[1].length
                    || offsets[2] > interactions[2].length
            ) {
                revert LibSignedSettlement__InvalidExtraParamsPartiallySigned();
            }
        }
    }

    function getParamsDigestAndCalldataFullySigned(
        address[] calldata tokens,
        uint256[] calldata clearingPrices,
        GPv2Trade.Data[] calldata trades,
        GPv2Interaction.Data[][3] calldata interactions
    )
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
            (deadline, r, s, v, lastByte) = readExtraParamsFullySigned(tokens, clearingPrices, trades, interactions);

            assembly ("memory-safe") {
                let freePtr := mload(0x40)
                let dataStart := add(freePtr, 0x20)
                // lastByte - 4(method id) + 32(deadline)
                let nBytesToCopy := add(lastByte, 0x1c)
                // copy all the params including the extra param `deadline` appended to the calldata
                calldatacopy(dataStart, 0x04, nBytesToCopy)
                // store the solver after deadline
                mstore(add(dataStart, nBytesToCopy), caller())
                // hash the message abi.encode(tokens, clearingPrices, trades, interactions) | deadline | solver
                digest := keccak256(dataStart, add(nBytesToCopy, 0x20))
                // update the freePtr
                mstore(0x40, add(freePtr, add(nBytesToCopy, 0x20)))
                // store the GPv2Interaction.settle method selector
                mstore(freePtr, 0x13d79a0b)

                calldataStart := add(freePtr, 0x1c)
                calldataSize := lastByte
            }
        }
    }

    function getParamsDigestAndCalldataPartiallySigned(
        address[] calldata tokens,
        uint256[] calldata clearingPrices,
        GPv2Trade.Data[] calldata trades,
        GPv2Interaction.Data[][3] calldata interactions
    )
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
            (deadline, r, s, v,, lastByte) =
                readExtraParamsPartiallySigned(tokens, clearingPrices, trades, interactions);
            uint256[3] calldata offsets;
            assembly {
                offsets := add(lastByte, 0x61)
            }
            uint256 dataSlices;

            assembly ("memory-safe") {
                dataSlices := mload(0x40)
                mstore(0x40, add(dataSlices, 0xc0))
                pop(staticcall(0, caller(), 0, 0, 0, 0))
            }

            storeSubsetOffets(interactions[0], dataSlices, offsets[0]);
            storeSubsetOffets(interactions[1], dataSlices + 0x40, offsets[1]);
            storeSubsetOffets(interactions[2], dataSlices + 0x80, offsets[2]);
            // uint lastInteractionsByte;
            // {
            //     GPv2Interaction.Data[] calldata postInteractions = interactions[2];
            //     if (postInteractions.length == 0) {
            //         assembly ("memory-safe") {
            //             lastInteractionsByte := postInteractions.offset
            //         }
            //     } else {
            //         lastInteractionsByte = getLastByteInteraction(postInteractions[postInteractions.length - 1]);
            //     }
            // }

            assembly ("memory-safe") {
                let freePtr := mload(0x40)
                // store the GPv2Settlement.settle data selector. setting at the bottom leads to stack too deep.
                mstore(freePtr, 0x13d79a0b)

                let dataStart := add(freePtr, 0x20)

                let nBytesToCopy := sub(interactions, 0x04)
                // call upto trades' last byte
                calldatacopy(dataStart, 0x04, nBytesToCopy)

                let interactionsStart := add(dataStart, nBytesToCopy)
                {
                    let lastWrittenByte := interactionsStart

                    function copyInteractionsSubset(
                        relativeOffset, offsets_, interactionsStart_, lastWrittenByte_, interactions_, dataSlices_
                    ) -> newLastWrittenByte {
                        let nSubset := calldataload(add(offsets_, relativeOffset))
                        let iOffset := sub(lastWrittenByte_, interactionsStart_)

                        // pre interactions offset is fixed
                        mstore(add(interactionsStart_, relativeOffset), iOffset)

                        // store pre interaction subset length
                        mstore(lastWrittenByte_, nSubset)
                        lastWrittenByte_ := add(lastWrittenByte_, 0x20)

                        // copy the pre interaction offsets
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

                        // copy the pre interactions subset
                        let interactionBytesStart := mload(add(dataSlices_, mul(relativeOffset, 2)))
                        let nInteractionBytes := mload(add(add(dataSlices_, mul(relativeOffset, 2)), 0x20))
                        mstore(0x00, interactionBytesStart)
                        mstore(0x20, nInteractionBytes)
                        pop(staticcall(0, 0x01, 0x00, 0x40, 0x00, 0x00))
                        calldatacopy(lastWrittenByte_, interactionBytesStart, nInteractionBytes)
                        lastWrittenByte_ := add(lastWrittenByte_, nInteractionBytes)
                        newLastWrittenByte := lastWrittenByte_
                    }

                    lastWrittenByte := add(lastWrittenByte, 0x60)
                    lastWrittenByte :=
                        copyInteractionsSubset(0x00, offsets, interactionsStart, lastWrittenByte, interactions, dataSlices)
                    lastWrittenByte :=
                        copyInteractionsSubset(0x20, offsets, interactionsStart, lastWrittenByte, interactions, dataSlices)
                    lastWrittenByte :=
                        copyInteractionsSubset(0x40, offsets, interactionsStart, lastWrittenByte, interactions, dataSlices)

                    // {
                    //     let nSubset := calldataload(offsets)
                    //
                    //     // pre interactions offset is fixed
                    //     mstore(interactionsStart, 0x60)
                    //
                    //     // store pre interaction subset length
                    //     mstore(add(interactionsStart, 0x60), nSubset)
                    //     lastWrittenByte := add(interactionsStart, 0x80)
                    //     let interactions_ := interactions
                    //
                    //     // copy the pre interaction offsets
                    //     let nInteractions := calldataload(add(interactions_, calldataload(interactions_)))
                    //     let firstInteractionOffset := add(add(interactions_, calldataload(interactions_)), 0x20)
                    //     let offsetsCutShort := mul(sub(nInteractions, nSubset), 0x20)
                    //     for {let i := 0} lt(i, nSubset) { i := add(i, 1) } {
                    //         mstore(lastWrittenByte, sub(calldataload(add(firstInteractionOffset, mul(i, 0x20))), offsetsCutShort))
                    //         lastWrittenByte := add(lastWrittenByte, 0x20)
                    //     }
                    //
                    //     // copy the pre interactions subset
                    //     let interactionBytesStart := mload(dataSlices)
                    //     let nInteractionBytes := mload(add(dataSlices, 0x20))
                    //     calldatacopy(lastWrittenByte, interactionBytesStart, nInteractionBytes)
                    //     lastWrittenByte := add(lastWrittenByte, nInteractionBytes)
                    // }

                    // {
                    //     let nSubset := calldataload(add(offsets, 0x20))
                    //
                    //     // store the intra interactions offset
                    //     mstore(add(interactionsStart, 0x20), sub(lastWrittenByte, interactionsStart))
                    //
                    //     // store the intra interactions length
                    //     mstore(lastWrittenByte, nSubset)
                    //     lastWrittenByte := add(lastWrittenByte, 0x20)
                    //     let interactions_ := interactions
                    //
                    //     // copy the intra interaction offsets
                    //     calldatacopy(
                    //         lastWrittenByte,
                    //         add(add(interactions_, calldataload(add(interactions_, 0x20))), 0x20),
                    //         mul(nSubset, 0x20)
                    //     )
                    //     lastWrittenByte := add(lastWrittenByte, mul(nSubset, 0x20))
                    //
                    //     // copy the intra interactions subset
                    //     let interactionBytesStart := mload(add(dataSlices, 0x40))
                    //     let nInteractionBytes := mload(add(dataSlices, 0x60))
                    //     calldatacopy(lastWrittenByte, interactionBytesStart, nInteractionBytes)
                    //     lastWrittenByte := add(lastWrittenByte, nInteractionBytes)
                    // }

                    // {
                    //     let nSubset := calldataload(add(offsets, 0x40))
                    //
                    //     // store the post interactions offset
                    //     mstore(add(interactionsStart, 0x40), sub(lastWrittenByte, interactionsStart))
                    //
                    //     // store the post interactions length
                    //     mstore(lastWrittenByte, nSubset)
                    //     lastWrittenByte := add(lastWrittenByte, 0x20)
                    //     let interactions_ := interactions
                    //
                    //     // copy the post interaction offsets
                    //     calldatacopy(
                    //         lastWrittenByte,
                    //         add(add(interactions_, calldataload(add(interactions_, 0x20))), 0x20),
                    //         mul(nSubset, 0x20)
                    //     )
                    //     lastWrittenByte := add(lastWrittenByte, mul(nSubset, 0x20))
                    //
                    //     // copy the post interactions subset
                    //     let interactionBytesStart := mload(add(dataSlices, 0x80))
                    //     let nInteractionBytes := mload(add(dataSlices, 0xa0))
                    //     calldatacopy(lastWrittenByte, interactionBytesStart, nInteractionBytes)
                    //     lastWrittenByte := add(lastWrittenByte, nInteractionBytes)
                    // }

                    mstore(lastWrittenByte, deadline)
                    lastWrittenByte := add(lastWrittenByte, 0x20)
                    mstore(lastWrittenByte, caller())
                    lastWrittenByte := add(lastWrittenByte, 0x20)
                    let nBytesToHash := sub(lastWrittenByte, dataStart)
                    digest := keccak256(dataStart, nBytesToHash)

                    // calldataSize := nBytesToHash
                    // calldataStart := dataStart
                    // mstore(0x00, nBytesToHash)
                    // pop(staticcall(0, 0x01, 0, 0x20, 0, 0))
                    // mstore(0x40, lastWrittenByte)
                }

                // overwrite the interactions with original data
                calldatacopy(interactionsStart, interactions, sub(lastByte, interactions))
                calldataSize := lastByte
                calldataStart := sub(dataStart, 0x04)

                // write the freePtr
                mstore(0x40, add(dataStart, sub(lastByte, 0x04)))
            }
        }
    }

    /// @dev stores the memory offse and size at memory slots `memoryOffset` and `memoryOffset + 20`
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

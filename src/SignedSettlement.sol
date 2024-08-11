pragma solidity ^0.8;

import {Auth} from "./Auth.sol";
import {GPv2Trade} from "cowprotocol/libraries/GPv2Trade.sol";
import {GPv2Interaction} from "cowprotocol/libraries/GPv2Interaction.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {LibSignedSettlement} from "./LibSignedSettlement.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {SubPoolFactory} from "./SubPoolFactory.sol";
import {GPv2Settlement, IERC20} from "cowprotocol/GPv2Settlement.sol";

contract SignedSettlement is Auth, EIP712 {
    error SignedSettlement__InvalidAttestor();
    error SignedSettlement__InvalidSolver();
    error SigendSettlement__DeadlineElapsed();
    error SignedSettlement__CannotSolve();

    /// @notice whether signer can attest
    address public immutable attestor;
    SubPoolFactory public immutable factory;
    GPv2Settlement public immutable settlement;

    constructor(SubPoolFactory _factory, GPv2Settlement _settlement, address _attestor) {
        factory = _factory;
        settlement = _settlement;
        attestor = _attestor;
    }

    error Incorrect(uint256, uint256, bytes);

    event Digest(bytes32);

    /// @notice Takes the required settlement data and verifies that it has been
    ///         signed by a `signer`, and subsequently calls `GPv2.(Settlement.settle`.
    /// @dev    Signed settlement function that is only callable by a collateralised subpool.
    function signedSettleFullySigned(
        address[] calldata tokens,
        uint256[] calldata clearingPrices,
        GPv2Trade.Data[] calldata trades,
        GPv2Interaction.Data[][3] calldata interactions
    )
        // bytes calldata signature
        external
    {
        (uint256 deadline, uint256 r, uint256 s, uint256 v, uint256 lastByte) =
            LibSignedSettlement.readDeadlineAndSignature(tokens, clearingPrices, trades, interactions);
        bytes32 digest;
        uint256 copiedToStart;

        assembly ("memory-safe") {
            let freePtr := mload(0x40)
            copiedToStart := freePtr
            let nBytesToCopy := add(lastByte, 28) // lastByte - 4(for method id) + 32 (for deadline)
            calldatacopy(freePtr, 0x04, nBytesToCopy)
            // store the solver after deadline
            mstore(add(freePtr, nBytesToCopy), caller())
            // update the free memory ptr
            mstore(0x40, add(freePtr, add(nBytesToCopy, 32)))
            // hash the message <tokens, clearingPrices, trades, interactions> | deadline | solver
            digest := keccak256(freePtr, add(nBytesToCopy, 32))
            log1(0, 0, add(nBytesToCopy, 32))
            log1(0, 0, caller())
        }
        emit Digest(digest);

        address signer = ECDSA.recover(digest, uint8(v), bytes32(r), bytes32(s));
        if (signer != attestor) {
            revert SignedSettlement__InvalidAttestor();
        }

        address settlement_ = address(settlement);
        assembly ("memory-safe") {
            // store the selector
            mstore(sub(copiedToStart, 0x20), 0x13d79a0b)
            // call settlement
            let success := call(gas(), settlement_, 0, sub(copiedToStart, 0x04), lastByte, 0, 0)

            switch success
            case 1 {
                // nothing to do on success
            }
            case 0 {
                // bubble up the revert data
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
        //
        // uint256 lengthOfPostInteractions = interactions[2].length;
        //
        // address solver = msg.sender;
        // // if (block.timestamp > deadline) revert SigendSettlement__DeadlineElapsed();
        //
        // bytes32 digest;
        // uint256 offset;
        // uint256 copySizeFixed = 32 // solver
        //     + 32 // deadline
        //     + 32 // tokens offset
        //     + 32 // clearing prices offset
        //     + 32 // trades offset
        //     + 32 // interactions offset
        //     + 32 // tokens length
        //     + (32 * tokens.length) // one word for each token
        //     + 32 // clearing prices length
        //     + (32 * clearingPrices.length) // one word for each clearing price
        //     + 32 // trades length
        //     + (
        //         32 // trade offset
        //             + 32 // sellTokenIndex
        //             + 32 // buyTokenIndex
        //             + 32 // receiver
        //             + 32 // sellAmount
        //             + 32 // buyAmount
        //             + 32 // validTo
        //             + 32 // appData
        //             + 32 // feeAmount
        //             + 32 // flags
        //             + 32 // executedAmount
        //             + 32 // signature offset
        //             + 32
        //     ) // signature length
        //         * trades.length // fixed length per trade, now need to add the length of signatures
        //     + 32 // pre interactions offset
        //     + 32 // intra interactions offset
        //     + 32 // post interactions offset
        //     + 32 // pre interactions length
        //     + 32 // intra interactions length
        //     + 32 // post interactions length
        //     + (
        //         32 // interaction offset
        //             + 32 // address
        //             + 32 // value
        //             + 32 // bytes offset
        //             + 32
        //     ) // bytes length
        //         * (interactions[0].length + interactions[1].length + interactions[2].length); // fixed cost per interaction, need to add the length of the bytes field of each interaction;
        // uint256 signaturesLength = 0;
        // for (uint256 i = 0; i < trades.length;) {
        //     uint256 len = trades[i].signature.length;
        //     signaturesLength += (len % 32 == 0 ? (len / 32) : (len / 32) + 1);
        //     unchecked {
        //         ++i;
        //     }
        // }
        // signaturesLength *= 32;
        // uint256 interactionsLength = 0;
        // for (uint256 i = 0; i < 3;) {
        //     for (uint256 j = 0; j < interactions[i].length;) {
        //         uint256 len = interactions[i][j].callData.length;
        //         interactionsLength += len % 32 == 0 ? len / 32 : (len / 32) + 1;
        //         unchecked {
        //             ++j;
        //         }
        //     }
        //     unchecked {
        //         ++i;
        //     }
        // }
        // interactionsLength *= 32;
        // uint256 copySize = copySizeFixed + signaturesLength + interactionsLength;
        // bytes memory debugData = abi.encode(
        //     tokens.length,
        //     clearingPrices.length,
        //     trades.length,
        //     interactions[0].length,
        //     interactions[1].length,
        //     interactions[2].length
        // );
        // // uint256 signatureOffset;
        // // assembly {
        // //     signatureOffset := sub(signature.offset, 64)
        // // }
        // // assert((copySize + 4) == signatureOffset);
        // // if (copySize + 4 != signatureOffset) {
        // //     revert Incorrect(copySize + 4, signatureOffset, debugData);
        // // }
        //
        // bytes memory data;
        //
        // assembly ("memory-safe") {
        //     offset := mload(0x40)
        //     data := sub(offset, 32)
        //     mstore(data, copySize)
        //     calldatacopy(offset, 4, copySize)
        //     digest := keccak256(offset, copySize)
        //     mstore(0x40, add(offset, copySize))
        // }
        //
        // // revert Incorrect(0, 0, abi.encodePacked(digest, copySize));
        // // revert Incorrect(0, 0, data);
        //
        // bytes calldata signature = msg.data[(4 + copySize):];
        // address signer = ECDSA.recoverCalldata(digest, signature);
        // if (signer != attestor) {
        //     revert SignedSettlement__InvalidAttestor();
        // }
        //
        // bool canSolve = factory.canSolve(msg.sender);
        // if (!canSolve) revert SignedSettlement__CannotSolve();
        //
        // address settlement_ = address(settlement);
        // assembly ("memory-safe") {
        //     // first two words are solver and deadline, we can reuse the rest of it for the call
        //     // set the selector
        //     mstore(add(offset, 0x20), 0x13d79a0b)
        //     let success := call(gas(), settlement_, 0, add(offset, 60), sub(copySize, 60), 0, 0)
        //     if iszero(success) {
        //         returndatacopy(0, 0, returndatasize())
        //         revert(0, returndatasize())
        //     }
        // }
    }

    function signedSettlePartiallySigned(
        address[] calldata tokens,
        uint256[] calldata clearingPrices,
        GPv2Trade.Data[] calldata trades,
        GPv2Interaction.Data[][3] calldata interactions,
        address solver,
        uint256 deadline,
        uint256[3] calldata nSigned,
        bytes calldata signature
    ) external {
        assembly {
            let freePtr := mload(0x40)
        }
    }

    /// @notice The EIP712 domain separator.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparator();
    }

    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "SignedSettlement";
        version = "1";
    }
}

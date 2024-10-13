pragma solidity ^0.8;

import {Auth} from "./Auth.sol";
import {GPv2Trade} from "cowprotocol/libraries/GPv2Trade.sol";
import {GPv2Interaction} from "cowprotocol/libraries/GPv2Interaction.sol";
import {LibSignedSettlement} from "./LibSignedSettlement.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {SubPoolFactory} from "./SubPoolFactory.sol";
import {GPv2Settlement, IERC20} from "cowprotocol/GPv2Settlement.sol";

contract SignedSettlement is Auth {
    error SignedSettlement__InvalidAttestor();
    error SignedSettlement__DeadlineElapsed();

    /// @notice whether signer can attest
    address public immutable attestor;
    GPv2Settlement public immutable settlement;

    constructor(GPv2Settlement _settlement, address _attestor) {
        settlement = _settlement;
        attestor = _attestor;
    }

    /// @notice Takes the required settlement data and verifies that it has been
    ///         signed by a `signer`, and subsequently calls `GPv2Settlement.settle`.
    /// @dev    Extra parameters need to be encoded at the end of the abi encoded calldata
    ///         for calling this function.
    ///         The calldata is as follows:
    ///             abi.encodePacked(
    ///                 abi.encodeCall(this.sigendSettleFullySigned, (tokens, clearingPrices, trades, interactions)),
    ///                 deadline, r, s, v
    ///             )
    function signedSettleFullySigned(
        address[] calldata, // tokens
        uint256[] calldata, // clearingPrices
        GPv2Trade.Data[] calldata, // trades
        GPv2Interaction.Data[][3] calldata // interactions
    ) external {
        (uint256 deadline, uint256 r, uint256 s, uint256 v, bytes32 digest, uint256 calldataStart, uint256 calldataSize)
        = LibSignedSettlement.getParamsDigestAndCalldataFullySigned();
        _verifyAndExecuteSettle(deadline, r, s, v, digest, calldataStart, calldataSize);
    }

    /// @notice Takes the required settlement data and verifies that it has been
    ///         signed by a `signer`, and subsequently calls `GPv2Settlement.settle`.
    /// @dev    Extra parameters need to be encoded at the end of the abi encoded calldata
    ///         for calling this function.
    ///         The calldata is as follows:
    ///             abi.encodePacked(
    ///                 abi.encodeCall(this.signedSettleFullySigned, (tokens, clearingPrices, trades, interactions)),
    ///                 deadline, r, s, v, lengths
    ///             )
    function signedSettlePartiallySigned(
        address[] calldata, // tokens
        uint256[] calldata, // clearingPrices
        GPv2Trade.Data[] calldata, // trades
        GPv2Interaction.Data[][3] calldata interactions
    ) external {
        (uint256 deadline, uint256 r, uint256 s, uint256 v, bytes32 digest, uint256 calldataStart, uint256 calldataSize)
        = LibSignedSettlement.getParamsDigestAndCalldataPartiallySigned(interactions);
        _verifyAndExecuteSettle(deadline, r, s, v, digest, calldataStart, calldataSize);
    }

    /// @param deadline      deadline expressed as block number
    /// @param r             signature part r
    /// @param s             signature part s
    /// @param v             signature part v
    /// @param digest        message digest
    /// @param calldataStart pointer to the start of calldata in memory that will be used for the `GPv2Settlement.settle` call.
    /// @param calldataSize  size of the calldata passed to the `GPv2Settlement.settle` call.
    function _verifyAndExecuteSettle(
        uint256 deadline,
        uint256 r,
        uint256 s,
        uint256 v,
        bytes32 digest,
        uint256 calldataStart,
        uint256 calldataSize
    ) internal {
        if (block.number > deadline) revert SignedSettlement__DeadlineElapsed();

        address signer = ECDSA.recover(digest, uint8(v), bytes32(r), bytes32(s));
        if (signer != attestor) {
            revert SignedSettlement__InvalidAttestor();
        }

        address settlement_ = address(settlement);
        assembly ("memory-safe") {
            // call settlement
            let success := call(gas(), settlement_, 0, calldataStart, calldataSize, 0, 0)

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
    }
}

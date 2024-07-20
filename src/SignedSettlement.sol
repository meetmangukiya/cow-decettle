pragma solidity 0.8.26;

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
    error SignedSettlement__NotASolver();

    /// @notice whether signer can attest
    address public immutable attestor;
    SubPoolFactory public immutable factory;
    GPv2Settlement public immutable settlement;

    constructor(SubPoolFactory _factory, GPv2Settlement _settlement, address _attestor) {
        factory = _factory;
        settlement = _settlement;
        attestor = _attestor;
    }

    /// @notice Takes the required settlement data and verifies that it has been
    ///         signed by a `signer`, and subsequently calls `GPv2.Settlement.settle`.
    /// @dev    Signed settlement function that is only callable by a collateralised subpool.
    function signedSettle(
        IERC20[] calldata tokens,
        uint256[] calldata clearingPrices,
        GPv2Trade.Data[] calldata trades,
        GPv2Interaction.Data[][3] calldata interactions,
        bytes calldata signature
    ) external {
        // verify that the signer is one of the vouched signers
        bytes32 digest =
            _hashTypedData(LibSignedSettlement.hashSettleData(tokens, clearingPrices, trades, interactions[0]));
        address signer = ECDSA.recoverCalldata(digest, signature);
        if (signer != attestor) {
            revert SignedSettlement__InvalidAttestor();
        }

        // scoped to clear the stack and prevent stack too deep error
        {
            // verify that the pool exists, hasnt undercollateralized, frozen or exited.
            bool canSolve = factory.canSolve(msg.sender);
            if (!canSolve) revert SignedSettlement__NotASolver();
        }

        settlement.settle(tokens, clearingPrices, trades, interactions);
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

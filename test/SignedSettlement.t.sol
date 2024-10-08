pragma solidity ^0.8;

import {BaseTest} from "./BaseTest.sol";
import {Auth} from "src/Auth.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {
    SignedSettlement,
    GPv2Interaction,
    GPv2Trade,
    IERC20,
    GPv2Settlement,
    SubPoolFactory
} from "src/SignedSettlement.sol";
import {LibSignedSettlementProxy} from "./LibSignedSettlement.t.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {TOKEN_COW_MAINNET, TOKEN_WETH_MAINNET} from "src/constants.sol";
import {GPv2AllowListAuthentication} from "cowprotocol/GPv2AllowListAuthentication.sol";
import {console2 as console} from "forge-std/console2.sol";

contract SignedSettlementTest is BaseTest {
    address notRelied = makeAddr("notRelied");

    address solver = makeAddr("solver");
    address solverPoolAddress;
    uint256 solverEthAmt = 20 ether;
    uint256 solverCowAmt = 20 ether;
    string backendUri = "https://backend.solver.com";

    function setUp() public override {
        super.setUp();

        // init a solver
        deal(TOKEN_WETH_MAINNET, solver, solverEthAmt);
        deal(TOKEN_COW_MAINNET, solver, solverCowAmt);
        vm.startPrank(solver);
        ERC20(TOKEN_WETH_MAINNET).approve(address(factory), solverEthAmt);
        ERC20(TOKEN_COW_MAINNET).approve(address(factory), solverCowAmt);
        solverPoolAddress = factory.create(TOKEN_WETH_MAINNET, solverEthAmt, solverCowAmt, backendUri);
        vm.stopPrank();

        GPv2AllowListAuthentication authenticator = GPv2AllowListAuthentication(address(settlement.authenticator()));
        address allowlistManager = authenticator.manager();
        vm.prank(allowlistManager);
        authenticator.addSolver(address(signedSettlement));

        vm.etch(address(settlement), hex"");
    }

    function testFuzzSignedSettleFullySigned(
        address[] calldata tokens,
        uint256[] calldata clearingPrices,
        GPv2Trade.Data[] calldata trades,
        GPv2Interaction.Data[][3] calldata interactions,
        uint256 deadline
    ) external {
        vm.assume(deadline >= block.number);
        (bytes memory payloadToSend, bytes memory expectedCalldata) =
            _fullySignedSettleCalldata(tokens, clearingPrices, trades, interactions, deadline, attestor);

        address settlement = address(signedSettlement.settlement());
        vm.prank(solver);
        vm.expectCall(settlement, expectedCalldata);
        (bool success, bytes memory ret) = address(signedSettlement).call(payloadToSend);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function testFuzzSignedSettlePartiallySigned(
        address[] memory tokens,
        uint256[] memory clearingPrices,
        GPv2Trade.Data[] memory trades,
        GPv2Interaction.Data[][3] memory interactions,
        uint256 deadline,
        uint256[3] memory offsets
    ) external {
        vm.assume(deadline >= block.number);
        offsets[0] = bound(offsets[0], 0, interactions[0].length);
        offsets[1] = bound(offsets[1], 0, interactions[1].length);
        offsets[2] = bound(offsets[2], 0, interactions[2].length);
        (bytes memory payloadToSend, bytes memory expectedCalldata) =
            _partiallySignedSettleCalldata(tokens, clearingPrices, trades, interactions, deadline, offsets, attestor);

        address settlement = address(signedSettlement.settlement());
        vm.prank(solver);
        vm.expectCall(settlement, expectedCalldata);
        (bool success, bytes memory ret) = address(signedSettlement).call(payloadToSend);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function testFullySignedSettle() external {
        address[] memory tokens = new address[](2);
        uint256[] memory clearingPrices = new uint256[](2);
        GPv2Trade.Data[] memory trades = new GPv2Trade.Data[](2);
        GPv2Interaction.Data[][3] memory interactions;

        uint256 deadline = block.number - 1;
        (bytes memory payloadToSend,) =
            _fullySignedSettleCalldata(tokens, clearingPrices, trades, interactions, deadline, attestor);
        vm.expectRevert(SignedSettlement.SignedSettlement__DeadlineElapsed.selector);
        address(signedSettlement).call(payloadToSend);

        VmSafe.Wallet memory notAttestor = vm.createWallet("notAttestor");
        deadline = block.number;
        (payloadToSend,) =
            _fullySignedSettleCalldata(tokens, clearingPrices, trades, interactions, deadline, notAttestor);
        vm.expectRevert(SignedSettlement.SignedSettlement__InvalidAttestor.selector);
        address(signedSettlement).call(payloadToSend);
    }

    function testPartiallySignedSettle() external {
        address[] memory tokens = new address[](2);
        uint256[] memory clearingPrices = new uint256[](2);
        GPv2Trade.Data[] memory trades = new GPv2Trade.Data[](2);
        GPv2Interaction.Data[][3] memory interactions;
        uint256[3] memory offsets;

        uint256 deadline = block.number - 1;
        (bytes memory payloadToSend,) =
            _partiallySignedSettleCalldata(tokens, clearingPrices, trades, interactions, deadline, offsets, attestor);
        vm.expectRevert(SignedSettlement.SignedSettlement__DeadlineElapsed.selector);
        address(signedSettlement).call(payloadToSend);

        VmSafe.Wallet memory notAttestor = vm.createWallet("notAttestor");
        deadline = block.number;
        (payloadToSend,) =
            _partiallySignedSettleCalldata(tokens, clearingPrices, trades, interactions, deadline, offsets, notAttestor);
        vm.expectRevert(SignedSettlement.SignedSettlement__InvalidAttestor.selector);
        address(signedSettlement).call(payloadToSend);
    }

    function _fullySignedSettleCalldata(
        address[] memory tokens,
        uint256[] memory clearingPrices,
        GPv2Trade.Data[] memory trades,
        GPv2Interaction.Data[][3] memory interactions,
        uint256 deadline,
        VmSafe.Wallet memory attestor
    ) internal returns (bytes memory payloadToSend, bytes memory expectedCalldata) {
        bytes memory encoded = abi.encode(tokens, clearingPrices, trades, interactions);
        bytes memory payloadToSign = abi.encodePacked(encoded, abi.encode(deadline, solver));
        console.log("payload to sign", payloadToSign.length);
        console.log("attestor", attestor.addr);
        bytes32 digest = keccak256(payloadToSign);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attestor, digest);
        payloadToSend = abi.encodePacked(SignedSettlement.signedSettleFullySigned.selector, encoded, deadline, r, s, v);
        expectedCalldata = abi.encodePacked(GPv2Settlement.settle.selector, encoded);
    }

    function _partiallySignedSettleCalldata(
        address[] memory tokens,
        uint256[] memory clearingPrices,
        GPv2Trade.Data[] memory trades,
        GPv2Interaction.Data[][3] memory interactions,
        uint256 deadline,
        uint256[3] memory offsets,
        VmSafe.Wallet memory attestor
    ) internal returns (bytes memory payloadToSend, bytes memory expectedCalldata) {
        GPv2Interaction.Data[][3] memory subsetInteractions;
        {
            for (uint256 i = 0; i < 3; i++) {
                subsetInteractions[i] = new GPv2Interaction.Data[](offsets[i]);
                for (uint256 j = 0; j < offsets[i]; j++) {
                    subsetInteractions[i][j] = interactions[i][j];
                }
            }
        }

        bytes memory encoded = abi.encode(tokens, clearingPrices, trades, subsetInteractions);
        bytes memory payloadToSign = abi.encodePacked(encoded, abi.encode(deadline, solver));
        console.log("payload to sign", payloadToSign.length);
        console.log("attestor", attestor.addr);
        bytes32 digest = keccak256(payloadToSign);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attestor, digest);
        uint256 deadline_ = deadline;
        uint256[3] memory offsets_ = offsets;
        payloadToSend = abi.encodePacked(
            SignedSettlement.signedSettlePartiallySigned.selector, encoded, deadline_, r, s, v, offsets_
        );
        expectedCalldata = abi.encodePacked(GPv2Settlement.settle.selector, encoded);
    }
}

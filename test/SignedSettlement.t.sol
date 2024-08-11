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

        vm.etch(address(signedSettlement.settlement()), hex"");
    }

    // function testSignedSettle() external {
    //     (
    //         IERC20[] memory tokens,
    //         uint256[] memory clearingPrices,
    //         GPv2Trade.Data[] memory trades,
    //         GPv2Interaction.Data[][3] memory interactions
    //     ) = _payload();
    //     bytes32 hashStruct = LibSignedSettlementProxy.hashSettleData(tokens, clearingPrices, trades, interactions[0]);
    //     bytes32 domainSeparator = signedSettlement.domainSeparator();
    //     bytes32 digest = keccak256(abi.encodePacked(hex"1901", domainSeparator, hashStruct));
    //     (uint8 v, bytes32 r, bytes32 s) = vm.sign(attestor, digest);
    //     bytes memory attestorSignature = abi.encodePacked(r, s, v);
    //
    //     (v, r, s) = vm.sign(notAttestor, digest);
    //     bytes memory notAttestorSignature = abi.encodePacked(r, s, v);
    //
    //     // only attestor allowed
    //     vm.expectRevert(SignedSettlement.SignedSettlement__InvalidAttestor.selector);
    //     signedSettlement.signedSettle(tokens, clearingPrices, trades, interactions, notAttestorSignature);
    //
    //     // check it calls settle if the payload is signed correctly and the solver is a valid solver
    //     // we dont need to process the settle, so just mock it so it doesnt attempt to process it
    //     vm.mockCall(address(settlement), abi.encodePacked(GPv2Settlement.settle.selector), hex"");
    //     vm.expectCall(
    //         address(settlement), abi.encodeCall(GPv2Settlement.settle, (tokens, clearingPrices, trades, interactions))
    //     );
    //     vm.prank(solver);
    //     signedSettlement.signedSettle(tokens, clearingPrices, trades, interactions, attestorSignature);
    //
    //     // mock canSolve to false, should revert
    //     vm.mockCall(address(factory), abi.encodeCall(factory.canSolve, solver), abi.encode(false));
    //     vm.expectRevert(SignedSettlement.SignedSettlement__NotASolver.selector);
    //     vm.prank(solver);
    //     signedSettlement.signedSettle(tokens, clearingPrices, trades, interactions, attestorSignature);
    //
    //     // non inited pools not allowed
    //     vm.expectRevert(SubPoolFactory.SubPoolFactory__UnknownPool.selector);
    //     signedSettlement.signedSettle(tokens, clearingPrices, trades, interactions, attestorSignature);
    // }

    // function _leanPayload()
    //     internal
    //     returns (
    //         address[] memory tokens,
    //         uint256[] memory clearingPrices,
    //         GPv2Trade.Data[] memory trades,
    //         GPv2Interaction.Data[][3] memory interactions
    //     )
    // {
    //     tokens = new IERC20[](3);
    //     tokens[0] = IERC20(makeAddr("token0"));
    //     tokens[1] = IERC20(makeAddr("token1"));
    //     tokens[2] = IERC20(makeAddr("token2"));
    //
    //     clearingPrices = new uint256[](3);
    //     clearingPrices[0] = 1 ether;
    //     clearingPrices[1] = 2 ether;
    //     clearingPrices[2] = 1000e8;
    //
    //     bytes32 appData = keccak256("appData");
    //     trades = new GPv2Trade.Data[](1);
    //     trades[0] = GPv2Trade.Data({
    //         sellTokenIndex: 0,
    //         buyTokenIndex: 1,
    //         receiver: makeAddr("user1"),
    //         sellAmount: 1 ether,
    //         buyAmount: 0.5 ether,
    //         validTo: uint32(block.timestamp),
    //         appData: appData,
    //         feeAmount: 0,
    //         flags: 0x11,
    //         executedAmount: 1 ether,
    //         signature: hex"000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000555555555555555555555555555555555555555555555555550"
    //     });
    //
    //     interactions[0] = new GPv2Interaction.Data[](1);
    //     interactions[0][0] = GPv2Interaction.Data({target: makeAddr("target"), value: 0, callData: hex"0011223344"});
    //
    //     interactions[1] = new GPv2Interaction.Data[](0);
    //     interactions[2] = new GPv2Interaction.Data[](0);
    // }

    error First(bytes32, bytes);

    function testSignedSettleFullySigned(
        address[] calldata tokens,
        uint256[] calldata clearingPrices,
        GPv2Trade.Data[] calldata trades,
        GPv2Interaction.Data[][3] calldata interactions,
        uint256 deadline
    ) external {
        bytes memory encoded = abi.encode(tokens, clearingPrices, trades, interactions);
        bytes memory payloadToSign = abi.encodePacked(encoded, abi.encode(deadline, solver));
        bytes32 digest = keccak256(payloadToSign);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attestor, digest);
        bytes memory payloadToSend =
            abi.encodePacked(SignedSettlement.signedSettleFullySigned.selector, encoded, deadline, r, s, v);
        bytes memory expectedCalldata = abi.encodePacked(GPv2Settlement.settle.selector, encoded);

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

    error Debug(bytes);

    function testSignedSettlePartiallySigned(
        address[] calldata tokens,
        uint256[] calldata clearingPrices,
        GPv2Trade.Data[] calldata trades,
        GPv2Interaction.Data[][3] calldata interactions,
        uint256 someUint
    ) external {
        bytes memory cd = abi.encodePacked(
            abi.encodeCall(LibExt.something, (tokens, clearingPrices, trades, interactions)), abi.encode(someUint)
        );
        // bytes memory cd = abi.encodeWithSelector(LibExt.something.selector, abi.encodePacked(abi.encode(tokens, clearingPrices, trades, interactions), someUint));
        LibExt ext = new LibExt();
        (bool success, bytes memory data) = address(ext).call(cd);
        require(success, "not successful");
        assertEq(abi.decode(data, (uint256)), someUint, "invalid cusotm data");
    }

    // function _payload1() internal returns () {
    //
    // }
}

contract LibExt {
    error Debug(bytes);

    function something(
        address[] calldata tokens,
        uint256[] calldata tokenPrices,
        GPv2Trade.Data[] calldata trades,
        GPv2Interaction.Data[][3] calldata interactions
    ) external pure returns (uint256) {
        uint256 lastByte;
        uint256 lenPostInteractions = interactions[2].length;
        if (lenPostInteractions > 0) {
            GPv2Interaction.Data calldata lastInteraction = interactions[2][lenPostInteractions - 1];
            uint256 offset;
            assembly {
                offset := lastInteraction
            }
            uint256 cdlen = lastInteraction.callData.length;
            lastByte = offset
                + (
                    1 // target
                        + 1 // value
                        + 1 // offset
                        + 1 // length
                        + (cdlen % 32 == 0 ? cdlen / 32 : (cdlen / 32) + 1)
                ) // n words for the data
                    * 32;
        } else {
            GPv2Interaction.Data[] calldata postInteractions = interactions[2];
            assembly {
                lastByte := postInteractions.offset
            }
        }
        uint256 customData;

        assembly {
            customData := calldataload(lastByte)
        }
        return customData;
        // assertEq(msg.data.length, lastByte, "incorrect!");
    }
}

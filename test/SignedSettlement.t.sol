pragma solidity 0.8.26;

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

contract SignedSettlementTest is BaseTest {
    address notRelied = makeAddr("notRelied");
    VmSafe.Wallet vouched = vm.createWallet("vouched");
    VmSafe.Wallet notVouched = vm.createWallet("notVouched");

    address solver = makeAddr("solver");
    address solverPoolAddress;
    uint256 solverEthAmt = 20 ether;

    function setUp() public override {
        super.setUp();
        signedSettlement.hope(vouched.addr);

        // init a solver
        _mockChainlinkPrice(TOKEN_WETH_MAINNET, 3500e8);
        deal(TOKEN_WETH_MAINNET, solver, solverEthAmt);
        deal(TOKEN_COW_MAINNET, solver, minCowAmt);
        vm.startPrank(solver);
        ERC20(TOKEN_WETH_MAINNET).approve(address(factory), solverEthAmt);
        ERC20(TOKEN_COW_MAINNET).approve(address(factory), minCowAmt);
        solverPoolAddress = factory.create(TOKEN_WETH_MAINNET, solverEthAmt, minCowAmt);
        vm.stopPrank();

        GPv2AllowListAuthentication authenticator = GPv2AllowListAuthentication(address(settlement.authenticator()));
        address allowlistManager = authenticator.manager();
        vm.prank(allowlistManager);
        authenticator.addSolver(address(signedSettlement));
    }

    function testHope() external {
        address toHope = makeAddr("toHope");

        vm.prank(notRelied);
        vm.expectRevert(Auth.Auth__OnlyWards.selector);
        signedSettlement.hope(toHope);

        signedSettlement.hope(toHope);
        assertEq(signedSettlement.can(toHope), true, "didnt hope as expected");
    }

    function testNope() external {
        address hoped = makeAddr("hoped");
        signedSettlement.hope(hoped);
        assertEq(signedSettlement.can(hoped), true, "didnt hope as expected");

        vm.prank(notRelied);
        vm.expectRevert(Auth.Auth__OnlyWards.selector);
        signedSettlement.nope(hoped);

        signedSettlement.nope(hoped);
        assertEq(signedSettlement.can(hoped), false, "didnt nope as expected");
    }

    function testSignedSettle() external {
        (
            IERC20[] memory tokens,
            uint256[] memory clearingPrices,
            GPv2Trade.Data[] memory trades,
            GPv2Interaction.Data[][3] memory interactions
        ) = _payload();
        bytes32 hashStruct = LibSignedSettlementProxy.hashSettleData(tokens, clearingPrices, trades, interactions[0]);
        bytes32 domainSeparator = signedSettlement.domainSeparator();
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domainSeparator, hashStruct));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(vouched, digest);
        bytes memory vouchedSignature = abi.encodePacked(r, s, v);

        (v, r, s) = vm.sign(notVouched, digest);
        bytes memory notVouchedSignature = abi.encodePacked(r, s, v);

        // only vouched signers allowed
        vm.expectRevert(SignedSettlement.SignedSettlement__UnknownSigner.selector);
        signedSettlement.signedSettle(tokens, clearingPrices, trades, interactions, notVouchedSignature);

        // check it calls settle if the payload is signed correctly and the solver is a valid solver
        // we dont need to process the settle, so just mock it so it doesnt attempt to process it
        vm.mockCall(address(settlement), abi.encodePacked(GPv2Settlement.settle.selector), hex"");
        vm.expectCall(
            address(settlement), abi.encodeCall(GPv2Settlement.settle, (tokens, clearingPrices, trades, interactions))
        );
        vm.prank(solver);
        signedSettlement.signedSettle(tokens, clearingPrices, trades, interactions, vouchedSignature);

        // mock isSolver to false, should revert
        vm.mockCall(address(factory), abi.encodeCall(factory.isSolver, solverPoolAddress), abi.encode(false));
        vm.expectRevert(SignedSettlement.SignedSettlement__NotASolver.selector);
        vm.prank(solver);
        signedSettlement.signedSettle(tokens, clearingPrices, trades, interactions, vouchedSignature);

        // non inited pools not allowed
        vm.expectRevert(SubPoolFactory.SubPoolFactory__UnknownPool.selector);
        signedSettlement.signedSettle(tokens, clearingPrices, trades, interactions, vouchedSignature);
    }

    function _payload()
        internal
        returns (
            IERC20[] memory tokens,
            uint256[] memory clearingPrices,
            GPv2Trade.Data[] memory trades,
            GPv2Interaction.Data[][3] memory interactions
        )
    {
        tokens = new IERC20[](3);
        tokens[0] = IERC20(makeAddr("token0"));
        tokens[1] = IERC20(makeAddr("token1"));
        tokens[2] = IERC20(makeAddr("token2"));

        clearingPrices = new uint256[](3);
        clearingPrices[0] = 1 ether;
        clearingPrices[1] = 2 ether;
        clearingPrices[2] = 1000e8;

        bytes32 appData = keccak256("appData");
        trades = new GPv2Trade.Data[](1);
        trades[0] = GPv2Trade.Data({
            sellTokenIndex: 0,
            buyTokenIndex: 1,
            receiver: makeAddr("user1"),
            sellAmount: 1 ether,
            buyAmount: 0.5 ether,
            validTo: uint32(block.timestamp),
            appData: appData,
            feeAmount: 0,
            flags: 0x11,
            executedAmount: 1 ether,
            signature: hex"000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000555555555555555555555555555555555555555555555555550"
        });

        interactions[0] = new GPv2Interaction.Data[](1);
        interactions[0][0] = GPv2Interaction.Data({target: makeAddr("target"), value: 0, callData: hex"0011223344"});

        interactions[1] = new GPv2Interaction.Data[](0);
        interactions[2] = new GPv2Interaction.Data[](0);
    }
}

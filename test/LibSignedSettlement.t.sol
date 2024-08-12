pragma solidity ^0.8;

import {LibSignedSettlement, GPv2Trade, GPv2Interaction, IERC20} from "src/LibSignedSettlement.sol";
import {Test} from "forge-std/Test.sol";
import {GPv2Settlement} from "cowprotocol/GPv2Settlement.sol";
import {console} from "forge-std/console.sol";

library LibSignedSettlementProxy {
    function readExtraBytes(
        address[] calldata tokens,
        uint256[] calldata clearingPrices,
        GPv2Trade.Data[] calldata trades,
        GPv2Interaction.Data[][3] calldata interactions
    ) external pure returns (bytes calldata remainder, uint256 lastByte) {
        (remainder, lastByte) = LibSignedSettlement.readExtraBytes(tokens, clearingPrices, trades, interactions);
    }

    function readExtraParamsFullySigned(
        address[] calldata tokens,
        uint256[] calldata clearingPrices,
        GPv2Trade.Data[] calldata trades,
        GPv2Interaction.Data[][3] calldata interactions
    ) external pure returns (uint256 deadline, uint256 r, uint256 s, uint256 v, uint256 lastByte) {
        (deadline, r, s, v, lastByte) =
            LibSignedSettlement.readExtraParamsFullySigned(tokens, clearingPrices, trades, interactions);
    }

    function readExtraParamsPartiallySigned(
        address[] calldata tokens,
        uint256[] calldata clearingPrices,
        GPv2Trade.Data[] calldata trades,
        GPv2Interaction.Data[][3] calldata interactions
    )
        external
        pure
        returns (uint256 deadline, uint256 r, uint256 s, uint256 v, uint256[3] memory offsets, uint256 lastByte)
    {
        (deadline, r, s, v, offsets, lastByte) =
            LibSignedSettlement.readExtraParamsPartiallySigned(tokens, clearingPrices, trades, interactions);
    }

    function getParamsDigestAndCalldataFullySigned(
        address[] calldata tokens,
        uint256[] calldata clearingPrices,
        GPv2Trade.Data[] calldata trades,
        GPv2Interaction.Data[][3] calldata interactions
    ) external view returns (uint256 deadline, uint256 r, uint256 s, uint256 v, bytes32 digest, bytes memory cd) {
        uint256 calldataStart;
        uint256 calldataSize;
        (deadline, r, s, v, digest, calldataStart, calldataSize) =
            LibSignedSettlement.getParamsDigestAndCalldataFullySigned(tokens, clearingPrices, trades, interactions);
        assembly {
            mstore(sub(calldataStart, 0x20), calldataSize)
            cd := sub(calldataStart, 0x20)
        }
    }

    function getParamsDigestAndCalldataPartiallySigned(
        address[] calldata tokens,
        uint256[] calldata clearingPrices,
        GPv2Trade.Data[] calldata trades,
        GPv2Interaction.Data[][3] calldata interactions
    ) external view returns (uint256 deadline, uint256 r, uint256 s, uint256 v, bytes32 digest, bytes memory cd) {
        uint256 calldataStart;
        uint256 calldataSize;
        (deadline, r, s, v, digest, calldataStart, calldataSize) =
            LibSignedSettlement.getParamsDigestAndCalldataPartiallySigned(tokens, clearingPrices, trades, interactions);
        console.log("calldataStart, size", calldataStart, calldataSize);
        assembly {
            mstore(sub(calldataStart, 0x20), calldataSize)
            cd := sub(calldataStart, 0x20)
        }
    }
}

contract LibSignedSettlementTest is Test {
    function testReadExtraParamsFullySigned(
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
            LibSignedSettlementProxy.readExtraParamsFullySigned.selector, tokens, prices, trades, interactions
        );
        bytes memory cdWithParams = abi.encodePacked(cd, deadline, r, s, v);
        (bool success, bytes memory data) = address(LibSignedSettlementProxy).call(cdWithParams);
        require(success, "readExtraParamsFullySigned call failed");
        (uint256 readDeadline, uint256 readR, uint256 readS, uint256 readV, uint256 lastByte) =
            abi.decode(data, (uint256, uint256, uint256, uint256, uint256));
        assertEq(readDeadline, deadline, "read deadline not as expected");
        assertEq(readR, r, "read r not as expected");
        assertEq(readS, s, "read s not as expected");
        assertEq(readV, v, "read v not as expected");
        assertEq(lastByte, cd.length, "lastByte not as expected");
    }

    function testExtraBytes(
        address[] calldata tokens,
        uint256[] calldata clearingPrices,
        GPv2Trade.Data[] calldata trades,
        GPv2Interaction.Data[][3] calldata interactions,
        bytes calldata extraBytes
    ) external {
        bytes memory cd = abi.encodeWithSelector(
            LibSignedSettlementProxy.readExtraBytes.selector, tokens, clearingPrices, trades, interactions
        );
        bytes memory cdWithExtraData = abi.encodePacked(cd, extraBytes);
        (bool success, bytes memory data) = address(LibSignedSettlementProxy).call(cdWithExtraData);
        require(success, "extraBytes call failed");
        (bytes memory extraBytesGot, uint256 lastByte) = abi.decode(data, (bytes, uint256));
        assertEq(extraBytesGot, extraBytes, "extraBytes not as expected");
        assertEq(lastByte, cd.length, "lastByte not as expected");
    }

    function testReadExtraParamsPartiallySigned(
        address[] calldata tokens,
        uint256[] calldata clearingPrices,
        GPv2Trade.Data[] calldata trades,
        GPv2Interaction.Data[][3] calldata interactions,
        uint256 r,
        uint256 s,
        uint8 v,
        uint256 deadline,
        uint256[3] memory offsets
    ) external {
        offsets[0] = interactions[0].length > 1 ? bound(offsets[0], 0, interactions[0].length - 1) : 0;
        offsets[1] = interactions[1].length > 1 ? bound(offsets[1], 0, interactions[1].length - 1) : 0;
        offsets[2] = interactions[2].length > 1 ? bound(offsets[2], 0, interactions[2].length - 1) : 0;
        bytes memory cd = abi.encodeWithSelector(
            LibSignedSettlementProxy.readExtraParamsPartiallySigned.selector,
            tokens,
            clearingPrices,
            trades,
            interactions
        );
        bytes memory cdWithParams = abi.encodePacked(cd, deadline, r, s, v, offsets);
        (bool success, bytes memory data) = address(LibSignedSettlementProxy).call(cdWithParams);
        require(success, "readExtraParamsPartiallySigned call failed");
        (uint256 deadline_, uint256 r_, uint256 s_, uint256 v_, uint256[3] memory offsets_, uint256 lastByte) =
            abi.decode(data, (uint256, uint256, uint256, uint256, uint256[3], uint256));
        assertEq(deadline_, deadline, "deadline not as expected");
        assertEq(r, r_, "r not as expected");
        assertEq(s, s_, "s not as expected");
        assertEq(v, v_, "v not as expected");
        assertEq(keccak256(abi.encode(offsets_)), keccak256(abi.encode(offsets)), "offsets not as expected");
        assertEq(lastByte, cd.length, "lastByte not as expected");
    }

    function testGetParamsDigestAndCalldataFullySigned(
        address[] calldata tokens,
        uint256[] calldata clearingPrices,
        GPv2Trade.Data[] calldata trades,
        GPv2Interaction.Data[][3] calldata interactions,
        uint256 r,
        uint256 s,
        uint8 v,
        uint256 deadline
    ) external {
        bytes memory encodedParams = abi.encode(tokens, clearingPrices, trades, interactions);
        bytes memory cd =
            abi.encodePacked(LibSignedSettlementProxy.getParamsDigestAndCalldataFullySigned.selector, encodedParams);
        bytes memory data;
        {
            bool success;
            bytes memory cdWithParams = abi.encodePacked(cd, deadline, r, s, v);
            (success, data) = address(LibSignedSettlementProxy).call(cdWithParams);
            require(success, "getParamsDigestAndCalldataFullySigned call failed");
        }

        (uint256 deadline_, uint256 r_, uint256 s_, uint256 v_, bytes32 digest_, bytes memory externalCd) =
            abi.decode(data, (uint256, uint256, uint256, uint256, bytes32, bytes));
        assertEq(deadline_, deadline, "deadline not as expected");
        assertEq(r_, r, "r not as expected");
        assertEq(s_, s, "s not as expected");
        assertEq(v_, v, "v not as expected");
        address solver = address(this);
        assertEq(
            digest_, keccak256(abi.encodePacked(encodedParams, abi.encode(deadline, solver))), "digest not as expected"
        );
        assertEq(
            keccak256(externalCd),
            keccak256(abi.encodePacked(GPv2Settlement.settle.selector, encodedParams)),
            "externalCd not as expected"
        );
    }

    function testGetParamsDigestAndCalldataPartiallySigned(
        address[] calldata tokens,
        uint256[] calldata clearingPrices,
        GPv2Trade.Data[] calldata trades,
        GPv2Interaction.Data[][3] calldata interactions,
        uint256 deadline,
        uint256 r,
        uint256 s,
        uint8 v,
        uint256[3] memory offsets
    ) external {
        {
            console.log("tokens, prices, trades, ", tokens.length, clearingPrices.length, trades.length);
            console.log("i0, i1, i2", interactions[0].length, interactions[1].length, interactions[2].length);
            offsets[0] = interactions[0].length >= 1 ? bound(offsets[0], 0, interactions[0].length - 1) : 0;
            offsets[1] = interactions[1].length >= 1 ? bound(offsets[1], 0, interactions[1].length - 1) : 0;
            offsets[2] = interactions[2].length >= 1 ? bound(offsets[2], 0, interactions[2].length - 1) : 0;
            console.log("o0, o1, o2", offsets[0], offsets[1], offsets[2]);
            console.log("deadline", deadline);
        }
        // vm.assume(offsets[0] > 0 && offsets[1] > 0 && offsets[2] > 0);

        bytes memory encodedParams = abi.encode(tokens, clearingPrices, trades, interactions);
        bytes memory encodedParams2;
        {
            GPv2Interaction.Data[][3] memory subsetInteractions;
            for (uint256 i = 0; i < 3; i++) {
                subsetInteractions[i] = new GPv2Interaction.Data[](offsets[i]);
                for (uint256 j = 0; j < offsets[i]; j++) {
                    subsetInteractions[i][j] = interactions[i][j];
                }
            }
            encodedParams2 = abi.encode(tokens, clearingPrices, trades, subsetInteractions);
            uint256 tokenOffset;
            uint256 clearingPricesOffset;
            uint256 tradesOffset;
            uint256 interactionsOffset;
            assembly {
                tokenOffset := mload(add(encodedParams, 0x20))
                clearingPricesOffset := mload(add(encodedParams, 0x40))
                tradesOffset := mload(add(encodedParams, 0x60))
                interactionsOffset := mload(add(encodedParams, 0x80))
            }
            console.log("offsets", tokenOffset, clearingPricesOffset, tradesOffset);
            console.log("interactions offset", interactionsOffset);
        }

        bytes memory cd =
            abi.encodePacked(LibSignedSettlementProxy.getParamsDigestAndCalldataPartiallySigned.selector, encodedParams);
        bytes memory data;
        {
            bool success;
            bytes memory cdWithParams = abi.encodePacked(cd, deadline, r, s, v, offsets);
            (success, data) = address(LibSignedSettlementProxy).call(cdWithParams);
            require(success, "getParamsDigestAndCalldataPartiallySigned call failed");
        }

        bytes32 digest;
        bytes memory cdWithParams2;
        {
            address solver = address(this);
            cdWithParams2 = abi.encodePacked(encodedParams2, abi.encode(deadline, solver));
            console.log("solver", solver, msg.sender);
            console.log("cdWithParams2.length", cdWithParams2.length);
            digest = keccak256(cdWithParams2);
        }

        (uint256 deadline_, uint256 r_, uint256 s_, uint256 v_, bytes32 digest_, bytes memory externalCd) =
            abi.decode(data, (uint256, uint256, uint256, uint256, bytes32, bytes));
        // assertEq(deadline_, deadline, "deadline not as expected");
        // assertEq(r_, r, "r not as expected");
        // assertEq(s_, s, "s not as expected");
        // assertEq(v_, v, "v not as expected");
        assertEq(digest_, digest, "digest not as expected");

        // bytes memory externalCd_ = externalCd;
        // console.log("externalCd.length", externalCd_.length);
        // // bytes memory encodedParams_ = encodedParams;
        // bytes memory encodedParams_ = cdWithParams2;
        // uint256 stepSize = 32;
        // uint256 diff = 0;
        // for (uint256 i = 0; i < ((externalCd_.length + 31) / stepSize); i += 1) {
        //     bytes32 hash1;
        //     bytes32 hash2;
        //     assembly {
        //         hash1 := keccak256(add(add(externalCd_, 0x20), mul(stepSize, i)), stepSize)
        //         hash2 := keccak256(add(add(encodedParams_, 0x20), mul(stepSize, i)), stepSize)
        //     }
        //     if (hash1 != hash2) {
        //         diff += 1;
        //         console.log(i);
        //         assembly {
        //             log0(add(add(externalCd_, 0x20), mul(stepSize, i)), stepSize)
        //             log0(add(add(encodedParams_, 0x20), mul(stepSize, i)), stepSize)
        //         }
        //     }
        // }
        // console.log("diff", diff);
        // assertEq(diff, 0, "diffs");

        // emit log_bytes(externalCd);
        // emit log_bytes(encodedParams);
        console.log("externalCd", externalCd.length, encodedParams.length + 4);
        assertEq(
            keccak256(externalCd),
            keccak256(abi.encodePacked(GPv2Settlement.settle.selector, encodedParams)),
            "externalCd not as expected"
        );
    }
}

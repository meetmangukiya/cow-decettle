# `cow-decettle`

`cow-decettle` is a system of contracts that allows solvers to deploy their 
subpools that will/can hold the full/partial bonding funds. The system owner/DAO
can bill the subpool funds in case it violates any of the agreed upon rules
and constraints.

## Development

### Build

```
$ forge build
```

### Test

```
$ forge test -vvv --rpc-url <rpc-url> --fork-block-number <fork-block-number>
```

### Format

```
$ forge fmt
```

### Deploy

```
$ export \
    EXIT_DELAY=604800 \
    COW_TOKEN="0xDEf1CA1fb7FBcDC777520aa7f396b4E015F497aB" \
    OWNER="0xffffffffffffffffffffffffffffffffffffffff" \
    SETTLEMENT="0x9008D19f58AAbD9eD0D60971565AA8510560ab41" \
    ATTESTOR="0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    ETHERSCAN_API_KEY="<API_KEY>"

$ forge script ./script/Deploy.s.sol \
    --broadcast --verify \
    --rpc-url "$ETH_RPC_URL" \
    --private-key "$PK"
```

### SignedSettlement signatures

The encoding, digest computation and signing is documented below as solidity code
using foundry's cheatcode `vm.sign`. This can be adapted to however the user wants
using libraries like `viem`, `ethers`, `alloy`, etc. in the language and library of
their choice.

> [!IMPORTANT]
> Solidity's `abi.encode` always encodes in strict mode[^1]. It is intentional, and the user
> **MUST** encode the data in strict mode[^1] as well.

#### Fully Signed

```solidity
bytes memory data = abi.encodePacked(
    abi.encode(tokens, clearingPrices, trades, interactions),
    abi.encode(deadline, solver)
);
bytes32 digest = keccak256(data);
(uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
```

#### Partially Signed

```solidity
bytes memory data = abi.encodePacked(
    abi.encode(tokens, clearingPrices, trades, partialInteractions),
    abi.encode(deadline, solver)
);
bytes32 digest = keccak256(data);
(uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
```

[^1]: [Solidity strict mode encoding](https://docs.soliditylang.org/en/latest/abi-spec.html#strict-encoding-mode)

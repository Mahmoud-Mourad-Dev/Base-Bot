# Off-chain packed payload for `ArbitrageExecutor`

The executor intentionally declares `execute()` with no Solidity parameters. The Rust
engine appends a packed payload directly after the four-byte selector:

```text
calldata = keccak256("execute()")[0:4] || header || hop[0] || ... || hop[n-1]
```

Every integer is unsigned and encoded in **big-endian (network) byte order**. Addresses
are their raw 20 bytes; there is no ABI padding.

## Header (61 bytes)

| Payload offset | Size | Field | Meaning |
|---:|---:|---|---|
| 0 | 1 | `version` | Must be `1`. |
| 1 | 1 | `flags` | Bit 0 unwraps realized WETH profit and sends native currency to `owner`; all other bits must be zero. |
| 2 | 1 | `hopCount` | Number of hops, `1..255`. |
| 3 | 2 | `routeBytes` | Must equal `hopCount * 57`. |
| 5 | 4 | `deadline` | Unix timestamp (`uint32`); zero disables the deadline check. |
| 9 | 20 | `startToken` | Inventory token sent to the first pair and expected back from the final pair. |
| 29 | 16 | `amountIn` | `uint128` quantity transferred to the first pair. |
| 45 | 16 | `minimumProfit` | `uint128` minimum increase in the executor's `startToken` balance. |

## Hop record (57 bytes each)

| Hop offset | Size | Field | Meaning |
|---:|---:|---|---|
| 0 | 20 | `pair` | Uniswap V2-compatible pair target. |
| 20 | 20 | `tokenOut` | Token expected from this pair. It is checked against `token0()` / `token1()`. |
| 40 | 16 | `amountOut` | Exact `uint128` output passed to `swap`. Compute it from reserves and the fork's fee model. |
| 56 | 1 | `direction` | `0`: request `amount0Out` and require current input = `token1`; `1`: request `amount1Out` and require current input = `token0`. |

The first input is transferred from the executor to `hop[0].pair`. Every non-final hop
sends its output directly to `hop[i + 1].pair`. The last hop sends output back to the
executor. Consequently, `hop[n - 1].tokenOut` must equal `startToken`, and adjacent hops
must agree on the token being forwarded.

The transaction reverts unless:

```text
endingBalance(startToken) >= startingBalance(startToken) + minimumProfit
```

This is inventory-funded execution. If a bundle contains external financing or repayment,
those transactions must leave the executor with `amountIn` before this call and account for
repayment when choosing `minimumProfit`.

## Rust encoding sketch

```rust
use alloy_primitives::{keccak256, Address};

fn push_u128_be(dst: &mut Vec<u8>, value: u128) {
    dst.extend_from_slice(&value.to_be_bytes());
}

fn build_execute_calldata(
    start_token: Address,
    amount_in: u128,
    min_profit: u128,
    deadline: u32,
    unwrap_profit: bool,
    hops: &[(Address, Address, u128, u8)], // pair, tokenOut, amountOut, direction
) -> Vec<u8> {
    assert!(!hops.is_empty() && hops.len() <= 255);
    let route_len = u16::try_from(hops.len() * 57).unwrap();

    let mut out = Vec::with_capacity(4 + 61 + route_len as usize);
    out.extend_from_slice(&keccak256(b"execute()")[..4]);
    out.push(1); // version
    out.push(u8::from(unwrap_profit));
    out.push(hops.len() as u8);
    out.extend_from_slice(&route_len.to_be_bytes());
    out.extend_from_slice(&deadline.to_be_bytes());
    out.extend_from_slice(start_token.as_slice());
    push_u128_be(&mut out, amount_in);
    push_u128_be(&mut out, min_profit);

    for (pair, token_out, amount_out, direction) in hops {
        assert!(*direction <= 1);
        out.extend_from_slice(pair.as_slice());
        out.extend_from_slice(token_out.as_slice());
        push_u128_be(&mut out, *amount_out);
        out.push(*direction);
    }
    out
}
```

`U256` is not needed for the packed amounts because version 1 deliberately limits them to
`uint128`. Before narrowing reserve math, the Rust engine must reject any value that does
not fit in 128 bits.

## Configuration slots

`setup(slot, value)` writes exactly storage slots 1 through 7. Values are opaque to the hot
path and can hold factory/router addresses (right-aligned in `bytes32`) or bot parameters.
Keeping policy metadata out of route execution avoids repeated storage loads. Pair/token
consistency is nevertheless validated on-chain for every hop.

## Operational constraints

- Use only V2 pairs implementing `token0()`, `token1()`, and
  `swap(uint256,uint256,address,bytes)` with empty callback data.
- Calculate `amountOut` against the state expected at bundle inclusion. Any stale reserve
  state should cause the pair or profitability guard to revert atomically.
- Fee-on-transfer, rebasing, and callback-dependent tokens require separate modeling and
  are not assumed by this format.
- Flag bit 0 is Base-specific because the hardcoded wrapped native address is
  `0x4200000000000000000000000000000000000006`.

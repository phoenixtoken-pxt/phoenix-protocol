# Audit scope — Phoenix Token (PXT) / ReturnDelta

This document defines the **in-scope surface** for a security review of the Phoenix Token Uniswap v4 ReturnDelta stack.

## In Scope

| | |
|--|--|
| **Protocol** | Phoenix Token (PXT) + Uniswap v4 ReturnDelta fee hook |
| **Chain target** | Base (EVM); pool fee `0` (fees via hook return-delta) |
| **In-scope root** | [`evm/src/`](evm/src/) |
| **Language** | Solidity `^0.8.26` (Foundry) |
| **Out of scope** | Uniswap v4 core / periphery, OpenZeppelin libraries, `web/`, Anvil tooling, and non-deployed ops scripts (see below) |

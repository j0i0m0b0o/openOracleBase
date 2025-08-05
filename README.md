# openOracle

openOracle is designed to be a trust-minimized way to get token prices that anyone can use. 

At its most basic level the oracle works by having a reporter submit both a limit bid and ask at the same price. Anyone can swap against these orders minus a small fee. If nobody takes either order in a certain amount of time, it is evidence of a good price that can be used for settlement. 


## Deployments

### Base

<table>
<tr>
<th>Contract</th>
<th>Deployment Address</th>
</tr>
<tr>
<td><a href="https://basescan.org/address/0x998cB9f953E8ED534e77d6D1B129ec4B52A7d11D#code">OpenOracle</a></td>
<td><code>0x998cB9f953E8ED534e77d6D1B129ec4B52A7d11D</code></td>
</tr>
<tr>
<td><a href="https://basescan.org/address/0xda28E0416966830A0c0954A3e44E2096a12c3315#code">openOracleBatcher</a></td>
<td><code>0xda28E0416966830A0c0954A3e44E2096a12c3315</code></td>
</tr>
<tr>
<td><a href="https://basescan.org/address/0xA5A6d54Cd934559D99A6aB53545AF47AeD9AD168#code">OracleSwapFacility</a></td>
<td><code>0xA5A6d54Cd934559D99A6aB53545AF47AeD9AD168</code></td>
</tr>
<tr>
<td><a href="https://basescan.org/address/0xd725f8839a5a48fac7867b0e56312c945a366221#code">openOracleDataProviderV3</a></td>
<td><code>0xd725f8839a5a48fac7867b0e56312c945a366221</code></td>
</tr>
</table>

## Docs

- [openOracle documentation](https://openprices.gitbook.io/openoracle-docs)

## Install

To install dependencies and compile contracts:

```bash
git clone 
forge install
forge build
```

### Foundry Tests

```bash
forge test
```

### Format

```bash
forge fmt
```

## Socials

- [Farcaster](https://farcaster.xyz/openoracle)
- [Discord](https://discord.gg/jQGeX6CAJB)
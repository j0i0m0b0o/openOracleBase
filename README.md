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
<td><a href="https://basescan.org/address/0x9339811f0F6deE122d2e97dd643c07991Aaa7a29#code">OpenOracle</a></td>
<td><code>0x998cB9f953E8ED534e77d6D1B129ec4B52A7d11D</code></td>
</tr>
<tr>
<td><a href="https://basescan.org/address/0x26bB116E62c9cE0b01aED25936f58fD1612f33Fe#code">openOracleBatcher</a></td>
<td><code>0xda28E0416966830A0c0954A3e44E2096a12c3315</code></td>
</tr>
<tr>
<td><a href="https://basescan.org/address/0xba007f80923554758e94516d749f99AF4F464465#code">OracleSwapFacility</a></td>
<td><code>0xA5A6d54Cd934559D99A6aB53545AF47AeD9AD168</code></td>
</tr>
<tr>
<td><a href="https://basescan.org/address/0x7d8ddF241A92Ec58d93BFfE56B991F9aa37dAFc2#code">openOracleDataProviderV3</a></td>
<td><code>0xd725f8839a5a48fac7867b0e56312c945a366221</code></td>
</tr>
</table>

## Docs

- [openOracle documentation](https://openprices.gitbook.io/openoracle-docs)

## Usage

### Install
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

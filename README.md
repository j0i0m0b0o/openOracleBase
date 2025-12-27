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
<td><a href="https://basescan.org/address/0x7caE6CCBd545Ad08f0Ea1105A978FEBBE2d1a752#code">OpenOracle</a></td>
<td><code>0x7caE6CCBd545Ad08f0Ea1105A978FEBBE2d1a752</code></td>
</tr>
<tr>
<td><a href="https://basescan.org/address/0xE23652de39374091B5495c737d414E76ba79bCb1#code">openOracleBatcher</a></td>
<td><code>0xE23652de39374091B5495c737d414E76ba79bCb1</code></td>
</tr>
<tr>
<td><a href="https://basescan.org/address/0xf7962733301A79D58FBA1747E0C0CaF40833e948#code">OracleSwapFacility</a></td>
<td><code>0xf7962733301A79D58FBA1747E0C0CaF40833e948</code></td>
</tr>
<tr>
<td><a href="https://basescan.org/address/0x4ccfb84f7EB35ee23c2e91f12e9CE4Ea2927d23C#code">openOracleDataProviderV3</a></td>
<td><code>0x4ccfb84f7EB35ee23c2e91f12e9CE4Ea2927d23C</code></td>
</tr>
</table>

### Ethereum L1

<table>
<tr>
<th>Contract</th>
<th>Deployment Address</th>
</tr>
<tr>
<td><a href="https://etherscan.io/address/0x7caE6CCBd545Ad08f0Ea1105A978FEBBE2d1a752#code">OpenOracle</a></td>
<td><code>0x7caE6CCBd545Ad08f0Ea1105A978FEBBE2d1a752</code></td>
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

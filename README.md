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
<td><a href="https://basescan.org/address/0xdcaa5082564F395819dC2F215716Fe901a1d0A23#code">OpenOracle</a></td>
<td><code>0xdcaa5082564F395819dC2F215716Fe901a1d0A23</code></td>
</tr>
<tr>
<td><a href="https://basescan.org/address/0x8FAF4b5E99fF6804BD259b2C44629A537a74a3ba#code">openOracleBatcher</a></td>
<td><code>0x8FAF4b5E99fF6804BD259b2C44629A537a74a3ba</code></td>
</tr>
<tr>
<td><a href="https://basescan.org/address/0xF7fA93DB7A5865530A20e816076da4760dFE4759#code">OracleSwapFacility</a></td>
<td><code>0xF7fA93DB7A5865530A20e816076da4760dFE4759</code></td>
</tr>
<tr>
<td><a href="https://basescan.org/address/0xa7FD2D2d35dF86437B26dCb41111F59787bD4192#code">openOracleDataProviderV3</a></td>
<td><code>0xa7FD2D2d35dF86437B26dCb41111F59787bD4192</code></td>
</tr>
</table>

### Ethereum L1

<table>
<tr>
<th>Contract</th>
<th>Deployment Address</th>
</tr>
<tr>
<td><a href="https://etherscan.io/address/0xdcaa5082564F395819dC2F215716Fe901a1d0A23#code">OpenOracle</a></td>
<td><code>0xdcaa5082564F395819dC2F215716Fe901a1d0A23</code></td>
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

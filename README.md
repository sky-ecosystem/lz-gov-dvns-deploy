# lz-dvns-deploy

Deploy library for Sky's LayerZero governance DVN wings (CCIP + multisig).

## Layout

- `src/SendSideDeployer.sol` — single-tx auditable deployer for the L1 CCIP DVN adapter + FeeLib. Holds adapter admin during bring-up; owner EOA drives configure/handoff.
- `src/RecvSideDeployer.sol` — single-tx auditable deployer for the remote-side CCIP adapter + DVN broadcasters (CCIP wing + multisig wing). Admin handoff happens inside the constructor.
- `src/LZDVNInit.sol` — spell-callable wiring helper (`wireCCIPDVN`) for configuring the CCIP DVN adapter + FeeLib for a new remote. Same body is reused by `SendSideDeployer.configure` at bring-up and by future governance spells adding new remotes post-handoff.

## Build

```bash
forge build
```

## Bring-up flow (per chain pair)

```
1. new SendSideDeployer(ccipRouter)        on L1
2. new RecvSideDeployer(chain)             on remote   (also revokes deployer admin)
3. sendDeployer.configure(remote, allowed) on L1       (remote.* come from step 2)
4. <smoke test through an allowed OApp>
5. sendDeployer.handOff(revokeOApps)       on L1       (moves roles to MCD_PAUSE_PROXY)
```

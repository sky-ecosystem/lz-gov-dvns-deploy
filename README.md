# lz-dvns-deploy

Deploy library for Sky's LayerZero governance DVN wings (CCIP + multisig).

## Scope

This version targets bring-up of governance bridging - deploying and wiring the DVN adapters up to the admin handoff, while pulling out reusable code to an init lib.
It deliberately does not expose functions for all ongoing operations such as updating the ACL/allowlist, adjusting fee config, or withdrawing accrued fees.

## Layout

- `src/SendSideDeployer.sol` — auditable deployer for the L1 CCIP DVN adapter + FeeLib. Holds adapter admin during bring-up; owner EOA drives configure/handoff.
- `src/RecvSideDeployer.sol` — single-tx auditable deployer for the remote-side CCIP adapter + DVN broadcasters (CCIP wing + multisig wing). Admin handoff happens inside the constructor.
- `src/LZDVNInit.sol` — spell-callable wiring helper (`wireCCIPDVN`) that configures the CCIP DVN adapter's routing for a new remote.

## Build

Install dependencies once after cloning (requires Node >= 18 and yarn, e.g. via `corepack enable`):

```bash
git submodule update --init
(cd lib/LayerZero-v2 && YARN_ENABLE_SCRIPTS=0 yarn install)
```

`YARN_ENABLE_SCRIPTS=0` skips all postinstall scripts — only the `.sol` sources are needed.

Then:

```bash
forge build
```

## Bring-up flow

### First chain pair (cold L1)

```
1. new SendSideDeployer(sendLib, allowedOApps) on L1
2. new RecvSideDeployer(chain)                 on remote   (also revokes deployer admin)
3. sendDeployer.configure(cfg)                 on L1       (cfg.remote* come from step 2)
4. <smoke test through an allowed OApp>
5. sendDeployer.handOff(revokeOApps)           on L1       (moves roles to MCD_PAUSE_PROXY)
```

### Subsequent pairs (L1 already handed off)

```
1. new RecvSideDeployer(chain)                 on remote
2. spell via MCD_PAUSE_PROXY: LZDVNInit.wireCCIPDVN(adapter, feeLib, cfg)
```

`SendSideDeployer` is not redeployed; `LZDVNInit.wireCCIPDVN` is the shared wiring path used by both flows.

### Funding the send-side adapter

The send-side `CCIPDVNAdapter` pays CCIP fees from its native balance. The first send finds it empty and reverts (`DVNAdapter_InsufficientBalance`) — seed it with a plain ETH transfer first. Subsequent sends self-replenish from accumulated SendLib fees.

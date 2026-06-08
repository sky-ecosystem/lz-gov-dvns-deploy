// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

// Vendored struct/interface declarations — this file is intended to be
// copied into downstream consumers (spells) that don't have the LZ-v2 deps.

// from @layerzerolabs/lz-evm-messagelib-v2/contracts/uln/interfaces/adapters/ICCIPDVNAdapter.sol (ICCIPDVNAdapter.DstConfigParam)
struct DstConfigParam {
    uint32  eid;
    uint16  multiplierBps;
    uint64  chainSelector;
    uint256 gas;
    bytes   peer;
}

// from @layerzerolabs/lz-evm-messagelib-v2/contracts/uln/dvn/adapters/DVNAdapterBase.sol
struct ReceiveLibParam {
    address sendLib;
    uint32  dstEid;
    bytes32 receiveLib;
}

interface CCIPDVNAdapterLike {
    function setDstConfig    (DstConfigParam[] calldata) external;
    function setReceiveLibs  (ReceiveLibParam[] calldata) external;
}

struct CCIPDVNCfg {
    uint32  remoteEid;  // raw v2 EID (e.g. 30184), not the %30000 form
    uint64  remoteChainSelector;
    address remoteCcipAdapter;
    address remoteCcipBroadcaster;
    address sendLib;
    uint16  multiplierBps;  // premium on the CCIP fee in bps; 1e4 = break-even
    uint256 gas;  // dest-chain exec gas for the CCIP attestation msg; keep <= CCIP maxPerMsgGasLimit
                  // for the destination lane: https://docs.chain.link/ccip/service-limits/evm
}

/// @notice Wires the CCIP DVN adapter routing for a new remote.
/// @dev Does not perform deployment sanity checks; these are assumed to be done off-chain.
library LZDVNInit {

    function wireCCIPDVN(address adapter, CCIPDVNCfg memory cfg) internal {
        CCIPDVNAdapterLike a = CCIPDVNAdapterLike(adapter);

        require(cfg.multiplierBps == 0 || cfg.multiplierBps >= 1e4, "LZDVNInit/bad-multiplier");

        DstConfigParam[] memory dstCfg = new DstConfigParam[](1);
        dstCfg[0] = DstConfigParam({
            eid:           cfg.remoteEid,
            multiplierBps: cfg.multiplierBps,
            chainSelector: cfg.remoteChainSelector,
            gas:           cfg.gas,
            peer:          abi.encode(cfg.remoteCcipAdapter)
        });
        a.setDstConfig(dstCfg);

        // Route CCIP attestations to the remote CCIP broadcaster
        ReceiveLibParam[] memory recvLibs = new ReceiveLibParam[](1);
        recvLibs[0] = ReceiveLibParam({
            sendLib:    cfg.sendLib,
            dstEid:     cfg.remoteEid,
            receiveLib: bytes32(uint256(uint160(cfg.remoteCcipBroadcaster)))
        });
        a.setReceiveLibs(recvLibs);
    }
}

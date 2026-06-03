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
    function workerFeeLib    () external view returns (address);
    function hasRole         (bytes32 role, address account) external view returns (bool);
}

struct CCIPDVNCfg {
    uint32    remoteEid;
    uint64    remoteChainSelector;
    address   remoteCcipAdapter;
    address   remoteCcipBroadcaster;
    address   sendUln302;
    uint16    multiplierBps;
    uint256   gas;
    address[] allowedOApps;
}

/// @notice Wires the CCIP DVN adapter routing for a new remote.
library LZDVNInit {

    bytes32 internal constant ALLOWLIST        = keccak256("ALLOWLIST");
    bytes32 internal constant MESSAGE_LIB_ROLE = keccak256("MESSAGE_LIB_ROLE");

    function wireCCIPDVN(address adapter, address feeLib, CCIPDVNCfg memory cfg) internal {
        CCIPDVNAdapterLike a = CCIPDVNAdapterLike(adapter);

        // Sanity checks
        require(a.workerFeeLib() == feeLib,                  "LZDVNInit/feelib-not-wired");
        require(a.hasRole(MESSAGE_LIB_ROLE, cfg.sendUln302), "LZDVNInit/sendlib-missing-role");
        for (uint256 i = 0; i < cfg.allowedOApps.length; ++i) {
            require(a.hasRole(ALLOWLIST, cfg.allowedOApps[i]), "LZDVNInit/oapp-not-allowlisted");
        }

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
            sendLib:    cfg.sendUln302,
            dstEid:     cfg.remoteEid,
            receiveLib: bytes32(uint256(uint160(cfg.remoteCcipBroadcaster)))
        });
        a.setReceiveLibs(recvLibs);
    }
}

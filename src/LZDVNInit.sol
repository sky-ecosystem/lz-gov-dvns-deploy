// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

// Vendored struct/interface declarations — this file is intended to be
// copied into downstream consumers (spells) that don't have the LZ-v2 deps.

struct CCIPDVNCfg {
    uint32    remoteEid;
    address   sendUln302;
    uint64    remoteChainSelector;
    address   remoteCcipAdapter;
    address   remoteCcipBroadcaster;
    uint16    multiplierBps;
    uint256   gas;
    uint128   floorMarginUSD;
    address[] allowedOApps;
}

struct ReceiveLibParam {
    address sendLib;
    uint32  dstEid;
    bytes32 receiveLib;
}

struct AdapterDstConfigParam {
    uint32  eid;
    uint16  multiplierBps;
    uint64  chainSelector;
    uint256 gas;
    bytes   peer;
}

struct FeeLibDstConfigParam {
    uint32  dstEid;
    uint128 floorMarginUSD;
}

interface CCIPDVNAdapterLike {
    function setDstConfig    (AdapterDstConfigParam[] calldata) external;
    function setReceiveLibs  (ReceiveLibParam[] calldata) external;
    function grantRole       (bytes32 role, address account) external;
}

interface CCIPDVNAdapterFeeLibLike {
    function setDstConfig(FeeLibDstConfigParam[] calldata) external;
}

/// @notice Spell-callable wiring helper for the CCIP DVN adapter and FeeLib.
///         Caller must hold ADMIN_ROLE + DEFAULT_ADMIN_ROLE on the adapter and
///         own the FeeLib (deployer at bring-up via SendSideDeployer.configure;
///         PauseProxy via spell after handoff).
library LZDVNInit {

    bytes32 internal constant ALLOWLIST = keccak256("ALLOWLIST");

    function wireCCIPDVN(
        address           adapter,
        address           feeLib,
        CCIPDVNCfg memory cfg
    ) internal {
        CCIPDVNAdapterLike a = CCIPDVNAdapterLike(adapter);

        {
            AdapterDstConfigParam[] memory params = new AdapterDstConfigParam[](1);
            params[0] = AdapterDstConfigParam({
                eid:           cfg.remoteEid,
                multiplierBps: cfg.multiplierBps,
                chainSelector: cfg.remoteChainSelector,
                gas:           cfg.gas,
                peer:          abi.encode(cfg.remoteCcipAdapter)
            });
            a.setDstConfig(params);
        }

        // receiveLibs redirect: CCIP-delivered packets land at the remote
        // broadcaster (decoded from this bytes32) instead of the real
        // ReceiveUln302, which fans verify out across the N replicas.
        {
            ReceiveLibParam[] memory params = new ReceiveLibParam[](1);
            params[0] = ReceiveLibParam({
                sendLib:    cfg.sendUln302,
                dstEid:     cfg.remoteEid,
                receiveLib: bytes32(uint256(uint160(cfg.remoteCcipBroadcaster)))
            });
            a.setReceiveLibs(params);
        }

        {
            FeeLibDstConfigParam[] memory params = new FeeLibDstConfigParam[](1);
            params[0] = FeeLibDstConfigParam({
                dstEid:         cfg.remoteEid,
                floorMarginUSD: cfg.floorMarginUSD
            });
            CCIPDVNAdapterFeeLibLike(feeLib).setDstConfig(params);
        }

        // First grantRole(ALLOWLIST, _) flips allowlistSize > 0 and makes the
        // ACL strict (deny-by-default).
        for (uint256 i = 0; i < cfg.allowedOApps.length; ++i) {
            a.grantRole(ALLOWLIST, cfg.allowedOApps[i]);
        }
    }
}

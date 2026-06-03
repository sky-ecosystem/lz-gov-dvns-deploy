// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import { CCIPDVNAdapter }       from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/dvn/adapters/CCIP/CCIPDVNAdapter.sol";
import { CCIPDVNAdapterFeeLib } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/dvn/adapters/CCIP/CCIPDVNAdapterFeeLib.sol";
import { LZDVNInit, CCIPDVNCfg } from "./LZDVNInit.sol";

interface ChainlogLike {
    function getAddress(bytes32) external view returns (address);
}

interface SendLibLike {
    function fees(address) external view returns (uint256);
}

contract SendSideDeployer {
    ChainlogLike internal constant chainlog   = ChainlogLike(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);
    address      internal constant CCIP_ROUTER = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;

    // Worker declares these `internal`, so we recompute them.
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant ADMIN_ROLE         = keccak256("ADMIN_ROLE");
    bytes32 internal constant ALLOWLIST          = keccak256("ALLOWLIST");
    bytes32 internal constant MESSAGE_LIB_ROLE   = keccak256("MESSAGE_LIB_ROLE");

    address              public immutable deployer;
    address              public immutable sendLib;
    CCIPDVNAdapter       public immutable adapter;
    CCIPDVNAdapterFeeLib public immutable feeLib;

    modifier onlyDeployer() {
        require(msg.sender == deployer, "SendSideDeployer/not-deployer");
        _;
    }

    constructor(address _sendLib, address[] memory allowedOApps) {
        deployer = msg.sender;
        sendLib  = _sendLib;

        // Upstream FeeLib is built for hardhat-deploy proxies. Calling
        // initialize() once on a freshly deployed instance seals the `proxied`
        // admin slot and runs __Ownable_init() with msg.sender as owner.
        feeLib = new CCIPDVNAdapterFeeLib();
        feeLib.initialize();

        address[] memory admins = new address[](1);
        admins[0] = address(this);
        adapter = new CCIPDVNAdapter(admins, CCIP_ROUTER);
        adapter.setWorkerFeeLib(address(feeLib));

        // MESSAGE_LIB_ROLE on the SendLib enables admin-triggered fee sweeps via Worker.withdrawFee.
        adapter.grantRole(MESSAGE_LIB_ROLE, _sendLib);

        // First grantRole(ALLOWLIST, _) flips allowlistSize > 0 and makes the ACL strict (deny-by-default).
        // The initial allowed Oapps may include a testing designated one, which can be revoked on handoff
        for (uint256 i = 0; i < allowedOApps.length; ++i) {
            adapter.grantRole(ALLOWLIST, allowedOApps[i]);
        }
    }

    function configure(CCIPDVNCfg calldata cfg) external onlyDeployer {
        LZDVNInit.wireCCIPDVN(address(adapter), address(feeLib), cfg);
    }

    // Recovers test funds to the deployer; call before handOff().
    // If called, any adapter pre-funding should come later.
    function withdrawFunds() external onlyDeployer {
        adapter.withdrawFee(sendLib, deployer, SendLibLike(sendLib).fees(address(adapter)));
        adapter.withdrawToken(address(0), deployer, address(adapter).balance);
    }

    function handOff(address[] calldata revokeOApps) external onlyDeployer {
        address pauseProxy = chainlog.getAddress("MCD_PAUSE_PROXY");

        // WARNING: if no OApp is left allowlisted, anyone can send through the CCIP adapter.
        for (uint256 i = 0; i < revokeOApps.length; ++i) {
            adapter.revokeRole(ALLOWLIST, revokeOApps[i]);
        }

        feeLib.transferOwnership(pauseProxy);

        adapter.grantRole(DEFAULT_ADMIN_ROLE, pauseProxy);
        adapter.grantRole(ADMIN_ROLE,         pauseProxy);

        adapter.revokeRole(ADMIN_ROLE,         address(this));
        adapter.revokeRole(DEFAULT_ADMIN_ROLE, address(this));
    }
}

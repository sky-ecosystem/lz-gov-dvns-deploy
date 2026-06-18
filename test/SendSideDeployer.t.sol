// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { CCIPDVNAdapter }       from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/dvn/adapters/CCIP/CCIPDVNAdapter.sol";
import { CCIPDVNAdapterFeeLib } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/dvn/adapters/CCIP/CCIPDVNAdapterFeeLib.sol";

import { SendSideDeployer }  from "../src/SendSideDeployer.sol";
import { LZDVNInit, CCIPDVNCfg } from "../src/LZDVNInit.sol";

interface ChainlogLike {
    function getAddress(bytes32) external view returns (address);
}

interface SendLibLike {
    function fees(address worker) external view returns (uint256);
}

// Mainnet-fork unit tests for the L1 send-side deployer. The test contract is
// the `deployer` (it runs `new SendSideDeployer`), so it can drive
// configure/withdrawFunds/handOff directly; a `stranger` exercises onlyDeployer.
contract SendSideTest is Test {
    using stdStorage for StdStorage;

    ChainlogLike constant CHAINLOG = ChainlogLike(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

    // Real mainnet LayerZero SendUln302 — used as the SendLib granted MESSAGE_LIB_ROLE.
    address constant L1_SEND_ULN_302     = 0xbB2Ea70C9E858123480642Cf96acbcCE1372dCe1;
    // Mainnet CCIP router — must match SendSideDeployer's hardcoded CCIP_ROUTER constant.
    address constant CCIP_ROUTER         = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;
    uint32  constant BASE_EID            = 30184;
    uint64  constant BASE_CHAIN_SELECTOR = 15971525489660198786;
    // A second remote (Arbitrum) added post-handoff to imitate a governance spell.
    uint32  constant ARB_EID             = 30110;
    uint64  constant ARB_CHAIN_SELECTOR  = 4949039107694359620;

    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant ADMIN_ROLE         = keccak256("ADMIN_ROLE");
    bytes32 constant ALLOWLIST          = keccak256("ALLOWLIST");
    bytes32 constant MESSAGE_LIB_ROLE   = keccak256("MESSAGE_LIB_ROLE");

    SendSideDeployer     dep;
    CCIPDVNAdapter       adapter;
    CCIPDVNAdapterFeeLib feeLib;

    address oapp              = makeAddr("oapp");
    address oapp2             = makeAddr("oapp2");
    address stranger          = makeAddr("stranger");
    address remoteAdapter     = makeAddr("remoteAdapter");
    address remoteBroadcaster = makeAddr("remoteBroadcaster");

    receive() external payable {} // to receive funds swept by withdrawFunds

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        address[] memory allowed = new address[](2);
        allowed[0] = oapp;
        allowed[1] = oapp2;
        dep     = new SendSideDeployer(L1_SEND_ULN_302, allowed);
        adapter = dep.adapter();
        feeLib  = dep.feeLib();
    }

    function _cfg() internal view returns (CCIPDVNCfg memory cfg) {
        cfg = CCIPDVNCfg({
            remoteEid:             BASE_EID,
            remoteChainSelector:   BASE_CHAIN_SELECTOR,
            remoteCcipAdapter:     remoteAdapter,
            remoteCcipBroadcaster: remoteBroadcaster,
            sendLib:               L1_SEND_ULN_302,
            multiplierBps:         0,  // 0 => fall back to the adapter's 10_000 break-even default
            gas:                   200_000
        });
    }

    function test_constructor() public view {
        assertEq(dep.deployer(), address(this));
        assertEq(dep.sendLib(),  L1_SEND_ULN_302);

        // Adapter points at the hardcoded mainnet CCIP router.
        assertEq(address(adapter.router()), CCIP_ROUTER);

        // FeeLib deployed, initialized (ownership burned) and wired into the adapter.
        assertEq(feeLib.owner(),         address(0));
        assertEq(adapter.workerFeeLib(), address(feeLib));

        // Default fee premium overridden from the adapter's hardcoded 12000 to break-even.
        assertEq(adapter.defaultMultiplierBps(), 10_000);

        // Deployer contract holds both admin roles during bring-up.
        assertTrue(adapter.hasRole(DEFAULT_ADMIN_ROLE, address(dep)));
        assertTrue(adapter.hasRole(ADMIN_ROLE,         address(dep)));

        // SendLib fee-sweep role + strict (deny-by-default) ACL with every OApp allowlisted.
        assertTrue(adapter.hasRole(MESSAGE_LIB_ROLE, L1_SEND_ULN_302));
        assertTrue(adapter.hasRole(ALLOWLIST,        oapp));
        assertTrue(adapter.hasRole(ALLOWLIST,        oapp2));
        assertEq(adapter.allowlistSize(), 2);
    }

    function test_constructorRevertsOnReInitFeeLib() public {
        // FeeLib was sealed by the constructor's initialize() — it can't be re-initialized.
        vm.expectRevert(bytes(""));
        feeLib.initialize();
    }

    function test_configure() public {
        dep.configure(_cfg());

        (uint64 chainSelector, uint16 multiplierBps, bytes memory peer, uint256 gas) =
            adapter.dstConfig(BASE_EID % 30000);
        assertEq(chainSelector, BASE_CHAIN_SELECTOR);
        assertEq(multiplierBps, 0);  // stored as-is; resolves to the 10_000 default at fee time
        assertEq(gas,           200_000);
        assertEq(peer,          abi.encode(remoteAdapter));

        assertEq(
            adapter.receiveLibs(L1_SEND_ULN_302, BASE_EID),
            bytes32(uint256(uint160(remoteBroadcaster)))
        );
    }

    function test_configureRevertsWhenNotDeployer() public {
        CCIPDVNCfg memory cfg = _cfg();
        vm.prank(stranger);
        vm.expectRevert("SendSideDeployer/not-deployer");
        dep.configure(cfg);
    }

    function test_configureRevertsOnWrongSendLib() public {
        CCIPDVNCfg memory cfg = _cfg();
        cfg.sendLib = makeAddr("otherSendLib");
        vm.expectRevert("SendSideDeployer/wrong-sendlib");
        dep.configure(cfg);
    }

    function test_configureRevertsOnUndercutMultiplier() public {
        // multiplierBps in (0, 1e4) would charge below the CCIP cost and drain the adapter.
        CCIPDVNCfg memory cfg = _cfg();
        cfg.multiplierBps = 9999;
        vm.expectRevert("LZDVNInit/bad-multiplier");
        dep.configure(cfg);
    }

    // End-to-end fee resolution against the real mainnet CCIP router: a lane wired
    // with multiplierBps == 0 inherits the constructor's 10_000 break-even default,
    // while an explicit multiplierBps overrides it. getFee() requires an allowlisted
    // sender and rejects non-empty options, so we quote as `oapp` with "".
    function test_getFeeResolvesMultiplier() public {
        CCIPDVNCfg memory cfg = _cfg();  // multiplierBps == 0

        dep.configure(cfg);
        uint256 feeZero = adapter.getFee(BASE_EID, 15, oapp, "");
        assertGt(feeZero, 0);

        // Explicit 10_000 must match the 0-fallback exactly (same break-even premium).
        cfg.multiplierBps = 10_000;
        dep.configure(cfg);
        uint256 feeTenK = adapter.getFee(BASE_EID, 15, oapp, "");
        assertEq(feeZero, feeTenK);

        // Explicit 12_000 overrides the default: +20% on the same underlying CCIP fee.
        cfg.multiplierBps = 12_000;
        dep.configure(cfg);
        uint256 feeTwelveK = adapter.getFee(BASE_EID, 15, oapp, "");
        assertEq(feeTwelveK * 10_000, feeTenK * 12_000);
    }

    function test_withdrawFunds() public {
        vm.deal(address(adapter), 1 ether);
        uint256 before = address(this).balance;

        dep.withdrawFunds();

        // Native balance is fully swept to the deployer; no accrued SendLib fees for a fresh adapter.
        assertEq(address(adapter).balance, 0);
        assertEq(address(this).balance,    before + 1 ether);
    }

    // Exercises the accrued-fees branch against the real SendUln302
    function test_withdrawFundsRecoversSendLibFeesAndBalance() public {
        uint256 feeCredit = 0.3 ether;

        // 1) credit the adapter (the worker) in the real SendUln302 fee ledger
        stdstore.target(L1_SEND_ULN_302).sig("fees(address)")
            .with_key(address(adapter)).checked_write(feeCredit);
        assertEq(SendLibLike(L1_SEND_ULN_302).fees(address(adapter)), feeCredit);
        // 2) ensure the lib holds enough native to pay the withdrawal
        vm.deal(L1_SEND_ULN_302, L1_SEND_ULN_302.balance + feeCredit);

        // adapter's own native balance (the leftover prefund)
        vm.deal(address(adapter), 1 ether);

        uint256 before = address(this).balance;
        dep.withdrawFunds();

        // SendLib credit debited, adapter native swept, both pools landed on the deployer.
        assertEq(SendLibLike(L1_SEND_ULN_302).fees(address(adapter)), 0);
        assertEq(address(adapter).balance, 0);
        assertEq(address(this).balance, before + 1 ether + feeCredit);
    }

    function test_withdrawFundsRevertsWhenNotDeployer() public {
        vm.prank(stranger);
        vm.expectRevert("SendSideDeployer/not-deployer");
        dep.withdrawFunds();
    }

    function test_handOff() public {
        dep.configure(_cfg());

        address pauseProxy = CHAINLOG.getAddress("MCD_PAUSE_PROXY");

        address[] memory revokeOApps = new address[](2);
        revokeOApps[0] = oapp;
        revokeOApps[1] = oapp2;
        dep.handOff(revokeOApps);

        // Roles move to the pause proxy.
        assertTrue(adapter.hasRole(DEFAULT_ADMIN_ROLE, pauseProxy));
        assertTrue(adapter.hasRole(ADMIN_ROLE,         pauseProxy));

        // Deployer contract is fully de-roled.
        assertFalse(adapter.hasRole(DEFAULT_ADMIN_ROLE, address(dep)));
        assertFalse(adapter.hasRole(ADMIN_ROLE,         address(dep)));

        // Revoked OApps are no longer allowlisted.
        assertFalse(adapter.hasRole(ALLOWLIST, oapp));
        assertFalse(adapter.hasRole(ALLOWLIST, oapp2));
        assertEq(adapter.allowlistSize(), 0);
    }

    function test_handOffRevertsWhenNotDeployer() public {
        address[] memory revokeOApps = new address[](0);
        vm.prank(stranger);
        vm.expectRevert("SendSideDeployer/not-deployer");
        dep.handOff(revokeOApps);
    }

    function test_configureRevertsAfterHandOff() public {
        address[] memory revokeOApps = new address[](0);
        dep.handOff(revokeOApps);

        // Deployer lost ADMIN_ROLE, so the adapter's setDstConfig rejects further configuration.
        CCIPDVNCfg memory cfg = _cfg();
        vm.expectRevert(bytes(string.concat(
            "AccessControl: account ",
            vm.toLowercase(vm.toString(address(dep))),
            " is missing role ",
            vm.toString(ADMIN_ROLE)
        )));
        dep.configure(cfg);
    }

    // Stands in for a governance spell wiring a new remote via the shared LZDVNInit
    // helper. Callers prank the pause proxy so the inlined adapter calls carry its
    // admin roles as msg.sender — the part that matters here — rather than literally
    // reproducing the pause proxy's delegatecall.
    function castAddRoute(CCIPDVNCfg memory cfg) public {
        LZDVNInit.wireCCIPDVN(address(adapter), cfg);
    }

    // The README's "subsequent pairs" flow: after handoff, a governance spell adds a
    // second remote through the pause proxy, reusing the same LZDVNInit wiring path.
    function test_addRouteAfterHandOffViaPauseProxy() public {
        // Bring-up: wire the first remote (Base), then hand off — keeping the
        // production OApp allowlisted and revoking only the test OApp.
        dep.configure(_cfg());
        address[] memory revokeOApps = new address[](1);
        revokeOApps[0] = oapp2;
        dep.handOff(revokeOApps);

        address pauseProxy = CHAINLOG.getAddress("MCD_PAUSE_PROXY");

        // Spell config for a new remote (Arbitrum), reusing the L1 SendLib.
        address arbAdapter     = makeAddr("arbAdapter");
        address arbBroadcaster = makeAddr("arbBroadcaster");
        CCIPDVNCfg memory cfg = CCIPDVNCfg({
            remoteEid:             ARB_EID,
            remoteChainSelector:   ARB_CHAIN_SELECTOR,
            remoteCcipAdapter:     arbAdapter,
            remoteCcipBroadcaster: arbBroadcaster,
            sendLib:               L1_SEND_ULN_302,
            multiplierBps:         12000,
            gas:                   300_000
        });

        // The pause proxy (now the adapter admin) runs the spell.
        vm.startPrank(pauseProxy);
        castAddRoute(cfg);
        vm.stopPrank();

        // New Arbitrum route is wired by the pause proxy...
        (uint64 cs, uint16 mb, bytes memory peer, uint256 g) = adapter.dstConfig(ARB_EID % 30000);
        assertEq(cs,   ARB_CHAIN_SELECTOR);
        assertEq(mb,   12000);
        assertEq(g,    300_000);
        assertEq(peer, abi.encode(arbAdapter));
        assertEq(
            adapter.receiveLibs(L1_SEND_ULN_302, ARB_EID),
            bytes32(uint256(uint160(arbBroadcaster)))
        );

        // The original Base route still coexists.
        (uint64 baseCs,,,) = adapter.dstConfig(BASE_EID % 30000);
        assertEq(baseCs, BASE_CHAIN_SELECTOR);
    }

}

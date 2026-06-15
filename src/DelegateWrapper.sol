// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import { ILayerZeroEndpointV2, Origin } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

// A LayerZero inbound nonce must be verified before any later nonce can execute, so one
// unverifiable message stalls the whole queue. When the delegate is remote governance, the
// fix can't get through — it's a bridge message trapped behind the same hole. A local
// multisig (`bud`) acts directly instead. Examples of where this helps:
//
//   - DVN config mismatch: the send-side committed DVNs don't satisfy the receive-side
//     set, so the message can never verify.
//   - Receive library mismatch: the receive-side library is different than the one used
//     by the DVNS (for any reason).
//   - Queue backlog: a large verified backlog makes `inboundNonce()` too gas-heavy to
//     compute.
//   - DVN temporal censorship: a required DVN withholds attestation for one nonce for some reason.

contract DelegateWrapper {
    mapping(address => uint256) public wards;
    mapping(address => uint256) public buds;

    ILayerZeroEndpointV2 public immutable endpoint;

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Kiss(address indexed usr);
    event Diss(address indexed usr);

    modifier auth {
        require(wards[msg.sender] == 1, "DelegateWrapper/not-authorized");
        _;
    }

    modifier budOrWard {
        require(buds[msg.sender] == 1 || wards[msg.sender] == 1, "DelegateWrapper/not-bud-or-ward");
        _;
    }

    constructor(address _endpoint, address[] memory _buds) {
        endpoint = ILayerZeroEndpointV2(_endpoint);

        wards[msg.sender] = 1;
        emit Rely(msg.sender);

        for (uint256 i = 0; i < _buds.length; i++) {
            buds[_buds[i]] = 1;
            emit Kiss(_buds[i]);
        }
    }

    function rely(address usr) external auth {
        wards[usr] = 1;
        emit Rely(usr);
    }

    function deny(address usr) external auth {
        wards[usr] = 0;
        emit Deny(usr);
    }

    function kiss(address usr) external auth {
        buds[usr] = 1;
        emit Kiss(usr);
    }

    function diss(address usr) external auth {
        buds[usr] = 0;
        emit Diss(usr);
    }

    /// @notice Guardian or ward: skip an unverified inbound nonce.
    function skip(address _oapp, uint32 _srcEid, bytes32 _sender, uint64 _nonce) external budOrWard {
        endpoint.skip(_oapp, _srcEid, _sender, _nonce);
    }

    /// @notice Guardian or ward: nil a verified inbound message, blocking execution until re-verified.
    function nilify(address _oapp, uint32 _srcEid, bytes32 _sender, uint64 _nonce, bytes32 _payloadHash) external budOrWard {
        endpoint.nilify(_oapp, _srcEid, _sender, _nonce, _payloadHash);
    }

    /// @notice Guardian or ward: permanently burn a verified inbound message.
    function burn(address _oapp, uint32 _srcEid, bytes32 _sender, uint64 _nonce, bytes32 _payloadHash) external budOrWard {
        endpoint.burn(_oapp, _srcEid, _sender, _nonce, _payloadHash);
    }

    /// @notice Guardian or ward: consume a verified inbound message without delivering it to the OApp.
    function clear(address _oapp, Origin calldata _origin, bytes32 _guid, bytes calldata _message) external budOrWard {
        endpoint.clear(_oapp, _origin, _guid, _message);
    }

    /// @notice Wards-only: forward any other delegate call to the endpoint, bubbling up return/revert data.
    fallback() external auth {
        (bool success, bytes memory ret) = address(endpoint).call(msg.data);
        if (!success) {
            assembly { revert(add(ret, 0x20), mload(ret)) }
        }
        assembly { return(add(ret, 0x20), mload(ret)) }
    }
}

// SPDX-License-Identifier: Beerware
pragma solidity ^0.8.13;

import "openzeppelin/contracts/token/ERC20/ERC20.sol";
import "openzeppelin/contracts/utils/cryptography/ECDSA.sol";

struct OwnerBalance {
    address owner;
    uint96 balance;
}

struct TransactionData {
    // split callType to uint16 & uint16 flag? whether to keep txn record or not
    uint32 callType; // call = 0, delegatecall = 1, ..
    uint64 expiry; // timestamp
    address target;
    uint256 value;
    bytes data;
}

struct ExecutionRecord {
    uint64 block;
    uint64 timestamp;
    uint64 gasUsed;
    bool success;
}

// TODO: do not inherit from erc20 - just reimpl necessary features for smaller size
contract ERC420 is ERC20 {
    uint256 public quroum;

    mapping(bytes32 => ExecutionRecord) public executionHistory;

    constructor(
        uint256 initQuorum,
        OwnerBalance[] memory initBalances
    ) ERC20("Blaze", "BLZ") {
        quorum = initQuorum;

        for (uint256 i = 0; i < initBalances.length; i++) {
            OwnerBalance memory ownerBalance = initBalances[i];
            _mint(ownerBalance.owner, ownerBalance.balance);
        }

        require(totalSupply() >= initQuorum, "total supply cannot reach quorum");
    }

    function _recover(TransactionData calldata txn) internal {
        // for recoery, the calldata is an array of OwnerBalances to redistribute
        require(txn.data.length % 32 == 0, "distribution addresses")
    }

    function _getSigningPower(bytes32[] calldata signatures) internal returns (uint256 signingPower) {
        // if the contract owns some tokens, signing is automatic
        if (signatures.length == 0) {
            // NOTE: if contract has quroum so any msg.sender could have 0 balance to sign
            // need to prevent contract from gaining quroum?
            signingPower = balanceOf(msg.sender);
        } else {
            require(signatures.length % 2 == 0, "got partial signature");

            address prevSigner = address(0);
            for (uint256 i = 0; i < signatures.length; i += 2) {
                bytes32 r = signatures[i];
                bytes32 vs = signatures[i + 1];
                address signer = ECDSA.recover(hash, r, vs);
                require(signer > prevSigner, "signers must have ascending order");
                // TODO: uncomment for prod, comment for testing only to avoid stupid sort...
                // prevSigner = signer;
                uint256 balance = balanceOf(signer);
                require(balance > 0, "signer has no signing power");
                signingPower += balance;
            }
        }
    }

    // TODO: should this contract prevent calls to itself, or specific token transfers??

    function execute(
        TransactionData calldata txn,
        // TODO: should create an overload without sigs param?
        bytes32[] calldata signatures
    ) external payable returns (bool success, bytes memory res) {
        // TODO: should expiry be checked even if signatures.length == 0?
        require(txn.expiry > block.timestamp, "transaction expired");

        // TODO: how to recover? transferFrom..? approve, or other method?
        // maybe: 
        // transferFrom() can transfer as many as block.timestamp - approvalTimestamps[from][to] tokens
        // (as long as it is not 0)
        // but

        // or... as soon as people want to start recovery
        // they can start an inflation timer that is based
        // on how many tokens they burned
        // so if 3 people with 1*days worth of tokens want to inflate
        // they burn 3 days worth tokens, they cannot sign for 3 days
        // until eventually they get 2x tokens minted back?
        // or actually just calculate the remainder needed to reach quorum
        // that's the amount of days needed to inflate over

        // TODO: encode contract address, chainid, ..?
        // (also allow them to be 0? same with expiry?)
        bytes32 hash = keccak256(abi.encode(txn));

        uint256 signingPower = _getSigningPower(signature);
        if (txn.callType == 2) {
            // QUORUM * 1e6 / signingPower is the amount of seconds to delay
            // so 1 day = 24 hours * 60 minutes * 60 seconds = 86400
            // and if signing power is let's say, 1 hour it is 86400 / 3600 = 24x times the quroum
            // meaning 1 day x 24 = 24 days
            // let's say signing power is 23 days, multiplier is 86400 / 82800 = 1.043
            // so 1 day x 1.043
            // note if signingPower is 0 then division by 0
            uint256 timelockMultiplier = quroum * 1e16 / signingPower;
            require(signingPower + balancOf(txn.target) >= quroum, "recovery quorum unmet");

            // if quorum is unmet, start a quroum * seconds period
            // after which you can recover tokens of txn.target
            // recovery is callType 2
            _recover(txn, timelockMultiplier);
            return (success, res);
        }

        require(signingPower >= quroum, "quorum unmet");

        // TODO: consider gas? delegate calls?

        ExecutionRecord memory record = ExecutionRecord({
            block: uint64(block.number),
            timestamp: uint64(block.timestamp),
            gasUsed: 0,
            success: false
        });

        // NOTE: callee can consume remaining gas by returning large memory amounts...
        // need to ensure executionHistory record is created before calling, maybe should give up on the gas used
        // and shave a few gas on the second storage write... (although slot is warm so no biggie)
        executionHistory[hash] = record;

        // gasUsed only measures the call itself, not the quorum calculation
        uint256 gasBefore = gasleft();

        if (txn.callType == 0) {
            require(
                txn.value >= address(this).balance,
                "insufficient eth balance"
            );
            (success, res) = txn.target.call{value: txn.value}(txn.data);
        } else if (txn.callType == 1) {
            // TODO: require 100% quroum (signingPower == totalSupply()) for delegatecall?
            require(
                uint256(txn.value) == msg.value,
                "delegatecall expects txn.value to match msg.value"
            );
            (success, res) = txn.target.delegatecall(txn.data);
        } else {
            // TODO: do nothing?
        }

        record.gasUsed = uint64(gasBefore - gasleft());
        record.success = success;
        executionHistory[hash] = record;

        return (success, res);
    }
}

// SPDX-License-Identifier: Beerware
pragma solidity ^0.8.13;

import "openzeppelin/contracts/token/ERC20/ERC20.sol";
import "openzeppelin/contracts/utils/cryptography/ECDSA.sol";

struct OwnerBalance {
    address owner;
    uint96 balance;
}

struct TransactionData {
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
    uint256 public immutable QUORUM;

    mapping(bytes32 => ExecutionRecord) public executionHistory;

    constructor(
        uint256 quorum,
        OwnerBalance[] memory initBalances
    ) ERC20("Blaze", "BLZ") {
        QUORUM = quorum;

        for (uint256 i = 0; i < initBalances.length; i++) {
            OwnerBalance memory ownerBalance = initBalances[i];
            _mint(ownerBalance.owner, ownerBalance.balance);
        }

        require(totalSupply() >= QUORUM, "total supply cannot reach quorum");
    }

    // TODO: should this contract prevent calls to itself, or specific token transfers??

    function execute(
        TransactionData calldata txn,
        bytes32[] calldata signatures
    ) external payable returns (bool success, bytes memory res) {
        require(txn.expiry > block.timestamp, "transaction expired");
        // TODO: encode contract address, chainid, ..?
        // (also allow them to be 0? same with expiry?)
        bytes32 hash = keccak256(abi.encode(txn));

        uint256 signingPower = 0;
        address prevSigner = address(0);

        require(signatures.length % 2 == 0, "got partial signature");
        for (uint256 i = 0; i < signatures.length; i += 2) {
            bytes32 r = signatures[i];
            bytes32 vs = signatures[i + 1];
            address signer = ECDSA.recover(hash, r, vs);
            require(signer > prevSigner, "signers must have ascending order");
            signingPower += balanceOf(signer);
        }

        // require(signingPower >= QUORUM, "quorum unmet");
        if (signingPower < QUORUM)
            return (false, hex"");

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

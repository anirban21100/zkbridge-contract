// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "./Hasher.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import "https://github.com/ernestognw/openzeppelin-contracts/blob/lib-869-bump-all-solidity-pragmas/contracts/token/ERC20/IERC20.sol";

// Interface for SNAKR verifier contract
interface IVerifier {
    function verifyProof(
        uint256[2] memory a,
        uint256[2][2] memory b,
        uint256[2] memory c,
        uint256[3] memory input
    ) external;
}

contract BridgeCore is CCIPReceiver {
    // struct to store deposit details
    // // emit Deposit(newRoot, hashPairings, hashDirections, _destChain, 0);
    struct depositStruct {
        uint256 rrotHash;
        uint256[10] hashPairings;
        uint256[10] hashDirections;
    }
    // Mapping relaTED TO  contracts
    mapping(uint64 => address) public chainIdToContractMapping;
    // Mapping CCIP ChainId to Contract
    mapping(uint64 => address) public ccipChainIdToContractMapping;
    // Mapping to store address to deposit details
    mapping(address => depositStruct) public despositMapping;
    uint64 chainId;
    uint256 ccipChainId;
    // verifier address
    address verifier;
    // mimic sponge hash generator contract address
    Hasher hasher;
    // ERC20 token
    address tokenAddress;
    // max allowed tree level. For now -> 10
    uint8 public treeLevel = 10;
    uint256 public denomination = 0.1 ether;
    uint256 public nextLeafIdx = 0;
    mapping(uint256 => bool) public roots;
    mapping(uint8 => uint256) lastLevelHash;
    // mapping to store nullifier hashes
    mapping(uint256 => bool) public nullifierHashes;
    // mapping to store deposit commitments
    mapping(uint256 => bool) public commitments;
    // precomputed hash of merkle tree
    uint256[10] levelDefaults = [
        23183772226880328093887215408966704399401918833188238128725944610428185466379,
        24000819369602093814416139508614852491908395579435466932859056804037806454973,
        90767735163385213280029221395007952082767922246267858237072012090673396196740,
        36838446922933702266161394000006956756061899673576454513992013853093276527813,
        68942419351509126448570740374747181965696714458775214939345221885282113404505,
        50082386515045053504076326033442809551011315580267173564563197889162423619623,
        73182421758286469310850848737411980736456210038565066977682644585724928397862,
        60176431197461170637692882955627917456800648458772472331451918908568455016445,
        105740430515862457360623134126179561153993738774115400861400649215360807197726,
        76840483767501885884368002925517179365815019383466879774586151314479309584255
    ];

    IRouterClient private s_router;
    LinkTokenInterface private s_linkToken;

    event SuccessfulDeposit(
        uint256 indexed uniqueKey,
        uint256 commitment,
        uint256 root,
        uint256[10] hashPairings,
        uint8[10] pairDirection
    );

    event InitiateDeposit(
        uint256 indexed uniqueKey,
        string dType,
        uint256 destinationChain,
        uint256 commitment
    );
    event Withdrawal(address to, uint256 nullifierHash);

    constructor(
        address _hasher,
        address _verifier,
        uint64 _chainId,
        uint64 _ccipChainId,
        address _send_router,
        address _receive_router,
        address _link,
        address _tokenAddress
    ) CCIPReceiver(_receive_router) {
        hasher = Hasher(_hasher);
        verifier = _verifier;
        chainId = _chainId;
        ccipChainId = _ccipChainId;
        s_router = IRouterClient(_send_router);
        s_linkToken = LinkTokenInterface(_link);
        tokenAddress = _tokenAddress;
    }

    receive() external payable {}

    function addContract(uint64 _chainId, address _contractAddress) public {
        chainIdToContractMapping[_chainId] = _contractAddress;
    }

    function addCCIPContract(uint64 _chainId, address _contractAddress) public {
        ccipChainIdToContractMapping[_chainId] = _contractAddress;
    }

    function _relayerDeposit(uint256 _commitment, uint64 _destChain) public {
        // emit Deposit(block.timestamp, _destChain, _commitment);
    }

    function _selfDeposit(uint256 _key, uint256 _commitment)
        public
        returns (
            uint256,
            uint256[10] memory,
            uint8[10] memory
        )
    {
        // require(msg.value == denomination, "incorrect-amount");
        require(!commitments[_commitment], "existing-commitment");
        require(nextLeafIdx < 2**treeLevel, "tree-full");

        uint256 newRoot;
        uint256[10] memory hashPairings;
        uint8[10] memory hashDirections;

        uint256 currentIdx = nextLeafIdx;
        uint256 currentHash = _commitment;

        uint256 left;
        uint256 right;
        uint256[2] memory ins;
        uint256 _tempCommitment = _commitment;
        uint256 tempKey = _key;
        for (uint8 i = 0; i < treeLevel; i++) {
            if (currentIdx % 2 == 0) {
                left = currentHash;
                right = levelDefaults[i];
                hashPairings[i] = levelDefaults[i];
                hashDirections[i] = 0;
            } else {
                left = lastLevelHash[i];
                right = currentHash;
                hashPairings[i] = lastLevelHash[i];
                hashDirections[i] = 1;
            }
            lastLevelHash[i] = currentHash;

            ins[0] = left;
            ins[1] = right;

            uint256 h = hasher.MiMC5Sponge{gas: 150000}(ins, _tempCommitment);

            currentHash = h;
            currentIdx = currentIdx / 2;
        }
        uint256 tempCommitment = _commitment;
        newRoot = currentHash;
        roots[newRoot] = true;
        nextLeafIdx += 1;

        commitments[tempCommitment] = true;
       
        emit SuccessfulDeposit(
            tempKey,
            tempCommitment,
            newRoot,
            hashPairings,
            hashDirections
        );
        return (newRoot, hashPairings, hashDirections);
    }

    function _ccipDeposit(
        uint256 _commitment,
        uint64 _srcChainId,
        uint64 _destChainId
    ) public {
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(ccipChainIdToContractMapping[_destChainId]),
            data: abi.encodeWithSignature("_selfDeposit(uint256)", _commitment),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                // Additional arguments, setting gas limit and non-strict sequencing mode
                Client.EVMExtraArgsV1({gasLimit: 1000_000, strict: false})
            ),
            feeToken: address(0)
        });

        uint256 fee = IRouterClient(i_router).getFee(_destChainId, message);

        bytes32 messageId;
        messageId = IRouterClient(i_router).ccipSend{value: fee}(
            _destChainId,
            message
        );
    }

    uint256 public funcall;

    function deposit(
        uint256 _commitment,
        uint64 _srcChain,
        uint64 _destChain,
        bool _self,
        bool _viaCCIP,
        bool _viaRelayer
    ) external {
        string memory _dType;
        uint256 root;
        uint256[10] memory hashPairings;
        uint8[10] memory pairDirection;
        // deposits and withdrawl from same contract
        if (_self) {
            funcall = 1;
            _dType = "SELF";

            (root, hashPairings, pairDirection) = _selfDeposit(block.timestamp, _commitment);
        }
        // deposit came from a different contract via ccip
        if (_viaCCIP) {
            funcall = 2;
            _dType = "CCIP";
            _ccipDeposit(_commitment, _srcChain, _destChain);
            emit InitiateDeposit(block.timestamp, _dType, _destChain, _commitment);
        }
        // depost came from a different chain via relayer
        if (_viaRelayer) {
            funcall = 3;
            _dType = "RELAY";
            _relayerDeposit(_commitment, _destChain);
            emit InitiateDeposit(block.timestamp, _dType, _destChain, _commitment);
        }
        IERC20(tokenAddress).transferFrom(msg.sender, address(this), denomination);
    }

    function withdraw(
        uint256[2] memory a,
        uint256[2][2] memory b,
        uint256[2] memory c,
        uint256[2] memory input
    ) external payable {
        uint256 _root = input[0];
        uint256 _nullifierHash = input[1];

        require(!nullifierHashes[_nullifierHash], "already-spent");
        require(roots[_root], "not-root");

        uint256 _addr = uint256(uint160(msg.sender));

        (bool verifyOK, ) = verifier.call(
            abi.encodeCall(
                IVerifier.verifyProof,
                (a, b, c, [_root, _nullifierHash, _addr])
            )
        );

        require(verifyOK, "invalid-proof");

        nullifierHashes[_nullifierHash] = true;
        // address payable target = payable(msg.sender);

        // (bool ok, ) = target.call{value: denomination}("");

        // require(ok, "payment-failed");
        IERC20(tokenAddress).transfer(msg.sender, denomination);
        emit Withdrawal(msg.sender, _nullifierHash);
    }

    function _ccipReceive(Client.Any2EVMMessage memory message)
        internal
        override
    {
        address(this).call(message.data);

        // s_lastReceivedMessageId = any2EvmMessage.messageId; // fetch the messageId
        // s_lastReceivedText = abi.decode(any2EvmMessage.data, (string)); // abi-decoding of the sent text
        // emit MessageReceived(
        //     any2EvmMessage.messageId,
        //     any2EvmMessage.sourceChainSelector, // fetch the source chain identifier (aka selector)
        //     abi.decode(any2EvmMessage.sender, (address)), // abi-decoding of the sender address,
        //     abi.decode(any2EvmMessage.data, (string))
        // );
    }
}

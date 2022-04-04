// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import { ERC165CheckerUpgradeable as ERC165Checker } from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165CheckerUpgradeable.sol";

import { ECDSAUpgradeable as ECDSA } from "@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/MerkleProofUpgradeable.sol";

// Using a draft contract isn't great, as is using EIP712 which is technically still under "Review"
// EIP712 was created over 4 years ago and has undegone multiple versions since
// Metamask supports multiple various versions of EIP712 and is committed to maintaing "v3" and "v4" support
// The only distinction between the two is the support for arrays/structs in structs, which aren't used by this contract
// Therefore, this usage is fine, now and in the long-term, as long as one of those two versions is indefinitely supported
import "@openzeppelin/contracts-upgradeable/utils/cryptography/draft-EIP712Upgradeable.sol";

import "../interfaces/frabric/IBond.sol";
import "../interfaces/thread/IThreadDeployer.sol";
import "../interfaces/thread/IThread.sol";

import "../dao/FrabricDAO.sol";

import "../interfaces/frabric/IFrabric.sol";

contract Frabric is EIP712Upgradeable, FrabricDAO, IFrabricInitializable {
  using ERC165Checker for address;

  mapping(address => ParticipantType) public override participant;

  address public override bond;
  address public override threadDeployer;
  address public override kyc;

  struct Participants {
    ParticipantType pType;
    bool passed;
    bytes32 participants;
  }
  // The proposal structs are private as their events are easily grabbed and contain the needed information
  mapping(uint256 => Participants) private _participants;

  mapping(address => GovernorStatus) public override governor;

  struct RemoveBondProposal {
    address governor;
    bool slash;
    uint256 amount;
  }
  mapping(uint256 => RemoveBondProposal) private _removeBonds;

  struct ThreadProposal {
    uint8 variant;
    address agent;
    string symbol;
    string name;
    bytes data;
  }
  mapping(uint256 => ThreadProposal) private _threads;

  struct ThreadProposalProposal {
    address thread;
    bytes4 selector;
    bytes data;
  }
  mapping(uint256 => ThreadProposalProposal) private _threadProposals;

  // The erc20 is expected to be fully initialized via JS during deployment
  // Given in practice, the InitialFrabric will upgrade to this, there's no reason
  // for this to be here other than testing. While the upgrade should set
  // bond/threadDeployer, KYC should be voted on via governance
  function initialize(
    address _erc20,
    address[] calldata genesis,
    bytes32 genesisMerkle,
    address _bond,
    address _threadDeployer,
    address _kyc
  ) external override initializer {
    __EIP712_init("Frabric Protocol", "1");
    __FrabricDAO_init(_erc20, 2 weeks);

    __Composable_init("Frabric", false);
    version++;
    supportsInterface[type(IFrabric).interfaceId] = true;

    // Simulate a full DAO proposal to add the genesis participants
    emit ParticipantsProposed(_nextProposalID, ParticipantType.Genesis, genesisMerkle);
    emit NewProposal(_nextProposalID, uint16(FrabricProposalType.Participants), address(0), "Genesis Participants");
    emit ProposalStateChanged(_nextProposalID, ProposalState.Active);
    emit ProposalStateChanged(_nextProposalID, ProposalState.Queued);
    emit ProposalStateChanged(_nextProposalID, ProposalState.Executed);
    // Update the proposal ID to ensure a lack of collision with the first actual DAO proposal
    _nextProposalID++;
    // Actually add the genesis participants
    for (uint256 i = 0; i < genesis.length; i++) {
      participant[genesis[i]] = ParticipantType.Genesis;
    }

    bond = _bond;
    threadDeployer = _threadDeployer;

    kyc = _kyc;
    participant[kyc] = ParticipantType.KYC;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() Composable("Frabric") initializer {}

  function canPropose() public view override returns (bool) {
    return uint256(participant[msg.sender]) > uint256(ParticipantType.Removed);
  }

  function proposeParticipants(
    ParticipantType participantType,
    bytes32 participants,
    string calldata info
  ) external override returns (uint256) {
    if (participantType == ParticipantType.Null) {
      // CommonProposalType.ParticipantRemoval should be used
      revert ProposingNullParticipants();
    } else if (participantType == ParticipantType.Genesis) {
      revert ProposingGenesisParticipants();
    }


    if ((participantType == ParticipantType.KYC) || (participantType == ParticipantType.Governor)) {
      // Validate this to be an address if this ParticipantType should only be a single address
      if (bytes32(bytes20(participants)) != participants) {
        revert InvalidAddress(address(bytes20(participants)));
      }

      if (participant[address(bytes20(participants))] != ParticipantType.Null) {
        revert ParticipantAlreadyApproved(address(bytes20(participants)));
      }
    }

    Participants storage pStruct = _participants[_nextProposalID];
    pStruct.pType = participantType;
    pStruct.participants = participants;
    emit ParticipantsProposed(_nextProposalID, participantType, participants);
    return _createProposal(uint16(FrabricProposalType.Participants), info);
  }

  function proposeRemoveBond(
    address _governor,
    bool slash,
    uint256 amount,
    string calldata info
  ) external override returns (uint256) {
    _removeBonds[_nextProposalID] = RemoveBondProposal(_governor, slash, amount);
    if (governor[_governor] < GovernorStatus.Active) {
      // Arguably a misuse as this actually checks they were never an active governor
      // Not that they aren't currently an active governor, which the error name suggests
      // This should be better to handle from an integration perspective however
      revert NotActiveGovernor(_governor, governor[_governor]);
    }
    emit RemoveBondProposed(_nextProposalID, _governor, slash, amount);
    return _createProposal(uint16(FrabricProposalType.RemoveBond), info);
  }

  function proposeThread(
    uint8 variant,
    address agent,
    string calldata name,
    string calldata symbol,
    bytes calldata data,
    string calldata info
  ) external override returns (uint256) {
    if (governor[agent] != GovernorStatus.Active) {
      revert NotActiveGovernor(agent, governor[agent]);
    }
    // Doesn't check for being alphanumeric due to iteration costs
    if ((bytes(name).length < 3) || (bytes(name).length > 50) || (bytes(symbol).length < 2) || (bytes(symbol).length > 5)) {
      revert InvalidName(name, symbol);
    }
    // Validate the data now before creating the proposal
    // ThreadProposal doesn't have this same level of validation yet not only are
    // Threads a far more integral part of the system, ThreadProposal deals with an enum
    // for proposal type. This variant field is a uint256 which has a much larger impact scope
    IThreadDeployer(threadDeployer).validate(variant, data);
    ThreadProposal storage proposal = _threads[_nextProposalID];
    proposal.variant = variant;
    proposal.agent = agent;
    proposal.name = name;
    proposal.symbol = symbol;
    proposal.data = data;
    emit ThreadProposed(_nextProposalID, variant, agent, name, symbol, data);
    return _createProposal(uint16(FrabricProposalType.Thread), info);
  }

  // This does assume the Thread's API meets expectations compiled into the Frabric
  // They can individually change their Frabric, invalidating this entirely, or upgrade their code, potentially breaking specific parts
  // These are both valid behaviors intended to be accessible by Threads
  function proposeThreadProposal(
    address thread,
    uint16 _proposalType,
    bytes calldata data,
    string calldata info
  ) external returns (uint256) {
    // Technically not needed given we check for interface support, yet a healthy check to have
    if (IComposable(thread).contractName() != keccak256("Thread")) {
      revert DifferentContract(IComposable(thread).contractName(), keccak256("Thread"));
    }

    // Lock down the selector to prevent arbitrary calls
    // While data is still arbitrary, it has reduced scope thanks to this, and can only be decoded in expected ways
    // data isn't validated to be technically correct as the UI is trusted to sanity check it
    // and present it accurately for humans to deliberate on
    bytes4 selector;
    if ((_proposalType & commonProposalBit) == commonProposalBit) {
      if (!thread.supportsInterface(type(IFrabricDAO).interfaceId)) {
        revert UnsupportedInterface(thread, type(IFrabricDAO).interfaceId);
      }

      CommonProposalType pType = CommonProposalType(_proposalType ^ commonProposalBit);
      if (pType == CommonProposalType.Paper) {
        selector = IFrabricDAO.proposePaper.selector;
      } else if (pType == CommonProposalType.Upgrade) {
        selector = IFrabricDAO.proposeUpgrade.selector;
      } else if (pType == CommonProposalType.TokenAction) {
        selector = IFrabricDAO.proposeTokenAction.selector;
      } else if (pType == CommonProposalType.ParticipantRemoval) {
        // If a participant should be removed, remove them from the Frabric, not the Thread
        revert ProposingParticipantRemovalOnThread();
      } else {
        revert UnhandledEnumCase("Frabric proposeThreadProposal CommonProposal", _proposalType);
      }
    } else {
      if (!thread.supportsInterface(type(IThread).interfaceId)) {
        revert UnsupportedInterface(thread, type(IThread).interfaceId);
      }

      IThread.ThreadProposalType pType = IThread.ThreadProposalType(_proposalType);
      if (pType == IThread.ThreadProposalType.AgentChange) {
        selector = IThread.proposeAgentChange.selector;
      } else if (pType == IThread.ThreadProposalType.FrabricChange) {
        // Doesn't use UnhandledEnumCase as that suggests a development-level failure to handle cases
        // While that already isn't guaranteed in this function, as _proposalType is user input,
        // it requires invalid input. Technically, FrabricChange is a legitimate enum value
        revert ProposingFrabricChange();
      } else if (pType == IThread.ThreadProposalType.Dissolution) {
        selector = IThread.proposeDissolution.selector;
      } else {
        revert UnhandledEnumCase("Frabric proposeThreadProposal ThreadProposal", _proposalType);
      }
    }

    _threadProposals[_nextProposalID] = ThreadProposalProposal(thread, selector, data);
    emit ThreadProposalProposed(_nextProposalID, thread, _proposalType, info);
    return _createProposal(uint16(FrabricProposalType.ThreadProposal), info);
  }

  function _participantRemoval(address _participant) internal override {
    if (governor[_participant] != GovernorStatus.Null) {
      governor[_participant] = GovernorStatus.Removed;
    }
    participant[_participant] = ParticipantType.Removed;
  }

  function _completeSpecificProposal(uint256 id, uint256 _pType) internal override {
    FrabricProposalType pType = FrabricProposalType(_pType);
    if (pType == FrabricProposalType.Participants) {
      Participants storage participants = _participants[id];

      if (participants.pType == ParticipantType.KYC) {
        address newKYC = address(bytes20(participants.participants));
        // This check also exists in proposeParticipants, yet that doesn't
        // prevent the same participant from being proposed multiple times simultaneously
        // This is an edge case which should never happen, yet handling it means
        // checking here to ensure if they already exist, they're not overwritten
        // While we could error here, we may as well delete the invalid proposal and move on with life
        if (participant[newKYC] != ParticipantType.Null) {
          delete _participants[id];
          return;
        }

        emit KYCChanged(kyc, newKYC);
        participant[kyc] = ParticipantType.Removed;
        kyc = newKYC;
        participant[kyc] = ParticipantType.KYC;
        // Delete for the gas savings
        delete _participants[id];

      } else {
        if (participants.pType == ParticipantType.Governor) {
          if (
            // Simultaneously proposed and became a different participant or approved governor
            (participant[address(bytes20(participants.participants))] != ParticipantType.Null) ||
            // Simultaneously proposed as a governor multiple times BUT solely Unverified
            // Because of that, this isn't actually significant, as they'll be set to Unverified
            // again and that's that. Best to clean up and move on though
            (governor[address(bytes20(participants.participants))] != GovernorStatus.Null)
          ) {
            delete _participants[id];
            return;
          }
          governor[address(bytes20(participants.participants))] = GovernorStatus.Unverified;
        }

        // Set this proposal as having passed so the KYC company can whitelist
        participants.passed = true;
      }

    } else if (pType == FrabricProposalType.RemoveBond) {
      RemoveBondProposal storage remove = _removeBonds[id];
      if (remove.slash) {
        IBond(bond).slash(remove.governor, remove.amount);
      } else {
        IBond(bond).unbond(remove.governor, remove.amount);
      }
      delete _removeBonds[id];

    } else if (pType == FrabricProposalType.Thread) {
      ThreadProposal storage proposal = _threads[id];
      IThreadDeployer(threadDeployer).deploy(
        proposal.variant, proposal.agent, proposal.name, proposal.symbol, proposal.data
      );
      delete _threads[id];

    } else if (pType == FrabricProposalType.ThreadProposal) {
      ThreadProposalProposal storage proposal = _threadProposals[id];
      (bool success, bytes memory data) = proposal.thread.call(
        abi.encodeWithSelector(proposal.selector, proposal.data)
      );
      if (!success) {
        revert ExternalCallFailed(proposal.thread, proposal.selector, data);
      }
      delete _threadProposals[id];
    } else {
      revert UnhandledEnumCase("Frabric _completeSpecificProposal", _pType);
    }
  }

  function approve(
    uint256 id,
    address approving,
    bytes32 kycHash,
    bytes32[] memory proof,
    bytes calldata signature
  ) external override {
    if (approving == address(0)) {
      // Technically, it's an invalid participant, not an invalid address
      revert InvalidAddress(address(0));
    } else if (participant[approving] != ParticipantType.Null) {
      revert ParticipantAlreadyApproved(approving);
    }

    Participants storage participants = _participants[id];
    if (!participants.passed) {
      revert ParticipantsProposalNotPassed(id);
    }

    // Places signer in a variable to make the information available for the error
    // While generally, the errors include an abundance of information with the expectation they'll be caught in a call,
    // and even if they are executed on chain, we don't care about the increased gas costs for the extreme minority,
    // this calculation is extensive enough it's worth the variable (which shouldn't even change gas costs?)
    address signer = ECDSA.recover(
      _hashTypedDataV4(
        keccak256(
          abi.encode(
            keccak256("KYCVerification(address participant,bytes32 kycHash)"),
            approving,
            kycHash
          )
        )
      ),
      signature
    );
    if (signer != kyc) {
      revert InvalidKYCSignature(signer, kyc);
    }

    // Verify the address was actually part of this proposal
    // Directly use the address as a leaf. Since it's a RipeMD-160 hash of a 32-byte value, this shouldn't be an issue
    if (!MerkleProofUpgradeable.verify(proof, participants.participants, bytes32(bytes20(approving)))) {
      revert IncorrectParticipant(approving, participants.participants, proof);
    }

    // Set their status
    participant[approving] = participants.pType;
    if (participants.pType == ParticipantType.Governor) {
      governor[approving] = GovernorStatus.Active;
      // Delete the proposal since it was just them
      delete _participants[id];
    }

    // Whitelist them
    IFrabricERC20(erc20).setWhitelisted(approving, kycHash);

    // We could delete _participants[id] here if we knew how many values were included in the Merkle
    // This gas refund isn't worth the extra variable and tracking
  }
}

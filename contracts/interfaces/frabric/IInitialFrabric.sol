// SPDX-License-Identifier: AGPLv3
pragma solidity >=0.8.9;

import "../dao/IFrabricDAO.sol";

interface IInitialFrabric {
  enum FrabricProposalType {
    Participants
  }

  enum ParticipantType {
    Null,
    // Removed is before any other type to allow using > Removed to check validity
    Removed,
    Genesis
  }

  event ParticipantsProposed(
    uint256 indexed id,
    ParticipantType indexed participantType,
    bytes32 participants
  );

  function participant(address participant) external view returns (ParticipantType);
}

interface IInitialFrabricSum is IFrabricDAOSum, IInitialFrabric {}
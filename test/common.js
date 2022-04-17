const { waffle } = require("hardhat");

module.exports = {
  ParticipantType: {
    Null: 0,
    Removed: 1,
    Genesis: 2,
    KYC: 3,
    Governor: 4,
    Individual: 5,
    Corporation: 6
  },

  snapshot: () => waffle.provider.send("evm_snapshot", []),
  revert: (id) => waffle.provider.send("evm_revert", [id]),

  completeProposal: async (dao, id) => {
    // Advance the clock by the voting period (+ 1 second)
    await waffle.provider.send("evm_increaseTime", [parseInt(await dao.votingPeriod()) + 1]);

    // Queue the proposal
    await dao.queueProposal(id);

    // Advance the clock 48 hours
    await waffle.provider.send("evm_increaseTime", [2 * 24 * 60 * 60 + 1]);

    // Complete it
    await dao.completeProposal(id);
  }
}
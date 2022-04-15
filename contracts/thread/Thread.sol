// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "../interfaces/erc20/IDistributionERC20.sol";
import "../interfaces/erc20/IFrabricERC20.sol";

import "../dao/FrabricDAO.sol";

import "../interfaces/frabric/IBond.sol";
import "../interfaces/frabric/IFrabric.sol";
import "../interfaces/thread/IThread.sol";

contract Thread is FrabricDAO, IThreadInitializable {
  using SafeERC20 for IERC20;
  using ERC165Checker for address;

  uint256 public override upgradesEnabled;

  bytes32 public override descriptor;

  address public override governor;
  address public override frabric;

  // Irremovable ecosystem contracts which hold Thread tokens
  mapping(address => bool) public override irremovable;

  // Private as all this info is available via events
  mapping(uint256 => bytes32) private _descriptors;
  mapping(uint256 => address) private _frabrics;
  mapping(uint256 => address) private _governors;

  struct Dissolution {
    address purchaser;
    address token;
    uint256 price;
  }
  mapping(uint256 => Dissolution) private _dissolutions;

  modifier viableFrabric(address _frabric) {
    // Technically not needed, healthy to have
    if (IComposable(_frabric).contractName() != keccak256("Frabric")) {
      revert DifferentContract(IComposable(_frabric).contractName(), keccak256("Frabric"));
    }

    // Technically, the erc20 of this DAO must implement FrabricWhitelist
    // That is implied by this Frabric implementing IDAO and when this executes,
    // setParentWhitelist is executed, confirming the FrabricWhitelist interface
    // is supported by it
    if (!_frabric.supportsInterface(type(IDAOCore).interfaceId)) {
      revert UnsupportedInterface(_frabric, type(IDAOCore).interfaceId);
    }

    // Converts to IComposable before calling supportsInterface again to save on gas
    // EIP165Checker's supportsInterface function does multiple checks to ensure
    // EIP165 validity. Since we've already performed these, now we can safely use
    if (!IComposable(_frabric).supportsInterface(type(IFrabricCore).interfaceId)) {
      revert UnsupportedInterface(_frabric, type(IFrabricCore).interfaceId);
    }

    _;
  }

  function _setFrabric(address _frabric) private viableFrabric(_frabric) {
    emit FrabricChanged(frabric, _frabric);
    frabric = _frabric;
    // Update the parent whitelist as well, if we're not still initializing
    // If we are, the this erc20 hasn't had init called yet, and the ThreadDeployer
    // will set the parentWhitelist when it calls init
    if (IFrabricWhitelist(erc20).parentWhitelist() != address(0)) {
      IFrabricERC20(erc20).setParentWhitelist(IDAO(frabric).erc20());
    }
  }

  modifier viableGovernor(address _governor) {
    if (IFrabricCore(frabric).governor(_governor) != IFrabricCore.GovernorStatus.Active) {
      revert NotActiveGovernor(_governor, IFrabricCore(frabric).governor(_governor));
    }

    _;
  }

  function _setGovernor(address _governor) private viableGovernor(_governor) {
    // If we're not being initialized, have the new governor trigger this to signify consent
    if ((governor != address(0)) && (msg.sender != _governor)) {
      revert NotGovernor(msg.sender, _governor);
    }

    emit GovernorChanged(governor, _governor);
    governor = _governor;
  }

  function initialize(
    string calldata name,
    address _erc20,
    bytes32 _descriptor,
    address _frabric,
    address _governor,
    address[] calldata _irremovable
  ) external override initializer {
    // The Frabric uses a 2 week voting period. If it wants to upgrade every Thread on the Frabric's code,
    // then it will be able to push an update in 2 weeks. If a Thread sees the new code and wants out,
    // it needs a shorter window in order to explicitly upgrade to the existing code to prevent Frabric upgrades
    __FrabricDAO_init(string(abi.encodePacked("Thread: ", name)), _erc20, 1 weeks, 10);

    __Composable_init("Thread", false);
    supportsInterface[type(IThread).interfaceId] = true;

    descriptor = _descriptor;
    _setFrabric(_frabric);
    _setGovernor(_governor);

    for (uint256 i = 0; i < _irremovable.length; i++) {
      irremovable[_irremovable[i]] = true;
    }
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() Composable("Thread") initializer {}

  // Allows proposing even when paused so TokenActions can be issued to recover funds
  // from this DAO. Also theoretically enables proposing an Upgrade to undo the pause
  // if that's desired for whatever reason
  function canPropose() public view override(DAO, IDAOCore) returns (bool) {
    return (
      // Whitelisted token holder
      (
        IWhitelist(erc20).whitelisted(msg.sender) &&
        (IERC20(erc20).balanceOf(msg.sender) != 0)
      ) ||
      // Governor
      (msg.sender == address(governor)) ||
      // Frabric
      (msg.sender == address(frabric))
    );
  }

  function _canProposeUpgrade(
    address beacon,
    address instance,
    address impl
  ) internal view override returns (bool) {
    return (
      // If upgrades are enabled, all good
      (block.timestamp >= upgradesEnabled) ||
      // Upgrades to the current impl/release channels are always allowed
      // This prevents the Frabric from forcing an update onto Threads and allows
      // switching between versions presumably published by the Frabric
      (impl == IFrabricBeacon(beacon).implementation(instance)) ||
      (uint160(impl) <= IFrabricBeacon(beacon).releaseChannels())
    );
  }

  function _canProposeRemoval(address participant) internal view override returns (bool) {
    return !irremovable[participant];
  }

  function proposeDescriptorChange(
    bytes32 _descriptor,
    bytes32 info
  ) external override returns (uint256 id) {
    id = _createProposal(uint16(ThreadProposalType.DescriptorChange), false, info);
    _descriptors[id] = _descriptor;
    emit DescriptorChangeProposed(id, _descriptor);
  }

  function proposeFrabricChange(
    address _frabric,
    address _governor,
    bytes32 info
  ) external override viableFrabric(_frabric) returns (uint256 id) {
    id = _createProposal(uint16(ThreadProposalType.FrabricChange), true, info);
    // This could use a struct yet this is straightforward and simple
    _frabrics[id] = _frabric;
    _governors[id] = _governor;
    emit FrabricChangeProposed(id, _frabric, _governor);
  }

  function proposeGovernorChange(
    address _governor,
    bytes32 info
  ) external override viableGovernor(_governor) returns (uint256 id) {
    id = _createProposal(uint16(ThreadProposalType.GovernorChange), true, info);
    _governors[id] = _governor;
    emit GovernorChangeProposed(id, _governor);
  }

  // Leave the ecosystem, setting a new Frabric and governor, while also enabling upgrades
  // The Frabric can already be changed and the code locked down to the existing version without this
  // This explicitly enables upgrades, and with that level of self-determination which the Frabric
  // will no longer be able to be responsible for, forces them to change their Frabric
  // Used to solely be called proposeEnablingUpgrades, now this much more verbose name
  // to communicate its effects in full
  function proposeEcosystemLeaveWithUpgrades(
    address _frabric,
    address _governor,
    bytes32 info
  ) external override returns (uint256 id) {
    // A Thread could do proposeFrabricChange, to change their Frabric,
    // and then proposeEcosystemLeaveWithUpgrades to enable upgrades while claiming
    // the Frabric as theirs

    // With upgrades, any checks we add would be defeated immediately anyways,
    // so this basic check (forcing at some point this Thread specifies a different Frabric) +
    // the name "EcosystemLeave" is judged as acceptable
    if (frabric == _frabric) {
      // This is redundant as hell given they're the same yet should help understand
      // what this error means
      revert NotLeaving(frabric, _frabric);
    }

    id = _createProposal(uint16(ThreadProposalType.EcosystemLeaveWithUpgrades), true, info);
    _frabrics[id] = _frabric;
    _governors[id] = _governor;
    emit EcosystemLeaveWithUpgradesProposed(id, _frabric, _governor);
  }

  function proposeDissolution(
    address token,
    uint256 price,
    bytes32 info
  ) external override returns (uint256 id) {
    if (price == 0) {
      revert ZeroPrice();
    }

    id = _createProposal(uint16(ThreadProposalType.Dissolution), true, info);
    _dissolutions[id] = Dissolution(msg.sender, token, price);
    emit DissolutionProposed(id, msg.sender, token, price);
  }

  function _completeSpecificProposal(uint256 id, uint256 _pType) internal override {
    ThreadProposalType pType = ThreadProposalType(_pType);
    if (pType == ThreadProposalType.DescriptorChange) {
      emit DescriptorChanged(descriptor, _descriptors[id]);
      descriptor = _descriptors[id];
      delete _descriptors[id];

    } else if (pType == ThreadProposalType.FrabricChange) {
      _setFrabric(_frabrics[id]);
      delete _frabrics[id];
      _setGovernor(_governors[id]);
      delete _governors[id];

    } else if (pType == ThreadProposalType.GovernorChange) {
      _setGovernor(_governors[id]);
      delete _governors[id];

    } else if (pType == ThreadProposalType.EcosystemLeaveWithUpgrades) {
      // Ecosystem leave
      emit LeftEcosystemWithUpgrades(id);
      _setFrabric(_frabrics[id]);
      delete _frabrics[id];
      _setGovernor(_governors[id]);
      delete _governors[id];

      // Enable upgrades after the Frabric's voting period + 1 week

      // There is an attack where a Thread upgrades and claws back timelocked tokens
      // Once this proposal passes, the Frabric can immediately void its timelock,
      // yet it'll need 2 weeks to pass a proposal on what to do with them
      // The added 1 week is because neither selling on the token's DEX nor an auction
      // would complete instantly, so this gives a buffer for it to execute

      // While the Frabric also needs time to decide what to do and can't be expected
      // to be perfect with time, enabling upgrades only enables Upgrade proposals to be created
      // That means there's an additional delay of the Thread's voting period (1 week)
      // while the actual Upgrade proposal occurs, granting that time
      upgradesEnabled = block.timestamp + IDAOCore(frabric).votingPeriod() + (1 weeks);

    } else if (pType == ThreadProposalType.Dissolution) {
      // Prevent the Thread from being locked up in a Dissolution the governor won't honor for whatever reason
      // This will issue payment and then the governor will be obligated to transfer property or have bond slashed
      // Not calling complete on a passed Dissolution may also be grounds for a bond slash
      // The intent is to allow the governor to not listen to impropriety with the Frabric as arbitrator
      // See the Frabric's community policies for more information on process
      if (msg.sender != governor) {
        revert NotGovernor(msg.sender, governor);
      }

      Dissolution storage dissolution = _dissolutions[id];
      IERC20(dissolution.token).safeTransferFrom(dissolution.purchaser, address(this), dissolution.price);
      IFrabricERC20(erc20).pause();
      IERC20(dissolution.token).safeIncreaseAllowance(erc20, dissolution.price);
      IFrabricERC20(erc20).distribute(dissolution.token, dissolution.price);
      emit Dissolved(id);
      delete _dissolutions[id];

    } else {
      revert UnhandledEnumCase("Thread _completeSpecificProposal", _pType);
    }
  }
}

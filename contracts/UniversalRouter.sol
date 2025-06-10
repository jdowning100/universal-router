// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

// Command implementations
import {Dispatcher} from './base/Dispatcher.sol';
import {RouterParameters} from './types/RouterParameters.sol';
import {PaymentsImmutables, PaymentsParameters} from './modules/PaymentsImmutables.sol';
import {UniswapImmutables, UniswapParameters} from './modules/uniswap/UniswapImmutables.sol';
import {V4SwapRouter} from './modules/uniswap/v4/V4SwapRouter.sol';
import {Commands} from './libraries/Commands.sol';
import {IUniversalRouter} from './interfaces/IUniversalRouter.sol';
import {MigratorImmutables, MigratorParameters} from './modules/MigratorImmutables.sol';

contract UniversalRouter is IUniversalRouter, Dispatcher {
    mapping(bytes32 => uint64) public commitsToRevealHeight;
    uint256 public constant COMMIT_REVEAL_HEIGHT = 3;

    constructor(RouterParameters memory params)
        UniswapImmutables(
            UniswapParameters(params.v2Factory, params.v3Factory, params.pairInitCodeHash, params.poolInitCodeHash)
        )
        V4SwapRouter(params.v4PoolManager)
        PaymentsImmutables(PaymentsParameters(params.permit2, params.weth9))
        MigratorImmutables(MigratorParameters(params.v3NFTPositionManager, params.v4PositionManager))
    {}

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert TransactionDeadlinePassed();
        _;
    }

    /// @notice To receive ETH from WETH
    receive() external payable {
        if (msg.sender != address(WETH9) && msg.sender != address(poolManager)) revert InvalidEthSender();
    }

    /// @inheritdoc IUniversalRouter
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline, uint256 entropy)
        external
        payable
        override
        checkDeadline(deadline)
    {
        execute(commands, inputs, entropy);
    }

    /// @notice Executes encoded commands along with provided inputs.
    /// @param commands A set of concatenated commands, each 1 byte in length
    /// @param inputs An array of byte strings containing abi encoded inputs for each command
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 entropy) public payable isNotLocked {
        bool success;
        bytes memory output;
        uint256 numCommands = commands.length;
        if (inputs.length != numCommands) revert LengthMismatch();
        
        reveal(commands, inputs, entropy);

        // loop through all given commands, execute them and pass along outputs as defined
        for (uint256 commandIndex = 0; commandIndex < numCommands; commandIndex++) {
            bytes1 command = commands[commandIndex];

            bytes calldata input = inputs[commandIndex];

            (success, output) = dispatch(command, input);

            if (!success && successRequired(command)) {
                revert ExecutionFailed({commandIndex: commandIndex, message: output});
            }
        }
    }

    // This function is used only for the EXECUTE_SUB_PLAN command and does not require reveal because the reveal is done in the initial plan
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable override isNotLocked {
        bool success;
        bytes memory output;
        uint256 numCommands = commands.length;
        if (inputs.length != numCommands) revert LengthMismatch();
        require(msg.sender == address(this), "Only callable by self");
        // loop through all given commands, execute them and pass along outputs as defined
        for (uint256 commandIndex = 0; commandIndex < numCommands; commandIndex++) {
            bytes1 command = commands[commandIndex];

            bytes calldata input = inputs[commandIndex];

            (success, output) = dispatch(command, input);

            if (!success && successRequired(command)) {
                revert ExecutionFailed({commandIndex: commandIndex, message: output});
            }
        }
    }

    function successRequired(bytes1 command) internal pure returns (bool) {
        return command & Commands.FLAG_ALLOW_REVERT == 0;
    }

    function commit(bytes32 h) external override {
        require(commitsToRevealHeight[h]==0, "Duplicate commit");
        commitsToRevealHeight[h] = uint64(block.number + COMMIT_REVEAL_HEIGHT);
    }

    // reveal() checks the validity and timing of the commitment
    // tx.origin is used to ensure that only the intended caller can reveal the commitment
    function reveal(bytes calldata commands, bytes[] calldata inputs, uint256 entropy) internal {
        bytes32 h = keccak256(abi.encode(commands, inputs, entropy, tx.origin));
        uint64 valid = commitsToRevealHeight[h];
        require(valid !=0 && block.number >= valid, "Not ready");
        delete commitsToRevealHeight[h];
    }
}

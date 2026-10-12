// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {ScoopToken} from "../src/ScoopToken.sol";

/// @title DeployScoop
/// @notice Manual deployment helper for environments other than the IMD launch. The launch itself
/// deploys `ScoopToken` from its built bytecode through the factory and needs no script.
/// @dev `deploy()` holds all the logic and is what the tests call. `run()` only wraps it in a
/// broadcast; it reads no environment variables, so the signer comes from the forge command line
/// (`--private-key`, `--ledger`, `--account`, ...). The token has no constructor arguments, so
/// there is no configuration to pass.
contract DeployScoop is Script {
    /// @notice Deploys the token. The caller of this function (the broadcaster, in `run()`)
    /// receives the entire supply.
    function deploy() public returns (ScoopToken token) {
        token = new ScoopToken();
    }

    function run() external returns (ScoopToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
